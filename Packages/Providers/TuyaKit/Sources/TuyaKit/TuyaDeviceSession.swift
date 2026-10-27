import Foundation
import LightCore
import NetKit
import TuyaCodec

/// Events a session reports to the provider.
enum TuyaSessionEvent: Sendable {
    case online(deviceId: String, Bool)
    case dps(deviceId: String, [String: TuyaJSON])
    /// The device turned out to be a device22 type; persist it.
    case deviceType(deviceId: String, TuyaDeviceType)
    /// Handshake/key problems worth surfacing (never contains the key).
    case problem(deviceId: String, String)
}

/// One persistent TCP 6668 session per device. Tuya devices accept a **single** local client, so the
/// provider never opens a second connection to a device while this one runs.
///
/// connect -> (3.4/3.5) session-key negotiation -> `DP_QUERY` -> online -> `HEART_BEAT` every 10 s;
/// status pushes (`STATUS`, cmd 8) arrive whenever the light changes. Three unanswered heartbeats or a
/// read error reset the connection, which then reconnects with exponential backoff.
actor TuyaDeviceSession {
    struct Settings: Sendable {
        var port: UInt16
        var connectTimeout: Duration
        var responseTimeout: Duration
        var heartbeatInterval: Duration
        var maxMissedHeartbeats: Int
        var backoff: ExponentialBackoff

        var link: TuyaLink.Settings {
            TuyaLink.Settings(port: port, connectTimeout: connectTimeout, responseTimeout: responseTimeout)
        }
    }

    enum Failure: Error, Sendable, Equatable {
        case heartbeatTimeout
        case connectionClosed
    }

    let deviceId: String
    private var record: TuyaDeviceRecord
    private let connector: any TuyaTCPConnector
    private let settings: Settings
    private let events: AsyncStream<TuyaSessionEvent>.Continuation
    private let log = Log(package: "tuyakit", category: "session")

    private(set) var isOnline = false
    private var runTask: Task<Void, Never>?
    private var link: TuyaLink?
    private var missedHeartbeats = 0

    init(record: TuyaDeviceRecord, connector: any TuyaTCPConnector, settings: Settings,
         events: AsyncStream<TuyaSessionEvent>.Continuation) {
        deviceId = record.id
        self.record = record
        self.connector = connector
        self.settings = settings
        self.events = events
    }

    var host: String? { record.host }
    var isRunning: Bool { runTask != nil }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    func stop() async {
        runTask?.cancel()
        runTask = nil
        if let link { await link.close() }
        link = nil
        setOnline(false)
    }

    /// New IP from discovery. Reconnects immediately if currently offline.
    func updateHost(_ newHost: String) async {
        guard newHost != record.host else { return }
        record.host = newHost
        if runTask != nil && !isOnline {
            await stop()
            start()
        }
    }

    /// Sends one `CONTROL` with `dps`. Throws `LightCoreError.unreachable` when not connected.
    func send(_ dps: [String: TuyaJSON]) async throws {
        guard isOnline, let link else { throw LightCoreError.unreachable("Tuya light \(record.name) is not connected") }
        do {
            try await link.send(.control(dps))
        } catch {
            await link.close()
            throw LightCoreError.transport("Tuya send failed: \(error.localizedDescription)")
        }
    }

    /// Asks for a full status (the answer arrives as an event).
    func refresh() async {
        guard isOnline, let link else { return }
        try? await link.send(.dpQuery)
    }

    // MARK: - Run loop

    private func runLoop() async {
        var backoff = settings.backoff
        while !Task.isCancelled {
            if let host = record.host {
                do {
                    try await runConnection(host: host, backoff: &backoff)
                } catch is CancellationError {
                    // stopping
                } catch {
                    log.info("session \(deviceId) ended: \(error)")
                    if case TuyaLink.Failure.handshake(let detail) = error {
                        events.yield(.problem(deviceId: deviceId, "Handshake failed (wrong local key?): \(detail)"))
                    }
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
        let codec = try TuyaSessionCodec(version: record.version, deviceId: record.id, localKey: record.keyBytes,
                                         deviceType: record.deviceType)
        let link = try await TuyaLink.open(host: host, codec: codec, connector: connector, settings: settings.link)
        self.link = link
        do {
            try await serve(link, backoff: &backoff)
        } catch {
            await closeLink(link)
            throw error
        }
        await closeLink(link)
    }

    /// Closes before returning so a reconnect never overlaps the old connection (one client per device).
    private func closeLink(_ link: TuyaLink) async {
        await link.close()
        if self.link === link { self.link = nil }
    }

    private func serve(_ link: TuyaLink, backoff: inout ExponentialBackoff) async throws {
        let dps = try await link.queryStatus(timeout: settings.responseTimeout)
        let type = await link.deviceType
        if type != record.deviceType {
            record.deviceType = type
            events.yield(.deviceType(deviceId: deviceId, type))
        }
        backoff.reset()
        missedHeartbeats = 0
        setOnline(true)
        if !dps.isEmpty { events.yield(.dps(deviceId: deviceId, dps)) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await response in link.responses {
                    guard let self else { return }
                    await self.handle(response)
                }
                throw Failure.connectionClosed
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.settings.heartbeatInterval else { return }
                    try await Task.sleep(for: interval)
                    try await self?.heartbeat(on: link)
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func heartbeat(on link: TuyaLink) async throws {
        if missedHeartbeats >= settings.maxMissedHeartbeats { throw Failure.heartbeatTimeout }
        missedHeartbeats += 1
        try await link.send(.heartbeat)
    }

    private func handle(_ response: TuyaResponse) {
        missedHeartbeats = 0 // any frame counts as alive
        if let dps = response.dps, !dps.isEmpty {
            events.yield(.dps(deviceId: deviceId, dps))
        }
    }

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        events.yield(.online(deviceId: deviceId, online))
    }
}
