import Foundation
import LightCore
import Testing
@testable import TPLinkCodec

@Suite("JSON value")
struct TPLinkJSONTests {
    @Test func parsesAndSerialisesCompactSorted() throws {
        let json = try TPLinkJSON.parse(#"{"b": [1, 2.5, true, null, "x\"y"], "a": {"c": -3}}"#)
        #expect(json["a"]?["c"]?.intValue == -3)
        #expect(json["b"]?.arrayValue?[1].doubleValue == 2.5)
        #expect(json["b"]?.arrayValue?[2].boolValue == true)
        #expect(json["b"]?.arrayValue?[3] == .null)
        #expect(json.compact == #"{"a":{"c":-3},"b":[1,2.5,true,null,"x\"y"]}"#)
        #expect(try TPLinkJSON.parse(json.compact) == json)
    }

    @Test func intsAndBoolsStayDistinct() throws {
        let json = try TPLinkJSON.parse(#"{"on_off":1,"device_on":true,"brightness":50}"#)
        #expect(json["on_off"] == .int(1))
        #expect(json["device_on"] == .bool(true))
        #expect(json["on_off"]?.boolValue == true)
        #expect(json["device_on"]?.intValue == 1)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: TPLinkCodecError.self) { try TPLinkJSON.parse("{nope") }
    }
}

@Suite("IOT and SMART requests")
struct TPLinkRequestTests {
    @Test func iotSetLightState() {
        let patch = TPLinkIOTLightPatch(onOff: true, brightness: 42, hue: 120, saturation: 75, colorTemp: 0, transitionPeriod: 500)
        let bulb = TPLinkIOT.setLightState(patch, strip: false)
        #expect(bulb.compact == #"{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"brightness":42,"color_temp":0,"hue":120,"ignore_default":1,"on_off":1,"saturation":75,"transition_period":500}}}"#)
        let strip = TPLinkIOT.setLightState(TPLinkIOTLightPatch(onOff: false), strip: true)
        #expect(strip.compact == #"{"smartlife.iot.lightStrip":{"set_light_state":{"ignore_default":1,"on_off":0}}}"#)
        // Turning on without colour keeps the bulb's last state (ignore_default 0).
        #expect(TPLinkIOTLightPatch(onOff: true).json["ignore_default"] == .int(0))
        #expect(TPLinkIOTLightPatch(onOff: true, transitionPeriod: 100).json["ignore_default"] == .int(0))
    }

    @Test func iotResultChecksErrorCodes() throws {
        let ok = try TPLinkJSON.parse(#"{"system":{"get_sysinfo":{"alias":"x","err_code":0}}}"#)
        #expect(try TPLinkIOT.result(of: ok, target: "system", command: "get_sysinfo")["alias"] == "x")
        let bad = try TPLinkJSON.parse(#"{"smartlife.iot.smartbulb.lightingservice":{"err_code":-1,"err_msg":"module not support"}}"#)
        #expect(throws: TPLinkCodecError.self) {
            try TPLinkIOT.result(of: bad, target: TPLinkIOT.bulbService, command: TPLinkIOT.bulbSetCommand)
        }
        let inner = try TPLinkJSON.parse(#"{"system":{"get_sysinfo":{"err_code":-2}}}"#)
        #expect(throws: TPLinkCodecError.self) { try TPLinkIOT.result(of: inner, target: "system", command: "get_sysinfo") }
    }

    @Test func smartRequestEnvelope() {
        let r = TPLinkSmart.request(method: "set_device_info", params: ["device_on": true], timeMillis: 1_700_000_000_000, terminalUUID: "abc==")
        #expect(r.compact == #"{"method":"set_device_info","params":{"device_on":true},"request_time_milis":1700000000000,"terminal_uuid":"abc=="}"#)
        #expect(TPLinkSmart.request(method: "get_device_info", timeMillis: 1, terminalUUID: "t")["params"] == nil)
    }

    @Test func smartErrorCodes() throws {
        let ok = try TPLinkJSON.parse(#"{"error_code":0}"#)
        #expect(try TPLinkSmart.result(of: ok, method: "set_device_info") == .null)
        let expired = try TPLinkJSON.parse(#"{"error_code":9999}"#)
        do {
            _ = try TPLinkSmart.result(of: expired, method: "get_device_info")
            Issue.record("expected an error")
        } catch TPLinkCodecError.smartError(let method, let code) {
            #expect(method == "get_device_info")
            #expect(code == .sessionTimeout)
            #expect(code.requiresNewSession)
            #expect(!code.isAuthentication)
        }
        #expect(TPLinkSmartErrorCode(rawValue: -40401).requiresNewSession)
        #expect(TPLinkSmartErrorCode(rawValue: -1501).isAuthentication)
        #expect(TPLinkSmartErrorCode(rawValue: 1003).isAuthentication)
    }

    @Test func terminalUUIDIsBase64MD5() {
        let t = TPLinkSmart.makeTerminalUUID(Data(repeating: 1, count: 16))
        #expect(Data(base64Encoded: t)?.count == 16)
    }
}

@Suite("Device info parsing")
struct TPLinkDeviceInfoTests {
    static let l530 = """
        {"device_id":"80223A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F","fw_ver":"1.1.6 Build 240130 Rel.173828","hw_ver":"3.0",
        "type":"SMART.TAPOBULB","model":"L530","mac":"5C-E9-31-12-34-56","nickname":"TGl2aW5nIHJvb20=","avatar":"bulb",
        "device_on":true,"brightness":80,"hue":0,"saturation":100,"color_temp":2700,"color_temp_range":[2500,6500],
        "dynamic_light_effect_enable":false,"overheated":false}
        """

    @Test func tapoBulb() throws {
        let info = try TPLinkSmartDeviceInfo(TPLinkJSON.parse(Self.l530))
        #expect(info.nickname == "Living room")
        #expect(info.model == "L530")
        #expect(info.isOn)
        #expect(info.brightness == 80)
        #expect(info.colorTempRange == 2500...6500)
        #expect(info.hasColor && info.hasVariableColorTemp && info.isDimmable)
        let caps = TPLinkMapping.capabilities(info: info)
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(caps.minKelvin == 2500 && caps.maxKelvin == 6500)
        #expect(!caps.supportsTransition)
        let state = TPLinkMapping.state(smart: info, capabilities: caps)
        #expect(state.colorMode == .colorTemp)
        #expect(state.kelvin == 2700)
        #expect(state.brightness == 0.8)
    }

    @Test func tapoStripWithFixedRangeIsColourOnly() throws {
        let json = try TPLinkJSON.parse("""
            {"model":"L900","mac":"A8-42-A1-00-00-01","device_on":false,"brightness":50,"hue":240,"saturation":100,
            "color_temp":0,"color_temp_range":[9000,9000],"lighting_effect":{"enable":1,"name":"Aurora","id":"x"}}
            """)
        let info = try TPLinkSmartDeviceInfo(json)
        #expect(!info.hasVariableColorTemp)
        #expect(info.effectActive && info.effectName == "Aurora")
        let caps = TPLinkMapping.capabilities(info: info)
        #expect(caps.supportedColorModes == [.hs])
        let state = TPLinkMapping.state(smart: info, capabilities: caps)
        #expect(!state.isOn)
        #expect(state.colorMode == .hs)
        #expect(state.hs == HS(h: 240, s: 1))
        #expect(state.effect == "Aurora")
    }

    @Test func dimmableTapo() throws {
        let info = try TPLinkSmartDeviceInfo(TPLinkJSON.parse(#"{"model":"L510","device_on":true,"brightness":10,"color_temp_range":[2700,2700]}"#))
        #expect(TPLinkMapping.capabilities(info: info).supportedColorModes == [.brightness])
    }

    @Test func kasaSysinfoOffUsesDefaultOnState() throws {
        let json = try TPLinkJSON.parse("""
            {"model":"KL130(US)","alias":"Desk","mic_type":"IOT.SMARTBULB","mic_mac":"1C3BF3112233","is_color":1,"is_dimmable":1,
            "is_variable_color_temp":1,"light_state":{"on_off":0,"dft_on_state":{"brightness":30,"color_temp":0,"hue":240,"mode":"normal","saturation":100}}}
            """)
        let info = try TPLinkIOTSysInfo(json)
        #expect(!info.isStrip)
        let caps = TPLinkMapping.capabilities(sysinfo: info)
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(caps.kelvinRange == 2500...9000)
        #expect(caps.supportsTransition)
        let state = TPLinkMapping.state(iot: try #require(info.lightState), capabilities: caps)
        #expect(!state.isOn)
        #expect(state.brightness == 0.3)
        #expect(state.colorMode == .hs)
        #expect(state.hs == HS(h: 240, s: 1))
    }

    @Test func kasaStripAndTunable() throws {
        let strip = try TPLinkIOTSysInfo(TPLinkJSON.parse(#"{"model":"KL430(US)","length":16,"is_color":1,"is_dimmable":1,"is_variable_color_temp":1,"light_state":{"on_off":1,"brightness":100,"hue":0,"saturation":0,"color_temp":3842,"mode":"normal"},"lighting_effect_state":{"enable":0,"name":"Flicker"}}"#))
        #expect(strip.isStrip)
        #expect(!strip.effectActive)
        let kl120 = try TPLinkIOTSysInfo(TPLinkJSON.parse(#"{"model":"KL120(US)","is_color":0,"is_dimmable":1,"is_variable_color_temp":1,"light_state":{"on_off":1,"brightness":5,"hue":0,"saturation":0,"color_temp":2700,"mode":"normal"}}"#))
        let caps = TPLinkMapping.capabilities(sysinfo: kl120)
        #expect(caps.supportedColorModes == [.colorTemp])
        #expect(caps.kelvinRange == 2700...5000)
        let kl110 = try TPLinkIOTSysInfo(TPLinkJSON.parse(#"{"model":"KL110(US)","is_color":0,"is_dimmable":1,"is_variable_color_temp":0,"light_state":{"on_off":1,"brightness":5}}"#))
        #expect(TPLinkMapping.capabilities(sysinfo: kl110).supportedColorModes == [.brightness])
    }
}

@Suite("Model table")
struct TPLinkModelTableTests {
    @Test func lookups() {
        #expect(TPLinkModelTable.lookup("KL130(US)")?.kind == .color)
        #expect(TPLinkModelTable.lookup("KL125(US)")?.kelvin == 2500...6500)
        #expect(TPLinkModelTable.lookup("KL110B(UN)")?.kind == .dimmable)
        #expect(TPLinkModelTable.lookup("KL400L5(US)")?.isStrip == true)
        #expect(TPLinkModelTable.lookup("KL420L5")?.prefix == "KL420")
        #expect(TPLinkModelTable.lookup("LB130(US)")?.kind == .color)
        #expect(TPLinkModelTable.lookup("LB100")?.kind == .dimmable)
        #expect(TPLinkModelTable.lookup("L510E(US)")?.kind == .dimmable)
        #expect(TPLinkModelTable.lookup("L530E(EU)")?.family == .smart)
        #expect(TPLinkModelTable.lookup("L535E")?.kind == .color)
        #expect(TPLinkModelTable.lookup("L630")?.kelvin == 2200...6500)
        #expect(TPLinkModelTable.lookup("L900-5")?.kind == .colorOnly)
        #expect(TPLinkModelTable.lookup("L920-5(US)")?.isStrip == true)
        #expect(TPLinkModelTable.lookup("L930-5")?.kind == .color)
        #expect(TPLinkModelTable.lookup("HS100(US)") == nil)
        #expect(TPLinkModelTable.kelvinRange(model: "KL120(US)") == 2700...5000)
        #expect(TPLinkModelTable.kelvinRange(model: "KL120(EU)") == 2700...6500)
    }

    @Test func capabilitiesBeforeFirstRead() {
        #expect(TPLinkMapping.capabilities(model: "L930-5", family: .smart).supportedColorModes == [.hs, .colorTemp])
        #expect(TPLinkMapping.capabilities(model: nil, family: .iot).supportedColorModes == [.brightness])
    }
}

@Suite("Command planning")
struct TPLinkPlanTests {
    static let color = LightCapabilities(supportedColorModes: [.hs, .colorTemp], minKelvin: 2500, maxKelvin: 6500, supportsTransition: true)
    static let dimmable = LightCapabilities(supportedColorModes: [.brightness], supportsTransition: true)

    @Test func brightnessAndColourInOneRequest() {
        let plan = TPLinkMapping.plan(LightCommand(brightness: 0.42, color: .hs(HS(h: 120, s: 0.75)), transition: .milliseconds(500)),
                                      capabilities: Self.color, isOn: true)
        #expect(plan == TPLinkMapping.Plan(on: nil, brightness: 42, hue: 120, saturation: 75, kelvin: nil, transitionMs: 500))
        #expect(plan.iotPatch.json.compact == #"{"brightness":42,"color_temp":0,"hue":120,"ignore_default":1,"on_off":1,"saturation":75,"transition_period":500}"#)
        #expect(plan.smartParams.compact == #"{"brightness":42,"color_temp":0,"hue":120,"saturation":75}"#)
    }

    @Test func kelvinIsClamped() {
        let plan = TPLinkMapping.plan(LightCommand(color: .kelvin(9000)), capabilities: Self.color, isOn: true)
        #expect(plan.kelvin == 6500)
        #expect(plan.smartParams.compact == #"{"color_temp":6500}"#)
    }

    @Test func brightnessZeroTurnsOff() {
        let plan = TPLinkMapping.plan(LightCommand(brightness: 0), capabilities: Self.dimmable, isOn: true)
        #expect(plan == TPLinkMapping.Plan(on: false))
        #expect(plan.smartParams.compact == #"{"device_on":false}"#)
    }

    @Test func brightnessOrColourTurnsOnAnOffLight() {
        #expect(TPLinkMapping.plan(LightCommand(brightness: 0.5), capabilities: Self.dimmable, isOn: false).on == true)
        #expect(TPLinkMapping.plan(LightCommand(color: .kelvin(3000)), capabilities: Self.color, isOn: false).on == true)
        #expect(TPLinkMapping.plan(LightCommand(brightness: 0.5), capabilities: Self.dimmable, isOn: true).on == nil)
    }

    @Test func offIgnoresColour() {
        let plan = TPLinkMapping.plan(LightCommand(on: false, color: .kelvin(3000)), capabilities: Self.color, isOn: true)
        #expect(plan == TPLinkMapping.Plan(on: false))
    }

    @Test func rgbBecomesHueSaturation() {
        let plan = TPLinkMapping.plan(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), capabilities: Self.color, isOn: true)
        #expect(plan.hue == 0)
        #expect(plan.saturation == 100)
    }

    @Test func tinyBrightnessRoundsUpToOne() {
        #expect(TPLinkMapping.plan(LightCommand(brightness: 0.001), capabilities: Self.dimmable, isOn: true).brightness == 1)
    }

    @Test func transitionDroppedWithoutSupport() {
        let tapo = LightCapabilities(supportedColorModes: [.hs], supportsTransition: false)
        #expect(TPLinkMapping.plan(LightCommand(on: true, transition: .seconds(2)), capabilities: tapo, isOn: false).transitionMs == nil)
    }

    @Test func applyUpdatesState() {
        let start = LightState(isOn: false, brightness: 0.2, colorMode: .colorTemp, kelvin: 3000)
        let plan = TPLinkMapping.plan(LightCommand(color: .hs(HS(h: 200, s: 0.5))), capabilities: Self.color, isOn: false)
        let next = TPLinkMapping.apply(plan, to: start)
        #expect(next.isOn)
        #expect(next.colorMode == .hs)
        #expect(next.hs == HS(h: 200, s: 0.5))
        #expect(next.kelvin == nil)
        #expect(next.brightness == 0.2)
    }
}
