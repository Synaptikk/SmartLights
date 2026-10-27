import Foundation
import NetKit

/// A bound UDP socket as the provider needs it. Implemented with NetKit's BSD `UDPSocket` on
/// Apple platforms (``NetKitWiZTransport``); tests supply an in-process implementation so the
/// provider logic runs on Linux against `FakeWiZBulb`.
public protocol WiZDatagramEndpoint: AnyObject, Sendable {
    /// Received datagrams; finishes when the endpoint is closed.
    var datagrams: AsyncStream<Datagram> { get }
    var localPort: UInt16? { get }
    /// Sends one datagram without waiting for anything.
    func sendDatagram(_ data: Data, to host: IPv4Addr, port: UInt16) throws
    /// Idempotent.
    func close()
}

/// Everything network-specific the provider uses, so it can be swapped in tests.
public protocol WiZTransport: Sendable {
    /// Binds a UDP socket. `port` 0 = ephemeral; `broadcast` enables `SO_BROADCAST` on the
    /// Wi-Fi interface.
    func bind(port: UInt16, broadcast: Bool) async throws -> any WiZDatagramEndpoint
    /// This device's Wi-Fi IPv4 address (the `phoneIp` for push registration).
    func localIPv4Address() async -> IPv4Addr?
    /// Unicast sweep targets (the Wi-Fi /24 without ourselves).
    func sweepHosts() async -> [IPv4Addr]
    /// Directed (and limited) broadcast addresses for discovery.
    func broadcastAddresses() async -> [IPv4Addr]
    /// Whether broadcast works (iOS: multicast entitlement present and Local Network allowed).
    func broadcastStatus() async -> BroadcastCapabilityStatus
}

#if canImport(Darwin)
/// Production transport: NetKit `UDPSocket` (BSD sockets), `InterfaceInfo` and
/// `BroadcastCapability`.
public struct NetKitWiZTransport: WiZTransport {
    public init() {}

    public func bind(port: UInt16, broadcast: Bool) async throws -> any WiZDatagramEndpoint {
        let wifi = InterfaceInfo.currentWiFi()
        let options = UDPSocket.Options(
            interfaceName: broadcast ? wifi?.name : nil,
            localAddress: .any,
            localPort: port,
            broadcast: broadcast
        )
        return NetKitUDPEndpoint(try UDPSocket(options: options))
    }

    public func localIPv4Address() async -> IPv4Addr? { InterfaceInfo.currentWiFi()?.address }

    public func sweepHosts() async -> [IPv4Addr] { SubnetSweeper.currentWiFiHosts() }

    public func broadcastAddresses() async -> [IPv4Addr] {
        var out: [IPv4Addr] = []
        if let directed = InterfaceInfo.currentWiFi()?.directedBroadcast { out.append(directed) }
        if !out.contains(.limitedBroadcast) { out.append(.limitedBroadcast) }
        return out
    }

    public func broadcastStatus() async -> BroadcastCapabilityStatus { await BroadcastCapability.detect() }
}

/// `UDPSocket` adapter.
final class NetKitUDPEndpoint: WiZDatagramEndpoint {
    let socket: UDPSocket

    init(_ socket: UDPSocket) { self.socket = socket }

    var datagrams: AsyncStream<Datagram> { socket.datagrams }
    var localPort: UInt16? { socket.localPort }

    func sendDatagram(_ data: Data, to host: IPv4Addr, port: UInt16) throws {
        try socket.sendNow(data, to: host, port: port)
    }

    func close() { socket.close() }
}
#endif
