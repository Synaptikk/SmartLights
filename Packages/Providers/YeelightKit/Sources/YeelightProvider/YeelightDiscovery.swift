import Foundation
import NetKit
import YeelightCodec

/// A `yeelink-*` instance seen on Bonjour (`_miio._udp`).
public struct YeelightBonjourHit: Sendable, Hashable {
    public var serviceName: String
    public var host: String?

    public init(serviceName: String, host: String?) {
        self.serviceName = serviceName
        self.host = host
    }

    public var parsedName: YeelightBonjourName? { YeelightBonjourName(serviceName) }
}

/// The datagram/Bonjour side of discovery, abstracted so the provider's merge logic is testable on
/// Linux. TCP probes (manual hosts, sweep) go through the provider's `YeelightConnector`.
public protocol YeelightDiscoveryBackend: Sendable {
    /// Multicast `M-SEARCH` to 239.255.255.250:1982 (needs the multicast entitlement on iOS) and
    /// stream parsed replies/NOTIFY advertisements until `timeout` or cancellation.
    func multicastSearch(timeout: Duration) -> AsyncStream<YeelightAdvertisement>
    /// Unicast `M-SEARCH` to `host:1982` (no entitlement needed); nil if no reply within `timeout`.
    func unicastSearch(host: String, timeout: Duration) async -> YeelightAdvertisement?
    /// Browse `_miio._udp` for `yeelink-*` instances until `timeout` or cancellation.
    func bonjour(timeout: Duration) -> AsyncStream<YeelightBonjourHit>
    /// Hosts of the current Wi-Fi subnet (clamped to a /24) for the TCP sweep fallback.
    func sweepHosts() -> [IPv4Addr]
}

/// Backend that finds nothing (Linux, tests that only use manual hosts).
public struct NoYeelightDiscoveryBackend: YeelightDiscoveryBackend {
    public init() {}
    public func multicastSearch(timeout: Duration) -> AsyncStream<YeelightAdvertisement> { AsyncStream { $0.finish() } }
    public func unicastSearch(host: String, timeout: Duration) async -> YeelightAdvertisement? { nil }
    public func bonjour(timeout: Duration) -> AsyncStream<YeelightBonjourHit> { AsyncStream { $0.finish() } }
    public func sweepHosts() -> [IPv4Addr] { [] }
}
