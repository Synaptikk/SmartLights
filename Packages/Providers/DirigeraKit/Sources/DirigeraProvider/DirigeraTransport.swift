import Foundation

/// Which certificate policy a request needs.
public enum DirigeraTrust: Sendable, Hashable {
    /// Before the hub id is known (discovery probe, pairing): any certificate is accepted and the
    /// leaf's SHA-256 is reported in `DirigeraHTTPResponse.peerCertificateSHA256`, so the provider
    /// can check every pairing request hit the same certificate and pin it under the hub id.
    case pairing
    /// After pairing: NetKit `TrustEvaluator` TOFU, the leaf must match the pin stored for `id`.
    case hub(id: String)
}

public struct DirigeraHTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    /// Includes `Authorization: Bearer <token>` on authenticated calls. Never log.
    public var headers: [String: String]
    public var body: Data?
    public var trust: DirigeraTrust
    public var timeout: Duration

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, trust: DirigeraTrust,
                timeout: Duration = .seconds(10)) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.trust = trust
        self.timeout = timeout
    }
}

public struct DirigeraHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data
    /// SHA-256 of the leaf certificate (`.pairing` requests over TLS only).
    public var peerCertificateSHA256: Data?

    public init(status: Int, body: Data, peerCertificateSHA256: Data? = nil) {
        self.status = status
        self.body = body
        self.peerCertificateSHA256 = peerCertificateSHA256
    }
}

/// Parameters of one WebSocket connection to `wss://<hub>:8443/v1`.
public struct DirigeraEventStreamRequest: Sendable, Hashable {
    public var url: URL
    public var hubID: String
    /// Sent as `Authorization: Bearer`. Never log.
    public var token: String
    /// WebSocket ping period (Leggin/dirigera: 60 s).
    public var pingInterval: Duration

    public init(url: URL, hubID: String, token: String, pingInterval: Duration = .seconds(60)) {
        self.url = url
        self.hubID = hubID
        self.token = token
        self.pingInterval = pingInterval
    }
}

public enum DirigeraStreamEvent: Sendable, Hashable {
    case connected
    /// One text frame (a JSON event).
    case message(String)
}

/// A Bonjour result that may be a hub (`gw2-<id>`).
public struct DirigeraBonjourRecord: Sendable, Hashable {
    public var name: String
    public var host: String?
    public var port: Int?
    public var txt: [String: String]

    public init(name: String, host: String?, port: Int?, txt: [String: String] = [:]) {
        self.name = name
        self.host = host
        self.port = port
        self.txt = txt
    }
}

public enum DirigeraTransportError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case timedOut
    /// The certificate did not match the pin for this hub (or was otherwise rejected).
    case trustRejected(String)
    /// The WebSocket upgrade was refused with 401/403.
    case unauthorized
}

/// Everything `DirigeraProvider` needs from the network. `URLSessionDirigeraTransport` implements
/// it on Apple platforms; tests use a loopback implementation (plain HTTP/WS).
public protocol DirigeraTransport: Sendable {
    func send(_ request: DirigeraHTTPRequest) async throws -> DirigeraHTTPResponse
    /// One WebSocket connection: yields `.connected`, then messages; finishes when the socket
    /// closes and throws `DirigeraTransportError.unauthorized` if the upgrade is refused.
    /// The provider reconnects.
    func eventStream(_ request: DirigeraEventStreamRequest) -> AsyncThrowingStream<DirigeraStreamEvent, any Error>
    /// Bonjour browse until terminated (empty where unavailable).
    func browseBonjour() -> AsyncStream<DirigeraBonjourRecord>
    /// Hosts of the current Wi-Fi /24 for the unicast HTTPS sweep.
    func sweepHosts() -> [String]
}

extension DirigeraTransport {
    public func browseBonjour() -> AsyncStream<DirigeraBonjourRecord> { AsyncStream { $0.finish() } }
    public func sweepHosts() -> [String] { [] }
}
