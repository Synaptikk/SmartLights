import Foundation
import LightCore
import MagicHomeCodec
import Synchronization
@testable import MagicHomeProvider

/// In-process Magic Home device: answers the UDP 48899 discovery datagram and speaks the LEDENET
/// TCP dialect of its model over in-memory connections (state query, power, levels, presets).
final class FakeMagicHomeDevice: Sendable {
    struct Snapshot {
        var raw: MagicHomeRawState
        var received: [Data] = []
        var connections: [Int: FakeMagicHomeConnection] = [:]
        var connectCount = 0
        var offline = false
        /// State queries to ignore before answering again (packet loss).
        var dropQueries = 0
        /// Answer discovery datagrams.
        var answersUDP = true
    }

    let ip: String
    let mac: String
    let hardware: String
    private let state: Mutex<Snapshot>
    private let nextID = Mutex(0)

    init(ip: String, mac: String, hardware: String = "AK001-ZJ2145", raw: MagicHomeRawState) {
        self.ip = ip
        self.mac = mac
        self.hardware = hardware
        state = Mutex(Snapshot(raw: raw))
    }

    var raw: MagicHomeRawState { state.withLock { $0.raw } }
    var received: [Data] { state.withLock { $0.received } }
    var connectCount: Int { state.withLock { $0.connectCount } }
    var openConnections: Int { state.withLock { $0.connections.count } }
    var profile: MagicHomeProfile { MagicHomeProfile(state: raw) }

    func setOffline(_ offline: Bool) {
        let open: [FakeMagicHomeConnection] = state.withLock { s in
            s.offline = offline
            return offline ? Array(s.connections.values) : []
        }
        for c in open { c.finish(throwing: LightCoreError.transport("connection reset")) }
    }

    func dropQueries(_ n: Int) { state.withLock { $0.dropQueries = n } }
    func setAnswersUDP(_ on: Bool) { state.withLock { $0.answersUDP = on } }

    /// Simulates a change from the vendor app / IR remote; push firmware reports it.
    func externalChange(_ change: (inout MagicHomeRawState) -> Void) {
        let (open, raw, pushes): ([FakeMagicHomeConnection], MagicHomeRawState, Bool) = state.withLock { s in
            change(&s.raw)
            return (Array(s.connections.values), s.raw, MagicHomeProfile(state: s.raw).protocol?.pushesUpdates == true)
        }
        guard pushes else { return }
        for c in open { c.deliver(frame(raw.encode())) }
    }

    // MARK: UDP

    func discoveryReply(to payload: Data) -> Data? {
        guard state.withLock({ $0.answersUDP && !$0.offline }) else { return nil }
        if payload == MagicHomeDiscovery.request {
            return MagicHomeDiscovery.encode(.init(ip: ip, mac: mac, model: hardware))
        }
        if payload == MagicHomeDiscovery.versionRequest {
            let r = raw
            return Data(String(format: "+ok=%02X_%02X_20210106_ZG-BL\r", r.modelNumber, r.version).utf8)
        }
        return nil
    }

    // MARK: TCP

    func connect() throws -> FakeMagicHomeConnection {
        let id = nextID.withLock { n -> Int in n += 1; return n }
        let connection = FakeMagicHomeConnection(id: id, device: self)
        try state.withLock { s in
            guard !s.offline else { throw LightCoreError.unreachable("\(ip):5577 connection refused") }
            s.connectCount += 1
            s.connections[id] = connection
        }
        return connection
    }

    func closed(_ id: Int) { _ = state.withLock { $0.connections.removeValue(forKey: id) } }

    private func frame(_ inner: Data) -> Data {
        profile.protocol?.wrapped == true ? MagicHomeMessage.wrap(inner, counter: 1) : inner
    }

    /// Handles one client write (may contain several messages).
    func handle(_ data: Data, from connection: FakeMagicHomeConnection) {
        var bytes = [UInt8](data)
        while !bytes.isEmpty {
            var message: [UInt8]
            if bytes[0] == 0xB0, bytes.count >= 10 {
                let total = 10 + (Int(bytes[8]) << 8 | Int(bytes[9])) + 1
                guard bytes.count >= total, let inner = MagicHomeMessage.unwrap(Data(bytes[0..<total])) else { return }
                bytes.removeFirst(total)
                message = [UInt8](inner)
            } else {
                let length: Int
                switch bytes[0] {
                case 0x81, 0x71: length = 4
                case 0x61, 0x38: length = 5
                case 0x35: length = 9
                case 0x31, 0x41: length = profile.protocol?.nineByteLevels == true ? 9 : 8
                default: length = bytes.count
                }
                guard bytes.count >= length else { return }
                message = Array(bytes[0..<length])
                bytes.removeFirst(length)
            }
            apply(message, from: connection)
        }
    }

