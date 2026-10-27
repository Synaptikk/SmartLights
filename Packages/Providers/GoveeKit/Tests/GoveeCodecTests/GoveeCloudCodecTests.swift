import Foundation
import LightCore
import Testing
@testable import GoveeCodec

@Suite("Govee Developer API codec")
struct GoveeCloudCodecTests {

    private func devices() throws -> [GoveeCloudDevice] {
        try GoveeCloudAPI.decodeDevices(GoveeHTTPResponse(status: 200, body: try Fixture.data("cloud_devices")))
    }

    @Test func devicesRequest() {
        let request = GoveeCloudAPI.devicesRequest(apiKey: "secret-key")
        #expect(request.method == "GET")
        #expect(request.path == "/router/api/v1/user/devices")
        #expect(request.headers["Govee-API-Key"] == "secret-key")
        #expect(request.body == nil)
        #expect(!request.logDescription.contains("secret"))
        #expect(GoveeCloudAPI.baseURL.absoluteString == "https://openapi.api.govee.com")
    }

    @Test func controlRequestBody() throws {
        let request = GoveeCloudAPI.controlRequest(apiKey: "k", requestID: "req-1", sku: "H605C", device: "64:09:C5:32:37:36:2D:13",
                                                   capability: .colorRGB(GoveeMapper.packRGB(RGB(r: 255, g: 128, b: 0))))
        #expect(request.method == "POST")
        #expect(request.path == "/router/api/v1/device/control")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try Fixture.json(try #require(request.body))
        #expect(body["requestId"] == .string("req-1"))
        #expect(body["payload"]?["sku"] == .string("H605C"))
        #expect(body["payload"]?["device"] == .string("64:09:C5:32:37:36:2D:13"))
        #expect(body["payload"]?["capability"]?["type"] == .string("devices.capabilities.color_setting"))
        #expect(body["payload"]?["capability"]?["instance"] == .string("colorRgb"))
        #expect(body["payload"]?["capability"]?["value"] == .int(16744448))
    }

