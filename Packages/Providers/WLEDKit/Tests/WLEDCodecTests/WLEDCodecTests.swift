import Foundation
import Testing
import LightCore
@testable import WLEDCodec

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let rgbCaps = WLEDMapping.capabilities(info: WLEDInfo(leds: .init(lc: 1)), effects: [])
private let rgbwCaps = WLEDMapping.capabilities(info: WLEDInfo(leds: .init(lc: 3)), effects: [])

@Suite("WLED JSON models")
struct WLEDModelTests {
    @Test func decodesState() throws {
        let s = try WLEDState.decode(fixture("state"))
        #expect(s.on == true)
        #expect(s.bri == 128)
        #expect(s.transition == 7)
        #expect(s.mainseg == 0)
        let seg = try #require(s.primarySegment)
        #expect(seg.id == 0 && seg.len == 60)
        #expect(seg.col == [[255, 160, 0], [0, 0, 0], [0, 0, 0]])
        #expect(seg.fx == 0)
        #expect(seg.sx == 128)
    }

    @Test func decodesHexColourSlots() throws {
        let s = try WLEDState.decode(fixture("state-hex-colors"))
        #expect(s.primarySegment?.col == [[255, 0, 128], [0, 255, 0], []])
    }

    @Test func decodesInfo() throws {
        let info = try WLEDInfo.decode(fixture("info"))
        #expect(info.ver == "0.14.4")
        #expect(info.vid == 2405180)
        #expect(info.name == "Kitchen Strip")
        #expect(info.mac == "a4cf12fdaea8")
        #expect(info.ip == "192.168.1.50")
        #expect(info.arch == "esp32")
        #expect(info.leds == WLEDInfo.LEDs(count: 60, rgbw: false, lc: 1, maxseg: 32))
        #expect(info.fxcount == 187)

        let legacy = try WLEDInfo.decode(fixture("info-rgbw-legacy"))
        #expect(legacy.leds?.rgbw == true)
        #expect(legacy.leds?.lc == nil)
    }

    @Test func decodesConfigIdentity() throws {
        let cfg = try WLEDConfig.decode(fixture("cfg"))
        #expect(cfg.id?.mdns == "wled-kitchen")
        #expect(cfg.id?.name == "Kitchen Strip")
    }

    @Test func rejectsMalformedDocuments() {
        #expect(throws: (any Error).self) { try WLEDState.decode(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try WLEDInfo.decode(Data("nope".utf8)) }
        #expect(throws: (any Error).self) { try WLEDMapping.decodeEffects(Data(#"{"a":1}"#.utf8)) }
    }

    @Test func updateEncodingOmitsUnsetFields() {
        let u = WLEDStateUpdate(on: true, bri: 200, tt: 5, seg: [.init(id: 0, col: [[255, 0, 0]], fx: 0)], v: true)
        #expect(String(decoding: u.encoded(), as: UTF8.self)
                == #"{"bri":200,"on":true,"seg":[{"col":[[255,0,0]],"fx":0,"id":0}],"tt":5,"v":true}"#)
        #expect(String(decoding: WLEDStateUpdate(on: false).encoded(), as: UTF8.self) == #"{"on":false}"#)
        #expect(WLEDStateUpdate(tt: 3, v: true).isEmpty)
        #expect(!WLEDStateUpdate(seg: [.init(fx: 2)]).isEmpty)
    }

    @Test func mergingAnUpdate() throws {
        let s = try WLEDState.decode(fixture("state"))
        let next = s.merging(WLEDStateUpdate(on: false, bri: 10, seg: [.init(col: [[1, 2, 3]], fx: 5)]))
        #expect(next.on == false && next.bri == 10)
        #expect(next.primarySegment?.col == [[1, 2, 3]])
        #expect(next.primarySegment?.fx == 5)
        #expect(next.primarySegment?.len == 60)
        let empty = WLEDState().merging(WLEDStateUpdate(seg: [.init(col: [[9, 9, 9]])]))
        #expect(empty.primarySegment?.col == [[9, 9, 9]])
    }
}

