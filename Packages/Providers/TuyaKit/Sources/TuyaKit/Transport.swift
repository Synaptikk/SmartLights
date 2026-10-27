import Foundation
import LightCore
import NetKit
import Synchronization

// Transport seams of the provider. Apple platforms use NWConnection (TCP) and NetKit (UDP);
// Linux uses a small POSIX fallback so the provider can be tested in the swift:6.1 container.

// MARK: - TCP

/// One TCP connection to a device.
public protocol TuyaTCPConnection: Sendable {
    /// Raw received bytes; finishes when the peer closes, throws on errors.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ data: Data) async throws
    /// Idempotent; finishes `incoming`.
    func close()
}

public protocol TuyaTCPConnector: Sendable {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TuyaTCPConnection
}

// MARK: - UDP

public struct TuyaDatagram: Sendable, Equatable {
    public var data: Data
    /// Source address.
    public var host: String

    public init(data: Data, host: String) {
        self.data = data
        self.host = host
    }
}

public protocol TuyaDatagramTransport: Sendable {
    /// Listens on `ports` (6666/6667) for device announcements until `duration` elapses. Receiving
    /// broadcasts needs the multicast entitlement on iOS.
    func listen(ports: [UInt16], duration: Duration) -> AsyncStream<TuyaDatagram>
    /// Sends one broadcast datagram (the `REQ_DEVINFO` nudge to UDP 7000); errors are ignored.
    func broadcast(_ payload: Data, port: UInt16) async
    /// Our IPv4 address on the Wi-Fi (for the `REQ_DEVINFO` body), if known.
    func localAddress() -> String?
    /// Hosts of the current Wi-Fi subnet for a TCP sweep (empty if unknown).
    func sweepHosts() -> [String]
}

// MARK: - Defaults

/// Platform default transports.
public enum TuyaTransports {
    public static var tcp: any TuyaTCPConnector {
        #if canImport(Network)
        NWTuyaTCPConnector()
        #elseif canImport(Glibc)
        PosixTuyaTCPConnector()
        #else
        UnsupportedTuyaTransport()
        #endif
    }

    public static var udp: any TuyaDatagramTransport {
        #if canImport(Network)
        NetKitTuyaDatagramTransport()
        #elseif canImport(Glibc)
        PosixTuyaDatagramTransport()
        #else
        UnsupportedTuyaTransport()
        #endif
    }
}

struct UnsupportedTuyaTransport: TuyaTCPConnector, TuyaDatagramTransport {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TuyaTCPConnection {
        throw LightCoreError.unsupported("TCP on this platform")
    }
    func listen(ports: [UInt16], duration: Duration) -> AsyncStream<TuyaDatagram> { AsyncStream { $0.finish() } }
    func broadcast(_ payload: Data, port: UInt16) async {}
    func localAddress() -> String? { nil }
    func sweepHosts() -> [String] { [] }
}

// MARK: - Helpers

/// Single-assignment bridge from callbacks to async code; the first `resume` wins.
final class OnceGate<T: Sendable>: Sendable {
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
