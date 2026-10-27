import Foundation
import LightCore
import Testing
@testable import YeelightCodec

let colorSupport: Set<String> = [
    "get_prop", "set_default", "set_power", "toggle", "set_bright", "start_cf", "stop_cf", "set_scene",
    "cron_add", "cron_get", "cron_del", "set_ct_abx", "set_rgb", "set_hsv", "set_name", "set_adjust",
]
let ctSupport: Set<String> = ["get_prop", "set_default", "set_power", "toggle", "set_bright", "set_scene", "set_ct_abx", "set_name"]
let monoSupport: Set<String> = ["get_prop", "set_default", "set_power", "toggle", "set_bright", "set_scene", "set_name"]

@Suite("Model table")
struct ModelTableTests {
    @Test(arguments: [
        ("color", 1700, 6500), ("color1", 1700, 6500), ("color4", 1700, 6500), ("colorc", 2700, 6500),
        ("stripe", 1700, 6500), ("strip1", 1700, 6500), ("strip6", 2700, 6500), ("bslamp1", 1700, 6500),
    ])
    func colorModels(model: String, lo: Int, hi: Int) {
        let caps = YeelightCapabilities.capabilities(model: model, support: colorSupport)
        #expect(caps.supportedColorModes == [.colorTemp, .hs, .rgb])
        #expect(caps.minKelvin == lo)
        #expect(caps.maxKelvin == hi)
        #expect(caps.supportsTransition)
        // Without a support list the model name alone decides.
        #expect(YeelightCapabilities.kind(model: model, support: []) == .color)
    }

    @Test(arguments: [
        ("ceiling", 2700, 6500), ("ceiling4", 2700, 6500), ("ceiling17", 3000, 5700), ("ceild", 3000, 6500),
        ("lamp1", 2700, 5000), ("ct_bulb", 2700, 6500), ("ceiling5", 2700, 5700),
    ])
    func tunableWhiteModels(model: String, lo: Int, hi: Int) {
        let caps = YeelightCapabilities.capabilities(model: model, support: ctSupport)
        #expect(caps.supportedColorModes == [.colorTemp])
        #expect(caps.kelvinRange == lo...hi)
        #expect(YeelightCapabilities.kind(model: model, support: []) == .colorTemperature)
    }

    @Test func monoModels() {
        for model in ["mono", "mono1", "mono5", "monob"] {
            let caps = YeelightCapabilities.capabilities(model: model, support: monoSupport)
            #expect(caps.supportedColorModes == [.brightness])
            #expect(caps.minKelvin == nil)
            #expect(YeelightCapabilities.kind(model: model, support: []) == .mono)
        }
        // lamp3 is forced mono even though it advertises set_ct_abx (python-yeelight bulb_type).
        #expect(YeelightCapabilities.kind(model: "lamp3", support: ctSupport) == .mono)
    }

    @Test func unknownModelsFallBack() {
        #expect(YeelightCapabilities.capabilities(model: "color9", support: colorSupport).kelvinRange == 1700...6500)
        #expect(YeelightCapabilities.capabilities(model: "newceiling", support: ctSupport).kelvinRange == 2700...6500)
        #expect(YeelightCapabilities.kind(model: "mystery", support: []) == .color)
        #expect(YeelightCapabilities.kind(model: nil, support: []) == .color)
        #expect(YeelightCapabilities.kind(model: "mystery", support: monoSupport) == .mono)
    }

    @Test func propertyHeuristicWhenNothingElseKnown() {
        #expect(YeelightCapabilities.kind(model: nil, support: [], properties: ["power": "on", "ct": "2700"]) == .colorTemperature)
        #expect(YeelightCapabilities.kind(model: nil, support: [], properties: ["power": "on", "bright": "10"]) == .mono)
        #expect(YeelightCapabilities.kind(model: nil, support: [], properties: ["rgb": "255", "ct": "2700"]) == .color)
        // Support list wins over properties.
        #expect(YeelightCapabilities.kind(model: nil, support: colorSupport, properties: ["ct": "2700"]) == .color)
    }

    @Test func supportLookup() {
        #expect(YeelightCapabilities.supports("set_scene", in: []))
        #expect(YeelightCapabilities.supports("set_scene", in: ctSupport))
        #expect(!YeelightCapabilities.supports("set_rgb", in: ctSupport))
    }
}

@Suite("State mapping")
struct StateMappingTests {
    @Test func rgbPacking() {
        #expect(YeelightMapper.rgbInt(RGB(r: 255, g: 0, b: 0)) == 16_711_680)
        #expect(YeelightMapper.rgbInt(RGB(r: 0, g: 255, b: 0)) == 65280)
        #expect(YeelightMapper.rgbInt(RGB(r: 0x12, g: 0x34, b: 0x56)) == 0x123456)
        #expect(YeelightMapper.rgb(fromInt: 0x123456) == RGB(r: 0x12, g: 0x34, b: 0x56))
        #expect(YeelightMapper.rgb(fromInt: 0x7FFF_FFFF) == RGB.white)
    }

