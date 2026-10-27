import Foundation
import LightCore
import Testing
@testable import MagicHomeCodec

private func state(_ model: UInt8, on: Bool = true, pattern: UInt8 = 0x61, mode: UInt8 = 0x23, version: UInt8 = 4,
                   r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, ww: UInt8 = 0, cw: UInt8 = 0) -> MagicHomeRawState {
    MagicHomeRawState(modelNumber: model, power: on ? 0x23 : 0x24, presetPattern: pattern, mode: mode, speed: 0x10,
                      red: r, green: g, blue: b, warmWhite: ww, version: version, coolWhite: cw, colorMode: 0)
}

@Suite("Mapping: capabilities and state")
struct MagicHomeStateMappingTests {
    @Test func capabilitiesPerLayout() {
        let rgbcw = MagicHomeProfile(state: state(0x35, mode: 0x17, version: 9))
        let caps = MagicHomeMapping.capabilities(for: rgbcw)
        #expect(caps.supportedColorModes == [.rgb, .colorTemp])
        #expect(caps.kelvinRange == 2700...6500)
        #expect(caps.effects.contains { $0.id == "cycle_rgb" })      // dimmable-effect firmware
        #expect(caps.effects.first { $0.id == "red_strobe" }?.isFast == true)

        #expect(MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0x21))).supportedColorModes == [.brightness])
        #expect(MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0x52))).supportedColorModes == [.colorTemp])
        #expect(MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0x44))).supportedColorModes == [.rgb, .white])
        #expect(MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0x97))) == .onOff)
        let plain = MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0x25)))
        #expect(!plain.effects.contains { $0.id == "cycle_rgb" })
        // Unsupported dialect: on/off only.
        #expect(MagicHomeMapping.capabilities(for: MagicHomeProfile(state: state(0xA3))) == .onOff)
    }

    @Test func rgbStateSplitsBrightness() {
        let raw = try! MagicHomeRawState(MagicHomeStateTests.rgbwBulb)  // 0x45 (182, 0, 152)
        let s = MagicHomeMapping.state(raw, profile: MagicHomeProfile(state: raw))
        #expect(s.isOn)
        #expect(s.colorMode == .rgb)
        #expect(s.rgb == RGB(r: 255, g: 0, b: 213))
        #expect(abs((s.brightness ?? 0) - 182.0 / 255) < 1e-9)
        #expect(s.effect == nil)
    }

    @Test func whiteStates() {
        // 0x52 Bulb CCT reports warm in red and cold in green.
        let cct = state(0x52, r: 255, g: 0)
        let s = MagicHomeMapping.state(cct, profile: MagicHomeProfile(state: cct))
        #expect(s.colorMode == .colorTemp)
        #expect(s.kelvin == 2700)
        #expect(s.brightness == 1)
        // 0x21 dimmable bulb reports its white level in red.
        let dim = state(0x21, r: 51)
        #expect(MagicHomeMapping.state(dim, profile: MagicHomeProfile(state: dim)).brightness == 0.2)
        // RGB/W bulb with only white lit -> white mode.
        let w = state(0x44, ww: 255)
        #expect(MagicHomeMapping.state(w, profile: MagicHomeProfile(state: w)).colorMode == .white)
        // CCT dialect: whites are temperature% / brightness%.
        let tw = state(0x09, ww: 100, cw: 50)
        let ts = MagicHomeMapping.state(tw, profile: MagicHomeProfile(state: tw))
        #expect(ts.kelvin == 6500)
        #expect(abs((ts.brightness ?? 0) - 0.5) < 0.01)
    }

    @Test func effectState() {
        let raw = try! MagicHomeRawState(MagicHomeStateTests.effectController)
        #expect(MagicHomeMapping.state(raw, profile: MagicHomeProfile(state: raw)).effect == "colorjump")
    }
}

