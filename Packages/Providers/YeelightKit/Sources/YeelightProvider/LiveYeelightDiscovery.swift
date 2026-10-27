#if canImport(Network) && canImport(Darwin)
import Foundation
import LightCore
import NetKit
import YeelightCodec

/// Discovery backend for the app:
/// - multicast `M-SEARCH` from a BSD `UDPSocket` bound to the Wi-Fi interface (needs the multicast
///   entitlement on iOS; the provider only calls it when `DiscoveryOptions.broadcastAvailable`);
/// - unicast `M-SEARCH` to one host with `UDPUnicast` (no entitlement);
/// - Bonjour `_miio._udp` (`yeelink-*` instances) with `BonjourBrowser`;
/// - the current Wi-Fi /24 for the TCP sweep.
public struct LiveYeelightDiscovery: YeelightDiscoveryBackend {
    /// How often the multicast search is repeated within one discovery window (UDP is lossy).
    public var multicastRepeats: Int
    private let log = Log(package: "yeelightkit", category: "discovery")

    public init(multicastRepeats: Int = 3) {
        self.multicastRepeats = max(1, multicastRepeats)
    }

    public func multicastSearch(timeout: Duration) -> AsyncStream<YeelightAdvertisement> {
        let (stream, continuation) = AsyncStream.makeStream(of: YeelightAdvertisement.self)
        let repeats = multicastRepeats
        let log = self.log
        let task = Task {
            let socket: UDPSocket
            do {
                socket = try UDPSocket(options: UDPSocket.Options(interfaceName: InterfaceInfo.currentWiFi()?.name))
            } catch {
                log.notice("multicast socket failed: \(error)")
                continuation.finish()
                return
            }
            defer { socket.close() }
            let group = IPv4Addr(YeelightProtocol.ssdpGroup)!
            let request = YeelightSSDP.searchRequest()
            let sender = Task {
                for i in 0..<repeats {
                    do {
                        try socket.sendNow(request, to: group, port: YeelightProtocol.ssdpPort)
                    } catch {
                        log.notice("multicast M-SEARCH failed: \(error)")
                        return
                    }
                    if i < repeats - 1 { try? await Task.sleep(for: .milliseconds(400)) }
                }
            }
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                socket.close()
            }
            for await datagram in socket.datagrams {
                if let adv = YeelightSSDP.parse(datagram.data, sourceHost: datagram.host.description) {
                    continuation.yield(adv)
                }
            }
            sender.cancel()
            deadline.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func unicastSearch(host: String, timeout: Duration) async -> YeelightAdvertisement? {
        do {
            let data = try await UDPUnicast.request(
                YeelightSSDP.searchRequest(host: host), to: host, port: YeelightProtocol.ssdpPort, timeout: timeout
            )
            return YeelightSSDP.parse(data, sourceHost: host)
        } catch {
            return nil
        }
    }

    public func bonjour(timeout: Duration) -> AsyncStream<YeelightBonjourHit> {
        let (stream, continuation) = AsyncStream.makeStream(of: YeelightBonjourHit.self)
        let task = Task {
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                continuation.finish()
            }
            for await event in BonjourBrowser.browse(type: YeelightProtocol.bonjourServiceType) {
                if Task.isCancelled { break }
                switch event {
                case .added(let service):
                    guard YeelightBonjourName(service.name) != nil else { continue }
                    continuation.yield(YeelightBonjourHit(serviceName: service.name, host: service.host))
                case .policyDenied, .failed:
                    deadline.cancel()
                    continuation.finish()
                    return
                case .removed:
                    continue
                }
            }
            deadline.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func sweepHosts() -> [IPv4Addr] {
        SubnetSweeper.currentWiFiHosts()
    }
}
#endif
