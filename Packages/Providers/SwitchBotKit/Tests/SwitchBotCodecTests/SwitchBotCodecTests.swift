import Foundation
import LightCore
import Testing

@testable import SwitchBotCodec

/// Vectors from `Fixtures/gen_fixtures.py` (README Python sample, docs reply shapes).
enum Fixtures {
    nonisolated(unsafe) static let root: [String: Any] = {
        let url = Bundle.module.url(forResource: "switchbot_fixtures", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: try! Data(contentsOf: url)) as! [String: Any]
    }()

    static func data(_ key: String) -> Data {
        try! JSONSerialization.data(withJSONObject: root[key]!)
    }

    static var signatures: [[String: Any]] { root["signatures"] as! [[String: Any]] }
}

@Suite("SwitchBot request signing and builders")
struct SwitchBotAPITests {
    @Test func signMatchesReadmePythonSample() {
        for v in Fixtures.signatures {
            let t = (v["t"] as! NSNumber).int64Value
            let sign = SwitchBotAPI.sign(token: v["token"] as! String, secret: v["secret"] as! String, t: t, nonce: v["nonce"] as! String)
            #expect(sign == v["sign"] as! String)
        }
    }

    @Test func headers() {
        let h = SwitchBotAPI.headers(token: "token", secret: "secret", t: 1700000000000, nonce: "")
        #expect(h["Authorization"] == "token")
        #expect(h["t"] == "1700000000000")
        #expect(h["nonce"] == "")
        #expect(h["sign"] == "Ttm0ZN0AQN2ebCj4A5Qj0Db63sBTdR36nBgM13GiHqs=")
        #expect(h["Content-Type"] == "application/json; charset=utf8")
        #expect(String(SwitchBotAPI.nowMillis()).count == 13)
    }

    @Test func requests() throws {
        let list = SwitchBotAPI.devices(token: "a", secret: "b", t: 1, nonce: "n")
        #expect(list.method == "GET" && list.path == "/v1.1/devices" && list.body == nil)
        #expect(list.url(baseURL: SwitchBotAPI.baseURL)?.absoluteString == "https://api.switch-bot.com/v1.1/devices")
        let status = SwitchBotAPI.status(deviceId: "6055F92B4F5A", token: "a", secret: "b")
        #expect(status.path == "/v1.1/devices/6055F92B4F5A/status")
        let ir = SwitchBotAPI.status(deviceId: "02-2020 08/x", token: "a", secret: "b")
        #expect(ir.path == "/v1.1/devices/02-2020%2008%2Fx/status")
        let cmd = SwitchBotAPI.command(.setBrightness(50), deviceId: "6055F92B4F5A", token: "a", secret: "b")
        #expect(cmd.method == "POST" && cmd.path == "/v1.1/devices/6055F92B4F5A/commands")
        let body = try JSONSerialization.jsonObject(with: try #require(cmd.body)) as! [String: Any]
        #expect(body["command"] as? String == "setBrightness")
        #expect(body["parameter"] as? Int == 50)
        #expect(body["commandType"] as? String == "command")
    }

    @Test func commandBodies() {
        #expect(String(decoding: SwitchBotCommand.turnOn.body, as: UTF8.self) == #"{"command":"turnOn","commandType":"command","parameter":"default"}"#)
        #expect(String(decoding: SwitchBotCommand.setColor(r: 255, g: 0, b: 128).body, as: UTF8.self)
            == #"{"command":"setColor","commandType":"command","parameter":"255:0:128"}"#)
        #expect(String(decoding: SwitchBotCommand.setColorTemperature(4000).body, as: UTF8.self)
            == #"{"command":"setColorTemperature","commandType":"command","parameter":4000}"#)
    }
}

@Suite("SwitchBot replies")
struct SwitchBotResponseTests {
    @Test func deviceList() throws {
        let devices = try SwitchBotResponse.decodeDevices(status: 200, body: Fixtures.data("devices"))
        #expect(devices.count == 6)
        let lights = devices.filter { $0.lightKind != nil }
        #expect(lights.map(\.deviceId) == ["6055F92B4F5A", "C1D2E3F4A5B6", "F0E1D2C3B4A5", "AA11BB22CC33"])
        #expect(lights[0].lightKind?.hasColor == true && lights[0].lightKind?.hasColorTemperature == true)
        #expect(lights[1].lightKind?.hasColor == true && lights[1].lightKind?.hasColorTemperature == false)
        #expect(lights[2].lightKind?.hasColor == false && lights[2].lightKind?.hasColorTemperature == true)
        #expect(!lights[0].usesHub && lights[2].usesHub)
        #expect(lights[3].enableCloudService == false)
    }