    @Test func stateRequestBody() throws {
        let request = GoveeCloudAPI.stateRequest(apiKey: "k", requestID: "r", sku: "H6601", device: "AA")
        #expect(request.path == "/router/api/v1/device/state")
        let body = try Fixture.json(try #require(request.body))
        #expect(body == .object(["requestId": .string("r"), "payload": .object(["sku": .string("H6601"), "device": .string("AA")])]))
    }

    @Test func decodesDeviceListFixture() throws {
        let list = try devices()
        #expect(list.count == 3)
        let lamp = list[0]
        #expect(lamp.sku == "H6601")
        #expect(lamp.deviceID == "9D:FA:85:EB:D3:00:8B:FF")
        #expect(lamp.deviceName == "Desk lamp")
        #expect(lamp.capabilities.count == 10)
        #expect(lamp.isLight)
        let ct = try #require(lamp.capability(GoveeCapabilityType.colorSetting, GoveeCapabilityInstance.colorTemperatureK))
        #expect(ct.parameters?.range == GoveeValueRange(min: 2000, max: 9000, precision: 1))
        let snapshot = try #require(lamp.capability(GoveeCapabilityType.dynamicScene, GoveeCapabilityInstance.snapshot))
        #expect(snapshot.parameters?.options?.map(\.name) == ["Sunrise", "Sunset"])
        #expect(snapshot.parameters?.options?.first?.value == .int(3853288))
        #expect(list[1].isLight) // no type, but dimmable + colour
        #expect(!list[2].isLight) // humidifier
    }

    @Test func mapsCloudCapabilities() throws {
        let lamp = try devices()[0]
        let caps = GoveeMapper.capabilities(for: lamp)
        #expect(caps.supportedColorModes == [.rgb, .colorTemp])
        #expect(caps.minKelvin == 2000)
        #expect(caps.maxKelvin == 9000)
        #expect(caps.effects.map(\.id) == ["snapshot/Sunrise", "snapshot/Sunset"])
        #expect(caps.supportsEffects)
        let onOffOnly = GoveeCloudDevice(sku: "H5080", device: "X", type: nil, capabilities: [
            GoveeCloudCapability(type: GoveeCapabilityType.onOff, instance: "powerSwitch"),
        ])
        #expect(GoveeMapper.capabilities(for: onOffOnly).supportedColorModes == [.onOff])
    }

    @Test func decodesStateFixture() throws {
        let states = try GoveeCloudAPI.decodeState(GoveeHTTPResponse(status: 200, body: try Fixture.data("cloud_state")))
        #expect(states.count == 8)
        let lamp = try devices()[0]
        let date = Date(timeIntervalSince1970: 1_000)
        let state = GoveeMapper.state(fromCloud: states, device: lamp, at: date)
        #expect(state.isOn)
        #expect(state.reachable)
        #expect(state.brightness == 0.5)
        #expect(state.colorMode == .rgb)
        #expect(state.rgb == RGB(r: 255, g: 128, b: 0))
        #expect(state.updatedAt == date)

        let white = [GoveeCapabilityState(type: GoveeCapabilityType.colorSetting, instance: "colorTemperatureK", value: .int(4000)),
                     GoveeCapabilityState(type: GoveeCapabilityType.online, instance: "online", value: .bool(false))]
        let next = GoveeMapper.state(fromCloud: white, previous: state)
        #expect(next.colorMode == .colorTemp)
        #expect(next.kelvin == 4000)
        #expect(next.isOn) // kept from previous
        #expect(!next.reachable)
    }

    @Test func decodesControlResponse() throws {
        let control = try GoveeCloudAPI.decodeControl(GoveeHTTPResponse(status: 200, body: try Fixture.data("cloud_control_response")))
        #expect(control.code == 200)
        #expect(control.status == "success")
        #expect(control.capability?.instance == "powerSwitch")
    }

    @Test func mapsHTTPErrors() {
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 200)) == nil)
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 401)) == .unauthorized)
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 429, headers: ["retry-after": "30"])) == .rateLimited(retryAfter: 30))
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 404, body: Data("nope".utf8))) == .notFound("nope"))
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 400)) == .badRequest(""))
        #expect(GoveeCloudAPI.error(for: GoveeHTTPResponse(status: 503)) == .server(status: 503, ""))
        // HTTP 200 with an error code in the body.
        let body = Data(#"{"code":429,"message":"Too many requests","data":[]}"#.utf8)
        #expect(throws: GoveeCloudError.rateLimited(retryAfter: nil)) {
            try GoveeCloudAPI.decodeDevices(GoveeHTTPResponse(status: 200, body: body))
        }
        let failed = Data(#"{"requestId":"x","msg":"success","code":200,"capability":{"state":{"status":"failed"}}}"#.utf8)
        #expect(throws: GoveeCloudError.self) {
            try GoveeCloudAPI.decodeControl(GoveeHTTPResponse(status: 200, body: failed))
        }
    }

    @Test func parsesRateLimitHeaders() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let info = GoveeRateLimitInfo.parse(GoveeHTTPResponse(status: 200, headers: [
            "api-ratelimit-limit": "10000", "API-RateLimit-Remaining": "9876", "API-RateLimit-Reset": "1700003600",
        ]), now: now)
        #expect(info == GoveeRateLimitInfo(limit: 10_000, remaining: 9876, reset: Date(timeIntervalSince1970: 1_700_003_600)))
        let delta = GoveeRateLimitInfo.parse(GoveeHTTPResponse(status: 200, headers: ["X-RateLimit-Remaining": "5", "X-RateLimit-Reset": "60"]), now: now)
        #expect(delta?.remaining == 5)
        #expect(delta?.reset == now.addingTimeInterval(60))
        #expect(GoveeRateLimitInfo.parse(GoveeHTTPResponse(status: 200, headers: ["Content-Type": "application/json"])) == nil)
    }
}

@Suite("Govee mapping")
struct GoveeMapperTests {
    private let rgbCT = GoveeMapper.capabilities(for: .basic("H6008"))

    @Test func rgbPacking() {
        #expect(GoveeMapper.packRGB(RGB(r: 255, g: 128, b: 0)) == 0xFF8000)
        #expect(GoveeMapper.packRGB(.white) == 16_777_215)
        #expect(GoveeMapper.unpackRGB(0x0A141E) == RGB(r: 10, g: 20, b: 30))
        #expect(GoveeMapper.unpackRGB(-1) == .white)
        for rgb in [RGB(r: 1, g: 2, b: 3), RGB(r: 200, g: 0, b: 99)] {
            #expect(GoveeMapper.unpackRGB(GoveeMapper.packRGB(rgb)) == rgb)
        }
    }

