import Foundation
import LightCore
import MerossCodec
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Transport seams of the provider. Tests inject in-package fakes; Apple platforms use
// URLSession for the cloud and NWConnection for the LAN (see MerossAppleTransport.swift).

/// HTTPS to the Meross cloud. Returns status + body for every HTTP answer; throws only for transport failures.
public protocol MerossCloudTransport: Sendable {
    func perform(_ request: MerossCloudRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data)
}

/// `POST http://<host>:<port>/config` on the LAN. Returns status + body; throws for transport failures.
public protocol MerossLocalTransport: Sendable {
    func post(host: String, port: UInt16, body: Data, contentType: String, timeout: Duration) async throws -> (status: Int, body: Data)
}

/// URLSession-based cloud transport (Apple platforms and Linux FoundationNetworking).
public struct URLSessionMerossCloudTransport: MerossCloudTransport {
    public init() {}

    public func perform(_ request: MerossCloudRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data) {
        guard let url = request.url(baseURL: baseURL) else { throw LightCoreError.transport("invalid Meross URL") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return try await URLSessionCall.run(urlRequest, timeout: timeout)
    }
}

/// URLSession-based LAN transport. Used on Linux (tests, no ATS); Apple platforms default to
/// `NWMerossLocalTransport` so plain HTTP needs no App Transport Security exception.
public struct URLSessionMerossLocalTransport: MerossLocalTransport {
    public init() {}

    public func post(host: String, port: UInt16, body: Data, contentType: String, timeout: Duration) async throws -> (status: Int, body: Data) {
        let authority = port == 80 ? host : "\(host):\(port)"
        guard let url = URL(string: "http://\(authority)\(MerossConstants.configPath)") else {
            throw LightCoreError.transport("invalid Meross host")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await URLSessionCall.run(urlRequest, timeout: timeout)
    }
}

enum URLSessionCall {
    static func run(_ request: URLRequest, timeout: Duration) async throws -> (status: Int, body: Data) {
        var request = request
        request.timeoutInterval = timeout.seconds
        let gate = OnceGate<(Int, Data)>()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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
            let (status, body) = try await gate.wait(timeout: timeout + .seconds(1))
            return (status, body)
        } onCancel: {
            task.cancel()
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// Platform defaults.
public enum MerossTransports {
    public static var local: any MerossLocalTransport {
        #if canImport(Network)
        NWMerossLocalTransport()
        #else
        URLSessionMerossLocalTransport()
        #endif
    }

    public static var cloud: any MerossCloudTransport { URLSessionMerossCloudTransport() }

    /// Hosts of the current Wi-Fi /24 for a unicast sweep (empty where unknown, e.g. Linux).
    public static var sweepHosts: @Sendable () -> [String] {
        #if canImport(Darwin)
        { NWMerossLocalTransport.currentWiFiHosts() }
        #else
        { [] }
        #endif
    }
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
