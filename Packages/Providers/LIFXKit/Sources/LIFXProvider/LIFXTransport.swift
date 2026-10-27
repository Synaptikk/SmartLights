import Foundation
import LIFXCodec
import NetKit

/// A received UDP datagram (host is a dotted-quad IPv4 address).
public struct LIFXDatagram: Sendable, Hashable {
    public var data: Data
    public var host: String
    public var port: UInt16

    public init(data: Data, host: String, port: UInt16) {
        self.data = data
        self.host = host
        self.port = port
    }
}

/// One UDP socket used for every LIFX exchange (unicast requests and broadcast discovery).
/// Replies are matched by the provider through `source` + `sequence`, so a single socket is enough.
///
/// Production: `UDPSocketLIFXTransport` (NetKit `UDPSocket`, Apple only). Tests: a POSIX socket
/// in the test target (Linux and macOS).
public protocol LIFXTransport: Sendable {
    /// Incoming datagrams. Read by exactly one consumer (the provider's receive loop).
    var datagrams: AsyncStream<LIFXDatagram> { get }
    /// Sends one datagram. Broadcast addresses need the multicast entitlement on iOS.
    func send(_ data: Data, to host: String, port: UInt16) async throws
    /// Closes the socket and finishes `datagrams`.
    func close()
}

/// A `_lifx._udp` Bonjour result (firmware >= 4.110). TXT: `id` = serial, `p` = product id,
/// `fw` = firmware version (https://lan.developer.lifx.com/docs/communicating-with-device).
public struct LIFXBonjourHit: Sendable, Hashable {
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

    public var serial: LIFXSerial? { txt["id"].flatMap(LIFXSerial.init) }
    public var productID: UInt32? { txt["p"].flatMap { UInt32($0) } }
    public var firmware: LIFXFirmwareVersion? { txt["fw"].flatMap(LIFXFirmwareVersion.init) }
}

/// Everything the provider needs from the platform; injectable for tests.
public struct LIFXNetworkEnvironment: Sendable {
    /// Opens the UDP socket (called lazily, once).
    public var makeTransport: @Sendable () throws -> any LIFXTransport
    /// Broadcast destinations for `GetService` (directed broadcast of the Wi-Fi subnet, 255.255.255.255).
    public var broadcastAddresses: @Sendable () -> [String]
    /// Hosts for the unicast sweep (current Wi-Fi /24).
    public var sweepHosts: @Sendable () -> [IPv4Addr]
    /// `_lifx._udp` browser; nil where Bonjour is unavailable (Linux).
    public var browseBonjour: (@Sendable () -> AsyncStream<LIFXBonjourHit>)?

    public init(
        makeTransport: @escaping @Sendable () throws -> any LIFXTransport,
        broadcastAddresses: @escaping @Sendable () -> [String] = { [] },
        sweepHosts: @escaping @Sendable () -> [IPv4Addr] = { [] },
        browseBonjour: (@Sendable () -> AsyncStream<LIFXBonjourHit>)? = nil
    ) {
        self.makeTransport = makeTransport
        self.broadcastAddresses = broadcastAddresses
        self.sweepHosts = sweepHosts
        self.browseBonjour = browseBonjour
    }
}
