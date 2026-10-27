import Foundation
import LightCore
import Testing
@testable import MagicHomeCodec

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined(separator: " ") }
func bytes(_ hex: String) -> Data {
    let clean = hex.filter(\.isHexDigit)
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// Byte vectors are the ones asserted by flux_led's own test suite (tests.py) and the protocol
/// docstrings in flux_led/protocol.py; see NOTICES.md.
@Suite("LEDENET messages")
struct MagicHomeMessageTests {
    @Test func checksumIsLowByteOfSum() {
        #expect(MagicHomeMessage.checksum([0x81, 0x8A, 0x8B]) == 0x96)
        #expect(MagicHomeMessage.checksum([0xFF, 0xFF, 0x02]) == 0x00)
        #expect(MagicHomeMessage.isChecksumValid(bytes("81 8a 8b 96")))
        #expect(!MagicHomeMessage.isChecksumValid(bytes("81 8a 8b 97")))
    }

    @Test func stateQuery() {
        #expect(hex(MagicHomeMessage.stateQuery()) == "81 8a 8b 96")
    }

    @Test func power() {
        #expect(hex(MagicHomeMessage.power(true)) == "71 23 0f a3")
        #expect(hex(MagicHomeMessage.power(false)) == "71 24 0f a4")
    }

    /// flux_led: model 0x45 `setRgb(1, 25, 80)` -> `31 01 19 50 00 f0 0f 9a` (colours-only write mode).
    @Test func eightByteColorLevels() {
        let m = MagicHomeMessage.levels(MagicHomeLevels(red: 1, green: 25, blue: 80), writeMode: .colors, protocol: .ledenet8Byte)
        #expect(hex(m) == "31 01 19 50 00 f0 0f 9a")
    }

    /// flux_led: model 0x45 `setWarmWhite255(25)` -> `31 00 00 00 19 0f 0f 68`.
    @Test func eightByteWhiteLevels() {
        let m = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 25), writeMode: .whites, protocol: .ledenet8Byte)
        #expect(hex(m) == "31 00 00 00 19 0f 0f 68")
    }

    /// flux_led: model 0x35 `setWhiteTemperature(2700, 255)` -> `31 00 00 00 ff 00 0f 0f 4e`.
    @Test func nineByteLevels() {
        let m = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 255, coolWhite: 0), writeMode: .whites, protocol: .ledenet9Byte)
        #expect(hex(m) == "31 00 00 00 ff 00 0f 0f 4e")
        // flux_led: model 0x35 `setWarmWhite255(25)` (cold mirrors warm) -> `... 19 19 0f 0f 81`.
        let both = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 25, coolWhite: 25), writeMode: .whites, protocol: .ledenet9ByteAutoOn)
        #expect(hex(both) == "31 00 00 00 19 19 0f 0f 81")
    }

    @Test func transientLevelsUse0x41() {
        let m = MagicHomeMessage.levels(MagicHomeLevels(red: 255, green: 0, blue: 0), writeMode: .colors, protocol: .ledenet8Byte, persist: false)
        #expect(m.first == 0x41)
        #expect(MagicHomeMessage.isChecksumValid(m))
    }

    /// protocol.py `ProtocolLEDENETCCTWrapped` docstring vectors.
    @Test func wrappedCCTLevels() {
        let warm = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 255, coolWhite: 0), writeMode: .all, protocol: .cctWrapped, counter: 0x52)
        #expect(hex(warm) == "b0 b1 b2 b3 00 01 01 52 00 09 35 b1 00 64 00 00 00 03 4d bd")
        let cool = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 0, coolWhite: 255), writeMode: .all, protocol: .cctWrapped, counter: 0x72)
        #expect(hex(cool) == "b0 b1 b2 b3 00 01 01 72 00 09 35 b1 64 64 00 00 00 03 b1 a5")
        let half = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 0, coolWhite: 128), writeMode: .all, protocol: .cctWrapped, counter: 0x9F)
        #expect(hex(half) == "b0 b1 b2 b3 00 01 01 9f 00 09 35 b1 64 32 00 00 00 03 7f 6e")
        // Unwrapped CCT dialect (0x09): same inner message.
        let plain = MagicHomeMessage.levels(MagicHomeLevels(warmWhite: 255, coolWhite: 0), writeMode: .all, protocol: .cct)
        #expect(hex(plain) == "35 b1 00 64 00 00 00 03 4d")
        #expect(MagicHomeMessage.unwrap(warm) == plain)
    }

    @Test func wrappedQueryAndPower() {
        let q = MagicHomeMessage.stateQuery(.cctWrapped, counter: 1)
        #expect(MagicHomeMessage.unwrap(q) == MagicHomeMessage.stateQuery())
        let p = MagicHomeMessage.power(true, protocol: .cctWrapped, counter: 2)
        #expect(MagicHomeMessage.unwrap(p) == MagicHomeMessage.power(true))
    }

    /// flux_led: `61 38 10 0f b8` (colorjump, speed 50) and dimmable `38 28 10 32 a2`
    /// (blue_fade, speed 50, brightness 50), `38 38 10 64 e4`.
    @Test func presetPatterns() {
        #expect(hex(MagicHomeMessage.presetPattern(0x38, speed: 50, brightness: 100, protocol: .ledenet9Byte)) == "61 38 10 0f b8")
        #expect(hex(MagicHomeMessage.presetPattern(0x28, speed: 50, brightness: 50, protocol: .ledenet8ByteDimmableEffects)) == "38 28 10 32 a2")
        #expect(hex(MagicHomeMessage.presetPattern(0x38, speed: 50, brightness: 100, protocol: .ledenet9ByteDimmableEffects)) == "38 38 10 64 e4")
    }

    @Test func effectSpeedDelayRoundTrip() {
        #expect(MagicHomeEffect.delay(forSpeed: 100) == 1)
        #expect(MagicHomeEffect.delay(forSpeed: 0) == 31)
        #expect(MagicHomeEffect.delay(forSpeed: 50) == 0x10)
        #expect(MagicHomeEffect.speed(forDelay: 0x10) == 50)
    }

    @Test func whiteMix() {
        #expect(MagicHomeWhite.levels(kelvin: 2700, brightness: 255) == (255, 0))
        #expect(MagicHomeWhite.levels(kelvin: 6500, brightness: 255) == (0, 255))
        let mid = MagicHomeWhite.kelvin(warm: 128, cool: 127)
        #expect(abs(mid.kelvin - 4600) <= 10)
        #expect(mid.brightness == 255)
        #expect(MagicHomeWhite.kelvin(warm: 0, cool: 0) == (2700, 0))
        #expect(MagicHomeWhite.scaledTemperature(warm: 0, cool: 255) == (100, 100))
        #expect(MagicHomeWhite.levels(scaledTemperature: 100, brightness: 50) == (0, 128))
    }
}

