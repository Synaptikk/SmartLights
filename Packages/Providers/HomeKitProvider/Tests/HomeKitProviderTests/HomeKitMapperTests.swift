import Foundation
import LightCore
import Testing
@testable import HomeKitProvider

@Suite("HomeKitMapper")
struct HomeKitMapperTests {
    // MARK: Identity

    @Test func lightIDFormat() throws {
        let bulb = Fixtures.colorBulb()
        let id = try #require(HomeKitMapper.lightID(for: bulb))
        #expect(id.brand == .appleHome)
        #expect(id.rawValue == "applehome:11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222")
        let ids = try #require(HomeKitMapper.identifiers(of: id))
        #expect(ids.accessoryID == Fixtures.hueAccessory)
        #expect(ids.serviceID == Fixtures.hueService)
        #expect(HomeKitMapper.identifiers(stableID: "not-a-uuid/also-not") == nil)
        #expect(HomeKitMapper.identifiers(of: LightID("wiz:a8bb5006033d")!) == nil)
    }

    @Test func lightMetadata() throws {
        let light = try #require(HomeKitMapper.light(from: Fixtures.colorBulb()))
        #expect(light.brand == .appleHome)
        #expect(light.name == "Desk Lamp")
        #expect(light.manufacturer == "Signify Netherlands B.V.")
        #expect(light.model == "LCA001")
        #expect(light.roomHint == "Office")
        #expect(light.providerRef == "11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222")
        #expect(light.state.reachable)

        let offline = try #require(HomeKitMapper.light(from: Fixtures.colorBulb(reachable: false, room: nil)))
        #expect(!offline.state.reachable)
        #expect(offline.roomHint == nil)

        let white = try #require(HomeKitMapper.light(from: Fixtures.tunableWhite()))
        #expect(white.name == "Ceiling Light") // service name wins
    }

    // MARK: Capabilities

    @Test func colorCapabilities() {
        let caps = HomeKitMapper.capabilities(for: Fixtures.colorBulb())
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(caps.minKelvin == 2000) // 500 mireds
        #expect(caps.maxKelvin == 6536) // 153 mireds
        #expect(!caps.supportsTransition)
        #expect(!caps.supportsEffects)
        #expect(caps.effects.isEmpty)
    }

    @Test func onOffAndDimmableCapabilities() {
        #expect(HomeKitMapper.capabilities(for: Fixtures.plug()).supportedColorModes == [.onOff])
        var dimmable = Fixtures.tunableWhite()
        dimmable.characteristics[.colorTemperature] = nil
        #expect(HomeKitMapper.capabilities(for: dimmable).supportedColorModes == [.brightness])
    }

    @Test func colorTempOnlyUsesHAPDefaultRange() {
        let caps = HomeKitMapper.capabilities(for: Fixtures.tunableWhite())
        #expect(caps.supportedColorModes == [.colorTemp])
        #expect(caps.minKelvin == 2000) // 500 mireds
        #expect(caps.maxKelvin == 7143) // 140 mireds
    }

    @Test func hueWithoutSaturationIsNotColor() {
        var bulb = Fixtures.colorBulb()
        bulb.characteristics[.saturation] = nil
        let caps = HomeKitMapper.capabilities(for: bulb)
        #expect(caps.supportedColorModes == [.colorTemp])
    }

    // MARK: Conversions

    @Test(arguments: [(2700, 370), (6500, 154), (2000, 500), (4000, 250), (6536, 153)])
    func kelvinToMireds(kelvin: Int, mireds: Int) {
        #expect(HomeKitMapper.mireds(fromKelvin: kelvin) == mireds)
    }

    @Test(arguments: [(370, 2703), (153, 6536), (500, 2000), (250, 4000), (140, 7143)])
    func miredsToKelvin(mireds: Int, kelvin: Int) {
        #expect(HomeKitMapper.kelvin(fromMireds: mireds) == kelvin)
    }