    @Test func brightnessScaling() {
        #expect(GoveeMapper.percent(fromBrightness: 1) == 100)
        #expect(GoveeMapper.percent(fromBrightness: 0.5) == 50)
        #expect(GoveeMapper.percent(fromBrightness: 0.001) == 1)
        #expect(GoveeMapper.brightness(fromPercent: 100) == 1)
        #expect(GoveeMapper.brightness(fromPercent: 0) == 0)
        #expect(GoveeMapper.brightness(fromPercent: 25) == 0.25)
    }

    @Test func lanModelCapabilities() {
        #expect(rgbCT.supportedColorModes == [.rgb, .colorTemp])
        #expect(rgbCT.kelvinRange == 2000...9000)
        let h6076 = GoveeMapper.capabilities(for: GoveeSKUCatalog.lanModel(for: "H6076")!)
        #expect(h6076.kelvinRange == 2700...6500)
        let rgbOnly = GoveeMapper.capabilities(for: GoveeSKUCatalog.lanModel(for: "H6043")!)
        #expect(rgbOnly.supportedColorModes == [.rgb])
        #expect(rgbOnly.minKelvin == nil)
        let dimmer = GoveeMapper.capabilities(for: GoveeSKUCatalog.lanModel(for: "H7012")!)
        #expect(dimmer.supportedColorModes == [.brightness])
    }

    @Test func devStatusToState() {
        let date = Date(timeIntervalSince1970: 5)
        let rgb = GoveeMapper.state(from: GoveeDevStatus(onOff: 1, brightness: 100, color: GoveeRGB(r: 255, g: 0, b: 0)), capabilities: rgbCT, at: date)
        #expect(rgb == LightState(isOn: true, brightness: 1, colorMode: .rgb, rgb: RGB(r: 255, g: 0, b: 0), updatedAt: date))
        let white = GoveeMapper.state(from: GoveeDevStatus(onOff: 0, brightness: 42, colorTemInKelvin: 7200), capabilities: rgbCT, at: date)
        #expect(white == LightState(isOn: false, brightness: 0.42, colorMode: .colorTemp, kelvin: 7200, updatedAt: date))
    }

    @Test func lanCommandOrderAndPowerRules() {
        #expect(GoveeMapper.lanCommands(for: .turnOff, capabilities: rgbCT) == [.turn(false)])
        #expect(GoveeMapper.lanCommands(for: LightCommand(on: false, brightness: 1), capabilities: rgbCT) == [.turn(false)])
        #expect(GoveeMapper.lanCommands(for: LightCommand(brightness: 0), capabilities: rgbCT) == [.turn(false)])
        #expect(GoveeMapper.lanCommands(for: LightCommand(on: true, brightness: 0.5, color: .rgb(RGB(r: 1, g: 2, b: 3))), capabilities: rgbCT)
            == [.turn(true), .brightness(50), .color(RGB(r: 1, g: 2, b: 3))])
        #expect(GoveeMapper.lanCommands(for: LightCommand(brightness: 0.3), capabilities: rgbCT, isOn: false) == [.turn(true), .brightness(30)])
        #expect(GoveeMapper.lanCommands(for: LightCommand(brightness: 0.3), capabilities: rgbCT, isOn: true) == [.brightness(30)])
        // Kelvin is clamped to the model range.
        let h6076 = GoveeMapper.capabilities(for: GoveeSKUCatalog.lanModel(for: "H6076")!)
        #expect(GoveeMapper.lanCommands(for: LightCommand(color: .kelvin(9000)), capabilities: h6076) == [.colorTemperature(6500)])
        // HS is converted to RGB; effects are dropped on LAN.
        let hs = GoveeMapper.lanCommands(for: LightCommand(color: .hs(HS(h: 0, s: 1)), effect: "x"), capabilities: rgbCT)
        #expect(hs == [.color(RGB(r: 255, g: 0, b: 0))])
    }

    @Test func cloudCommands() throws {
        let list = try GoveeCloudAPI.decodeDevices(GoveeHTTPResponse(status: 200, body: try Fixture.data("cloud_devices")))
        let lamp = list[0]
        #expect(GoveeMapper.cloudCommands(for: .turnOff, device: lamp) == [.power(false)])
        let cmds = GoveeMapper.cloudCommands(for: LightCommand(on: true, brightness: 0.75, color: .kelvin(12000)), device: lamp)
        #expect(cmds == [.power(true), .brightness(75), .colorTemperature(9000)])
        #expect(GoveeMapper.cloudCommands(for: LightCommand(color: .rgb(RGB(r: 0, g: 0, b: 255))), device: lamp) == [.colorRGB(255)])
        let scene = GoveeMapper.cloudCommands(for: LightCommand(effect: "snapshot/Sunset"), device: lamp)
        #expect(scene == [GoveeCapabilityCommand(type: GoveeCapabilityType.dynamicScene, instance: "snapshot", value: .int(3853289))])
        #expect(GoveeMapper.cloudCommands(for: LightCommand(effect: "snapshot/Nope"), device: lamp).isEmpty)
    }

    @Test func displayName() {
        #expect(GoveeMapper.displayName(sku: "H6008", deviceName: nil) == "Govee H6008")
        #expect(GoveeMapper.displayName(sku: "H6008", deviceName: " ") == "Govee H6008")
        #expect(GoveeMapper.displayName(sku: "H6008", deviceName: "Lamp") == "Lamp")
    }
}