@Suite("WLED mapping")
struct WLEDMappingTests {
    @Test func identity() {
        #expect(WLEDMapping.stableID(mdns: "WLED-Kitchen.local.") == "wled-kitchen")
        #expect(WLEDMapping.stableID(mdns: " wled-desk ") == "wled-desk")
        #expect(WLEDMapping.stableID(mdns: ".local") == nil)
        #expect(WLEDMapping.lightID(mdns: "wled-kitchen")?.rawValue == "wled:wled-kitchen")
        #expect(WLEDMapping.defaultMDNSName(mac: "A4:CF:12:FD:AE:A8") == "wled-fdaea8")
        #expect(WLEDMapping.defaultMDNSName(mac: "nope") == nil)
        #expect(WLEDMapping.normalizedMAC("84F3EB123456") == "84f3eb123456")
        #expect(WLEDMapping.formattedMAC("a4cf12fdaea8") == "a4:cf:12:fd:ae:a8")
    }

    @Test func effectsFromFixture() throws {
        let fx = try WLEDMapping.decodeEffects(fixture("effects"))
        #expect(fx.first == EffectDescriptor(id: "0", name: "Solid"))
        #expect(fx.contains(EffectDescriptor(id: "2", name: "Breathe")))
        // Reserved slots are skipped but ids stay the array index.
        #expect(!fx.contains { $0.name == "RSVD" || $0.name == "-" })
        #expect(fx.first { $0.name == "Lightning" }?.id == "32")
        // Metadata after "@" is stripped.
        #expect(fx.last == EffectDescriptor(id: "34", name: "Fire 2012"))
        // Strobe-like effects are flagged for the photosensitivity warning.
        #expect(fx.first { $0.name == "Strobe" }?.isFast == true)
        #expect(fx.first { $0.name == "Blink" }?.isFast == true)
        #expect(fx.first { $0.name == "Lightning" }?.isFast == true)
        #expect(fx.first { $0.name == "Breathe" }?.isFast == false)
        #expect(fx.count == 33)
    }

    @Test func capabilities() throws {
        let info = try WLEDInfo.decode(fixture("info"))
        let fx = [EffectDescriptor(id: "0", name: "Solid")]
        let caps = WLEDMapping.capabilities(info: info, effects: fx)
        #expect(caps.supportedColorModes == [.rgb])
        #expect(caps.supportsTransition)
        #expect(caps.supportsEffects && caps.effects == fx)
        #expect(WLEDMapping.capabilities(info: try WLEDInfo.decode(fixture("info-rgbw-legacy")), effects: []).supportedColorModes == [.rgbw])
        #expect(WLEDMapping.capabilities(info: WLEDInfo(leds: .init(lc: 3)), effects: []).supportedColorModes == [.rgbw])
        #expect(WLEDMapping.capabilities(info: WLEDInfo(leds: .init(lc: 2)), effects: []).supportedColorModes == [.brightness])
        #expect(WLEDMapping.capabilities(info: nil, effects: []).supportedColorModes == [.rgb])
        #expect(!WLEDMapping.capabilities(info: nil, effects: []).supportsEffects)
    }

    @Test func rgbState() throws {
        let s = WLEDMapping.state(from: try WLEDState.decode(fixture("state")), capabilities: rgbCaps)
        #expect(s.isOn)
        #expect(s.brightness == ColorMath.brightness(fromDeviceValue: 128, in: 1...255))
        #expect(s.colorMode == .rgb)
        #expect(s.rgb == RGB(r: 255, g: 160, b: 0))
        #expect(s.hs != nil)
        #expect(s.effect == nil)
    }

    @Test func rgbwStateWithEffect() throws {
        let s = WLEDMapping.state(from: try WLEDState.decode(fixture("state-rgbw-effect")), capabilities: rgbwCaps)
        #expect(!s.isOn)
        #expect(s.brightness == 1)
        #expect(s.colorMode == .rgbw)
        #expect(s.rgbw == RGBW(r: 0, g: 0, b: 255, w: 40))
        #expect(s.effect == "9")
    }