    @Test func brightnessScale() {
        #expect(YeelightMapper.deviceBrightness(1) == 100)
        #expect(YeelightMapper.deviceBrightness(0.5) == 50)
        #expect(YeelightMapper.deviceBrightness(0.001) == 1)
        #expect(YeelightMapper.brightness(fromDevice: 100) == 1)
        #expect(YeelightMapper.brightness(fromDevice: 50) == 0.5)
    }

    @Test func getPropResultToState() throws {
        let names = YeelightCommands.stateProperties
        let values: [YeelightValue] = ["on", "100", "4000", "16711680", "100", "35", "1", "0", ""]
        let props = YeelightMapper.properties(names: names, values: values)
        #expect(props["name"] == nil) // empty = unsupported
        let state = YeelightMapper.state(merging: props, into: LightState(reachable: false), kind: .color)
        #expect(state.isOn)
        #expect(state.brightness == 1)
        #expect(state.colorMode == .rgb)
        #expect(state.rgb == RGB(r: 255, g: 0, b: 0))
        #expect(state.kelvin == 4000)
        #expect(state.hs == HS(h: 100, s: 0.35))
        #expect(state.reachable)
        #expect(state.colorAttribute == .rgb(RGB(r: 255, g: 0, b: 0)))
    }

    @Test func notificationsMergeIntoState() {
        let base = YeelightMapper.state(merging: ["power": "on", "bright": "80", "color_mode": "1", "rgb": "255"], into: LightState(), kind: .color)
        #expect(base.colorMode == .rgb)
        let ct = YeelightMapper.state(merging: ["ct": .int(6500)], into: base, kind: .color)
        #expect(ct.colorMode == .colorTemp)
        #expect(ct.kelvin == 6500)
        #expect(ct.brightness == 0.8)
        let off = YeelightMapper.state(merging: ["power": "off"], into: ct, kind: .color)
        #expect(!off.isOn)
        #expect(off.kelvin == 6500)
        let hsv = YeelightMapper.state(merging: ["hue": .int(120), "sat": .int(50), "color_mode": .int(3)], into: off, kind: .color)
        #expect(hsv.colorMode == .hs)
        #expect(hsv.hs == HS(h: 120, s: 0.5))
        let satOnly = YeelightMapper.state(merging: ["sat": "100"], into: hsv, kind: .color)
        #expect(satOnly.hs == HS(h: 120, s: 1))
    }

    @Test func whiteKinds() {
        let ct = YeelightMapper.state(merging: ["power": "on", "bright": "30", "ct": "2700", "rgb": "16711680"], into: LightState(), kind: .colorTemperature)
        #expect(ct.colorMode == .colorTemp)
        #expect(ct.kelvin == 2700)
        #expect(ct.rgb == nil)
        let mono = YeelightMapper.state(merging: ["power": "on", "bright": "30", "ct": "2700"], into: LightState(), kind: .mono)
        #expect(mono.colorMode == .brightness)
        #expect(mono.kelvin == nil)
        #expect(mono.brightness == 0.3)
    }
}

@Suite("Command planning")
struct CommandPlanningTests {
    let color = YeelightCapabilities.capabilities(model: "color1", support: colorSupport)
    let ceiling = YeelightCapabilities.capabilities(model: "ceiling4", support: ctSupport)
    let mono = YeelightCapabilities.capabilities(model: "mono1", support: monoSupport)
    let onRGB = LightState(isOn: true, brightness: 0.8, colorMode: .rgb, rgb: RGB(r: 255, g: 0, b: 0))
    let offCT = LightState(isOn: false, brightness: 0.4, colorMode: .colorTemp, kelvin: 3000)

    @Test func turnOnWithColorWhileOffIsOneScene() {
        let calls = YeelightMapper.calls(
            for: LightCommand(on: true, brightness: 0.5, color: .rgb(RGB(r: 255, g: 0, b: 0))),
            capabilities: color, current: offCT, support: colorSupport
        )
        #expect(calls == [YeelightCall(method: "set_scene", params: ["color", 16_711_680, 50])])
    }

    @Test func colorWhileOffUsesCurrentBrightness() {
        let calls = YeelightMapper.calls(for: LightCommand(on: true, color: .kelvin(5000)), capabilities: color, current: offCT, support: colorSupport)
        #expect(calls == [YeelightCall(method: "set_scene", params: ["ct", 5000, 40])])
        let unknown = YeelightMapper.calls(for: LightCommand(on: true, color: .kelvin(5000)), capabilities: color, current: nil)
        #expect(unknown == [YeelightCall(method: "set_scene", params: ["ct", 5000, 100])])
    }

    @Test func colorOnlyWhileOnIsOneSetter() {
        let calls = YeelightMapper.calls(for: LightCommand(color: .kelvin(4000)), capabilities: color, current: onRGB, support: colorSupport)
        #expect(calls == [YeelightCall(method: "set_ct_abx", params: [4000, "smooth", 300])])
    }

