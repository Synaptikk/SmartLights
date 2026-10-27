import Foundation
import LightCore
import Testing

@testable import TuyaCodec

@Suite("Colour strings match tinytuya BulbDevice")
struct ColourTests {
    @Test func fromRGB() throws {
        for item in try #require(Fixture["colour", "fromRGB"].arrayValue) {
            let rgb = try #require(item["rgb"]?.arrayValue?.compactMap { $0.intValue })
            #expect(TuyaColour.hex(r: rgb[0], g: rgb[1], b: rgb[2], format: .hsv16) == item["hsv16"]?.stringValue)
            #expect(TuyaColour.hex(r: rgb[0], g: rgb[1], b: rgb[2], format: .rgb8) == item["rgb8"]?.stringValue)
        }
    }

    @Test func fromHSV() throws {
        for item in try #require(Fixture["colour", "fromHSV"].arrayValue) {
            let hsv = try #require(item["hsv"]?.arrayValue?.compactMap { $0.doubleValue })
            #expect(TuyaColour.hsv16(h: hsv[0], s: hsv[1], v: hsv[2]) == item["hsv16"]?.stringValue)
        }
    }

    @Test func parse() throws {
        for item in try #require(Fixture["colour", "parse"].arrayValue) {
            let hex = try #require(item["hex"]?.stringValue)
            let hsv = try #require(TuyaColour.hsv(fromHex: hex))
            let want = try #require(item["hsv"]?.arrayValue?.compactMap { $0.doubleValue })
            #expect(abs(hsv.h - want[0]) < 1e-12 && abs(hsv.s - want[1]) < 1e-12 && abs(hsv.v - want[2]) < 1e-12, "\(hex)")
            let rgb = try #require(TuyaColour.rgb(fromHex: hex))
            #expect([rgb.r, rgb.g, rgb.b] == item["rgb"]?.arrayValue?.compactMap(\.intValue), "\(hex)")
        }
        #expect(TuyaColour.hsv(fromHex: "abc") == nil)
    }

    @Test func defaultDPSetsMatchUpstream() throws {
        for type in [TuyaBulbType.a, .b, .c] {
            let up = Fixture["dpset", type.rawValue]
            let set = TuyaDPSet.defaults(for: type)
            #expect(up["switch"]?.intValue.map(String.init) == set.switchDP)
            #expect(up["mode"]?.intValue.map(String.init) == set.modeDP)
            #expect(up["brightness"]?.intValue.map(String.init) == set.brightnessDP)
            #expect(up["colourtemp"]?.intValue.map(String.init) == set.colourTempDP)
            #expect(up["colour"]?.intValue.map(String.init) == set.colourDP)
            #expect(up["value_min"]?.intValue == set.valueMin)
            #expect(up["value_max"]?.intValue == set.valueMax)
            #expect(up["value_hexformat"]?.stringValue == set.colourFormat.rawValue)
        }
    }
}

@Suite("Bulb type detection (tinytuya detect_bulb examples)")
struct DetectionTests {
    @Test func sylvaniaRGBCCT() {
        let set = TuyaDPSet.detect(from: ["20": true, "21": "colour", "22": 750, "23": 278, "24": "00f003e803e8",
                                          "25": "000e0d0000000000000000c803e8", "26": 0])
        #expect(set.type == .b && set.hasColour && set.hasColourTemp)
        #expect(TuyaLightModel(dpset: set).capabilities.supportedColorModes == [.hs, .colorTemp])
    }

    @Test func feitSoftWhiteHasNoTempOrColour() {
        let set = TuyaDPSet.detect(from: ["20": true, "21": "white", "22": 60, "25": "x", "26": 0, "34": false, "41": true])
        #expect(set.type == .b && set.colourTempDP == nil && set.colourDP == nil && set.brightnessDP == "22")
        #expect(TuyaLightModel(dpset: set).capabilities.supportedColorModes == [.brightness])
    }

    @Test func geeniFilamentIsTypeC() {
        let set = TuyaDPSet.detect(from: ["1": true, "2": 25, "3": 0])
        #expect(set.type == .c && set.brightnessDP == "2" && set.colourTempDP == "3" && set.modeDP == nil)
        #expect(TuyaLightModel(dpset: set).capabilities.supportedColorModes == [.colorTemp])
    }

    @Test func legacyRGBIsTypeA() {
        let set = TuyaDPSet.detect(from: ["1": true, "2": "colour", "3": 255, "4": 0, "5": "ff00000000ffff"])
        #expect(set.type == .a && set.colourFormat == .rgb8 && set.hasColour)
    }

    @Test func plugOrUnknownIsSwitchOnly() {
        #expect(TuyaDPSet.detect(from: ["1": true, "20": true]).type == .switchOnly)
        #expect(TuyaDPSet.detect(from: ["1": true]).type == .switchOnly)
        #expect(TuyaLightModel(dpset: TuyaDPSet.detect(from: ["1": true])).capabilities.supportedColorModes == [.onOff])
    }
}

