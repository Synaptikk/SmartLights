import Foundation

/// An IPv4 address stored in host byte order. Named `IPv4Addr` to avoid clashing with
/// `Network.IPv4Address` on Apple platforms.
public struct IPv4Addr: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        rawValue = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// Parses dotted-quad notation (`"192.168.1.20"`).
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        rawValue = value
    }

    public var octets: [UInt8] {
        [UInt8(truncatingIfNeeded: rawValue >> 24), UInt8(truncatingIfNeeded: rawValue >> 16),
         UInt8(truncatingIfNeeded: rawValue >> 8), UInt8(truncatingIfNeeded: rawValue)]
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }

    public var isLoopback: Bool { rawValue >> 24 == 127 }
    public var isLinkLocal: Bool { rawValue >> 16 == 0xA9FE } // 169.254/16
    public var isPrivate: Bool {
        rawValue >> 24 == 10 || rawValue >> 20 == 0xAC1 || rawValue >> 16 == 0xC0A8
    }

    public static let any = IPv4Addr(rawValue: 0)
    public static let limitedBroadcast = IPv4Addr(rawValue: .max)

    public static func < (lhs: IPv4Addr, rhs: IPv4Addr) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An IPv4 CIDR block.
public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    /// Network address (host bits cleared).
    public let network: IPv4Addr
    public let prefixLength: Int

    public init?(address: IPv4Addr, prefixLength: Int) {
        guard (0...32).contains(prefixLength) else { return nil }
        self.prefixLength = prefixLength
        self.network = IPv4Addr(rawValue: address.rawValue & Self.mask(prefixLength))
    }

    /// Builds a subnet from an interface address and its netmask; `nil` if the mask is not contiguous.
    public init?(address: IPv4Addr, netmask: IPv4Addr) {
        guard let prefix = Self.prefixLength(forNetmask: netmask) else { return nil }
        self.init(address: address, prefixLength: prefix)
    }

    /// Parses `"192.168.1.0/24"` (host bits are cleared, so `"192.168.1.7/24"` works too).
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPv4Addr(String(parts[0])),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let prefix = Int(parts[1]) else { return nil }
        self.init(address: address, prefixLength: prefix)
    }

    public static func mask(_ prefixLength: Int) -> UInt32 {
        prefixLength <= 0 ? 0 : UInt32.max << UInt32(32 - min(prefixLength, 32))
    }

    /// Returns the prefix length for a contiguous netmask such as 255.255.255.0, else `nil`.
    public static func prefixLength(forNetmask netmask: IPv4Addr) -> Int? {
        let ones = netmask.rawValue.nonzeroBitCount
        return mask(ones) == netmask.rawValue ? ones : nil
    }

    public var netmask: IPv4Addr { IPv4Addr(rawValue: Self.mask(prefixLength)) }
    public var broadcast: IPv4Addr { IPv4Addr(rawValue: network.rawValue | ~Self.mask(prefixLength)) }

    /// Number of usable host addresses (RFC 3021: a /31 has 2, a /32 has 1).
    public var hostCount: Int {
        switch prefixLength {
        case 32: return 1
        case 31: return 2
        default: return (1 << (32 - prefixLength)) - 2
        }
    }

    /// First and last usable host addresses.
    public var hostRange: ClosedRange<IPv4Addr> {
        switch prefixLength {
        case 32: return network...network
        case 31: return network...broadcast
        default:
            return IPv4Addr(rawValue: network.rawValue + 1)...IPv4Addr(rawValue: broadcast.rawValue - 1)
        }
    }

    public func contains(_ address: IPv4Addr) -> Bool {
        address.rawValue & Self.mask(prefixLength) == network.rawValue
    }

    /// Enumerates usable hosts in ascending order, skipping network and broadcast addresses
    /// (except for /31 and /32) and anything in `excluded` (pass your own address here).
    /// Clamp large subnets first with ``clamped(toPrefixAtLeast:around:)``.
    public func hosts(excluding excluded: Set<IPv4Addr> = []) -> [IPv4Addr] {
        let range = hostRange
        var result: [IPv4Addr] = []
        result.reserveCapacity(hostCount)
        for raw in range.lowerBound.rawValue...range.upperBound.rawValue {
            let address = IPv4Addr(rawValue: raw)
            if !excluded.contains(address) { result.append(address) }
        }
        return result
    }

    /// Narrows a large subnet (e.g. a /16 home network) to the /`prefix` block containing
    /// `address`, so a sweep stays bounded. Subnets already that small are returned unchanged.
    public func clamped(toPrefixAtLeast prefix: Int = 24, around address: IPv4Addr) -> IPv4Subnet {
        guard prefixLength < prefix, contains(address),
              let narrowed = IPv4Subnet(address: address, prefixLength: prefix) else { return self }
        return narrowed
    }

    public var description: String { "\(network)/\(prefixLength)" }
}
