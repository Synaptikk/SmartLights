import Foundation
import Testing
@testable import LightCore

@Suite("LightCommand.normalized(for:)")
struct LightCommandNormalisationTests {
    let hueColor = LightCapabilities(supportedColorModes: [.xy, .colorTemp], minKelvin: 2000, maxKelvin: 6535, supportsTransition: true, gamut: .hueC)
    let wizRGB = LightCapabilities(supportedColorModes: [.rgb, .colorTemp], minKelvin: 2200, maxKelvin: 6500)
    let tunableWhite = LightCapabilities(supportedColorModes: [.colorTemp], minKelvin: 2700, maxKelvin: 6500)
    let rgbOnly = LightCapabilities(supportedColorModes: [.rgb])
    let hsOnly = LightCapabilities(supportedColorModes: [.hs])
    let rgbwwOnly = LightCapabilities(supportedColorModes: [.rgbww], minKelvin: 2000, maxKelvin: 6535)
    let rgbwOnly = LightCapabilities(supportedColorModes: [.rgbw])

    @Test func hsBecomesGamutClampedXYOnHue() throws {
        let cmd = LightCommand(brightness: 0.5, color: .hs(HS(h: 0, s: 1))).normalized(for: hueColor)
        guard case .xy(let xy) = try #require(cmd.color) else { Issue.record("expected xy"); return }
        #expect(close(xy, XY(x: 0.6915, y: 0.3083), 0.0005))
        #expect(Gamut.hueC.contains(xy))
        #expect(cmd.brightness == 0.5)
    }

    @Test func xyIsClampedToGamut() throws {
        let cmd = LightCommand(color: .xy(XY(x: 0.8, y: 0.2))).normalized(for: hueColor)
        guard case .xy(let xy) = try #require(cmd.color) else { Issue.record("expected xy"); return }
        #expect(Gamut.hueC.contains(xy))
    }

    @Test func kelvinClampedToRange() {
        #expect(LightCommand(color: .kelvin(9000)).normalized(for: tunableWhite).color == .kelvin(6500))
        #expect(LightCommand(color: .kelvin(1500)).normalized(for: tunableWhite).color == .kelvin(2700))
        #expect(LightCommand(color: .kelvin(4000)).normalized(for: wizRGB).color == .kelvin(4000))
    }

    @Test func kelvinOnColourOnlyLights() {
        #expect(LightCommand(color: .kelvin(2700)).normalized(for: rgbOnly).color == .rgb(RGB(r: 255, g: 167, b: 87)))
        #expect(LightCommand(color: .kelvin(6535)).normalized(for: rgbwwOnly).color == .rgbww(RGBWW(r: 0, g: 0, b: 0, cw: 255, ww: 0)))
        guard case .hs(let hs) = LightCommand(color: .kelvin(2700)).normalized(for: hsOnly).color else {
            Issue.record("expected hs")
            return
        }
        #expect(hs.h > 20 && hs.h < 40 && hs.s > 0.5)
    }

