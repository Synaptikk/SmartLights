import Foundation
import Testing
@testable import NetKit

@Suite("SubnetMath")
struct SubnetMathTests {
    @Test func parseAndFormatIPv4() {
        #expect(IPv4Addr("192.168.1.20") == IPv4Addr(192, 168, 1, 20))
        #expect(IPv4Addr("192.168.1.20")?.description == "192.168.1.20")
        #expect(IPv4Addr(rawValue: 0xC0A8_0114).octets == [192, 168, 1, 20])
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "a.b.c.d", "1..2.3", "-1.2.3.4", "1.2.3.4 ", "+1.2.3.4"] {
            #expect(IPv4Addr(bad) == nil, "\(bad)")
        }
        #expect(IPv4Addr("10.0.0.1")!.isPrivate)
        #expect(IPv4Addr("172.16.5.1")!.isPrivate)
        #expect(!IPv4Addr("172.32.0.1")!.isPrivate)
        #expect(IPv4Addr("169.254.3.4")!.isLinkLocal)
        #expect(IPv4Addr("127.0.0.1")!.isLoopback)
    }

    @Test func slash24() throws {
        let me = try #require(IPv4Addr("192.168.1.37"))
        let subnet = try #require(IPv4Subnet(address: me, netmask: IPv4Addr(255, 255, 255, 0)))
        #expect(subnet.description == "192.168.1.0/24")
        #expect(subnet.broadcast == IPv4Addr(192, 168, 1, 255))
        #expect(subnet.netmask == IPv4Addr(255, 255, 255, 0))
        #expect(subnet.hostCount == 254)
        let hosts = subnet.hosts(excluding: [me])
        #expect(hosts.count == 253)
        #expect(hosts.first == IPv4Addr(192, 168, 1, 1))
        #expect(hosts.last == IPv4Addr(192, 168, 1, 254))
        #expect(!hosts.contains(me))
        #expect(!hosts.contains(subnet.network))
        #expect(!hosts.contains(subnet.broadcast))
        #expect(subnet.contains(me))
        #expect(!subnet.contains(IPv4Addr(192, 168, 2, 1)))
    }

    @Test func cidrParsingNormalisesHostBits() {
        #expect(IPv4Subnet(cidr: "10.1.2.3/8")?.description == "10.0.0.0/8")
        #expect(IPv4Subnet(cidr: "10.1.2.3/33") == nil)
        #expect(IPv4Subnet(cidr: "10.1.2.3") == nil)
        #expect(IPv4Subnet(cidr: "10.1.2.3/-1") == nil)
        #expect(IPv4Subnet(cidr: "0.0.0.0/0")?.broadcast == .limitedBroadcast)
    }

    @Test func smallPrefixes() throws {
        let s30 = try #require(IPv4Subnet(cidr: "192.168.0.4/30"))
        #expect(s30.hosts() == [IPv4Addr(192, 168, 0, 5), IPv4Addr(192, 168, 0, 6)])
        #expect(s30.broadcast == IPv4Addr(192, 168, 0, 7))
        let s31 = try #require(IPv4Subnet(cidr: "192.168.0.4/31"))
        #expect(s31.hosts() == [IPv4Addr(192, 168, 0, 4), IPv4Addr(192, 168, 0, 5)])
        let s32 = try #require(IPv4Subnet(cidr: "192.168.0.4/32"))
        #expect(s32.hosts() == [IPv4Addr(192, 168, 0, 4)])
        #expect(s32.hosts(excluding: [IPv4Addr(192, 168, 0, 4)]).isEmpty)
    }

    @Test func netmaskToPrefix() {
        #expect(IPv4Subnet.prefixLength(forNetmask: IPv4Addr(255, 255, 255, 0)) == 24)
        #expect(IPv4Subnet.prefixLength(forNetmask: IPv4Addr(255, 255, 252, 0)) == 22)
        #expect(IPv4Subnet.prefixLength(forNetmask: IPv4Addr(0, 0, 0, 0)) == 0)
        #expect(IPv4Subnet.prefixLength(forNetmask: .limitedBroadcast) == 32)
        #expect(IPv4Subnet.prefixLength(forNetmask: IPv4Addr(255, 0, 255, 0)) == nil)
        #expect(IPv4Subnet(address: IPv4Addr(10, 0, 0, 1), netmask: IPv4Addr(255, 0, 255, 0)) == nil)
    }

    @Test func clampLargeSubnetToSlash24AroundSelf() throws {
        let me = try #require(IPv4Addr("172.16.40.9"))
        let s16 = try #require(IPv4Subnet(address: me, prefixLength: 16))
        #expect(s16.hostCount == 65_534)
        let clamped = s16.clamped(toPrefixAtLeast: 24, around: me)
        #expect(clamped.description == "172.16.40.0/24")
        #expect(clamped.hosts(excluding: [me]).count == 253)
        let s25 = try #require(IPv4Subnet(cidr: "192.168.1.128/25"))
        #expect(s25.clamped(around: IPv4Addr(192, 168, 1, 130)) == s25)
        #expect(s25.hosts().count == 126)
    }
}
