import Foundation
import LightCore
import NetKit
import YeelightCodec

/// A persistent JSON-RPC session with one device: numbers requests, matches replies by `id`,
/// forwards `props` notifications, and (with `keepAlive`) reconnects with exponential backoff after
/// the connection drops.
///
/// Yeelight quirk (HA docs): after a dropped connection the first command may be ignored, so a
/// request that times out on a freshly opened connection is retried once.
public actor YeelightSession {
    public enum Event: Sendable, Equatable {
        /// A connection was established (first connect or reconnect).
        case connected
        /// The connection closed or failed.
        case disconnected(YeelightTransportError)
        /// `props` notification parameters.
        case properties([String: YeelightValue])
    }

    public struct Options: Sendable {
        public var connectTimeout: Duration
        public var requestTimeout: Duration
        /// Reconnect automatically after a drop (persistent session) instead of on next request.
        public var keepAlive: Bool
        public var backoff: ExponentialBackoff

        public init(
            connectTimeout: Duration = .seconds(3),
            requestTimeout: Duration = .seconds(3),
            keepAlive: Bool = true,
            backoff: ExponentialBackoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2)
        ) {
            self.connectTimeout = connectTimeout
            self.requestTimeout = requestTimeout
            self.keepAlive = keepAlive
            self.backoff = backoff
        }
    }

    public nonisolated let host: String
    public nonisolated let port: UInt16
    private let connector: any YeelightConnector
    private let options: Options
    private let onEvent: @Sendable (Event) async -> Void
    private let log = Log(package: "yeelightkit", category: "session")

    private var connection: (any YeelightConnection)?
    private var connectTask: Task<any YeelightConnection, any Error>?
    private var readTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    private var freshConnection = false
    private var pending: [Int: CheckedContinuation<[YeelightValue], any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextID = 1
    private var isClosed = false
    private var backoff: ExponentialBackoff

    public init(
        host: String,
        port: UInt16 = YeelightProtocol.controlPort,
        connector: any YeelightConnector,
        options: Options = Options(),
        onEvent: @escaping @Sendable (Event) async -> Void = { _ in }
    ) {
        self.host = host
        self.port = port
        self.connector = connector
        self.options = options
        self.onEvent = onEvent
        self.backoff = options.backoff
    }

    public var isConnected: Bool { connection != nil }

    /// Sends `call` and waits for its reply. Throws `YeelightRPCError` for device errors and
    /// `YeelightTransportError` for connection problems.
    @discardableResult
    public func perform(_ call: YeelightCall) async throws -> [YeelightValue] {
        do {
            return try await attempt(call)
        } catch YeelightTransportError.timedOut where lastAttemptWasFresh {
            log.debug("\(host): first command after (re)connect timed out; retrying once")
            return try await attempt(call)
        }
    }

    private var lastAttemptWasFresh = false

    private func attempt(_ call: YeelightCall) async throws -> [YeelightValue] {
        guard !isClosed else { throw YeelightTransportError.closed }
        let conn = try await ensureConnected()
        lastAttemptWasFresh = freshConnection
        freshConnection = false
        let id = nextID
        nextID = nextID >= 999_999 ? 1 : nextID + 1
        let data = call.request(id: id).encoded
        let timeout = options.requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                await self?.finish(id, with: .failure(YeelightTransportError.timedOut))
            }
            Task { [weak self] in
                do {
                    try await conn.send(data)
                } catch {
                    await self?.finish(id, with: .failure(Self.transportError(error)))
                }
            }
        }
    }

    /// Closes the connection and stops reconnecting; outstanding requests fail with `.closed`.
    public func close() async {
        isClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        readTask?.cancel()
        readTask = nil
        let conn = connection
        connection = nil
        generation += 1
        failAll(.closed)
        await conn?.close()
    }

    /// Opens the connection now (pairing, reconnect probes). No-op when connected.
    public func connect() async throws {
        _ = try await ensureConnected()
    }

    // MARK: - Connection management

    private func ensureConnected() async throws -> any YeelightConnection {
        if let connection { return connection }
        if let connectTask { return try await connectTask.value }
        let connector = self.connector
        let host = self.host, port = self.port, timeout = options.connectTimeout
        let task = Task<any YeelightConnection, any Error> {
            let conn = try await connector.connect(host: host, port: port, timeout: timeout)
            await self.install(conn)
            return conn
        }
        connectTask = task
        defer { connectTask = nil }
        do {
            return try await task.value
        } catch {
            throw Self.transportError(error)
        }
    }

    private func install(_ conn: any YeelightConnection) async {
        guard !isClosed else {
            await conn.close()
            return
        }
        generation += 1
        let gen = generation
        connection = conn
        freshConnection = true
        backoff.reset()
        reconnectTask?.cancel()
        reconnectTask = nil
        let stream = conn.incoming
        readTask = Task { [weak self] in
            var framer = YeelightLineFramer()
            do {
                for try await chunk in stream {
                    for line in framer.append(chunk) {
                        guard let message = YeelightMessage.parse(line) else { continue }
                        await self?.handle(message)
                    }
                }
                await self?.connectionEnded(generation: gen, error: .connectionLost)
            } catch {
                await self?.connectionEnded(generation: gen, error: Self.transportError(error))
            }
        }
        log.debug("connected to \(host):\(port)")
        await onEvent(.connected)
    }

    private func handle(_ message: YeelightMessage) async {
        switch message {
        case .result(let id, let values):
            finish(id, with: .success(values))
        case .error(let id, let error):
            if let id { finish(id, with: .failure(error)) }
            else { log.notice("\(host): error without id: \(error)") }
        case .notification(let method, let params):
            if method == "props" { await onEvent(.properties(params)) }
        }
    }

    private func connectionEnded(generation gen: Int, error: YeelightTransportError) async {
        guard gen == generation, !isClosed else { return }
        let conn = connection
        connection = nil
        readTask = nil
        failAll(.connectionLost)
        await conn?.close()
        log.notice("\(host): connection ended (\(error))")
        await onEvent(.disconnected(error))
        if options.keepAlive { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, !isClosed else { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.nextBackoff()
                guard (try? await Task.sleep(for: delay)) != nil else { return }
                if await self.reconnectAttempt() { return }
            }
        }
    }

    private func nextBackoff() -> Duration { backoff.nextDelay() }

    /// Returns true when done (connected or closed).
    private func reconnectAttempt() async -> Bool {
        guard !isClosed else { return true }
        if connection != nil { reconnectTask = nil; return true }
        do {
            _ = try await ensureConnected()
            reconnectTask = nil
            return true
        } catch {
            log.debug("\(host): reconnect failed (\(error))")
            return false
        }
    }

    private func finish(_ id: Int, with result: Result<[YeelightValue], any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAll(_ error: YeelightTransportError) {
        for id in Array(pending.keys) { finish(id, with: .failure(error)) }
    }

    static func transportError(_ error: any Error) -> YeelightTransportError {
        if let e = error as? YeelightTransportError { return e }
        if error is CancellationError { return .closed }
        return .other(String(describing: error))
    }
}
