import Foundation
import Testing
import LightCore
@testable import ElgatoCodec

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Elgato JSON models")
struct ElgatoModelTests {
    @Test func decodesKeyLightAccessoryInfo() throws {
        let info = try ElgatoAccessoryInfo.decode(fixture("accessory-info-key-light"))
        #expect(info.productName == "Elgato Key Light")
        #expect(info.serialNumber == "CN11A1A00001")
        #expect(info.displayName == "Desk Light")
        #expect(info.name == "Desk Light")
        #expect(info.firmwareVersion == "1.0.3")
        #expect(info.firmwareBuildNumber == 192)
        #expect(info.hardwareBoardType == 53)
        #expect(info.features == ["lights"])
        #expect(info.macAddress == nil)
        #expect(info.wifiInfo?.ssid == "Home")
        #expect(info.wifiInfo?.rssi == -48)
    }

    @Test func decodesLightStripAccessoryInfo() throws {
        let info = try ElgatoAccessoryInfo.decode(fixture("accessory-info-light-strip"))
        #expect(info.productName == "Elgato Light Strip")
        #expect(info.macAddress == "3C:6A:9D:14:D0:F5")
        #expect(info.hardwareRevision == "1.0")
        // Empty display name falls back to the product name.
        #expect(info.name == "Elgato Light Strip")
    }

    @Test func decodesLights() throws {
        let doc = try ElgatoLightsDocument.decode(fixture("lights-key-light"))
        #expect(doc.numberOfLights == 1)
        #expect(doc.lights == [ElgatoLightState(on: 1, brightness: 21, temperature: 297)])

        let strip = try ElgatoLightsDocument.decode(fixture("lights-light-strip-color"))
        #expect(strip.lights.first == ElgatoLightState(on: 1, brightness: 50, hue: 358, saturation: 6))
    }

