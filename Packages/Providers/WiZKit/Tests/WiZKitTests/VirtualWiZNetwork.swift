import Foundation
import LightCore
import NetKit
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import WiZKit

/// In-process `WiZTransport` for tests: virtual IPv4 addresses (e.g. 10.0.0.2:38899) are routed
/// to `FakeWiZBulb`s listening on 127.0.0.1 ephemeral ports, and replies/pushes from those ports
/// are translated back to the virtual address. Supports a virtual broadcast address, packet
/// drops, re-routing (IP changes) and injected datagrams.
final class VirtualWiZNetwork: WiZTransport {
    struct State {
        var routes: [IPv4Addr: Int] = [:]
        var drops: [IPv4Addr: Int] = [:]
        var bound: [UInt16: Int] = [:]
        var endpoints: [VirtualEndpoint] = []
        var sent: [(host: IPv4Addr, payload: String)] = []
    }

    let state = NIOLockedValueBox(State())
    let broadcast = IPv4Addr(10, 0, 0, 255)
    let local = IPv4Addr(127, 0, 0, 1)
    let hosts: [IPv4Addr]
    let status: BroadcastCapabilityStatus

    init(sweep hosts: [IPv4Addr] = (1...10).map { IPv4Addr(10, 0, 0, UInt8($0)) }, broadcastStatus: BroadcastCapabilityStatus = .notEntitled) {
        self.hosts = hosts
        self.status = broadcastStatus
    }

    func route(_ host: IPv4Addr, toPort port: Int) { state.withLockedValue { $0.routes[host] = port } }
    func unroute(_ host: IPv4Addr) { _ = state.withLockedValue { $0.routes.removeValue(forKey: host) } }
    func drop(_ host: IPv4Addr, next count: Int) { state.withLockedValue { $0.drops[host] = count } }
    /// The real port behind a requested well-known port (e.g. the push listener on 38900).
    func boundPort(forRequested port: UInt16) -> Int? { state.withLockedValue { $0.bound[port] } }
    var sent: [(host: IPv4Addr, payload: String)] { state.withLockedValue { $0.sent } }
    var endpoints: [VirtualEndpoint] { state.withLockedValue { $0.endpoints } }

    func resolve(_ host: IPv4Addr, payload: Data) -> [Int] {
        state.withLockedValue { s in
            s.sent.append((host, String(decoding: payload, as: UTF8.self)))
            if host == broadcast { return Array(s.routes.values) }
            if let n = s.drops[host], n > 0 {
                s.drops[host] = n - 1
                return []
            }
            return s.routes[host].map { [$0] } ?? []
        }
    }

    func virtualAddress(for address: SocketAddress) -> IPv4Addr {
        let port = address.port
        return state.withLockedValue { s in s.routes.first(where: { $0.value == port })?.key }
            ?? address.ipAddress.flatMap { IPv4Addr($0) } ?? local
    }

    // MARK: WiZTransport

    func bind(port: UInt16, broadcast: Bool) async throws -> any WiZDatagramEndpoint {
        let (stream, continuation) = AsyncStream.makeStream(of: Datagram.self)
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { [self] ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(Receiver { address, bytes in
                        continuation.yield(Datagram(data: Data(bytes), host: self.virtualAddress(for: address), port: WiZPortForTests.control))
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let endpoint = VirtualEndpoint(channel: channel, network: self, datagrams: stream, continuation: continuation)
        state.withLockedValue { s in
            if port != 0, let real = channel.localAddress?.port { s.bound[port] = real }
            s.endpoints.append(endpoint)
        }
        return endpoint
    }

    func localIPv4Address() async -> IPv4Addr? { local }
    func sweepHosts() async -> [IPv4Addr] { hosts }
    func broadcastAddresses() async -> [IPv4Addr] { [broadcast] }
    func broadcastStatus() async -> BroadcastCapabilityStatus { status }
}

enum WiZPortForTests {
    static let control: UInt16 = 38899
}

final class VirtualEndpoint: WiZDatagramEndpoint {
    let channel: any Channel
    let network: VirtualWiZNetwork
    let datagrams: AsyncStream<Datagram>
    let continuation: AsyncStream<Datagram>.Continuation

    init(channel: any Channel, network: VirtualWiZNetwork, datagrams: AsyncStream<Datagram>, continuation: AsyncStream<Datagram>.Continuation) {
        self.channel = channel
        self.network = network
        self.datagrams = datagrams
        self.continuation = continuation
    }

    var localPort: UInt16? { channel.localAddress?.port.map { UInt16($0) } }

    func sendDatagram(_ data: Data, to host: IPv4Addr, port: UInt16) throws {
        for real in network.resolve(host, payload: data) {
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: real)
            let buffer = channel.allocator.buffer(bytes: Array(data))
            channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer), promise: nil)
        }
    }

    /// Delivers a datagram as if it had arrived from `host`.
    func inject(_ text: String, from host: IPv4Addr) {
        continuation.yield(Datagram(data: Data(text.utf8), host: host, port: WiZPortForTests.control))
    }

    func close() {
        channel.close(promise: nil)
        continuation.finish()
    }
}

private final class Receiver: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let deliver: @Sendable (SocketAddress, [UInt8]) -> Void

    init(_ deliver: @escaping @Sendable (SocketAddress, [UInt8]) -> Void) { self.deliver = deliver }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        deliver(envelope.remoteAddress, Array(envelope.data.readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}

/// Collects provider events for assertions.
actor EventRecorder {
    private(set) var events: [ProviderEvent] = []
    func append(_ e: ProviderEvent) { events.append(e) }

    func first(within timeout: Duration = .seconds(5), where predicate: @Sendable (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let e = events.first(where: predicate) { return e }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events.first(where: predicate)
    }
}

/// Polls `condition` until true or timeout.
func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
