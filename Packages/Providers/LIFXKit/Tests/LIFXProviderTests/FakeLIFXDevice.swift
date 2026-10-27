import Foundation
import LIFXCodec
import LIFXProvider

/// An in-process LIFX bulb/strip speaking the LAN protocol over real UDP on 127.0.0.1
/// (ephemeral port). Behaviour follows https://lan.developer.lifx.com : replies echo source and
/// sequence, carry the device serial as target; Get* always answer; Set* answer with an
/// Acknowledgement when `ack_required` and with the State when `res_required`; unknown types get
/// `StateUnhandled` (223).
final class FakeLIFXDevice: @unchecked Sendable {
    struct State {
        var label: String
        var color: HSBK
        var power: UInt16
        var zones: [HSBK]
        var received: [LIFXPacket] = []
        /// Drop this many incoming requests without answering (tests retries).
        var dropNext = 0
        /// Stop answering entirely.
        var offline = false
    }

    let serial: LIFXSerial
    let vendor: UInt32
    let product: UInt32
    let firmware: (major: UInt16, minor: UInt16)
    private let socket: TestUDPSocket
    private let lock = NSLock()
    private var state: State
    private var loop: Task<Void, Never>?

    var port: UInt16 { socket.port }
    var hostSpec: String { "127.0.0.1:\(port)" }

    init(
        serial: String = "d073d5001337",
        label: String = "Desk",
        vendor: UInt32 = 1,
        product: UInt32 = 27,
        firmware: (UInt16, UInt16) = (3, 70),
        color: HSBK = HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 3500),
        power: UInt16 = 65535,
        zoneCount: Int = 0
    ) throws {
        self.serial = LIFXSerial(serial)!
        self.vendor = vendor
        self.product = product
        self.firmware = firmware
        self.socket = try TestUDPSocket()
        let zones = (0..<zoneCount).map { HSBK(hue: UInt16(truncatingIfNeeded: $0 * 1000), saturation: 65535, brightness: 65535, kelvin: 3500) }
        self.state = State(label: label, color: color, power: power, zones: zones)
        let stream = socket.datagrams
        loop = Task.detached { [weak self] in
            for await d in stream {
                self?.handle(d)
            }
        }
    }

    deinit { stop() }

    func stop() {
        loop?.cancel()
        socket.close()
    }

    func with<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var snapshot: State { with { $0 } }

    /// Messages received of a given type.
    func received(_ type: UInt16) -> [LIFXPacket] { snapshot.received.filter { $0.header.type == type } }

    private func handle(_ d: LIFXDatagram) {
        guard let packet = try? LIFXPacket.decode(d.data) else { return }
        // Only accept broadcasts or packets addressed to us.
        guard packet.header.tagged || packet.header.target.isAll || packet.header.target == serial else { return }
        let replies: [LIFXMessage]? = with { s in
            s.received.append(packet)
            if s.offline { return nil }
            if s.dropNext > 0 {
                s.dropNext -= 1
                return nil
            }
            return respond(to: packet, state: &s)
        }
        guard let replies else { return }
        for message in replies {
            let reply = LIFXPacket(message, source: packet.header.source, target: serial, tagged: false, sequence: packet.header.sequence)
            try? socket.send(reply.encode(), to: d.host, port: d.port)
        }
    }

    private func respond(to packet: LIFXPacket, state s: inout State) -> [LIFXMessage] {
        var out: [LIFXMessage] = []
        if packet.header.ackRequired { out.append(.acknowledgement) }
        let lightState = { (s: State) in LIFXMessage.lightState(LIFXLightStatePayload(color: s.color, power: s.power, label: s.label)) }
        switch packet.message {
        case .getService:
            out.append(.stateService(service: LIFXMessage.serviceUDP, port: UInt32(port)))
        case .getHostFirmware:
            out.append(.stateHostFirmware(build: 0, major: firmware.major, minor: firmware.minor))
        case .getVersion:
            out.append(.stateVersion(vendor: vendor, product: product))
        case .getLabel:
            out.append(.stateLabel(s.label))
        case .getPower:
            out.append(.statePower(level: s.power))
        case .setPower(let level):
            s.power = level
            if packet.header.resRequired { out.append(.statePower(level: level)) }
        case .lightGet:
            out.append(lightState(s))
        case .lightGetPower:
            out.append(.lightStatePower(level: s.power))
        case .lightSetPower(let level, _):
            if packet.header.resRequired { out.append(.lightStatePower(level: s.power)) }
            s.power = level
        case .lightSetColor(let color, _):
            if packet.header.resRequired { out.append(lightState(s)) }
            s.color = color
            if !s.zones.isEmpty { s.zones = Array(repeating: color, count: s.zones.count) }
        case .lightSetWaveform:
            break
        case .getColorZones(let start, let end):
            guard !s.zones.isEmpty else {
                out.append(.stateUnhandled(type: packet.header.type))
                break
            }
            let count = s.zones.count
            var index = Int(start)
            while index <= min(Int(end), count - 1) {
                let chunk = Array(s.zones[index..<min(index + 8, count)])
                out.append(.stateMultiZone(count: UInt8(count), index: UInt8(index), colors: chunk))
                index += 8
            }
        case .setColorZones(let start, let end, let color, _, _):
            for i in Int(start)...Int(end) where i < s.zones.count { s.zones[i] = color }
        case .extendedGetColorZones:
            let count = s.zones.count
            var index = 0
            repeat {
                let chunk = Array(s.zones[index..<min(index + 82, count)])
                out.append(.extendedStateMultiZone(count: UInt16(count), index: UInt16(index), colors: chunk))
                index += 82
            } while index < count
        case .extendedSetColorZones(_, _, let index, let colors):
            for (i, c) in colors.enumerated() where Int(index) + i < s.zones.count { s.zones[Int(index) + i] = c }
        default:
            out.append(.stateUnhandled(type: packet.header.type))
        }
        return out
    }
}