@Suite("Govee cloud budget")
struct GoveeBudgetTests {
    @Test func pollIntervalRespectsDailyLimit() {
        let budget = GoveeCloudBudget.default
        #expect(budget.pollingAllowance == 7000)
        #expect(budget.commandReserve == 3000)
        #expect(budget.pollInterval(devices: 0) == nil)
        #expect(budget.pollInterval(devices: 1) == .seconds(60))
        #expect(budget.pollInterval(devices: 4) == .seconds(60)) // 5760/day fits
        let five = budget.pollInterval(devices: 5)
        #expect(five == .seconds(62)) // 86400*5/7000 = 61.7
        for n in [1, 5, 10, 25, 100] {
            let interval = budget.pollInterval(devices: n)!
            #expect(budget.pollsPerDay(devices: n, interval: interval) <= budget.pollingAllowance)
        }
    }

    @Test func quotaCountsAndKeepsReserve() {
        let start = Date(timeIntervalSince1970: 86_400 * 100 + 10)
        var quota = GoveeDailyQuota(budget: GoveeCloudBudget(dailyLimit: 10, reserveFraction: 0.3), now: start)
        var left = quota.remaining(now: start)
        #expect(left == 10)
        for _ in 0..<7 {
            let ok = quota.canSpend(polling: true, now: start)
            #expect(ok)
            quota.record(now: start)
        }
        var pollOK = quota.canSpend(polling: true, now: start)
        var commandOK = quota.canSpend(polling: false, now: start)
        #expect(!pollOK) // 3 left = reserve
        #expect(commandOK)
        quota.update(GoveeRateLimitInfo(limit: 10_000, remaining: 0, reset: nil), now: start)
        commandOK = quota.canSpend(polling: false, now: start)
        #expect(!commandOK)
        // Next UTC day resets.
        let tomorrow = start.addingTimeInterval(86_400)
        left = quota.remaining(now: tomorrow)
        #expect(left == 10)
        // Per-minute headers do not touch the daily window.
        quota.update(GoveeRateLimitInfo(limit: 30, remaining: 0, reset: nil), now: tomorrow)
        left = quota.remaining(now: tomorrow)
        pollOK = quota.canSpend(polling: true, now: tomorrow)
        #expect(left == 10)
        #expect(pollOK)
    }
}

@Suite("Govee JSON value")
struct GoveeJSONValueTests {
    @Test func decodesMixedValues() throws {
        let value = try JSONDecoder().decode(GoveeJSONValue.self, from: Data(#"{"a":1,"b":true,"c":"x","d":[1.5,null],"e":{"id":7}}"#.utf8))
        #expect(value["a"] == .int(1))
        #expect(value["b"] == .bool(true))
        #expect(value["c"] == .string("x"))
        #expect(value["d"] == .array([.double(1.5), .null]))
        #expect(value["e"]?["id"]?.intValue == 7)
        #expect(GoveeJSONValue.string("").isEmpty)
        #expect(GoveeJSONValue.bool(true).intValue == 1)
        #expect(GoveeJSONValue.int(0).boolValue == false)
    }
}
