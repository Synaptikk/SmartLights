import Foundation
import NetKit

/// Which certificate policy a request needs.
public enum HueTrust: Sendable, Hashable {
    /// Public internet host with system trust (discovery.meethue.com).
    case publicInternet
    /// Unauthenticated identity probe (`GET /api/config`) before the bridge id is known: any
    /// certificate is accepted, its leaf CN is reported in `HueHTTPResponse.peerCommonName` and
    /// must equal the returned bridge id. Never send secrets with this policy.
    case probe
    /// Signify roots (`hue-roots.pem`) with leaf CN == bridge id, TOFU for self-signed bridges.
    case bridge(id: String)
}

public struct HueHTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    /// Includes `hue-application-key` for CLIP calls. Never log.
    public var headers: [String: String]
    public var body: Data?
    public var trust: HueTrust
    public var timeout: Duration

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, trust: HueTrust,
                timeout: Duration = .seconds(10)) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.trust = trust
        self.timeout = timeout
    }
}

public struct HueHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data
    /// Leaf certificate CN (filled for `.probe` requests over HTTPS).
    public var peerCommonName: String?

    public init(status: Int, body: Data, peerCommonName: String? = nil) {
        self.status = status
        self.body = body
        self.peerCommonName = peerCommonName
    }
}

/// Parameters of the CLIP v2 event stream (`GET /eventstream/clip/v2`).
public struct HueEventStreamRequest: Sendable {
    public var url: URL
    public var bridgeID: String
    /// Sent as `hue-application-key`. Never log.
    public var applicationKey: String
    public var lastEventID: String?
    /// Idle timeout (aiohue: 90 s; the keep-alive fires every 60 s).
    public var readTimeout: Duration
    public var backoff: ExponentialBackoff

    public init(url: URL, bridgeID: String, applicationKey: String, lastEventID: String? = nil,
                readTimeout: Duration = .seconds(90), backoff: ExponentialBackoff = .hueEventStream) {
        self.url = url
        self.bridgeID = bridgeID
        self.applicationKey = applicationKey
        self.lastEventID = lastEventID
        self.readTimeout = readTimeout
        self.backoff = backoff
    }
}

/// Event-stream lifecycle as seen by the provider (mirrors NetKit `SSEClientEvent`).
public enum HueStreamEvent: Sendable, Hashable {
    case connected
    /// One SSE message; `data` is the JSON array text.
    case message(id: String?, data: String)
    /// Connection dropped; the transport reconnects after `retryIn`.
    case disconnected(reason: String, retryIn: Duration)
}

/// A `_hue._tcp` Bonjour result.
public struct HueBonjourRecord: Sendable, Hashable {
    public var name: String
    public var host: String?
    public var port: Int?
    /// TXT record: `bridgeid` (lower-case), `modelid`.
    public var txt: [String: String]

    public init(name: String, host: String?, port: Int?, txt: [String: String]) {
        self.name = name
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// Transport-level failures (no HTTP status).
public enum HueTransportError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case timedOut
    /// The certificate was rejected by the trust policy (wrong CN, unknown CA, pin mismatch).
    case trustRejected(String)
}

/// Everything HueProvider needs from the network. `URLSessionHueTransport` implements it on
/// Apple platforms; tests inject a fake.
public protocol HueTransport: Sendable {
    func send(_ request: HueHTTPRequest) async throws -> HueHTTPResponse
    /// Reconnects internally (with `request.backoff`) until the stream is terminated; finishes
    /// with `HueError.unauthorized` / `.v2Unsupported` on 401/403/404.
    func eventStream(_ request: HueEventStreamRequest) -> AsyncThrowingStream<HueStreamEvent, any Error>
    /// Browses `_hue._tcp` until the stream is terminated.
    func browseBonjour() -> AsyncStream<HueBonjourRecord>
}