@Suite("Mapping: command plans")
struct MagicHomePlanTests {
    @Test func colorAndBrightnessInOneMessage() {
        let raw = state(0x33, version: 9, r: 255, g: 255, b: 255)   // RGB controller, dimmable effects
        let p = MagicHomeProfile(state: raw)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 0.5, color: .rgb(RGB(r: 255, g: 0, b: 0))), current: raw, profile: p)
        #expect(plan.messages.map(hex) == ["31 80 00 00 00 00 0f c0"])   // 0x33 always writes all
        #expect(plan.predicted.red == 128)
        let after = MagicHomeMapping.state(plan.predicted, profile: p)
        #expect(after.rgb == RGB(r: 255, g: 0, b: 0))
    }

    /// flux_led `setRgb(1, 25, 80)` on model 0x45 (RGB/W, colours-only write mode).
    @Test func rgbOrWhiteColour() {
        let raw = try! MagicHomeRawState(MagicHomeStateTests.rgbwBulb)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 1, color: .rgb(RGB(r: 1, g: 25, b: 80))), current: raw, profile: MagicHomeProfile(state: raw))
        #expect(plan.messages.map(hex) == ["31 01 19 50 00 f0 0f 9a"])
    }

    /// Kelvin on an RGB/W bulb selects the white channel (flux_led `setWarmWhite255(25)`).
    @Test func rgbOrWhiteKelvinSelectsWhite() {
        let raw = try! MagicHomeRawState(MagicHomeStateTests.rgbwBulb)
        let p = MagicHomeProfile(state: raw)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 25.0 / 255, color: .kelvin(4000)), current: raw, profile: p)
        #expect(plan.messages.map(hex) == ["31 00 00 00 19 0f 0f 68"])
        #expect(MagicHomeMapping.state(plan.predicted, profile: p).colorMode == .white)
    }

    /// flux_led `setWhiteTemperature(2700, 255)` on model 0x35 firmware 4.
    @Test func rgbCCTBulbWhite() {
        let raw = state(0x35, mode: 0x17, r: 182, b: 152)
        let p = MagicHomeProfile(state: raw)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 1, color: .kelvin(2700)), current: raw, profile: p)
        #expect(plan.messages.map(hex) == ["31 00 00 00 ff 00 0f 0f 4e"])
        let after = MagicHomeMapping.state(plan.predicted, profile: p)
        #expect(after.colorMode == .colorTemp)
        #expect(after.kelvin == 2700)
    }

    @Test func cctChannelMapAndAllWriteMode() {
        let raw = state(0x52, r: 255)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 1, color: .kelvin(6500)), current: raw, profile: MagicHomeProfile(state: raw))
        // warm -> red byte, cold -> green byte; write mode 00.
        #expect(plan.messages.map(hex) == ["31 00 ff 00 00 00 0f 3f"])
    }

    @Test func dimmerBrightness() {
        let raw = state(0x21, version: 2, r: 255)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 0.2), current: raw, profile: MagicHomeProfile(state: raw))
        #expect(plan.messages.map(hex) == ["31 33 00 00 00 00 0f 73"])
    }

    @Test func rgbwwAndCCTDialect() {
        let ctrl = state(0x07, mode: 0x15, version: 2, r: 10)
        let p = MagicHomeProfile(state: ctrl)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 1, color: .rgbww(RGBWW(r: 255, g: 0, b: 0, cw: 0, ww: 255))), current: ctrl, profile: p)
        #expect(plan.messages.map(hex) == ["31 ff 00 00 ff 00 00 0f 3e"])

        let bulb = state(0x09, ww: 0, cw: 100)
        let cp = MagicHomeProfile(state: bulb)
        let warm = MagicHomeMapping.plan(LightCommand(brightness: 1, color: .kelvin(2700)), current: bulb, profile: cp)
        #expect(warm.messages.map(hex) == ["35 b1 00 64 00 00 00 03 4d"])
        #expect(warm.predicted.warmWhite == 0 && warm.predicted.coolWhite == 100)
    }

    @Test func powerHandling() {
        let off = state(0x06, on: false, version: 0, r: 255)          // 8-byte: levels do not turn on
        let p = MagicHomeProfile(state: off)
        let on = MagicHomeMapping.plan(LightCommand(color: .rgbw(RGBW(r: 0, g: 255, b: 0, w: 0))), current: off, profile: p)
        #expect(on.messages.first.map(hex) == "71 23 0f a3")
        #expect(on.messages.count == 2)
        #expect(on.predicted.isOn)

        let autoOn = state(0x06, on: false, version: 1, r: 255)       // auto-on firmware: levels only
        let a = MagicHomeMapping.plan(LightCommand(color: .rgbw(RGBW(r: 0, g: 255, b: 0, w: 0))), current: autoOn, profile: MagicHomeProfile(state: autoOn))
        #expect(a.messages.count == 1)
        #expect(a.messages[0].first == 0x31)

        let lit = state(0x06, version: 1, r: 255)
        let p2 = MagicHomeProfile(state: lit)
        #expect(MagicHomeMapping.plan(.turnOff, current: lit, profile: p2).messages.map(hex) == ["71 24 0f a4"])
        #expect(MagicHomeMapping.plan(LightCommand(brightness: 0), current: lit, profile: p2).messages.map(hex) == ["71 24 0f a4"])
        #expect(MagicHomeMapping.plan(.turnOn, current: lit, profile: p2).messages.isEmpty)
        #expect(MagicHomeMapping.plan(.turnOn, current: autoOn, profile: MagicHomeProfile(state: autoOn)).messages.map(hex) == ["71 23 0f a3"])
    }

    @Test func effects() {
        let raw = state(0x33, version: 9, r: 255)
        let plan = MagicHomeMapping.plan(LightCommand(brightness: 0.5, effect: "blue_fade"), current: raw, profile: MagicHomeProfile(state: raw))
        #expect(plan.messages.map(hex) == ["38 28 10 32 a2"])
        #expect(plan.predicted.presetPattern == 0x28)
        // Unknown effects are dropped by normalisation.
        #expect(MagicHomeMapping.plan(LightCommand(effect: "nope"), current: raw, profile: MagicHomeProfile(state: raw)).isEmpty)
    }

    @Test func unsupportedDialectPlansNothing() {
        let raw = state(0xA3, r: 255)
        #expect(MagicHomeMapping.plan(.turnOff, current: raw, profile: MagicHomeProfile(state: raw)).isEmpty)
    }
}
