import Foundation
import HomeAssistantCodec
import LightCore

/// Errors of one WebSocket session. The provider maps them to `LightCoreError`.
public enum HAClientError: Error, Sendable, Equatable, LocalizedError {
    /// `auth_invalid`: the token was rejected (expired, revoked, mistyped).
    case authInvalid(String?)
    /// A `result` with `success: false`.
    case commandFailed(HAErrorInfo)
    case connectionClosed
    case timeout
    /// The server did not speak the expected protocol (e.g. no `auth_required`: wrong URL/port).
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .authInvalid(let m): "Home Assistant rejected the access token\(m.map { " (\($0))" } ?? "")"
        case .commandFailed(let e): "Home Assistant error \(e.code): \(e.message)"
        case .connectionClosed: "Connection to Home Assistant closed"
        case .timeout: "Home Assistant did not answer in time"
        case .unexpected(let s): "Unexpected Home Assistant response: \(s)"
        }
    }
}

/// One authenticated WebSocket session: `auth` handshake, id correlation of commands and
/// results, event subscriptions, pings. A closed client is not reused; the provider opens a
/// new one (with backoff).
actor HAClient {
    private let connection: any HAWebSocketConnection
    private let log = Log(package: "homeassistantkit", category: "websocket")
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<HAJSONValue, any Error>] = [:]
    private var subscriptions: [Int: AsyncStream<HAEvent>.Continuation] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var readerTask: Task<Void, Never>?
    private(set) var isClosed = false
    private(set) var closeReason: (any Error)?
    /// `ha_version` from `auth_required`/`auth_ok`.
    nonisolated let haVersion: String?

    private init(connection: any HAWebSocketConnection, haVersion: String?) {
        self.connection = connection
        self.haVersion = haVersion
    }

    // MARK: Connect

    /// Reads `auth_required` and returns the HA version, then closes. Used to validate a URL
    /// before asking for a token.
    static func probe(transport: any HAWebSocketTransport, url: URL, timeout: Duration) async throws -> String? {
        let connection = try await transport.connect(to: url)
        defer { connection.close() }
        let first = try await receiveMessage(connection, timeout: timeout)
        guard case .authRequired(let version) = first else {
            throw HAClientError.unexpected("expected auth_required")
        }
        return version
    }

    /// Opens a WebSocket, authenticates and starts the reader.
    static func connect(
        transport: any HAWebSocketTransport, url: URL, accessToken: String, timeout: Duration
    ) async throws -> HAClient {
        let connection = try await transport.connect(to: url)
        do {
            var version: String?
            switch try await receiveMessage(connection, timeout: timeout) {
            case .authRequired(let v): version = v
            // Some proxies/older cores skip straight to auth_ok when already authenticated.
            case .authOK(let v): return HAClient.started(connection, version: v)
            default: throw HAClientError.unexpected("expected auth_required")
            }
            try await connection.send(try HAAuthMessage.auth(accessToken: accessToken).jsonString())
            switch try await receiveMessage(connection, timeout: timeout) {
            case .authOK(let v): return HAClient.started(connection, version: v ?? version)
            case .authInvalid(let message): throw HAClientError.authInvalid(message)
            default: throw HAClientError.unexpected("expected auth_ok")
            }
        } catch {
            connection.close()
            throw error
        }
    }

    private static func started(_ connection: any HAWebSocketConnection, version: String?) -> HAClient {
        let client = HAClient(connection: connection, haVersion: version)
        Task { await client.startReader() }
        return client
    }

    /// The next frame's first message, or `timeout`.
    private static func receiveMessage(_ connection: any HAWebSocketConnection, timeout: Duration) async throws -> HAIncomingMessage {
        let text = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await connection.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                connection.close()
                throw HAClientError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard let first = try HAIncomingMessage.parse(text).first else { throw HAClientError.unexpected("empty frame") }
        return first
    }

    // MARK: Reader

    private func startReader() {
        guard readerTask == nil, !isClosed else { return }
        let connection = connection
        readerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let text = try await connection.receive()
                    guard let self else { return }
                    await self.handle(text)
                }
            } catch {
                await self?.shutdown(error)
            }
        }
    }

    private func handle(_ text: String) {
        let messages: [HAIncomingMessage]
        do {
            messages = try HAIncomingMessage.parse(text)
        } catch {
            log.error("Unparseable frame (\(text.count) bytes)")
            return
        }
        for message in messages {
            switch message {
            case .result(let id, let success, let result, let error):
                guard let continuation = pending.removeValue(forKey: id) else { continue }
                if success {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: HAClientError.commandFailed(error ?? HAErrorInfo(code: HAErrorInfo.unknownError, message: "")))
                }
            case .pong(let id):
                pending.removeValue(forKey: id)?.resume(returning: .null)
            case .event(let id, let event):
                subscriptions[id]?.yield(event)
            case .authInvalid(let message):
                shutdown(HAClientError.authInvalid(message))
            case .authRequired, .authOK, .unknown:
                break
            }
        }
    }

    // MARK: Commands

    /// Sends a command and waits for its `result` (or `pong`).
    func command(_ command: HACommand, timeout: Duration) async throws -> HAJSONValue {
        let (_, value) = try await send(command, timeout: timeout)
        return value
    }

    private func send(_ command: HACommand, timeout: Duration) async throws -> (id: Int, result: HAJSONValue) {
        if isClosed { throw closeReason ?? HAClientError.connectionClosed }
        let id = nextID
        nextID += 1
        let text = try command.message(id: id).jsonString()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id, HAClientError.timeout)
        }
        defer { timeoutTask.cancel() }
        let value: HAJSONValue = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let connection = connection
            Task { [weak self] in
                do {
                    try await connection.send(text)
                } catch {
                    await self?.fail(id, error)
                }
            }
        }
        return (id, value)
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// `subscribe_events`; the stream finishes when the connection closes.
    func subscribe(eventType: String?, timeout: Duration) async throws -> AsyncStream<HAEvent> {
        let (stream, continuation) = AsyncStream<HAEvent>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        // Register before the result arrives: HA may deliver the first event right after it.
        let id = nextID
        subscriptions[id] = continuation
        do {
            let (sentID, _) = try await send(.subscribeEvents(eventType: eventType), timeout: timeout)
            assert(sentID == id)
        } catch {
            subscriptions.removeValue(forKey: id)?.finish()
            throw error
        }
        return stream
    }

    /// Round trip `ping` -> `pong`.
    func ping(timeout: Duration) async throws {
        _ = try await command(.ping, timeout: timeout)
    }

    // MARK: Close

    /// Waits until the connection is closed (by either side).
    func waitUntilClosed() async {
        if isClosed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func close() {
        shutdown(HAClientError.connectionClosed)
    }

    private func shutdown(_ reason: any Error) {
        guard !isClosed else { return }
        isClosed = true
        closeReason = reason
        connection.close()
        readerTask?.cancel()
        for continuation in pending.values { continuation.resume(throwing: reason) }
        pending.removeAll()
        for continuation in subscriptions.values { continuation.finish() }
        subscriptions.removeAll()
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters.removeAll()
    }
}
