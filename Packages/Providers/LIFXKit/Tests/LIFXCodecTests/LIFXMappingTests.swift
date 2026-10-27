import Foundation
import Testing
import LightCore
@testable import LIFXCodec

@Suite("HSBK conversion and command planning")
struct LIFXMappingTests {
    let colorBulb = LIFXProduct.find(vendor: 1, product: 27)!.resolved(firmware: LIFXFirmwareVersion(major: 3, minor: 70))
    let white = LIFXProduct.find(vendor: 1, product: 10)!

    @Test func hueEncoding() {
        #expect(HSBK.encodeHue(0) == 0)
        #expect(HSBK.encodeHue(120) == 21845)
        #expect(HSBK.encodeHue(240) == 43691)
        #expect(HSBK.encodeHue(360) == 0)
        #expect(HSBK.encodeHue(-90) == 49152)
        #expect(HSBK.encodeHue(359.999) == 0) // rounds up and wraps
        #expect(HSBK.encodeHue(.nan) == 0)
        #expect(abs(HSBK(hue: 21845, saturation: 0, brightness: 0, kelvin: 0).hueDegrees - 120) < 0.01)
    }

    @Test func unitEncoding() {
        #expect(HSBK.encodeUnit(0) == 0)
        #expect(HSBK.encodeUnit(1) == 65535)
        #expect(HSBK.encodeUnit(0.5) == 32768)
        #expect(HSBK.encodeUnit(2) == 65535)
        #expect(HSBK.encodeUnit(-1) == 0)
        let c = HSBK(hueDegrees: 200, saturation: 0.25, brightness: 0.75, kelvin: 2700)
        #expect(abs(c.saturationFraction - 0.25) < 1e-4)
        #expect(abs(c.brightnessFraction - 0.75) < 1e-4)
        #expect(c.kelvin == 2700)
    }

    @Test func hsRoundTripsThroughHSBK() {
        for h in stride(from: 0.0, to: 360, by: 7.5) {
            for s in [0.1, 0.5, 1.0] {
                let c = HSBK(hueDegrees: h, saturation: s, brightness: 1, kelvin: 3500)
                #expect(abs(c.hueDegrees - h) < 0.01)
                #expect(abs(c.saturationFraction - s) < 1e-4)
            }
        }
    }

    @Test func stateFromColourPayload() {
        let payload = LIFXLightStatePayload(color: HSBK(hue: 21845, saturation: 65535, brightness: 32768, kelvin: 3500), power: 65535, label: "Desk")
        let s = LIFXMapping.state(from: payload, product: colorBulb)
        #expect(s.isOn)
        #expect(s.colorMode == .hs)
        #expect(abs(s.hs!.h - 120) < 0.01)
        #expect(s.hs!.s == 1)
        #expect(abs(s.brightness! - 0.5) < 1e-4)
        #expect(s.rgb == ColorMath.hsToRGB(HS(h: s.hs!.h, s: 1)))
        #expect(s.kelvin == nil)
    }

    @Test func zeroSaturationIsColourTemperature() {
        let payload = LIFXLightStatePayload(color: HSBK(hue: 999, saturation: 0, brightness: 65535, kelvin: 2700), power: 0, label: "")
        let s = LIFXMapping.state(from: payload, product: colorBulb)
        #expect(!s.isOn)
        #expect(s.colorMode == .colorTemp)
        #expect(s.kelvin == 2700)
        #expect(s.hs == nil)
        // Out-of-range kelvin on a white bulb is clamped to the product range.
        let w = LIFXMapping.state(color: HSBK(hue: 0, saturation: 0, brightness: 100, kelvin: 9000), power: 1, product: white)
        #expect(w.colorMode == .colorTemp)
        #expect(w.kelvin == 6500)
    }

    @Test func applyingAttributes() {
        let base = HSBK(hue: 0, saturation: 0, brightness: 40000, kelvin: 3500)
        let range = 1500...9000
        let k = LIFXMapping.hsbk(applying: .kelvin(12000), to: HSBK(hue: 5, saturation: 9, brightness: 1, kelvin: 3500), kelvinRange: range)
        #expect(k == HSBK(hue: 5, saturation: 0, brightness: 1, kelvin: 9000))
        let hs = LIFXMapping.hsbk(applying: .hs(HS(h: 240, s: 0.5)), to: base, kelvinRange: range)
        #expect(hs == HSBK(hue: 43691, saturation: 32768, brightness: 40000, kelvin: 3500))
        let red = LIFXMapping.hsbk(applying: .rgb(RGB(r: 255, g: 0, b: 0)), to: base, kelvinRange: range)
        #expect(red.hue == 0 && red.saturation == 65535 && red.brightness == 40000)
        let green = LIFXMapping.hsbk(applying: .xy(XY(x: 0.17, y: 0.7)), to: base, kelvinRange: range)
        #expect(green.saturation > 0)
        #expect((80.0...160.0).contains(green.hueDegrees))
    }