    @Test func conversionEdgeCases() {
        #expect(HomeKitMapper.mireds(fromKelvin: 0) == 0)
        #expect(HomeKitMapper.kelvin(fromMireds: -5) == 0)
        // Round trip stays within a few Kelvin across the usual range.
        for k in stride(from: 2000, through: 6500, by: 100) {
            let back = HomeKitMapper.kelvin(fromMireds: HomeKitMapper.mireds(fromKelvin: k))
            #expect(abs(back - k) <= Int(Double(k * k) / 1_000_000 * 0.5) + 1)
        }
    }

    // MARK: State

    @Test func stateFromCharacteristics() {
        let state = HomeKitMapper.state(for: Fixtures.colorBulb(brightness: 42, hue: 120, saturation: 50))
        #expect(state.isOn)
        #expect(state.brightness == 0.42)
        #expect(state.hs == HS(h: 120, s: 0.5))
        #expect(state.kelvin == 2703)
        #expect(state.colorMode == .hs) // saturation > 0, no hint
        #expect(state.reachable)
    }

    @Test func stateColorModeHint() {
        let bulb = Fixtures.colorBulb(saturation: 50)
        #expect(HomeKitMapper.state(for: bulb, colorModeHint: .colorTemp).colorMode == .colorTemp)
        #expect(HomeKitMapper.state(for: Fixtures.colorBulb(saturation: 0)).colorMode == .colorTemp)
        #expect(HomeKitMapper.state(for: Fixtures.tunableWhite()).colorMode == .colorTemp)
        #expect(HomeKitMapper.state(for: Fixtures.plug(on: true)).colorMode == .onOff)
        #expect(HomeKitMapper.state(for: Fixtures.plug(on: true)).isOn)
    }

    // MARK: Commands -> writes

    @Test func turnOnOffSkipsUnchangedPower() {
        let off = Fixtures.colorBulb(on: false)
        #expect(HomeKitMapper.writes(for: .turnOn, to: off) == [.power(true)])
        #expect(HomeKitMapper.writes(for: .turnOff, to: off) == [])
        let on = Fixtures.colorBulb(on: true)
        #expect(HomeKitMapper.writes(for: .turnOn, to: on) == [])
        #expect(HomeKitMapper.writes(for: .turnOff, to: on) == [.power(false)])
    }

    @Test func brightnessPercent() {
        let on = Fixtures.colorBulb(brightness: 10)
        #expect(HomeKitMapper.writes(for: LightCommand(brightness: 0.42), to: on) == [.brightness(42)])
        #expect(HomeKitMapper.writes(for: LightCommand(brightness: 1.7), to: on) == [.brightness(100)])
        // Unchanged brightness is skipped.
        #expect(HomeKitMapper.writes(for: LightCommand(brightness: 0.1), to: on) == [])
    }

    @Test func brightnessOnOffLightAlsoTurnsOn() {
        let off = Fixtures.colorBulb(on: false, brightness: 10)
        #expect(HomeKitMapper.writes(for: LightCommand(brightness: 0.8), to: off) == [.power(true), .brightness(80)])
    }

    @Test func brightnessZeroTurnsOff() {
        let on = Fixtures.colorBulb()
        #expect(HomeKitMapper.writes(for: LightCommand(brightness: 0), to: on) == [.power(false)])
        // Explicit on + 0 % keeps it on at the minimum.
        #expect(HomeKitMapper.writes(for: LightCommand(on: true, brightness: 0), to: on) == [.brightness(1)])
    }

    @Test func turningOffIgnoresColorAndBrightness() {
        let on = Fixtures.colorBulb()
        let cmd = LightCommand(on: false, brightness: 0.3, color: .kelvin(2700))
        #expect(HomeKitMapper.writes(for: cmd, to: on) == [.power(false)])
    }

