import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LightCore
import NetKit

/// One HTTP exchange with a WLED controller.
public struct WLEDHTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    /// IPv4/IPv6 literal or host name (`wled-kitchen.local`).
    public var host: String
    public var port: UInt16
    public var path: String
    public var body: Data?
    public var timeout: Duration

    public init(method: HTTPMethod, host: String, port: UInt16, path: String, body: Data? = nil, timeout: Duration = .seconds(5)) {
        self.method = method
        self.host = host
        self.port = port
        self.path = path
        self.body = body
        self.timeout = timeout
    }

    /// `http://host:port/path` (IPv6 literals bracketed, zone ids percent-encoded).
    public var url: URL? {
        var h = host
        if h.contains(":"), !h.hasPrefix("[") {
            h = "[" + h.replacingOccurrences(of: "%", with: "%25") + "]"
        }
        return URL(string: "http://\(h):\(port)\(path)")
    }
}

public struct WLEDHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// HTTP access to WLED controllers. Production and tests both use `URLSessionWLEDTransport`
/// (Linux: FoundationNetworking); the protocol exists so the provider can be driven by a stub.
public protocol WLEDHTTPTransport: Sendable {
    /// Performs one request. Throws `LightCoreError.timeout` / `.transport` on network failure;
    /// any HTTP status is returned (the provider maps non-2xx).
    func send(_ request: WLEDHTTPRequest) async throws -> WLEDHTTPResponse
}

/// `WLEDHTTPTransport` over an ephemeral `URLSession`. ESP8266 builds serve few concurrent
/// connections, so the session keeps one connection per host; the provider additionally
/// serialises requests per controller and retries once on a transport error.
public final class URLSessionWLEDTransport: WLEDHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: WLEDHTTPRequest) async throws -> WLEDHTTPResponse {
        guard let url = request.url else { throw LightCoreError.unreachable("invalid WLED address \(request.host)") }
        var r = URLRequest(url: url)
        r.httpMethod = request.method.rawValue
        r.timeoutInterval = Double(request.timeout.components.seconds) + Double(request.timeout.components.attoseconds) / 1e18
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw LightCoreError.protocolError("no HTTP response") }
            return WLEDHTTPResponse(status: http.statusCode, body: data)
        } catch let error as URLError where error.code == .timedOut {
            throw LightCoreError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw LightCoreError.transport("\(request.host): \(error.code.rawValue) \(error.localizedDescription)")
        }
    }
}

/// A `_wled._tcp` Bonjour result. The instance name is the mDNS host name ("wled-kitchen");
/// WLED adds a TXT record `mac` (12 hex digits).
public struct WLEDBonjourHit: Sendable, Hashable {
    public var name: String
    public var host: String?
    public var port: UInt16?
    public var txt: [String: String]

    public init(name: String, host: String?, port: UInt16?, txt: [String: String]) {
        self.name = name
        self.host = host
        self.port = port
        self.txt = txt
    }

    public var macAddress: String? { txt["mac"].flatMap { $0.isEmpty ? nil : $0 } }
}

/// Everything the provider needs from the platform; injectable for tests.
public struct WLEDNetworkEnvironment: Sendable {
    public var http: any WLEDHTTPTransport
    /// `_wled._tcp` browser; nil where Bonjour is unavailable (Linux).
    public var browseBonjour: (@Sendable () -> AsyncStream<WLEDBonjourHit>)?

    public init(http: any WLEDHTTPTransport = URLSessionWLEDTransport(),
                browseBonjour: (@Sendable () -> AsyncStream<WLEDBonjourHit>)? = nil) {
        self.http = http
        self.browseBonjour = browseBonjour
    }
}
