#if canImport(Darwin)
import Darwin
import Foundation

/// An IPv4 address assigned to a network interface.
public struct NetworkInterface: Sendable, Hashable, CustomStringConvertible {
    public let name: String
    public let index: UInt32
    public let address: IPv4Addr
    public let netmask: IPv4Addr
    /// Directed broadcast address reported by the interface (prefer this over 255.255.255.255).
    public let broadcastAddress: IPv4Addr?
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool
    public let supportsBroadcast: Bool
    public let isPointToPoint: Bool

    /// The interface's subnet (`nil` if the netmask is not contiguous).
    public var subnet: IPv4Subnet? { IPv4Subnet(address: address, netmask: netmask) }

    /// Directed broadcast from the interface, falling back to subnet math.
    public var directedBroadcast: IPv4Addr? { broadcastAddress ?? subnet?.broadcast }

    /// Hosts to sweep: the subnet clamped to at most a /24 around our address, excluding ourselves.
    public var sweepHosts: [IPv4Addr] {
        guard let subnet else { return [] }
        return subnet.clamped(toPrefixAtLeast: 24, around: address).hosts(excluding: [address])
    }

    public var description: String {
        "\(name)#\(index) \(address)/\(subnet?.prefixLength ?? -1)"
    }
}

/// `getifaddrs` wrapper.
public enum InterfaceInfo {
    /// All IPv4 interface addresses.
    public static func ipv4Interfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetworkInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addressPointer = entry.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            let name = String(cString: entry.ifa_name)
            let address = ipv4(addressPointer)
            let netmask = entry.ifa_netmask.map(ipv4) ?? IPv4Addr(rawValue: 0)
            let supportsBroadcast = flags & IFF_BROADCAST != 0
            // On Darwin `ifa_broadaddr` is a macro for `ifa_dstaddr` and is not imported into Swift.
            let broadcast: IPv4Addr? = supportsBroadcast
                ? entry.ifa_dstaddr.flatMap { $0.pointee.sa_family == sa_family_t(AF_INET) ? ipv4($0) : nil }
                : nil
            result.append(NetworkInterface(
                name: name,
                index: if_nametoindex(entry.ifa_name),
                address: address,
                netmask: netmask,
                broadcastAddress: broadcast,
                isUp: flags & IFF_UP != 0,
                isRunning: flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0,
                supportsBroadcast: supportsBroadcast,
                isPointToPoint: flags & IFF_POINTOPOINT != 0
            ))
        }
        return result
    }

    /// Interfaces that can reach the local network: up, running, broadcast-capable, not loopback,
    /// point-to-point (VPN/cellular), AWDL or link-local-only.
    public static func localNetworkInterfaces() -> [NetworkInterface] {
        let excludedPrefixes = ["lo", "pdp_ip", "utun", "ipsec", "awdl", "llw", "ap", "bridge", "anpi", "gif", "stf"]
        return ipv4Interfaces().filter { interface in
            interface.isUp && interface.isRunning && !interface.isLoopback && interface.supportsBroadcast
                && !interface.isPointToPoint && !interface.address.isLinkLocal
                && !excludedPrefixes.contains(where: { interface.name.hasPrefix($0) })
        }
    }

    /// The current Wi-Fi (or Ethernet) IPv4 interface: `en0` if present (iPhone Wi-Fi), else the
    /// first local-network interface. Never hard-code `en0` for binding; use the returned `name`.
    public static func currentWiFi() -> NetworkInterface? {
        let candidates = localNetworkInterfaces()
        return candidates.first(where: { $0.name == "en0" }) ?? candidates.first
    }

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> IPv4Addr {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4Addr(rawValue: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
    }
}

extension SubnetSweeper {
    /// Hosts of the current Wi-Fi subnet (clamped to a /24 around our address, self excluded).
    public static func currentWiFiHosts() -> [IPv4Addr] {
        InterfaceInfo.currentWiFi()?.sweepHosts ?? []
    }

    /// Sweeps the current Wi-Fi /24 with `probe`.
    public func sweepCurrentWiFi<R: Sendable>(probe: @escaping @Sendable (IPv4Addr) async -> R?) async -> [R] {
        await sweep(Self.currentWiFiHosts(), probe: probe)
    }
}
#endif