    @Test func kelvinToColorTemperatureWrite() {
        let bulb = Fixtures.colorBulb(mireds: 250)
        #expect(HomeKitMapper.writes(for: LightCommand(color: .kelvin(2700)), to: bulb, colorModeHint: .colorTemp)
            == [.colorTemperature(mireds: 370)])
        // Clamped to the light's metadata range (153...500 mireds).
        #expect(HomeKitMapper.writes(for: LightCommand(color: .kelvin(10_000)), to: bulb, colorModeHint: .colorTemp)
            == [.colorTemperature(mireds: 153)])
        #expect(HomeKitMapper.writes(for: LightCommand(color: .kelvin(1000)), to: bulb, colorModeHint: .colorTemp)
            == [.colorTemperature(mireds: 500)])
    }

    @Test func unchangedColorTemperatureIsSkippedOnlyInSameMode() {
        let bulb = Fixtures.colorBulb(mireds: 370)
        #expect(HomeKitMapper.writes(for: LightCommand(color: .kelvin(2700)), to: bulb, colorModeHint: .colorTemp) == [])
        // Light currently showing a colour: the temperature must be written to switch modes.
        #expect(HomeKitMapper.writes(for: LightCommand(color: .kelvin(2700)), to: bulb, colorModeHint: .hs)
            == [.colorTemperature(mireds: 370)])
    }

    @Test func hsWrites() {
        let bulb = Fixtures.colorBulb(hue: 30, saturation: 80)
        let cmd = LightCommand(color: .hs(HS(h: 240, s: 0.5)))
        #expect(HomeKitMapper.writes(for: cmd, to: bulb, colorModeHint: .hs) == [.hue(240), .saturation(50)])
        // Only the hue changed.
        let hueOnly = LightCommand(color: .hs(HS(h: 200, s: 0.8)))
        #expect(HomeKitMapper.writes(for: hueOnly, to: bulb, colorModeHint: .hs) == [.hue(200)])
        // Same colour, coming from colour-temperature mode: both written.
        let same = LightCommand(color: .hs(HS(h: 30, s: 0.8)))
        #expect(HomeKitMapper.writes(for: same, to: bulb, colorModeHint: .colorTemp) == [.hue(30), .saturation(80)])
    }

    @Test func rgbIsNormalisedToHS() {
        let bulb = Fixtures.colorBulb(hue: 100, saturation: 10)
        let writes = HomeKitMapper.writes(for: LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), to: bulb, colorModeHint: .hs)
        #expect(writes == [.hue(0), .saturation(100)])
    }

    @Test func colorOnTunableWhiteBecomesTemperature() {
        let white = Fixtures.tunableWhite(mireds: 153)
        let writes = HomeKitMapper.writes(for: LightCommand(color: .rgb(RGB(r: 255, g: 147, b: 41))), to: white)
        #expect(writes.count == 1)
        #expect(writes.first?.kind == .colorTemperature)
    }

    @Test func combinedCommandOrder() {
        let off = Fixtures.colorBulb(on: false, brightness: 10, mireds: 200)
        let cmd = LightCommand(on: true, brightness: 0.6, color: .kelvin(2700))
        #expect(HomeKitMapper.writes(for: cmd, to: off, colorModeHint: .colorTemp)
            == [.power(true), .brightness(60), .colorTemperature(mireds: 370)])
    }

    @Test func plugIgnoresBrightnessAndColor() {
        let plug = Fixtures.plug(on: false)
        let cmd = LightCommand(on: true, brightness: 0.5, color: .kelvin(3000))
        #expect(HomeKitMapper.writes(for: cmd, to: plug) == [.power(true)])
    }

    @Test func applyingUpdatesSnapshot() {
        let bulb = Fixtures.colorBulb(on: false)
        let next = HomeKitMapper.applying([.power(true), .brightness(75)], to: bulb)
        #expect(next.value(.powerState) == 1)
        #expect(next.value(.brightness) == 75)
        #expect(next.characteristics[.brightness]?.maximum == 100)
        #expect(HomeKitMapper.colorMode(of: [.hue(1)]) == .hs)
        #expect(HomeKitMapper.colorMode(of: [.colorTemperature(mireds: 300)]) == .colorTemp)
        #expect(HomeKitMapper.colorMode(of: [.power(true)]) == nil)
    }

    @Test func discoveredDevice() {
        let device = HomeKitMapper.discoveredDevice(for: Fixtures.colorBulb())
        #expect(device.brand == .appleHome)
        #expect(device.method == .homeKit)
        #expect(device.id == "11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222")
        #expect(device.metadata["manufacturer"] == "Signify Netherlands B.V.")
        #expect(device.metadata["room"] == "Office")
        #expect(device.model == "LCA001")
    }
}
