import AiDotCodec
import Foundation
import LightCore
import NetKit

/// Events a session reports to the provider.
enum AiDotSessionEvent: Sendable {
    case online(deviceId: String, Bool)
    case message(deviceId: String, AiDotDeviceMessage)
}

/// One persistent TCP 10000 session per device (python-aidot `DeviceClient`):
/// connect -> `loginReq` -> `ack.code == 200` -> `getDevAttrReq` -> keepalive every 30 s
/// (`getDevAttrReq` every 10 s for `lk.WIFI-RGBWLight-D0006`); 3 unanswered keepalives or any
/// read error reset the connection; reconnect with exponential backoff.
actor AiDotDeviceSession {
    struct Settings: Sendable {
        var port: UInt16
        var connectTimeout: Duration
        var loginTimeout: Duration
        var pingInterval: Duration
        var firstGenerationPingInterval: Duration
        var maxMissedPings: Int
        var backoff: ExponentialBackoff
    }

    enum Failure: Error, Sendable, Equatable {
        case loginRejected(Int?)
        case keepaliveTimeout
        case connectionClosed
    }

    let deviceId: String
    private let userId: String
    private let devicePassword: String?
    private let simpleVersion: String?
    private let isFirstGeneration: Bool
    private let codec: AiDotSessionCodec
    private let connector: any AiDotTCPConnector
    private let settings: Settings
    private let events: AsyncStream<AiDotSessionEvent>.Continuation
    private let log = Log(package: "aidotkit", category: "session")

    private(set) var host: String?
    private(set) var isOnline = false
    private var runTask: Task<Void, Never>?
    private var connection: (any AiDotTCPConnection)?
    private var decoder = AiDotFrameDecoder()
    private var counters = AiDotSessionCounters()
    private var missedPings = 0
    private var loginAttempt = 0
    private var awaitingLogin = false
    private var loginGate: OnceGate<AiDotDeviceMessage>?

    init(record: AiDotDeviceRecord, aesKey: String, userId: String, host: String?, connector: any AiDotTCPConnector,
         settings: Settings, events: AsyncStream<AiDotSessionEvent>.Continuation) {
        deviceId = record.id
        self.userId = userId
        devicePassword = record.password
        simpleVersion = record.simpleVersion
        isFirstGeneration = record.isFirstGeneration
        codec = AiDotSessionCodec(aesKey: aesKey)
        self.connector = connector
        self.settings = settings
        self.events = events
        self.host = host
    }

    var isRunning: Bool { runTask != nil }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        connection?.close()
        connection = nil
        setOnline(false)
    }

    /// New IP from discovery. Reconnects immediately if currently offline.
    func updateHost(_ newHost: String) {
        guard newHost != host else { return }
        host = newHost
        if runTask != nil && !isOnline {
            stop()
            start()
        }
    }

    /// Sends one `setDevAttrReq`. Throws `LightCoreError.unreachable` when not logged in.
    func send(_ attributes: AiDotAttributes) async throws {
        guard isOnline, let connection else { throw LightCoreError.unreachable("AiDot light \(deviceId) is not connected") }
        let request = AiDotMessages.setDevAttrRequest(
            userId: userId, deviceId: deviceId, devicePassword: devicePassword, ascNumber: counters.ascNumber,
            attributes: attributes, seq: counters.nextActionSeq(), simpleVersion: simpleVersion,
            tst: AiDotTimestamp.milliseconds(Date()))
        do {
            try await connection.send(codec.frame(request))
        } catch {
            connection.close()
            throw LightCoreError.transport("AiDot send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Run loop

    private func runLoop() async {
        var backoff = settings.backoff
        while !Task.isCancelled {
            if let host {
                do {
                    try await runConnection(host: host, backoff: &backoff)
                } catch is CancellationError {
                    // stopping
                } catch {
                    log.info("session \(deviceId) ended: \(error)")
                }
                setOnline(false)
            }
            if Task.isCancelled { break }
            do {
                try await Task.sleep(for: backoff.nextDelay())
            } catch {
                break
            }
        }
    }

    private func runConnection(host: String, backoff: inout ExponentialBackoff) async throws {
        let conn = try await connector.connect(host: host, port: settings.port, timeout: settings.connectTimeout)
        connection = conn
        decoder.reset()
        counters = AiDotSessionCounters()
        missedPings = 0
        defer {
            conn.close()
            connection = nil
            awaitingLogin = false
            loginGate?.resume(.failure(Failure.connectionClosed))
            loginGate = nil
        }

        let reader = Task { [weak self] in
            do {
                for try await chunk in conn.incoming {
                    guard let self else { return }
                    try await self.received(chunk)
                }
            } catch {
                await self?.logReadError(error)
            }
        }
        defer { reader.cancel() }

        // Login.
        let gate = OnceGate<AiDotDeviceMessage>()
        loginGate = gate
        awaitingLogin = true
        let login = AiDotMessages.loginRequest(
            seq: AiDotMessages.loginSeq(milliseconds: AiDotTimestamp.milliseconds(Date()), attempt: loginAttempt),
            userId: userId, deviceId: deviceId, devicePassword: devicePassword,
            timestamp: AiDotTimestamp.string(from: Date()))
        loginAttempt += 1
        try await conn.send(codec.frame(login))
        let ack = try await gate.wait(timeout: settings.loginTimeout)
        loginGate = nil
        guard ack.ackCode == 200 else {
            // Wrong account (not the owner), stale device password, or wrong key.
            throw Failure.loginRejected(ack.ackCode)
        }
        counters.loggedIn(deviceAscNumber: ack.ascNumber)
        backoff.reset()
        setOnline(true)
        try await sendGetAttributes(on: conn)

        // Keepalive until the reader ends or pings go unanswered.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Cancellation (keepalive failure, stop) must also end the reader, or the group
                // would wait for it forever.
                await withTaskCancellationHandler {
                    await reader.value
                } onCancel: {
                    reader.cancel()
                    conn.close()
                }
                throw Failure.connectionClosed
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try await self.keepalive(on: conn)
                    try await Task.sleep(for: self.keepaliveInterval)
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    nonisolated var keepaliveInterval: Duration {
        isFirstGeneration ? settings.firstGenerationPingInterval : settings.pingInterval
    }

    private func keepalive(on conn: any AiDotTCPConnection) async throws {
        if missedPings >= settings.maxMissedPings { throw Failure.keepaliveTimeout }
        missedPings += 1
        if isFirstGeneration {
            try await sendGetAttributes(on: conn)
        } else {
            try await conn.send(codec.frame(AiDotMessages.pingRequest, type: .ping))
        }
    }

    private func sendGetAttributes(on conn: any AiDotTCPConnection) async throws {
        let request = AiDotMessages.getDevAttrRequest(
            userId: userId, deviceId: deviceId, devicePassword: devicePassword, ascNumber: counters.ascNumber,
            properties: isFirstGeneration ? AiDotConstants.firstGenerationSyncProperties : [],
            seq: counters.nextActionSeq(), simpleVersion: simpleVersion, tst: AiDotTimestamp.milliseconds(Date()))
        try await conn.send(codec.frame(request))
    }

    private func received(_ chunk: Data) throws {
        for frame in try decoder.append(chunk) {
            missedPings = 0 // any data counts as alive (python resets ping_count on every header)
            guard let message = try? codec.message(from: frame) else {
                log.error("session \(deviceId): undecryptable frame (\(frame.body.count) bytes)")
                continue
            }
            if awaitingLogin {
                awaitingLogin = false
                loginGate?.resume(.success(message))
                continue
            }
            counters.observe(message)
            if message.isPing { continue }
            if message.attributes != nil { events.yield(.message(deviceId: deviceId, message)) }
        }
    }

    private func logReadError(_ error: any Error) {
        log.info("session \(deviceId) read error: \(error)")
    }

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        events.yield(.online(deviceId: deviceId, online))
    }
}
