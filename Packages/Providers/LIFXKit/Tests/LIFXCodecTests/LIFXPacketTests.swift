import Foundation
import Testing
@testable import LIFXCodec

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func bytes(_ hex: String) -> Data {
    let clean = hex.filter { !$0.isWhitespace }
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Suite("LIFX header and packets")
struct LIFXPacketTests {
    /// Broadcast discovery: tagged GetService (type 2), source 2, sequence 0, no payload.
    /// size 0x24, protocol 1024 | addressable | tagged = 0x3400.
    @Test func getServiceBroadcastBytes() {
        let packet = LIFXPacket(.getService, source: 2, target: .all, tagged: true, sequence: 0)
        let expected = "24000034" + "02000000" + "0000000000000000" + "000000000000" + "00" + "00"
            + "0000000000000000" + "0200" + "0000"
        #expect(hex(packet.encode()) == expected)
        #expect(packet.encode().count == 36)
    }

    /// The worked example from https://lan.developer.lifx.com/docs/encoding-a-packet :
    /// SetColor to d073d5001337, source 2, ack_required, sequence 1, hue 21845 (120 deg),
    /// saturation 65535, brightness 65535, kelvin 3500, duration 0 -> 49 bytes.
    @Test func documentedSetColorExample() throws {
        let expected = """
            3100001402000000
            d073d50013370000
            0000000000000201
            0000000000000000
            66000000005555ff
            ffffffac0d000000
            00
            """
        let serial = try #require(LIFXSerial("d073d5001337"))
        let color = HSBK(hue: 21845, saturation: 65535, brightness: 65535, kelvin: 3500)
        let packet = LIFXPacket(.lightSetColor(color, durationMs: 0), source: 2, target: serial, ackRequired: true, sequence: 1)
        let encoded = packet.encode()
        #expect(encoded.count == 49)
        #expect(hex(encoded) == hex(bytes(expected)))

        let decoded = try LIFXPacket.decode(bytes(expected))
        #expect(decoded.header.size == 49)
        #expect(decoded.header.tagged == false)
        #expect(decoded.header.addressable)
        #expect(decoded.header.source == 2)
        #expect(decoded.header.target == serial)
        #expect(decoded.header.ackRequired)
        #expect(!decoded.header.resRequired)
        #expect(decoded.header.sequence == 1)
        #expect(decoded.header.type == 102)
        #expect(decoded.message == .lightSetColor(color, durationMs: 0))
        // The documented hue for 120 degrees.
        #expect(HSBK.encodeHue(120) == 21845)
    }

    @Test func headerFlagBits() throws {
        let serial = try #require(LIFXSerial("D0:73:D5:01:02:03"))
        let p = LIFXPacket(.lightGet, source: 0xDEADBEEF, target: serial, ackRequired: true, resRequired: true, sequence: 255)
        let data = p.encode()
        #expect(data[2] == 0x00 && data[3] == 0x14) // addressable, not tagged
        #expect(Array(data[4..<8]) == [0xEF, 0xBE, 0xAD, 0xDE])
        #expect(Array(data[8..<16]) == [0xD0, 0x73, 0xD5, 0x01, 0x02, 0x03, 0, 0])
        #expect(data[22] == 0x03)
        #expect(data[23] == 255)
        #expect(data[32] == 101 && data[33] == 0)
        let back = try LIFXPacket.decode(data)
        #expect(back == p)
    }

    @Test func decodesStateService() throws {
        // Reply from d073d5001337 to source 2, seq 0: service 1 (UDP), port 56700 (0xDD7C).
        let data = bytes("29000014" + "02000000" + "d073d50013370000" + "000000000000" + "00" + "00"
            + "0000000000000000" + "0300" + "0000" + "01" + "7cdd0000")
        let p = try LIFXPacket.decode(data)
        #expect(p.header.target.hex == "d073d5001337")
        #expect(p.message == .stateService(service: 1, port: 56700))
    }

    @Test func decodesStateVersionFirmwareLabelPower() throws {
        let serial = try #require(LIFXSerial("d073d5001337"))
        func reply(_ type: UInt16, _ payload: String) -> Data {
            let header = LIFXHeader(source: 7, target: serial, sequence: 9, type: type)
            var w = ByteWriter()
            var h = header
            h.size = UInt16(36 + payload.count / 2)
            h.write(into: &w)
            return Data(w.bytes) + bytes(payload)
        }
        // StateVersion: vendor 1, product 27 (LIFX A19), reserved.
        #expect(try LIFXPacket.decode(reply(33, "01000000" + "1b000000" + "00000000")).message == .stateVersion(vendor: 1, product: 27))
        // StateHostFirmware: build, reserved, minor 80 (0x50), major 2.
        let fw = try LIFXPacket.decode(reply(15, "0011223344556677" + "0000000000000000" + "5000" + "0200")).message
        #expect(fw == .stateHostFirmware(build: 0x7766554433221100, major: 2, minor: 80))
        // StateLabel "Kitchen" NUL padded to 32.
        let label = "4b69746368656e" + String(repeating: "00", count: 25)
        #expect(try LIFXPacket.decode(reply(25, label)).message == .stateLabel("Kitchen"))
        #expect(try LIFXPacket.decode(reply(118, "ffff")).message == .lightStatePower(level: 65535))
        #expect(try LIFXPacket.decode(reply(45, "")).message == .acknowledgement)
        #expect(try LIFXPacket.decode(reply(223, "6600")).message == .stateUnhandled(type: 102))
    }

    @Test func decodesLightState() throws {
        let serial = try #require(LIFXSerial("d073d5001337"))
        // hue 0x5555, sat 0xffff, bri 0x8000, kelvin 3500, reserved, power 0xffff, label "Desk", reserved 8.
        let payload = "5555" + "ffff" + "0080" + "ac0d" + "0000" + "ffff" + "4465736b" + String(repeating: "00", count: 28)
            + "0000000000000000"
        var w = ByteWriter()
        LIFXHeader(size: UInt16(36 + 52), source: 3, target: serial, sequence: 4, type: 107).write(into: &w)
        let p = try LIFXPacket.decode(Data(w.bytes) + bytes(payload))
        guard case .lightState(let s) = p.message else {
            Issue.record("not a LightState: \(p.message)")
            return
        }
        #expect(s.color == HSBK(hue: 0x5555, saturation: 0xFFFF, brightness: 0x8000, kelvin: 3500))
        #expect(s.isOn)
        #expect(s.label == "Desk")
    }

    @Test func payloadSizesMatchSpec() {
        let c = HSBK.white
        let sizes: [(LIFXMessage, Int)] = [
            (.getService, 0), (.stateService(service: 1, port: 56700), 5), (.getHostFirmware, 0),
            (.stateHostFirmware(build: 1, major: 3, minor: 70), 20), (.getPower, 0), (.setPower(level: 0), 2),
            (.statePower(level: 1), 2), (.getLabel, 0), (.stateLabel("x"), 32), (.getVersion, 0),
            (.stateVersion(vendor: 1, product: 1), 12), (.acknowledgement, 0), (.stateUnhandled(type: 1), 2),
            (.lightGet, 0), (.lightSetColor(c, durationMs: 1), 13),
            (.lightSetWaveform(LIFXWaveform(color: c, periodMs: 1, cycles: 1, waveform: .sine)), 21),
            (.lightState(LIFXLightStatePayload(color: c, power: 0, label: "")), 52), (.lightGetPower, 0),
            (.lightSetPower(level: 1, durationMs: 1), 6), (.lightStatePower(level: 1), 2),
            (.setColorZones(start: 0, end: 1, color: c, durationMs: 0, apply: .apply), 15),
            (.getColorZones(start: 0, end: 255), 2), (.stateZone(count: 1, index: 0, color: c), 10),
            (.stateMultiZone(count: 8, index: 0, colors: [c]), 66),
            (.extendedSetColorZones(durationMs: 0, apply: .apply, index: 0, colors: [c]), 664),
            (.extendedGetColorZones, 0), (.extendedStateMultiZone(count: 1, index: 0, colors: [c]), 661),
        ]
        for (message, size) in sizes {
            #expect(message.encodePayload().count == size, "\(message.type)")
        }
    }

    @Test func everyMessageRoundTrips() throws {
        let c = HSBK(hue: 1000, saturation: 2000, brightness: 3000, kelvin: 4000)
        let multi = (0..<8).map { HSBK(hue: UInt16($0), saturation: 1, brightness: 2, kelvin: 3500) }
        let ext = (0..<30).map { HSBK(hue: UInt16($0 * 100), saturation: 65535, brightness: 65535, kelvin: 3500) }
        let messages: [LIFXMessage] = [
            .getService, .stateService(service: 1, port: 56700), .getHostFirmware,
            .stateHostFirmware(build: 42, major: 3, minor: 70), .getPower, .setPower(level: 65535),
            .statePower(level: 0), .getLabel, .stateLabel("Living room 💡"), .getVersion,
            .stateVersion(vendor: 1, product: 32), .acknowledgement, .stateUnhandled(type: 999),
            .lightGet, .lightSetColor(c, durationMs: 1500),
            .lightSetWaveform(LIFXWaveform(transient: true, color: c, periodMs: 600, cycles: 2.5, skewRatio: -16384, waveform: .pulse)),
            .lightState(LIFXLightStatePayload(color: c, power: 65535, label: "Desk")), .lightGetPower,
            .lightSetPower(level: 65535, durationMs: 250), .lightStatePower(level: 65535),
            .setColorZones(start: 2, end: 5, color: c, durationMs: 100, apply: .noApply),
            .getColorZones(start: 0, end: 255), .stateZone(count: 16, index: 3, color: c),
            .stateMultiZone(count: 16, index: 8, colors: multi),
            .extendedSetColorZones(durationMs: 10, apply: .apply, index: 0, colors: ext),
            .extendedGetColorZones, .extendedStateMultiZone(count: 30, index: 0, colors: ext),
            .unknown(type: 4242, payload: [1, 2, 3]),
        ]
        let serial = try #require(LIFXSerial("d073d5aabbcc"))
        for (i, m) in messages.enumerated() {
            let p = LIFXPacket(m, source: 99, target: serial, ackRequired: i % 2 == 0, resRequired: i % 3 == 0, sequence: UInt8(i))
            let back = try LIFXPacket.decode(p.encode())
            #expect(back == p, "type \(m.type)")
        }
    }

    @Test func labelTruncatesOnCharacterBoundary() throws {
        let long = String(repeating: "é", count: 20) // 40 UTF-8 bytes
        let payload = LIFXMessage.stateLabel(long).encodePayload()
        #expect(payload.count == 32)
        let decoded = try LIFXMessage.decode(type: 25, payload: payload)
        #expect(decoded == .stateLabel(String(repeating: "é", count: 16)))
    }

    @Test func rejectsMalformedPackets() throws {
        #expect(throws: LIFXCodecError.truncated(expected: 36, actual: 10)) { try LIFXPacket.decode(Data(count: 10)) }
        var data = LIFXPacket(.getService, source: 1).encode()
        data.append(0)
        #expect(throws: LIFXCodecError.sizeMismatch(declared: 36, actual: 37)) { try LIFXPacket.decode(data) }
        var wrongProtocol = LIFXPacket(.getService, source: 1).encode()
        wrongProtocol[2] = 0x01
        wrongProtocol[3] = 0x34
        #expect(throws: LIFXCodecError.unsupportedProtocol(0x401)) { try LIFXPacket.decode(wrongProtocol) }
        // StateService with a short payload.
        let serial = try #require(LIFXSerial("d073d5001337"))
        var w = ByteWriter()
        LIFXHeader(size: 38, source: 1, target: serial, type: 3).write(into: &w)
        #expect(throws: LIFXCodecError.self) { try LIFXPacket.decode(Data(w.bytes) + Data([1, 0])) }
    }

    @Test func serialParsing() {
        #expect(LIFXSerial("d073d5001337")?.macAddress == "d0:73:d5:00:13:37")
        #expect(LIFXSerial("D0-73-D5-00-13-37")?.hex == "d073d5001337")
        #expect(LIFXSerial("d073d50013") == nil)
        #expect(LIFXSerial("zz73d5001337") == nil)
        #expect(LIFXSerial.all.isAll)
    }
}