    @Test func brightnessRoundTrips() {
        for bri in [1, 2, 64, 128, 254, 255] {
            let b = ColorMath.brightness(fromDeviceValue: bri, in: WLEDMapping.brightnessRange)
            #expect(ColorMath.deviceValue(forBrightness: b, in: WLEDMapping.brightnessRange) == bri)
        }
    }

    @Test func planBrightnessColourTransitionInOneBody() throws {
        let current = try WLEDState.decode(fixture("state"))
        let plan = try #require(WLEDMapping.plan(LightCommand(brightness: 1, color: .rgb(RGB(r: 0, g: 255, b: 0)), transition: .milliseconds(1250)),
                                                 current: current, capabilities: rgbCaps))
        #expect(plan == WLEDStateUpdate(bri: 255, tt: 13, seg: [.init(id: 0, col: [[0, 255, 0]], fx: 0)], v: true))
    }

    @Test func planConvertsColourAttributes() throws {
        let hs = try #require(WLEDMapping.plan(LightCommand(color: .hs(HS(h: 0, s: 1))), current: nil, capabilities: rgbCaps))
        #expect(hs.seg?.first?.col == [[255, 0, 0]])
        let warm = try #require(WLEDMapping.plan(LightCommand(color: .kelvin(2700)), current: nil, capabilities: rgbCaps))
        let slot = try #require(warm.seg?.first?.col?.first)
        #expect(slot.count == 3 && slot[0] == 255 && slot[2] < slot[1])
        let w = try #require(WLEDMapping.plan(LightCommand(color: .rgb(RGB(r: 255, g: 255, b: 255))), current: nil, capabilities: rgbwCaps))
        #expect(w.seg?.first?.col?.first?.count == 4)
        // A bare colour does not switch an off light on.
        #expect(hs.on == nil)
    }

    @Test func planPower() throws {
        let off = WLEDState(on: false, bri: 100)
        #expect(WLEDMapping.plan(.turnOn, current: off, capabilities: rgbCaps) == WLEDStateUpdate(on: true, v: true))
        #expect(WLEDMapping.plan(LightCommand(brightness: 0.5), current: off, capabilities: rgbCaps) == WLEDStateUpdate(on: true, bri: 128, v: true))
        #expect(WLEDMapping.plan(LightCommand(brightness: 0), current: WLEDState(on: true), capabilities: rgbCaps) == WLEDStateUpdate(on: false, v: true))
        #expect(WLEDMapping.plan(LightCommand(on: true, brightness: 0.0001), current: off, capabilities: rgbCaps)?.bri == 1)
    }

    @Test func planEffects() throws {
        let caps = WLEDMapping.capabilities(info: nil, effects: [EffectDescriptor(id: "0", name: "Solid"), EffectDescriptor(id: "9", name: "Rainbow")])
        let fx = try #require(WLEDMapping.plan(LightCommand(effect: "9"), current: WLEDState(on: false), capabilities: caps))
        #expect(fx == WLEDStateUpdate(on: true, seg: [.init(id: 0, fx: 9)], v: true))
        // Unknown effects are dropped by normalisation.
        #expect(WLEDMapping.plan(LightCommand(effect: "77"), current: nil, capabilities: caps) == nil)
        // Colour plus effect keeps the effect (it is drawn in that colour).
        let both = try #require(WLEDMapping.plan(LightCommand(color: .rgb(RGB(r: 1, g: 2, b: 3)), effect: "9"), current: WLEDState(on: true), capabilities: caps))
        #expect(both.seg == [.init(id: 0, col: [[1, 2, 3]], fx: 9)])
    }

    @Test func planTransitionLimitsAndNoOps() {
        #expect(WLEDMapping.plan(LightCommand(transition: .seconds(1)), current: nil, capabilities: rgbCaps) == nil)
        #expect(WLEDMapping.plan(LightCommand(on: true, transition: .seconds(100_000)), current: nil, capabilities: rgbCaps)?.tt == 65535)
        #expect(WLEDMapping.plan(LightCommand(on: false, transition: .milliseconds(40)), current: nil, capabilities: rgbCaps)?.tt == 0)
    }
}
