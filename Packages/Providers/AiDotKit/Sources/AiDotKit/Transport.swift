import AiDotCodec
import Foundation
import LightCore
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Transport seams of the provider. Apple platforms use NWConnection (TCP) and NetKit (UDP);
// Linux uses a small POSIX fallback so the provider can be tested in the swift:6.1 container.

// MARK: - HTTP

public protocol AiDotHTTPTransport: Sendable {
    /// Performs `request` below `baseURL`; returns the status and body for every HTTP answer
    /// (non-2xx included). Throws only for transport failures.
    func perform(_ request: AiDotHTTPRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data)
}

/// URLSession-based transport (works on Apple platforms and Linux FoundationNetworking).
public struct URLSessionAiDotHTTPTransport: AiDotHTTPTransport {
    public init() {}

    public func perform(_ request: AiDotHTTPRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data) {
        guard let url = request.url(baseURL: baseURL) else { throw LightCoreError.transport("invalid AiDot URL") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let gate = OnceGate<(Int, Data)>()
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                gate.resume(.failure(LightCoreError.transport(error.localizedDescription)))
            } else if let http = response as? HTTPURLResponse {
                gate.resume(.success((http.statusCode, data ?? Data())))
            } else {
                gate.resume(.failure(LightCoreError.transport("no HTTP response")))
            }
        }
        task.resume()
        return try await withTaskCancellationHandler {
            let (status, body) = try await gate.wait()
            return (status, body)
        } onCancel: {
            task.cancel()
            gate.resume(.failure(CancellationError()))
        }
    }
}

// MARK: - TCP

/// One TCP connection to a device.
public protocol AiDotTCPConnection: Sendable {
    /// Raw received bytes; finishes when the peer closes, throws on errors.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ data: Data) async throws
    /// Idempotent; finishes `incoming`.
    func close()
}

public protocol AiDotTCPConnector: Sendable {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any AiDotTCPConnection
}

// MARK: - UDP

public struct AiDotDatagramReply: Sendable, Equatable {
    public var data: Data
    /// Source address of the reply.
    public var host: String
    public init(data: Data, host: String) {
        self.data = data
        self.host = host
    }
}

public protocol AiDotDatagramTransport: Sendable {
    /// Sends `payload` to the IPv4 broadcast address(es) a few times and streams every reply until
    /// `listen` elapses. Needs the multicast entitlement on iOS.
    func broadcast(_ payload: Data, port: UInt16, listen: Duration) -> AsyncStream<AiDotDatagramReply>
    /// Unicast request; first reply or `nil` on timeout/error.
    func request(_ payload: Data, host: String, port: UInt16, timeout: Duration) async -> AiDotDatagramReply?
    /// Hosts of the current Wi-Fi subnet for a sweep (empty if unknown).
    func sweepHosts() -> [String]
}

// MARK: - Defaults

/// Platform default transports.
public enum AiDotTransports {
    public static var tcp: any AiDotTCPConnector {
        #if canImport(Network)
        NWAiDotTCPConnector()
        #elseif canImport(Glibc)
        PosixAiDotTCPConnector()
        #else
        UnsupportedAiDotTransport()
        #endif
    }

    public static var udp: any AiDotDatagramTransport {
        #if canImport(Network)
        NetKitAiDotDatagramTransport()
        #elseif canImport(Glibc)
        PosixAiDotDatagramTransport()
        #else
        UnsupportedAiDotTransport()
        #endif
    }
}

struct UnsupportedAiDotTransport: AiDotTCPConnector, AiDotDatagramTransport {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any AiDotTCPConnection {
        throw LightCoreError.unsupported("TCP on this platform")
    }
    func broadcast(_ payload: Data, port: UInt16, listen: Duration) -> AsyncStream<AiDotDatagramReply> { AsyncStream { $0.finish() } }
    func request(_ payload: Data, host: String, port: UInt16, timeout: Duration) async -> AiDotDatagramReply? { nil }
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

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