@Suite("LEDENET state and framing")
struct MagicHomeStateTests {
    /// flux_led tests: model 0x45, on, static colour (182, 0, 152), version 4.
    static let rgbwBulb = bytes("81 45 23 61 21 10 b6 00 98 00 04 00 f0 bd")
    /// flux_led tests: model 0x25 running colorjump.
    static let effectController = bytes("81 25 23 38 05 10 b6 00 98 19 04 25 0f b5")

    @Test func parsesStateResponse() throws {
        let s = try MagicHomeRawState(Self.rgbwBulb)
        #expect(s.modelNumber == 0x45)
        #expect(s.isOn)
        #expect(s.presetPattern == 0x61)
        #expect(s.mode == 0x21)
        #expect((s.red, s.green, s.blue, s.warmWhite) == (182, 0, 152, 0))
        #expect(s.version == 4)
        #expect(s.colorMode == 0xF0)
        #expect(s.encode() == Self.rgbwBulb)
    }

    @Test func rejectsBadStates() {
        #expect(throws: MagicHomeDecodeError.checksum) { try MagicHomeRawState(bytes("81 45 23 61 21 10 b6 00 98 00 04 00 f0 be")) }
        #expect(throws: MagicHomeDecodeError.unexpectedHead(0x66)) { try MagicHomeRawState(bytes("66 45 23 61 21 10 b6 00 98 00 04 00 f0 bd")) }
        #expect(throws: MagicHomeDecodeError.length(expected: 14, got: 3)) { try MagicHomeRawState(bytes("81 45 23")) }
    }