    @Test func planMergesBrightnessAndColourIntoOneSetColor() {
        let current = HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 3500)
        let cmd = LightCommand(on: true, brightness: 0.5, color: .hs(HS(h: 120, s: 1)), transition: .milliseconds(1500))
        let plan = LIFXMapping.plan(cmd, current: current, isOn: true, product: colorBulb)
        #expect(plan.color == HSBK(hue: 21845, saturation: 65535, brightness: 32768, kelvin: 3500))
        #expect(plan.power == true) // explicit on is asserted
        #expect(plan.durationMs == 1500)
        #expect(plan.messages(currentlyOn: true) == [
            .lightSetColor(HSBK(hue: 21845, saturation: 65535, brightness: 32768, kelvin: 3500), durationMs: 1500),
            .lightSetPower(level: 65535, durationMs: 1500),
        ])
    }

    @Test func turningOnSetsColourInstantlyThenFadesPower() {
        let current = HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 3500)
        let plan = LIFXMapping.plan(LightCommand(brightness: 0.25, transition: .seconds(2)), current: current, isOn: false, product: colorBulb)
        #expect(plan.power == true) // brightness > 0 on an off light turns it on
        #expect(plan.messages(currentlyOn: false) == [
            .lightSetColor(HSBK(hue: 0, saturation: 0, brightness: 16384, kelvin: 3500), durationMs: 0),
            .lightSetPower(level: 65535, durationMs: 2000),
        ])
    }

    @Test func brightnessZeroTurnsOffAndKeepsColour() {
        let current = HSBK(hue: 100, saturation: 100, brightness: 30000, kelvin: 3500)
        let plan = LIFXMapping.plan(LightCommand(brightness: 0), current: current, isOn: true, product: colorBulb)
        #expect(plan.color == nil)
        #expect(plan.messages(currentlyOn: true) == [.lightSetPower(level: 0, durationMs: 0)])
    }

    @Test func offOnlyAndNoOps() {
        let current = HSBK.white
        #expect(LIFXMapping.plan(.turnOff, current: current, isOn: true, product: colorBulb).messages(currentlyOn: true)
            == [.lightSetPower(level: 0, durationMs: 0)])
        // Same colour as cached: no SetColor.
        let same = LIFXMapping.plan(LightCommand(brightness: 1), current: current, isOn: true, product: colorBulb)
        #expect(same.isEmpty)
    }

    @Test func colourOnWhiteBulbBecomesKelvin() {
        let current = HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 4000)
        let plan = LIFXMapping.plan(LightCommand(color: .hs(HS(h: 30, s: 0.6))), current: current, isOn: true, product: white)
        let c = try! #require(plan.color)
        #expect(c.saturation == 0)
        #expect((2700...6500).contains(Int(c.kelvin)))
        #expect(c.kelvin < 4000) // warm orange -> warmer white
    }

    @Test func effectsUseWaveform() {
        let current = HSBK(hue: 21845, saturation: 65535, brightness: 50000, kelvin: 3500)
        let plan = LIFXMapping.plan(LightCommand(effect: "pulse"), current: current, isOn: true, product: colorBulb)
        let wf = try! #require(plan.waveform)
        #expect(wf.waveform == .pulse)
        #expect(wf.transient)
        #expect(wf.color.hue == 21845)
        #expect(wf.color.brightness == 10000)
        #expect(plan.messages(currentlyOn: true) == [.lightSetWaveform(wf)])
        // Unknown effects are dropped by normalisation.
        #expect(LIFXMapping.plan(LightCommand(effect: "disco"), current: current, isOn: true, product: colorBulb).isEmpty)
    }

    @Test func lightIDs() {
        let serial = LIFXSerial("d073d5001337")!
        let id = LIFXMapping.lightID(serial)
        #expect(id.rawValue == "lifx:d073d5001337")
        #expect(LIFXMapping.serial(of: id) == serial)
        #expect(LIFXMapping.serial(of: LightID("wiz:d073d5001337")!) == nil)
    }
}
