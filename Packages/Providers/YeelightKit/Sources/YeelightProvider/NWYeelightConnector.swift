#if canImport(Network)
import Foundation
@preconcurrency import Network

/// `YeelightConnector` over `NWConnection` (TCP). A refused connection (`ECONNREFUSED`, which
/// Network.framework reports as `.waiting`) maps to `YeelightTransportError.connectionRefused`.
public struct NWYeelightConnector: YeelightConnector {
    public init() {}

    public func connect(host: String, port: UInt16, timeout: Duration) async throws -> any YeelightConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw YeelightTransportError.other("invalid port \(port)") }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = max(1, Int(timeout.components.seconds))
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let wrapper = NWYeelightConnection(connection: connection)
        do {
            try await wrapper.start(timeout: timeout)
        } catch {
            connection.cancel()
            throw error
        }
        return wrapper
    }
}

final class NWYeelightConnection: YeelightConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var started = false

    init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.sinap.smartlights.yeelightkit.tcp")
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    func start(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.resumeStart(.failure(YeelightTransportError.timedOut))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                startContinuation = c
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                connection.start(queue: queue)
            }
        } onCancel: {
            self.resumeStart(.failure(CancellationError()))
        }
    }

    private func resumeStart(_ result: Result<Void, any Error>) {
        lock.lock()
        let c = startContinuation
        startContinuation = nil
        if case .success = result { started = true }
        lock.unlock()
        c?.resume(with: result)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            resumeStart(.success(()))
            receive()
        case .waiting(let error):
            let mapped = Self.map(error, path: connection.currentPath)
            lock.lock()
            let isStarted = started
            lock.unlock()
            if isStarted {
                continuation.finish(throwing: mapped)
                connection.cancel()
            } else if mapped != .timedOut {
                // Refused / denied are definitive; don't wait for the timeout.
                resumeStart(.failure(mapped))
            }
        case .failed(let error):
            let mapped = Self.map(error, path: connection.currentPath)
            resumeStart(.failure(mapped))
            continuation.finish(throwing: mapped)
        case .cancelled:
            resumeStart(.failure(YeelightTransportError.closed))
            continuation.finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(data) }
            if let error {
                self.continuation.finish(throwing: Self.map(error, path: nil))
                return
            }
            if isComplete {
                self.continuation.finish()
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: Self.map(error, path: nil)) } else { c.resume() }
            })
        }
    }

    func close() async {
        connection.cancel()
        continuation.finish()
    }

    static func map(_ error: NWError, path: NWPath?) -> YeelightTransportError {
        if path?.unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ETIMEDOUT: return .timedOut
            case .EACCES, .EPERM: return .localNetworkDenied
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: return .unreachable(String(describing: code))
            case .ECONNRESET, .EPIPE, .ENOTCONN: return .connectionLost
            default: return .other(error.localizedDescription)
            }
        case .dns(let code):
            return .unreachable("DNS error \(code)")
        default:
            return .other(error.localizedDescription)
        }
    }
}
#endif
