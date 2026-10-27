#if canImport(Darwin)
import Foundation
import GoveeCodec
import NetKit

/// Govee LAN transport over NetKit's BSD `UDPSocket`, bound to the Wi-Fi interface on the
/// listen port (4002, `SO_REUSEADDR`/`SO_REUSEPORT`) with `SO_BROADCAST`.
///
/// Multicast scans to 239.255.255.250:4001 need `com.apple.developer.networking.multicast` on
/// iOS; without it `send` throws `UDPSocketError` with `EACCES` and the provider falls back to
/// unicast scans of cached/manual hosts and the /24 sweep. Unicast commands work without it
/// (Local Network permission is still required).
public actor NetKitGoveeLANTransport: GoveeLANTransport {
    public let listenPort: UInt16
    public let interfaceName: String?
    private var socket: UDPSocket?
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - listenPort: 4002 in production; 0 (ephemeral) for tests against a fake device that
    ///     replies to the sender's port.
    ///   - interfaceName: interface to bind (`IP_BOUND_IF`); nil = current Wi-Fi (`InterfaceInfo.currentWiFi()`).
    public init(listenPort: UInt16 = GoveeLAN.listenPort, interfaceName: String? = nil) {
        self.listenPort = listenPort
        self.interfaceName = interfaceName
    }

    public func open() throws -> AsyncStream<GoveeDatagram> {
        close()
        let name = interfaceName ?? InterfaceInfo.currentWiFi()?.name
        let socket = try UDPSocket(options: .init(interfaceName: name, localPort: listenPort, broadcast: true))
        self.socket = socket
        let (stream, continuation) = AsyncStream.makeStream(of: GoveeDatagram.self, bufferingPolicy: .bufferingNewest(256))
        let source = socket.datagrams
        pump = Task {
            for await datagram in source {
                continuation.yield(GoveeDatagram(data: datagram.data, host: datagram.host.description))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in socket.close() }
        return stream
    }

    public func send(_ data: Data, to host: String, port: UInt16) throws {
        guard let socket else { throw GoveeTransportError.notOpen }
        guard let address = IPv4Addr(host) else { throw GoveeTransportError.invalidHost(host) }
        try socket.sendNow(data, to: address, port: port)
    }

    public func close() {
        socket?.close()
        socket = nil
        pump?.cancel()
        pump = nil
    }

    /// Port actually bound (useful when `listenPort` is 0).
    public var boundPort: UInt16? { socket?.localPort }
}
#endif