    @Test func statuses() throws {
        let bulb = try SwitchBotResponse.decodeStatus(status: 200, body: Fixtures.data("status_color_bulb"))
        #expect(bulb.isOn == true && bulb.brightness == 80 && bulb.rgb == RGB(r: 255, g: 0, b: 128) && bulb.colorTemperature == 4000)
        #expect(bulb.version == "V3.1-6.3")
        let ceiling = try SwitchBotResponse.decodeStatus(status: 200, body: Fixtures.data("status_ceiling"))
        #expect(ceiling.isOn == true && ceiling.brightness == 35 && ceiling.rgb == nil) // "ON", brightness as string
        #expect(SwitchBotLightStatus(power: "partial").isOn == nil)
        #expect(SwitchBotLightStatus(color: "1:2").rgb == nil)
        #expect(SwitchBotLightStatus(color: "1:2:300").rgb == nil)
    }

    @Test func errors() throws {
        try SwitchBotResponse.check(status: 200, body: Fixtures.data("command_ok"))
        #expect(throws: SwitchBotError.api(code: 161, message: "device offline")) {
            try SwitchBotResponse.check(status: 200, body: Fixtures.data("command_offline"))
        }
        #expect(SwitchBotError.api(code: 161, message: nil).isOffline && SwitchBotError.api(code: 171, message: nil).isOffline)
        #expect(throws: SwitchBotError.api(code: 160, message: "command is not supported")) {
            try SwitchBotResponse.check(status: 200, body: Fixtures.data("command_unsupported"))
        }
        #expect(throws: SwitchBotError.unauthorized) { try SwitchBotResponse.check(status: 401, body: Fixtures.data("unauthorized")) }
        #expect(throws: SwitchBotError.unauthorized) { try SwitchBotResponse.check(status: 200, body: Fixtures.data("unauthorized")) }
        #expect(throws: SwitchBotError.tooManyRequests) { try SwitchBotResponse.check(status: 429, body: Data()) }
        #expect(throws: SwitchBotError.http(500)) { try SwitchBotResponse.check(status: 500, body: Data()) }
        #expect(throws: SwitchBotError.malformed("undecodable body")) { try SwitchBotResponse.check(status: 200, body: Data("x".utf8)) }
        #expect(throws: SwitchBotError.malformed("missing body")) {
            try SwitchBotResponse.decodeStatus(status: 200, body: Data(#"{"statusCode":100,"message":"success"}"#.utf8))
        }
    }
}

@Suite("SwitchBot light mapping")
struct SwitchBotMappingTests {
    let bulb = SwitchBotLightKind(deviceType: "Color Bulb")!
    let strip = SwitchBotLightKind(deviceType: "strip light")!
    let ceiling = SwitchBotLightKind(deviceType: "Ceiling Light")!

    @Test func kinds() {
        #expect(bulb.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(bulb.capabilities.minKelvin == 2700 && bulb.capabilities.maxKelvin == 6500)
        #expect(strip.capabilities.supportedColorModes == [.rgb] && strip.capabilities.minKelvin == nil)
        #expect(ceiling.capabilities.supportedColorModes == [.colorTemp])
        #expect(SwitchBotLightKind(deviceType: "Candle Warmer Lamp")?.capabilities.supportedColorModes == [.brightness])
        #expect(SwitchBotLightKind(deviceType: "Hub 2") == nil)
        #expect(SwitchBotLightKind(deviceType: "RGBICWW Ceiling Light") == nil) // different command set
    }

