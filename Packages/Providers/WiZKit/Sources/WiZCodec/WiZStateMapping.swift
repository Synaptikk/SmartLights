import Foundation
import LightCore

/// Conversions between WiZ pilots and the LightCore domain model.
public enum WiZStateMapping {
    /// WiZ accepts `dimming` 10...100 %; lower values are clamped by the bulb.
    public static let dimmingRange = 10...100

    /// `dimming` -> brightness `0...1` (10 -> ~0.011, 100 -> 1.0).
    public static func brightness(fromDimming dimming: Int) -> Double {
        ColorMath.brightness(fromDeviceValue: dimming, in: dimmingRange)
    }

    /// Brightness `0...1` -> `dimming` 10...100 (any positive value is at least 10).
    public static func dimming(fromBrightness brightness: Double) -> Int {
        ColorMath.deviceValue(forBrightness: brightness, in: dimmingRange)
    }

    /// Maps a `getPilot` result / `syncPilot` params to a `LightState`.
    ///
    /// Mode exclusivity: a bulb is in white (`temp`) mode or colour (`r,g,b`) mode, never both;
    /// if a firmware reports both, `temp` wins (pywizlight behaviour). A running scene
    /// (`sceneId != 0`) is reported as `effect` = scene id, with no colour attribute unless the
    /// bulb also reports one.
    public static func state(from pilot: WiZPilot, capabilities: LightCapabilities, at date: Date = Date()) -> LightState {
        var state = LightState(isOn: pilot.state ?? false, reachable: true, updatedAt: date)
        let modes = capabilities.supportedColorModes

        if capabilities.supportsBrightness, let dimming = pilot.dimming {
            state.brightness = brightness(fromDimming: dimming)
        }
        if let scene = pilot.sceneId, scene != 0 {
            state.effect = String(scene)
        }

        if modes.contains(.colorTemp), let temp = pilot.temp, temp > 0 {
            state.colorMode = .colorTemp
            state.kelvin = temp
        } else if modes.contains(.rgb), pilot.hasRGB {
            let rgb = RGB(r: channel(pilot.r), g: channel(pilot.g), b: channel(pilot.b))
            state.colorMode = .rgb
            state.rgb = rgb
            state.hs = ColorMath.rgbToHS(rgb)
            if (pilot.c ?? 0) > 0 || (pilot.w ?? 0) > 0 {
                state.rgbww = RGBWW(r: rgb.r, g: rgb.g, b: rgb.b, cw: channel(pilot.c), ww: channel(pilot.w))
            }
        } else if modes.contains(.brightness) {
            state.colorMode = .brightness
        } else if modes.contains(.onOff) {
            state.colorMode = .onOff
        } else if state.effect == nil, modes.contains(.colorTemp) {
            // White-only bulb that did not report temp: still in white mode.
            state.colorMode = .colorTemp
        }
        return state
    }

    private static func channel(_ v: Int?) -> UInt8 { UInt8(min(max(v ?? 0, 0), 255)) }
}

/// Builds `setPilot` params from a `LightCommand`.
public enum WiZCommandEncoder {
    /// Params for one `setPilot` combining state, colour/temperature/scene and dimming in a single
    /// message (avoids flashes), in pywizlight `PilotBuilder` order: `state`, then
    /// `r,g,b[,c,w]` | `temp` | `sceneId`, then `dimming`.
    ///
    /// - `on == false` (or brightness 0) sends only `{"state":false}`: changing other params
    ///   would turn the light back on.
    /// - The command is first `normalized(for:)`: Kelvin is clamped to the bulb's `cctRange`,
    ///   HS/xy are converted to RGB (`ColorMath`), and RGB on a white-only bulb becomes a Kelvin.
    /// - An effect (WiZ scene id) wins over a colour in the same command; the bulb cannot show both.
    /// - Returns an empty object if the command changes nothing this bulb supports.
    public static func params(for command: LightCommand, capabilities: LightCapabilities) -> WiZObject {
        let cmd = command.normalized(for: capabilities)
        var p = WiZObject()

        let turnsOff = cmd.on == false || (cmd.on == nil && cmd.brightness.map { $0 <= 0 } == true)
        if turnsOff {
            p["state"] = false
            return p
        }

        let sceneID = cmd.effect.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let color = sceneID == nil ? cmd.color : nil
        let changesLight = cmd.brightness != nil || color != nil || sceneID != nil
        guard cmd.on == true || changesLight else { return p }

        p["state"] = true
        if let sceneID {
            p["sceneId"] = .int(sceneID)
        } else if let color {
            appendColor(color, capabilities: capabilities, to: &p)
        }
        if let b = cmd.brightness, b > 0, capabilities.supportsBrightness {
            p["dimming"] = .int(WiZStateMapping.dimming(fromBrightness: b))
        }
        return p
    }

    static func appendColor(_ color: ColorAttribute, capabilities: LightCapabilities, to p: inout WiZObject) {
        func rgb(_ v: RGB) {
            p["r"] = .int(Int(v.r))
            p["g"] = .int(Int(v.g))
            p["b"] = .int(Int(v.b))
        }
        switch color {
        case .kelvin(let k):
            p["temp"] = .int(capabilities.clampKelvin(k))
        case .rgb(let v):
            rgb(v)
        case .hs(let hs):
            rgb(ColorMath.hsToRGB(hs))
        case .xy(let xy):
            rgb(ColorMath.xyToRGB(xy, gamut: capabilities.gamut))
        case .rgbw(let v):
            rgb(RGB(r: v.r, g: v.g, b: v.b))
            p["w"] = .int(Int(v.w))
        case .rgbww(let v):
            rgb(RGB(r: v.r, g: v.g, b: v.b))
            p["c"] = .int(Int(v.cw))
            p["w"] = .int(Int(v.ww))
        }
    }

    /// Full `setPilot` request for a command (nil if there is nothing to send).
    public static func request(for command: LightCommand, capabilities: LightCapabilities, id: Int? = nil) -> WiZRequest? {
        let p = params(for: command, capabilities: capabilities)
        return p.isEmpty ? nil : .setPilot(p, id: id)
    }
}
