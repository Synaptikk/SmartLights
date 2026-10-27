import Foundation
import LightCore
import Synchronization

/// One TCP connection to a device (port 5577).
public protocol MagicHomeConnection: Sendable {
    /// Raw received bytes; finishes when the peer closes, throws on errors.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ data: Data) async throws
    /// Idempotent; finishes `incoming`.
    func close()
}

/// A UDP datagram received during discovery.
public struct MagicHomeDatagram: Sendable, Hashable {
    public var data: Data
    /// Source address (dotted-quad IPv4).
    public var host: String

    public init(data: Data, host: String) {
        self.data = data
        self.host = host
    }
}

/// Everything the provider needs from the platform; injectable for tests.
///
/// Production: `MagicHomeNetworkEnvironment.live` (NWConnection TCP, NetKit UDP; Apple only).
/// Tests: an in-process fake device (`Tests/MagicHomeProviderTests/FakeMagicHomeDevice.swift`).
public struct MagicHomeNetworkEnvironment: Sendable {
    /// Opens a TCP connection.
    public var connect: @Sendable (_ host: String, _ port: UInt16, _ timeout: Duration) async throws -> any MagicHomeConnection
    /// Broadcasts `payload` to the Wi-Fi subnet on `port` and streams replies until `listen`
    /// elapses. nil where broadcast is impossible; also skipped unless
    /// `DiscoveryOptions.broadcastAvailable` (multicast entitlement).
    public var broadcast: (@Sendable (_ payload: Data, _ port: UInt16, _ listen: Duration) -> AsyncStream<MagicHomeDatagram>)?
    /// Unicast request; the first reply or nil on timeout/error (no entitlement needed).
    public var unicast: @Sendable (_ payload: Data, _ host: String, _ port: UInt16, _ timeout: Duration) async -> MagicHomeDatagram?
    /// Hosts for the unicast sweep (current Wi-Fi /24).
    public var sweepHosts: @Sendable () -> [String]

    public init(
        connect: @escaping @Sendable (_ host: String, _ port: UInt16, _ timeout: Duration) async throws -> any MagicHomeConnection,
        broadcast: (@Sendable (_ payload: Data, _ port: UInt16, _ listen: Duration) -> AsyncStream<MagicHomeDatagram>)? = nil,
        unicast: @escaping @Sendable (_ payload: Data, _ host: String, _ port: UInt16, _ timeout: Duration) async -> MagicHomeDatagram? = { _, _, _, _ in nil },
        sweepHosts: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.connect = connect
        self.broadcast = broadcast
        self.unicast = unicast
        self.sweepHosts = sweepHosts
    }
}

/// Single-assignment bridge from callbacks to async code; the first `resume` wins.
final class MagicHomeGate<T: Sendable>: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<T, any Error>)
        case ready(Result<T, any Error>)
        case done
    }

    private let state = Mutex<State>(.idle)

    init() {}

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let ready: Result<T, any Error>? = state.withLock { s in
                switch s {
                case .idle:
                    s = .waiting(continuation)
                    return nil
                case .ready(let r):
                    s = .done
                    return r
                case .waiting, .done:
                    return .failure(CancellationError())
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    /// Waits with a deadline; times out with `LightCoreError.timeout`.
    func wait(timeout: Duration) async throws -> T {
        let timer = Task { [self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self.resume(.failure(LightCoreError.timeout))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await wait()
        } onCancel: {
            self.resume(.failure(CancellationError()))
        }
    }

    func resume(_ result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { s in
            switch s {
            case .idle:
                s = .ready(result)
                return nil
            case .waiting(let c):
                s = .done
                return c
            case .ready, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