    @Test func statusToState() throws {
        let status = try SwitchBotResponse.decodeStatus(status: 200, body: Fixtures.data("status_color_bulb"))
        let s = SwitchBotMapping.state(from: status, kind: bulb, previousMode: nil, reachable: true)
        #expect(s.isOn && s.brightness == 0.8 && s.colorMode == .rgb && s.rgb == RGB(r: 255, g: 0, b: 128) && s.kelvin == 4000)
        #expect(SwitchBotMapping.state(from: status, kind: bulb, previousMode: .colorTemp, reachable: true).colorMode == .colorTemp)
        let white = try SwitchBotResponse.decodeStatus(status: 200, body: Fixtures.data("status_color_bulb_white"))
        let w = SwitchBotMapping.state(from: white, kind: bulb, previousMode: nil, reachable: false)
        #expect(!w.isOn && w.colorMode == .colorTemp && w.kelvin == 2700 && !w.reachable)
        let c = SwitchBotMapping.state(from: try SwitchBotResponse.decodeStatus(status: 200, body: Fixtures.data("status_ceiling")),
                                       kind: ceiling, previousMode: .rgb, reachable: true)
        #expect(c.colorMode == .colorTemp && c.rgb == nil && c.kelvin == 6500 && c.brightness == 0.35)
    }

    @Test func commands() {
        #expect(SwitchBotMapping.commands(for: .turnOff, kind: bulb, currentlyOn: true) == [.turnOff])
        #expect(SwitchBotMapping.commands(for: LightCommand(brightness: 0), kind: bulb, currentlyOn: true) == [.turnOff])
        #expect(SwitchBotMapping.commands(for: .turnOn, kind: bulb, currentlyOn: false) == [.turnOn])
        #expect(SwitchBotMapping.commands(for: LightCommand(brightness: 0.5), kind: bulb, currentlyOn: true) == [.setBrightness(50)])
        #expect(SwitchBotMapping.commands(for: LightCommand(brightness: 0.001), kind: bulb, currentlyOn: true) == [.setBrightness(1)])
        #expect(SwitchBotMapping.commands(for: LightCommand(brightness: 0.5), kind: bulb, currentlyOn: false) == [.turnOn, .setBrightness(50)])
        #expect(SwitchBotMapping.commands(for: LightCommand(brightness: 0.3, color: .rgb(RGB(r: 1, g: 2, b: 3))), kind: bulb, currentlyOn: true)
            == [.setColor(r: 1, g: 2, b: 3), .setBrightness(30)])
        #expect(SwitchBotMapping.commands(for: LightCommand(color: .kelvin(9000)), kind: bulb, currentlyOn: true) == [.setColorTemperature(6500)])
        // Colour is converted to what the lamp has: hs -> rgb on the strip, rgb -> Kelvin on the ceiling light.
        #expect(SwitchBotMapping.commands(for: LightCommand(color: .hs(HS(h: 240, s: 1))), kind: strip, currentlyOn: true) == [.setColor(r: 0, g: 0, b: 255)])
        let warm = SwitchBotMapping.commands(for: LightCommand(color: .rgb(RGB(r: 255, g: 160, b: 80))), kind: ceiling, currentlyOn: true)
        #expect(warm.count == 1 && warm[0].command == "setColorTemperature")
        #expect(SwitchBotMapping.commands(for: LightCommand(color: .kelvin(3000)), kind: strip, currentlyOn: true).first?.command == "setColor")
        #expect(SwitchBotMapping.commands(for: LightCommand(effect: "x"), kind: bulb, currentlyOn: true).isEmpty)
    }

    @Test func optimisticApply() {
        let s = SwitchBotMapping.apply([.turnOn, .setColor(r: 9, g: 8, b: 7), .setBrightness(42)], to: LightState())
        #expect(s.isOn && s.colorMode == .rgb && s.rgb == RGB(r: 9, g: 8, b: 7) && s.brightness == 0.42)
        let t = SwitchBotMapping.apply([.setColorTemperature(3000), .turnOff], to: s)
        #expect(!t.isOn && t.colorMode == .colorTemp && t.kelvin == 3000)
    }
}