@Suite("DPS <-> LightState / LightCommand")
struct MappingTests {
    let rgbcct = TuyaDPSet.defaults(for: .b)

    @Test func colourStateFromDPS() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "colour", "22": 800, "23": 500, "24": "00f003e801f4"])
        let s = model.lightState(reachable: true)
        #expect(s.isOn && s.colorMode == .hs)
        #expect(s.hs == HS(h: 240, s: 1))
        #expect(abs((s.brightness ?? 0) - 0.5) < 0.005)
    }

    @Test func whiteStateFromDPS() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": false, "21": "white", "22": 1000, "23": 0, "24": "000003e803e8"])
        let s = model.lightState(reachable: false)
        #expect(!s.isOn && !s.reachable)
        #expect(s.colorMode == .colorTemp && s.kelvin == 2700 && s.brightness == 1)
        var cold = model
        cold.apply(["23": 1000, "22": 10])
        #expect(cold.lightState(reachable: true).kelvin == 6500)
        #expect(abs((cold.lightState(reachable: true).brightness ?? 1) - 1.0 / 991) < 1e-9)
    }

    @Test func sceneModeIsAnEffect() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "scene", "22": 500])
        #expect(model.lightState(reachable: true).effect == "scene")
    }

    @Test func onOffAndBrightness() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": false, "21": "white", "22": 500])
        #expect(model.dps(for: .turnOn) == ["20": true])
        #expect(model.dps(for: .turnOff) == ["20": false])
        #expect(model.dps(for: LightCommand(brightness: 1)) == ["20": true, "22": 1000])
        #expect(model.dps(for: LightCommand(brightness: 0.5)) == ["20": true, "22": 505])
        #expect(model.dps(for: LightCommand(brightness: 0)) == ["20": false])
        #expect(model.dps(for: LightCommand(on: true, brightness: 0.001)) == ["20": true, "22": 10])
    }

    @Test func kelvinWithBrightnessInOneCommand() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "colour", "24": "000003e803e8"])
        #expect(model.dps(for: LightCommand(brightness: 1, color: .kelvin(4600))) == ["20": true, "21": "white", "22": 1000, "23": 500])
        // Clamped to the 2700-6500 K range.
        #expect(model.dps(for: LightCommand(color: .kelvin(9000))) == ["21": "white", "23": 1000])
    }

    @Test func colourKeepsBrightness() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "white", "22": 505])
        #expect(model.dps(for: LightCommand(color: .hs(HS(h: 120, s: 0.5)))) == ["21": "colour", "24": "007801f401f9"])
        #expect(model.dps(for: LightCommand(brightness: 1, color: .rgb(RGB(r: 255, g: 0, b: 0))))
            == ["20": true, "21": "colour", "24": "000003e803e8"])
    }

    @Test func brightnessInColourModeRewritesValue() {
        let model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "colour", "22": 1000, "24": "00f003e803e8"])
        #expect(model.dps(for: LightCommand(brightness: 0.25)) == ["20": true, "24": "00f003e80101"])
    }

    @Test func typeAUsesRGB8AndLegacyRanges() {
        let model = TuyaLightModel(dpset: TuyaDPSet.defaults(for: .a), dps: ["1": true, "2": "white", "3": 255, "4": 255])
        let s = model.lightState(reachable: true)
        #expect(s.brightness == 1 && s.kelvin == 6500)
        #expect(model.dps(for: LightCommand(color: .hs(HS(h: 0, s: 1)))) == ["2": "colour", "5": "ff00000000ffff"])
        #expect(model.dps(for: LightCommand(brightness: 0.5, color: .kelvin(2700))) == ["1": true, "2": "white", "3": 140, "4": 0])
    }

    @Test func typeCDimmerFilament() {
        let model = TuyaLightModel(dpset: TuyaDPSet.detect(from: ["1": true, "2": 25, "3": 0]), dps: ["1": true, "2": 25, "3": 0])
        let s = model.lightState(reachable: true)
        #expect(s.colorMode == .colorTemp && s.kelvin == 2700)
        #expect(model.dps(for: LightCommand(brightness: 1, color: .kelvin(6500))) == ["1": true, "2": 255, "3": 255])
        // Colour is converted to a colour temperature for a CCT-only bulb.
        #expect(model.dps(for: LightCommand(color: .hs(HS(h: 30, s: 0.6))))["3"] != nil)
    }

    @Test func roundTripThroughState() {
        var model = TuyaLightModel(dpset: rgbcct, dps: ["20": true, "21": "white", "22": 500, "23": 500])
        let command = LightCommand(brightness: 0.7, color: .hs(HS(h: 200, s: 0.8)))
        model.apply(model.dps(for: command))
        let s = model.lightState(reachable: true)
        #expect(s.colorMode == .hs)
        #expect(abs((s.hs?.h ?? 0) - 200) < 0.5 && abs((s.hs?.s ?? 0) - 0.8) < 0.001)
        #expect(abs((s.brightness ?? 0) - 0.7) < 0.002)
    }
}
