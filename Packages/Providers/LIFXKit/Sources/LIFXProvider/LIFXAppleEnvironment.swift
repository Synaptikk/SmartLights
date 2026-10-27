#if canImport(Darwin)
import Foundation
import LightCore
import NetKit

/// `LIFXTransport` over NetKit's BSD `UDPSocket` (bound to the Wi-Fi interface, `SO_BROADCAST`).
/// Unicast works with Local Network permission alone; broadcast sends fail with `EACCES` without
/// the multicast entitlement (the provider then falls back to the unicast sweep).
public final class UDPSocketLIFXTransport: LIFXTransport {
    private let socket: UDPSocket
    public let datagrams: AsyncStream<LIFXDatagram>

    public init(interfaceName: String? = InterfaceInfo.currentWiFi()?.name) throws {
        socket = try UDPSocket(options: UDPSocket.Options(interfaceName: interfaceName, broadcast: true))
        let source = socket.datagrams
        let (stream, continuation) = AsyncStream.makeStream(of: LIFXDatagram.self, bufferingPolicy: .bufferingNewest(512))
        datagrams = stream
        let pump = Task {
            for await d in source {
                continuation.yield(LIFXDatagram(data: d.data, host: d.host.description, port: d.port))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
    }

    public func send(_ data: Data, to host: String, port: UInt16) async throws {
        guard let address = IPv4Addr(host) else {
            throw LightCoreError.unsupported("LIFX LAN needs an IPv4 address, got \(host)")
        }
        try await socket.send(data, to: address, port: port)
    }

    public func close() { socket.close() }
}

extension LIFXNetworkEnvironment {
    /// Real network: NetKit UDP socket, Wi-Fi broadcast/sweep hosts, Bonjour `_lifx._udp`.
    public static var live: LIFXNetworkEnvironment {
        LIFXNetworkEnvironment(
            makeTransport: { try UDPSocketLIFXTransport() },
            broadcastAddresses: {
                var out: [String] = []
                if let directed = InterfaceInfo.currentWiFi()?.directedBroadcast { out.append(directed.description) }
                out.append(IPv4Addr.limitedBroadcast.description)
                return out
            },
            sweepHosts: { SubnetSweeper.currentWiFiHosts() },
            browseBonjour: LIFXNetworkEnvironment.bonjourBrowser
        )
    }

    #if canImport(Network)
    static let bonjourBrowser: (@Sendable () -> AsyncStream<LIFXBonjourHit>)? = {
        let (stream, continuation) = AsyncStream.makeStream(of: LIFXBonjourHit.self)
        let task = Task {
            for await event in BonjourBrowser.browse(type: "_lifx._udp") {
                if case .added(let service) = event {
                    continuation.yield(LIFXBonjourHit(name: service.name, host: service.host, port: service.port, txt: service.txt))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
    #else
    static let bonjourBrowser: (@Sendable () -> AsyncStream<LIFXBonjourHit>)? = nil
    #endif
}

extension LIFXProvider {
    /// The provider wired to the real network and the Keychain.
    public static func live(secretStore: any SecretStore = KeychainSecretStore()) -> LIFXProvider {
        LIFXProvider(environment: .live, secretStore: secretStore)
    }
}
#endif