    private func apply(_ m: [UInt8], from connection: FakeMagicHomeConnection) {
        guard MagicHomeMessage.isChecksumValid(Data(m)) else { return }
        let reply: Data? = state.withLock { s in
            s.received.append(Data(m))
            let proto = MagicHomeProfile(state: s.raw).protocol
            switch m[0] {
            case 0x81:
                if s.dropQueries > 0 { s.dropQueries -= 1; return nil }
                return s.raw.encode()
            case 0x71:
                s.raw.power = m[1]
                return proto?.pushesUpdates == true ? MagicHomeMessage.withChecksum([0x0F, 0x71, m[1]]) : nil
            case 0x31, 0x41:
                let nine = proto?.nineByteLevels == true
                let mode = nine ? m[6] : m[5]
                if mode != MagicHomeWriteMode.whites.rawValue {
                    (s.raw.red, s.raw.green, s.raw.blue) = (m[1], m[2], m[3])
                }
                if mode != MagicHomeWriteMode.colors.rawValue {
                    s.raw.warmWhite = m[4]
                    if nine { s.raw.coolWhite = m[5] }
                }
                s.raw.presetPattern = 0x61
                if proto?.autoOn == true { s.raw.power = MagicHomeRawState.onByte }
                return nil
            case 0x35:
                s.raw.warmWhite = m[2]
                s.raw.coolWhite = m[3]
                if proto?.autoOn == true { s.raw.power = MagicHomeRawState.onByte }
                return nil
            case 0x61, 0x38:
                s.raw.presetPattern = m[1]
                s.raw.speed = m[2]
                if proto?.autoOn == true { s.raw.power = MagicHomeRawState.onByte }
                return nil
            default:
                return nil
            }
        }
        if let reply { connection.deliver(frame(reply)) }
    }
}

/// In-memory TCP connection to a `FakeMagicHomeDevice`.
final class FakeMagicHomeConnection: MagicHomeConnection, Sendable {
    let id: Int
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let device: FakeMagicHomeDevice
    private let isClosed = Mutex(false)

    init(id: Int, device: FakeMagicHomeDevice) {
        self.id = id
        self.device = device
        (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func send(_ data: Data) async throws {
        guard !isClosed.withLock({ $0 }) else { throw LightCoreError.transport("connection closed") }
        device.handle(data, from: self)
    }

    func deliver(_ data: Data) {
        // Split like a real TCP stream sometimes does.
        if data.count > 4 {
            continuation.yield(data.prefix(2))
            continuation.yield(data.dropFirst(2))
        } else {
            continuation.yield(data)
        }
    }

    func finish(throwing error: any Error) {
        isClosed.withLock { $0 = true }
        continuation.finish(throwing: error)
        device.closed(id)
    }

    func close() {
        isClosed.withLock { $0 = true }
        continuation.finish()
        device.closed(id)
    }
}

/// A LAN of fake devices, exposed as a `MagicHomeNetworkEnvironment`.
final class FakeMagicHomeNetwork: Sendable {
    private let devices: Mutex<[String: FakeMagicHomeDevice]>
    let sweep: [String]
    let broadcastAvailable: Bool

    init(_ devices: [FakeMagicHomeDevice], sweep: [String] = [], broadcast: Bool = true) {
        self.devices = Mutex(Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) }))
        self.sweep = sweep
        self.broadcastAvailable = broadcast
    }

    func device(at ip: String) -> FakeMagicHomeDevice? { devices.withLock { $0[ip] } }

    /// Moves a device to another IP (DHCP renewal).
    func move(_ device: FakeMagicHomeDevice, to ip: String) -> FakeMagicHomeDevice {
        let moved = FakeMagicHomeDevice(ip: ip, mac: device.mac, hardware: device.hardware, raw: device.raw)
        devices.withLock { d in
            d[device.ip] = nil
            d[ip] = moved
        }
        device.setOffline(true)
        return moved
    }

    var environment: MagicHomeNetworkEnvironment {
        let net = self
        let broadcast: @Sendable (Data, UInt16, Duration) -> AsyncStream<MagicHomeDatagram> = { payload, _, _ in
            let all = net.devices.withLock { Array($0.values) }
            return AsyncStream { c in
                for d in all { if let r = d.discoveryReply(to: payload) { c.yield(MagicHomeDatagram(data: r, host: d.ip)) } }
                c.finish()
            }
        }
        return MagicHomeNetworkEnvironment(
            connect: { host, _, _ in
                guard let d = net.device(at: host) else { throw LightCoreError.unreachable("\(host): no route") }
                return try d.connect()
            },
            broadcast: broadcastAvailable ? broadcast : nil,
            unicast: { payload, host, _, _ in
                guard let d = net.device(at: host), let r = d.discoveryReply(to: payload) else { return nil }
                return MagicHomeDatagram(data: r, host: host)
            },
            sweepHosts: { net.sweep }
        )
    }
}