    @Test func rgbConversions() throws {
        #expect(LightCommand(color: .rgb(RGB(r: 0, g: 0, b: 255))).normalized(for: hsOnly).color == .hs(HS(h: 240, s: 1)))
        #expect(LightCommand(color: .rgb(.white)).normalized(for: rgbwOnly).color == .rgbw(RGBW(r: 0, g: 0, b: 0, w: 255)))
        #expect(LightCommand(color: .rgbw(RGBW(r: 255, g: 0, b: 0, w: 0))).normalized(for: rgbOnly).color == .rgb(RGB(r: 255, g: 0, b: 0)))
        #expect(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))).normalized(for: wizRGB).color == .rgb(RGB(r: 255, g: 0, b: 0)))
        let xyCmd = LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))).normalized(for: hueColor)
        guard case .xy(let xy) = try #require(xyCmd.color) else { Issue.record("expected xy"); return }
        #expect(close(xy, XY(x: 0.6915, y: 0.3083), 0.0005))
    }

    @Test func xyOnHsLight() throws {
        let cmd = LightCommand(color: .xy(XY(x: 0.17, y: 0.7))).normalized(for: hsOnly)
        guard case .hs(let hs) = try #require(cmd.color) else { Issue.record("expected hs"); return }
        #expect(hs.h > 90 && hs.h < 150)
    }

    @Test func colourOnTunableWhiteBecomesClampedKelvin() throws {
        let warm = LightCommand(color: .rgb(RGB(r: 255, g: 167, b: 87))).normalized(for: tunableWhite)
        guard case .kelvin(let k) = try #require(warm.color) else { Issue.record("expected kelvin"); return }
        #expect((2700...3000).contains(k))
        let red = LightCommand(color: .hs(HS(h: 0, s: 1))).normalized(for: tunableWhite)
        guard case .kelvin(let kr) = try #require(red.color) else { Issue.record("expected kelvin"); return }
        #expect((2700...6500).contains(kr))
    }

    @Test func onOffAndDimmableDropUnsupportedFields() {
        let full = LightCommand(on: true, brightness: 0.4, color: .hs(HS(h: 10, s: 1)), effect: "party", transition: .milliseconds(400))
        let plug = full.normalized(for: .onOff)
        #expect(plug == LightCommand(on: true))
        let dimmer = full.normalized(for: .dimmable)
        #expect(dimmer == LightCommand(on: true, brightness: 0.4))
    }

    @Test func brightnessClamped() {
        #expect(LightCommand(brightness: 1.5).normalized(for: rgbOnly).brightness == 1)
        #expect(LightCommand(brightness: -1).normalized(for: rgbOnly).brightness == 0)
        #expect(LightCommand(brightness: .nan).normalized(for: rgbOnly).brightness == nil)
    }

    @Test func effectsAndTransitions() {
        let caps = LightCapabilities(supportedColorModes: [.rgb], effects: [EffectDescriptor(id: "4", name: "Party", isFast: true)])
        #expect(caps.supportsEffects)
        #expect(LightCommand(effect: "4").normalized(for: caps).effect == "4")
        #expect(LightCommand(effect: "99").normalized(for: caps).effect == nil)
        #expect(LightCommand(effect: "4").normalized(for: rgbOnly).effect == nil)
        #expect(LightCommand(on: true, transition: .seconds(1)).normalized(for: hueColor).transition == .seconds(1))
        #expect(LightCommand(on: true, transition: .seconds(1)).normalized(for: rgbOnly).transition == nil)
    }

    @Test func transitionMilliseconds() {
        #expect(LightCommand(transition: .milliseconds(1500)).transitionMilliseconds == 1500)
        #expect(LightCommand().transitionMilliseconds == nil)
        #expect(LightCommand().isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let cmd = LightCommand(on: true, brightness: 0.25, color: .xy(XY(x: 0.3, y: 0.3)), effect: nil, transition: .milliseconds(250))
        let back = try JSONDecoder().decode(LightCommand.self, from: JSONEncoder().encode(cmd))
        #expect(back == cmd)
    }

    @Test func stateApplyingAndSnapshot() throws {
        let id = try #require(LightID("wiz:a8bb5006033d"))
        var light = Light(id: id, name: "Desk", capabilities: wizRGB, state: LightState(isOn: false))
        light.state = light.state.applying(LightCommand(brightness: 0.6, color: .kelvin(3000)))
        #expect(light.state.isOn)
        #expect(light.state.colorMode == .colorTemp && light.state.kelvin == 3000 && light.state.brightness == 0.6)
        let scene = LightScene.snapshot(of: [light], name: "Evening", id: "s1")
        #expect(scene.kind == .app)
        #expect(scene.commands[id] == LightCommand(on: true, brightness: 0.6, color: .kelvin(3000)))
        let decoded = try JSONDecoder().decode(LightScene.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
    }
}