    @Test func colorAndBrightnessWhileOnIsOneScene() {
        let calls = YeelightMapper.calls(
            for: LightCommand(brightness: 1, color: .kelvin(9000)), capabilities: color, current: onRGB, support: colorSupport
        )
        #expect(calls == [YeelightCall(method: "set_scene", params: ["ct", 6500, 100])])
    }

    @Test func explicitTransitionKeepsSmoothSetters() {
        let calls = YeelightMapper.calls(
            for: LightCommand(brightness: 0.2, color: .hs(HS(h: 240, s: 0.5)), transition: .seconds(1)),
            capabilities: color, current: onRGB, support: colorSupport
        )
        #expect(calls == [
            YeelightCall(method: "set_hsv", params: [240, 50, "smooth", 1000]),
            YeelightCall(method: "set_bright", params: [20, "smooth", 1000]),
        ])
        let sudden = YeelightMapper.calls(for: LightCommand(brightness: 0.2, transition: .zero), capabilities: color, current: onRGB)
        #expect(sudden == [YeelightCall(method: "set_bright", params: [20, "sudden", 30])])
    }

    @Test func offAndBrightnessZero() {
        let off = [YeelightCall(method: "set_power", params: ["off", "smooth", 300])]
        #expect(YeelightMapper.calls(for: .turnOff, capabilities: color, current: onRGB) == off)
        #expect(YeelightMapper.calls(for: LightCommand(on: false, brightness: 0.5, color: .kelvin(3000)), capabilities: color, current: onRGB) == off)
        #expect(YeelightMapper.calls(for: LightCommand(brightness: 0), capabilities: color, current: onRGB) == off)
    }

    @Test func brightnessTurnOnReusesKnownColor() {
        let calls = YeelightMapper.calls(for: LightCommand(brightness: 0.2), capabilities: ceiling, current: offCT, support: ctSupport)
        #expect(calls == [YeelightCall(method: "set_scene", params: ["ct", 3000, 20])])
    }

    @Test func plainOnAndRedundantOn() {
        #expect(YeelightMapper.calls(for: .turnOn, capabilities: color, current: offCT)
            == [YeelightCall(method: "set_power", params: ["on", "smooth", 300])])
        #expect(YeelightMapper.calls(for: .turnOn, capabilities: color, current: onRGB)
            == [YeelightCall(method: "set_power", params: ["on", "smooth", 300])])
    }

    @Test func colorWhileOffWithoutTurningOnIsDropped() {
        #expect(YeelightMapper.calls(for: LightCommand(color: .kelvin(3000)), capabilities: color, current: offCT).isEmpty)
    }

    @Test func withoutSetSceneFallsBackToPowerThenSetters() {
        let support = colorSupport.subtracting(["set_scene"])
        let calls = YeelightMapper.calls(
            for: LightCommand(on: true, brightness: 0.5, color: .rgb(RGB(r: 0, g: 0, b: 255))),
            capabilities: color, current: offCT, support: support
        )
        #expect(calls == [
            YeelightCall(method: "set_power", params: ["on", "smooth", 300]),
            YeelightCall(method: "set_rgb", params: [255, "smooth", 300]),
            YeelightCall(method: "set_bright", params: [50, "smooth", 300]),
        ])
    }

    @Test func monoDropsColor() {
        let calls = YeelightMapper.calls(
            for: LightCommand(on: true, brightness: 0.3, color: .kelvin(3000)), capabilities: mono, current: LightState(isOn: false, colorMode: .brightness)
        )
        #expect(calls == [
            YeelightCall(method: "set_power", params: ["on", "smooth", 300]),
            YeelightCall(method: "set_bright", params: [30, "smooth", 300]),
        ])
    }

    @Test func xyIsConvertedToHSAndKelvinClampedToModel() {
        let calls = YeelightMapper.calls(for: LightCommand(color: .xy(XY(x: 0.7, y: 0.3))), capabilities: color, current: onRGB)
        #expect(calls.count == 1)
        #expect(calls[0].method == "set_hsv")
        let hue = calls[0].params[0].intValue ?? -1
        #expect(hue >= 340 || hue <= 10)
        let ct = YeelightMapper.calls(for: LightCommand(color: .kelvin(1800)), capabilities: ceiling, current: LightState(isOn: true, colorMode: .colorTemp, kelvin: 4000))
        #expect(ct == [YeelightCall(method: "set_ct_abx", params: [2700, "smooth", 300])])
    }

    @Test func rgbOnTunableWhiteBecomesKelvin() {
        let calls = YeelightMapper.calls(for: LightCommand(color: .rgb(RGB(r: 255, g: 180, b: 100))), capabilities: ceiling, current: LightState(isOn: true, colorMode: .colorTemp, kelvin: 4000))
        #expect(calls.count == 1)
        #expect(calls[0].method == "set_ct_abx")
    }
}
