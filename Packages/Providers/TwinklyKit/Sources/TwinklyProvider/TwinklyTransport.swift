import Foundation

/// One HTTP exchange with a Twinkly device (plain HTTP on the LAN; the device has no TLS).
public struct TwinklyHTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    /// Includes `X-Auth-Token` on authenticated calls. Never log.
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: Duration = .seconds(5)) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct TwinklyHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// A UDP datagram received during discovery.
public struct TwinklyDatagram: Sendable, Hashable {
    public var data: Data
    /// Sender address (dotted quad).
    public var host: String
    public var port: UInt16

    public init(data: Data, host: String, port: UInt16) {
        self.data = data
        self.host = host
        self.port = port
    }
}

/// Transport-level failures (no HTTP status).
public enum TwinklyTransportError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case timedOut
}

/// Everything `TwinklyProvider` needs from the network. `URLSessionTwinklyTransport` implements
/// it on Apple platforms (URLSession + NetKit `UDPSocket`); tests use a loopback implementation.
public protocol TwinklyTransport: Sendable {
    func send(_ request: TwinklyHTTPRequest) async throws -> TwinklyHTTPResponse
    /// Sends `payload` once to every destination (`host` or `host:port`, default `port`) from one
    /// UDP socket and streams every datagram received until `window` elapses. Destinations that
    /// fail (e.g. broadcast without the multicast entitlement: `EACCES`) are skipped.
    func probeUDP(_ payload: Data, destinations: [String], port: UInt16, window: Duration) -> AsyncStream<TwinklyDatagram>
    /// Broadcast addresses for discovery (directed Wi-Fi broadcast, 255.255.255.255).
    func broadcastAddresses() -> [String]
    /// Hosts of the current Wi-Fi /24 for the unicast sweep.
    func sweepHosts() -> [String]
}

extension TwinklyTransport {
    public func broadcastAddresses() -> [String] { [] }
    public func sweepHosts() -> [String] { [] }
}