    @Test func acceptsBoolOnAndMissingCount() throws {
        let doc = try ElgatoLightsDocument.decode(Data(#"{"lights":[{"on":true,"brightness":10.4,"temperature":200}]}"#.utf8))
        #expect(doc.numberOfLights == 1)
        #expect(doc.lights.first?.on == 1)
        #expect(doc.lights.first?.brightness == 10)
    }

    @Test func rejectsMalformedLights() {
        #expect(throws: (any Error).self) { try ElgatoLightsDocument.decode(Data(#"{"numberOfLights":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try ElgatoLightsDocument.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try ElgatoAccessoryInfo.decode(Data(#"{"productName":"x"}"#.utf8)) }
    }

    @Test func decodesSettings() throws {
        let key = try ElgatoSettings.decode(fixture("settings-key-light"))
        #expect(key.powerOnTemperature == 213)
        #expect(key.powerOnHue == nil)
        #expect(key.switchOffDurationMs == 300)
        let strip = try ElgatoSettings.decode(fixture("settings-light-strip"))
        #expect(strip.powerOnHue == 40)
        #expect(strip.powerOnSaturation == 15)
    }

    @Test func putBodyOmitsUnsetFields() throws {
        let body = ElgatoMapping.putDocument(ElgatoLightState(on: 1, temperature: 200)).encoded()
        #expect(String(decoding: body, as: UTF8.self) == #"{"lights":[{"on":1,"temperature":200}],"numberOfLights":1}"#)
        let obj = try json(body)
        #expect(obj["numberOfLights"] as? Int == 1)
    }

    @Test func mergingSwitchesBetweenTemperatureAndColour() {
        let colour = ElgatoLightState(on: 1, brightness: 50, hue: 120, saturation: 80)
        let warm = colour.merging(ElgatoLightState(temperature: 300))
        #expect(warm == ElgatoLightState(on: 1, brightness: 50, temperature: 300))
        let back = warm.merging(ElgatoLightState(hue: 10, saturation: 20))
        #expect(back == ElgatoLightState(on: 1, brightness: 50, hue: 10, saturation: 20))
        #expect(back.merging(ElgatoLightState(on: 0)).isOn == false)
    }
}

@Suite("Elgato mapping")
struct ElgatoMappingTests {
    @Test func miredKelvinConversion() {
        #expect(ElgatoMapping.kelvin(fromMireds: 143) == 6993)
        #expect(ElgatoMapping.kelvin(fromMireds: 344) == 2907)
        #expect(ElgatoMapping.kelvin(fromMireds: 297) == 3367)
        #expect(ElgatoMapping.mireds(fromKelvin: 3367) == 297)
        #expect(ElgatoMapping.mireds(fromKelvin: 2000) == 344)
        #expect(ElgatoMapping.mireds(fromKelvin: 9000) == 143)
        #expect(ElgatoMapping.kelvinRange == 2907...6993)
        // Every wire value survives a round trip through Kelvin.
        for m in ElgatoMapping.miredRange {
            #expect(ElgatoMapping.mireds(fromKelvin: ElgatoMapping.kelvin(fromMireds: m)) == m)
        }
    }

    @Test func identity() {
        #expect(ElgatoMapping.lightID(serial: "CN11A1A00001")?.rawValue == "elgato:CN11A1A00001")
        #expect(ElgatoMapping.stableID(serial: " CN11 A1\n") == "CN11A1")
        #expect(ElgatoMapping.lightID(serial: "  ") == nil)
    }

    @Test func capabilities() throws {
        let key = ElgatoMapping.capabilities(supportsColor: false)
        #expect(key.supportedColorModes == [.colorTemp])
        #expect(key.minKelvin == 2907 && key.maxKelvin == 6993)
        #expect(!key.supportsTransition && !key.supportsEffects)
        #expect(ElgatoMapping.capabilities(supportsColor: true).supportedColorModes == [.colorTemp, .hs])

        let stripInfo = try ElgatoAccessoryInfo.decode(fixture("accessory-info-light-strip"))
        let keyInfo = try ElgatoAccessoryInfo.decode(fixture("accessory-info-key-light"))
        let stripSettings = try ElgatoSettings.decode(fixture("settings-light-strip"))
        #expect(ElgatoMapping.supportsColor(info: stripInfo, settings: nil, state: nil))
        #expect(ElgatoMapping.supportsColor(info: nil, settings: stripSettings, state: nil))
        #expect(ElgatoMapping.supportsColor(info: nil, settings: nil, state: ElgatoLightState(hue: 1)))
        #expect(!ElgatoMapping.supportsColor(info: keyInfo, settings: ElgatoSettings(powerOnTemperature: 200), state: ElgatoLightState(temperature: 200)))
    }

    @Test func keyLightState() throws {
        let light = try #require(try ElgatoLightsDocument.decode(fixture("lights-key-light")).lights.first)
        let s = ElgatoMapping.state(from: light, supportsColor: false, at: Date(timeIntervalSince1970: 0))
        #expect(s.isOn)
        #expect(s.brightness == 0.21)
        #expect(s.colorMode == .colorTemp)
        #expect(s.kelvin == 3367)
        #expect(s.hs == nil)
        #expect(s.reachable)
    }

    @Test func lightStripStates() throws {
        let colour = try #require(try ElgatoLightsDocument.decode(fixture("lights-light-strip-color")).lights.first)
        let s = ElgatoMapping.state(from: colour, supportsColor: true)
        #expect(s.colorMode == .hs)
        #expect(s.hs == HS(h: 358, s: 0.06))
        #expect(s.rgb != nil)
        #expect(s.brightness == 0.5)

        let white = try #require(try ElgatoLightsDocument.decode(fixture("lights-light-strip-temperature")).lights.first)
        let w = ElgatoMapping.state(from: white, supportsColor: true)
        #expect(!w.isOn)
        #expect(w.colorMode == .colorTemp)
        #expect(w.kelvin == 6993)
    }

    @Test func planBrightnessAndTemperatureInOneBody() {
        let current = ElgatoLightState(on: 1, brightness: 21, temperature: 297)
        let plan = ElgatoMapping.plan(LightCommand(brightness: 0.5, color: .kelvin(4000)), current: current, supportsColor: false)
        #expect(plan == ElgatoLightState(brightness: 50, temperature: 250))
    }

    @Test func planPower() {
        let off = ElgatoLightState(on: 0, brightness: 40, temperature: 200)
        #expect(ElgatoMapping.plan(.turnOn, current: off, supportsColor: false) == ElgatoLightState(on: 1))
        #expect(ElgatoMapping.plan(.turnOff, current: off, supportsColor: false) == ElgatoLightState(on: 0))
        // Brightness on an off light switches it on; brightness 0 means off and keeps the level.
        #expect(ElgatoMapping.plan(LightCommand(brightness: 1), current: off, supportsColor: false) == ElgatoLightState(on: 1, brightness: 100))
        #expect(ElgatoMapping.plan(LightCommand(brightness: 0), current: ElgatoLightState(on: 1), supportsColor: false) == ElgatoLightState(on: 0))
        // Tiny brightness never becomes 0 on the wire.
        #expect(ElgatoMapping.plan(LightCommand(on: true, brightness: 0.001), current: off, supportsColor: false)?.brightness == 1)
    }

    @Test func planClampsTemperatureAndConvertsColourOnKeyLight() throws {
        #expect(ElgatoMapping.plan(LightCommand(color: .kelvin(10000)), current: nil, supportsColor: false)?.temperature == 143)
        #expect(ElgatoMapping.plan(LightCommand(color: .kelvin(1000)), current: nil, supportsColor: false)?.temperature == 344)
        // A Key Light has no colour: RGB is mapped to the closest temperature.
        let warm = try #require(ElgatoMapping.plan(LightCommand(color: .rgb(RGB(r: 255, g: 170, b: 80))), current: nil, supportsColor: false))
        #expect(warm.hue == nil)
        #expect(ElgatoMapping.miredRange.contains(try #require(warm.temperature)))
    }

    @Test func planColourOnLightStrip() throws {
        let hs = try #require(ElgatoMapping.plan(LightCommand(color: .hs(HS(h: 400, s: 0.456))), current: nil, supportsColor: true))
        #expect(hs == ElgatoLightState(hue: 40, saturation: 45.6))
        let red = try #require(ElgatoMapping.plan(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), current: nil, supportsColor: true))
        #expect(red.hue == 0 && red.saturation == 100 && red.temperature == nil)
        let k = try #require(ElgatoMapping.plan(LightCommand(color: .kelvin(5000)), current: nil, supportsColor: true))
        #expect(k == ElgatoLightState(temperature: 200))
    }

    @Test func planDropsEffectsAndTransitions() {
        #expect(ElgatoMapping.plan(LightCommand(effect: "party"), current: nil, supportsColor: true) == nil)
        #expect(ElgatoMapping.plan(LightCommand(on: true, transition: .seconds(2)), current: nil, supportsColor: false) == ElgatoLightState(on: 1))
    }
}