    @Test func framesSplitAndCoalescedMessages() {
        var framer = MagicHomeFramer()
        // flux_led reads the state in two parts (2 + 12 bytes).
        #expect(framer.push(Self.rgbwBulb.prefix(2)).isEmpty)
        let first = framer.push(Self.rgbwBulb.dropFirst(2))
        #expect(first == [.state(try! MagicHomeRawState(Self.rgbwBulb))])
        // Power push and a state in one segment.
        let combined = framer.push(bytes("0f 71 23 a3") + Self.effectController)
        #expect(combined.count == 2)
        #expect(combined.first == .power(on: true))
        if case .state(let s) = combined.last { #expect(s.presetPattern == 0x38) } else { Issue.record("expected state") }
    }

    @Test func framesWrappedState() throws {
        let inner = MagicHomeRawState(modelNumber: 0x1C, power: 0x23, warmWhite: 40, coolWhite: 80).encode()
        let wrapped = MagicHomeMessage.wrap(inner, counter: 7)
        var framer = MagicHomeFramer()
        let out = framer.push(wrapped.prefix(5)) + framer.push(wrapped.dropFirst(5))
        #expect(out == [.state(try MagicHomeRawState(inner))])
    }

    @Test func clockAndUnknownMessages() {
        var framer = MagicHomeFramer()
        // flux_led tests: get-time reply (12 bytes) is consumed as one message.
        let clock = framer.push(bytes("0f 11 14 16 01 02 10 36 02 07 00 9c"))
        #expect(clock.count == 1)
        if case .other(let d) = clock.first { #expect(d.count == 12) } else { Issue.record("expected other") }
        let junk = framer.push(bytes("de ad be ef"))
        #expect(junk.count == 1)
        #expect(framer.push(Self.rgbwBulb).count == 1)
    }
}

@Suite("Discovery text")
struct MagicHomeDiscoveryTests {
    @Test func parsesReply() {
        let r = MagicHomeDiscovery.parseReply(Data("192.168.214.252,B4E842E10588,AK001-ZJ2145".utf8))
        #expect(r == MagicHomeDiscovery.Reply(ip: "192.168.214.252", mac: "b4e842e10588", model: "AK001-ZJ2145"))
        #expect(MagicHomeDiscovery.parseReply(Data("HF-A11ASSISTHREAD".utf8)) == nil)
        #expect(MagicHomeDiscovery.parseReply(Data("1.2.3.4,nothex,M".utf8)) == nil)
        #expect(MagicHomeDiscovery.encode(r!) == Data("192.168.214.252,B4E842E10588,AK001-ZJ2145".utf8))
    }

    @Test func parsesVersion() {
        let v = MagicHomeDiscovery.parseVersion(Data("+ok=07_06_20210106_ZG-BL\r".utf8))
        #expect(v == MagicHomeDiscovery.Version(modelNumber: 0x07, version: 0x06, firmwareDate: "20210106", info: "ZG-BL"))
        #expect(MagicHomeDiscovery.parseVersion(Data("+ok=33".utf8)) == MagicHomeDiscovery.Version(version: 0x33))
        #expect(MagicHomeDiscovery.parseVersion(Data("ERR".utf8)) == nil)
    }

    @Test func requestBytes() {
        #expect(String(data: MagicHomeDiscovery.request, encoding: .utf8) == "HF-A11ASSISTHREAD")
        #expect(MagicHomeDiscovery.versionRequest == Data([0x41, 0x54, 0x2B, 0x4C, 0x56, 0x45, 0x52, 0x0D]))
        #expect(MagicHomeDiscovery.normalizeMAC("b4:e8:42:e1:05:88") == "b4e842e10588")
    }
}

@Suite("Model table")
struct MagicHomeModelTests {
    @Test func protocolByFirmwareVersion() {
        let rgbw = MagicHomeModel.lookup(0x06)
        #expect(rgbw.protocol(forVersion: 0) == .ledenet8Byte)
        #expect(rgbw.protocol(forVersion: 1) == .ledenet8ByteAutoOn)
        #expect(rgbw.protocol(forVersion: 5) == .ledenet8ByteDimmableEffects)
        let bulb = MagicHomeModel.lookup(0x35)
        #expect(bulb.protocol(forVersion: 4) == .ledenet9Byte)
        #expect(bulb.protocol(forVersion: 9) == .ledenet9ByteDimmableEffects)
        #expect(bulb.protocol(forVersion: 10) == nil)
        #expect(MagicHomeModel.lookup(0xA3).supported == false)
    }

    @Test func layouts() {
        #expect(MagicHomeModel.lookup(0x07).layout(forMode: 0x17) == .rgbOrCCT)
        #expect(MagicHomeModel.lookup(0x07).layout(forMode: 0x25) == .rgbww)
        #expect(MagicHomeModel.lookup(0x06).layout(forMode: 0x16) == .rgbOrWhite)
        #expect(MagicHomeModel.lookup(0x06).layout(forMode: 0x21) == .rgbw)
        #expect(MagicHomeModel.lookup(0x25).layout(forMode: 0x02) == .cct)
        #expect(MagicHomeModel.lookup(0x97).layout == .switch)
        // Unknown ids: 8-byte, layout from the low nibble of the mode byte.
        let unknown = MagicHomeModel.lookup(0x77)
        #expect(!unknown.known)
        #expect(unknown.protocol(forVersion: 3) == .ledenet8Byte)
        #expect(unknown.layout(forMode: 0x25) == .rgbww)
        #expect(unknown.layout(forMode: 0x99) == .rgb)
    }

    @Test func tableHasNoDuplicates() {
        #expect(MagicHomeModel.table.count == MagicHomeModel.all.count)
    }
}
