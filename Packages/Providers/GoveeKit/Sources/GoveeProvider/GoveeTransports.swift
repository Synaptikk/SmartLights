import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoveeCodec

/// A datagram received on the client's LAN port (4002).
public struct GoveeDatagram: Sendable, Hashable {
    public var data: Data
    /// Sender IPv4 address (dotted quad).
    public var host: String

    public init(data: Data, host: String) {
        self.data = data
        self.host = host
    }
}

/// UDP transport for the Govee LAN API: one socket bound to the listen port (4002) that also
/// sends scans (multicast or unicast to 4001) and commands (unicast to 4003), so every reply
/// lands on it.
///
/// Production: `NetKitGoveeLANTransport` (NetKit `UDPSocket`, Apple only). Tests: a POSIX socket
/// transport and an in-memory network in the test target.
public protocol GoveeLANTransport: Sendable {
    /// Binds the socket and returns the datagrams it receives. Called once per provider; calling
    /// again after `close()` reopens.
    func open() async throws -> AsyncStream<GoveeDatagram>
    /// Sends one datagram. Multicast sends fail with EACCES on iOS without the multicast entitlement.
    func send(_ data: Data, to host: String, port: UInt16) async throws
    func close() async
}

/// HTTP transport for the Developer API.
public protocol GoveeHTTPTransport: Sendable {
    func perform(_ request: GoveeHTTPRequest) async throws -> GoveeHTTPResponse
}

/// Errors raised by the built-in transports.
public enum GoveeTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOpen
    case invalidHost(String)
    case invalidURL(String)
    case network(String)

    public var description: String {
        switch self {
        case .notOpen: "LAN socket is not open"
        case .invalidHost(let h): "Not an IPv4 address: \(h)"
        case .invalidURL(let p): "Invalid URL path \(p)"
        case .network(let m): "Network error: \(m)"
        }
    }
}

/// `URLSession` transport (Apple platforms and Linux via FoundationNetworking).
public struct URLSessionGoveeHTTPTransport: GoveeHTTPTransport {
    public let baseURL: URL
    public let timeout: TimeInterval
    private let session: URLSession

    public init(baseURL: URL = GoveeCloudAPI.baseURL, session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func perform(_ request: GoveeHTTPRequest) async throws -> GoveeHTTPResponse {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            throw GoveeTransportError.invalidURL(request.path)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let session = self.session
        let built = urlRequest
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GoveeHTTPResponse, any Error>) in
            let task = session.dataTask(with: built) { data, response, error in
                if let error {
                    continuation.resume(throwing: GoveeTransportError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: GoveeTransportError.network("no HTTP response"))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
                continuation.resume(returning: GoveeHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

/// One-shot value handoff with timeout: whichever of `resume` / timeout / cancellation comes
/// first wins. Used to wait for a `devStatus` reply.
final class GoveeOneShot<T: Sendable>: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T?, Never>)
        case ready(T?)
        case done
    }

    private let lock = NSLock()
    private var state = State.idle

    func resume(_ value: T?) {
        lock.lock()
        let continuation: CheckedContinuation<T?, Never>?
        switch state {
        case .idle:
            state = .ready(value)
            continuation = nil
        case .waiting(let c):
            state = .done
            continuation = c
        case .ready, .done:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }

    /// Waits for `resume`; returns nil after `timeout` or on cancellation.
    func wait(timeout: Duration) async -> T? {
        let timer = Task { [self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self.resume(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                lock.lock()
                switch state {
                case .idle:
                    state = .waiting(continuation)
                    lock.unlock()
                case .ready(let value):
                    state = .done
                    lock.unlock()
                    continuation.resume(returning: value)
                case .waiting, .done:
                    lock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            self.resume(nil)
        }
    }
}
