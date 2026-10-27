#if canImport(Darwin)
import Foundation
import LightCore
import NetKit
import TPLinkCodec

/// Discovery datagrams over NetKit's BSD `UDPSocket` (bound to the Wi-Fi interface). Unicast probes
/// work with Local Network permission alone; broadcast sends fail with `EACCES` without the
/// multicast entitlement, in which case the provider uses the unicast sweep instead.
public struct NetKitTPLinkDatagramTransport: TPLinkDatagramTransport {
    private let log = Log(package: "tplinkkit", category: "discovery")

    public init() {}

    public func broadcast(_ probes: [TPLinkProbe], to addresses: [String], rounds: Int, listen: Duration) -> AsyncStream<TPLinkDatagram> {
        let log = log
        let (stream, continuation) = AsyncStream.makeStream(of: TPLinkDatagram.self, bufferingPolicy: .bufferingNewest(512))
        let socket: UDPSocket
        do {
            socket = try UDPSocket(options: UDPSocket.Options(interfaceName: InterfaceInfo.currentWiFi()?.name, broadcast: true))
        } catch {
            log.notice("cannot open UDP socket: \(error)")
            continuation.finish()
            return stream
        }
        let targets = addresses.compactMap { IPv4Addr($0) }
        let sender = Task {
            for round in 0..<max(1, rounds) {
                if round > 0 { try? await Task.sleep(for: .milliseconds(400 * round)) }
                for address in targets {
                    for probe in probes {
                        do { try await socket.send(probe.payload, to: address, port: probe.port) } catch {
                            log.notice("broadcast to \(address):\(probe.port) failed: \(error)")
                        }
                    }
                }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: listen)
            socket.close()
        }
        let reader = Task {
            for await d in socket.datagrams {
                continuation.yield(TPLinkDatagram(data: d.data, host: d.host.description, port: d.port))
            }
            sender.cancel()
            timer.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            sender.cancel()
            timer.cancel()
            reader.cancel()
            socket.close()
        }
        return stream
    }

    public func probe(_ probes: [TPLinkProbe], host: String, timeout: Duration) async -> [TPLinkDatagram] {
        guard let address = IPv4Addr(host),
              let socket = try? UDPSocket(options: UDPSocket.Options(interfaceName: InterfaceInfo.currentWiFi()?.name))
        else { return [] }
        defer { socket.close() }
        let box = DatagramBox()
        let reader = Task {
            for await d in socket.datagrams where d.host == address {
                await box.append(TPLinkDatagram(data: d.data, host: d.host.description, port: d.port))
            }
        }
        defer { reader.cancel() }
        for probe in probes {
            try? await socket.send(probe.payload, to: address, port: probe.port)
        }
        // Wait for the first answer, then a short grace period for the other port's answer.
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: timeout)
        var graceSet = false
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            if !graceSet, await box.count > 0 {
                graceSet = true
                deadline = min(deadline, clock.now.advanced(by: .milliseconds(150)))
            }
        }
        return await box.items
    }
}

private actor DatagramBox {
    private(set) var items: [TPLinkDatagram] = []
    var count: Int { items.count }
    func append(_ d: TPLinkDatagram) { items.append(d) }
}

extension TPLinkNetworkEnvironment {
    /// Real network: POSIX TCP, URLSession, NetKit UDP on the Wi-Fi interface, Wi-Fi broadcast and
    /// sweep hosts.
    public static var live: TPLinkNetworkEnvironment {
        TPLinkNetworkEnvironment(
            datagrams: NetKitTPLinkDatagramTransport(),
            broadcastAddresses: {
                var out: [String] = []
                if let directed = InterfaceInfo.currentWiFi()?.directedBroadcast { out.append(directed.description) }
                out.append(IPv4Addr.limitedBroadcast.description)
                return out
            },
            sweepHosts: { SubnetSweeper.currentWiFiHosts() }
        )
    }
}

extension TPLinkProvider {
    /// The provider wired to the real network and the Keychain.
    public static func live(secretStore: any SecretStore = KeychainSecretStore()) -> TPLinkProvider {
        TPLinkProvider(environment: .live, secretStore: secretStore)
    }
}
#endif
