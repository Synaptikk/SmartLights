import Foundation
import LightCore
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request to a device (`http://host:port/uri`).
public struct ShellyHTTPRequest: Sendable, Hashable {
    public var method: String
    public var host: String
    public var port: Int
    /// Path plus query (`/rpc`, `/light/0?turn=on`).
    public var uri: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", host: String, port: Int = 80, uri: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.host = host
        self.port = port
        self.uri = uri
        self.headers = headers
        self.body = body
    }

    public var url: URL? { URL(string: "http://\(host)\(port == 80 ? "" : ":\(port)")\(uri)") }
}

public struct ShellyHTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// HTTP seam. Returns every HTTP answer (401 included); throws only for transport failures.
public protocol ShellyHTTPTransport: Sendable {
    func perform(_ request: ShellyHTTPRequest, timeout: Duration) async throws -> ShellyHTTPResponse
}

/// A text WebSocket to `ws://host/rpc` (Gen2+ notifications).
public protocol ShellyWebSocket: Sendable {
    var messages: AsyncThrowingStream<String, any Error> { get }
    func send(_ text: String) async throws
    /// Idempotent; finishes `messages`.
    func close()
}

/// A `_shelly._tcp` or `_http._tcp` Bonjour result.
public struct ShellyBonjourHit: Sendable, Hashable {
    public var name: String
    /// `_shelly._tcp` or `_http._tcp`.
    public var type: String
    public var host: String?
    public var port: UInt16?
    /// Gen2+ TXT: `gen`, `app`, `ver`.
    public var txt: [String: String]

    public init(name: String, type: String, host: String?, port: UInt16?, txt: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// Everything the provider needs from the platform; injectable for tests.
public struct ShellyNetworkEnvironment: Sendable {
    public var http: any ShellyHTTPTransport
    /// Browses `_shelly._tcp` and `_http._tcp`; nil where Bonjour is unavailable (Linux).
    public var browseBonjour: (@Sendable () -> AsyncStream<ShellyBonjourHit>)?
    /// Hosts for the unicast sweep (current Wi-Fi /24).
    public var sweepHosts: @Sendable () -> [String]
    /// Opens `ws://host:port/rpc`; nil = polling only.
    public var openWebSocket: (@Sendable (_ host: String, _ port: Int) async throws -> any ShellyWebSocket)?

    public init(
        http: any ShellyHTTPTransport,
        browseBonjour: (@Sendable () -> AsyncStream<ShellyBonjourHit>)? = nil,
        sweepHosts: @escaping @Sendable () -> [String] = { [] },
        openWebSocket: (@Sendable (_ host: String, _ port: Int) async throws -> any ShellyWebSocket)? = nil
    ) {
        self.http = http
        self.browseBonjour = browseBonjour
        self.sweepHosts = sweepHosts
        self.openWebSocket = openWebSocket
    }
}

/// `URLSession` transport (Apple platforms and Linux FoundationNetworking). Uses an ephemeral
/// session so the system never stores or replays Shelly credentials; digest/basic auth headers are
/// computed by the provider.
public final class URLSessionShellyTransport: ShellyHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Shelly allows few concurrent HTTP clients; keep it small.
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    public func perform(_ request: ShellyHTTPRequest, timeout: Duration) async throws -> ShellyHTTPResponse {
        guard let url = request.url else { throw LightCoreError.transport("invalid Shelly URL for \(request.host)") }
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        r.httpBody = request.body
        r.timeoutInterval = max(0.1, timeout.seconds)
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let gate = ShellyGate<ShellyHTTPResponse>()
        let task = session.dataTask(with: r) { data, response, error in
            if let error {
                gate.resume(.failure(LightCoreError.unreachable("\(request.host): \(error.localizedDescription)")))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let k = k as? String, let v = v as? String { headers[k] = v }
                }
                gate.resume(.success(ShellyHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data())))
            } else {
                gate.resume(.failure(LightCoreError.transport("no HTTP response from \(request.host)")))
            }
        }
        task.resume()
        return try await withTaskCancellationHandler {
            try await gate.wait(timeout: timeout + .seconds(1))
        } onCancel: {
            task.cancel()
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// Single-assignment bridge from callbacks to async code; the first `resume` wins.
final class ShellyGate<T: Sendable>: Sendable {
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
        return try await wait()
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
