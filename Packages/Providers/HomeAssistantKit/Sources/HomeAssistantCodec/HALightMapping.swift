import Foundation
import LightCore

/// Typed view of a `light.*` entity's state attributes
/// (https://developers.home-assistant.io/docs/core/entity/light).
///
/// HA writes the colour attributes (`hs_color`, `rgb_color`, `xy_color`, `color_temp_kelvin`, ...)
/// only while the light is on; capability attributes (`supported_color_modes`,
/// `min/max_color_temp_kelvin`, `effect_list`, `supported_features`) are always present.
public struct HALightAttributes: Sendable, Hashable {
    public var supportedColorModes: [String]
    public var colorMode: String?
    /// `0...255`.
    public var brightness: Int?
    public var colorTempKelvin: Int?
    public var minColorTempKelvin: Int?
    public var maxColorTempKelvin: Int?
    /// `[hue 0...360, saturation 0...100]`.
    public var hsColor: [Double]?
    public var rgbColor: [Int]?
    public var rgbwColor: [Int]?
    public var rgbwwColor: [Int]?
    public var xyColor: [Double]?
    public var effect: String?
    public var effectList: [String]
    /// `LightEntityFeature` bits: EFFECT = 4, FLASH = 8, TRANSITION = 32.
    public var supportedFeatures: Int
    public var friendlyName: String?

    public static let featureEffect = 4
    public static let featureFlash = 8
    public static let featureTransition = 32

    public init(_ a: [String: HAJSONValue]) {
        supportedColorModes = a["supported_color_modes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        colorMode = a["color_mode"]?.stringValue
        brightness = a["brightness"]?.intValue
        // Kelvin attributes since 2022.11; the mired ones were removed in 2025.x but older cores
        // (and some custom integrations) still send only those.
        colorTempKelvin = a["color_temp_kelvin"]?.intValue ?? a["color_temp"]?.intValue.flatMap(Self.miredToKelvin)
        minColorTempKelvin = a["min_color_temp_kelvin"]?.intValue ?? a["max_mireds"]?.intValue.flatMap(Self.miredToKelvin)
        maxColorTempKelvin = a["max_color_temp_kelvin"]?.intValue ?? a["min_mireds"]?.intValue.flatMap(Self.miredToKelvin)
        hsColor = a["hs_color"]?.arrayValue?.compactMap(\.doubleValue)
        rgbColor = a["rgb_color"]?.arrayValue?.compactMap(\.intValue)
        rgbwColor = a["rgbw_color"]?.arrayValue?.compactMap(\.intValue)
        rgbwwColor = a["rgbww_color"]?.arrayValue?.compactMap(\.intValue)
        xyColor = a["xy_color"]?.arrayValue?.compactMap(\.doubleValue)
        effect = a["effect"]?.stringValue
        effectList = a["effect_list"]?.arrayValue?.compactMap(\.stringValue) ?? []
        supportedFeatures = a["supported_features"]?.intValue ?? 0
        friendlyName = a["friendly_name"]?.stringValue
    }

    private static func miredToKelvin(_ mired: Int) -> Int? {
        mired > 0 ? ColorMath.miredToKelvin(mired) : nil
    }
}

/// Home Assistant `light` <-> LightCore mapping. LightCore's model already follows HA's
/// `ColorMode` semantics (PLAN.md D7), so this is mostly unit conversion.
public enum HALightMapping {
    /// HA's `EFFECT_OFF`: listed in `effect_list` and reported as `effect` when none runs.
    public static let effectOff = "off"

    // MARK: Colour modes

    public static func colorMode(_ ha: String) -> ColorMode? {
        switch ha {
        case "onoff": .onOff
        case "brightness": .brightness
        case "color_temp": .colorTemp
        case "hs": .hs
        case "xy": .xy
        case "rgb": .rgb
        case "rgbw": .rgbw
        case "rgbww": .rgbww
        case "white": .white
        default: nil  // "unknown"
        }
    }

    public static func haColorMode(_ mode: ColorMode) -> String {
        switch mode {
        case .onOff: "onoff"
        case .brightness: "brightness"
        case .colorTemp: "color_temp"
        case .hs: "hs"
        case .xy: "xy"
        case .rgb: "rgb"
        case .rgbw: "rgbw"
        case .rgbww: "rgbww"
        case .white: "white"
        }
    }

    // MARK: Capabilities

    public static func capabilities(for state: HAEntityState) -> LightCapabilities {
        capabilities(from: HALightAttributes(state.attributes))
    }

    public static func capabilities(from a: HALightAttributes) -> LightCapabilities {
        let modes = supportedModes(a)
        let effects = a.effectList.filter { $0 != effectOff }.map {
            EffectDescriptor(id: $0, name: $0, isFast: isFastEffect($0))
        }
        let ct = modes.contains(.colorTemp)
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: ct ? a.minColorTempKelvin : nil,
            maxKelvin: ct ? a.maxColorTempKelvin : nil,
            supportsTransition: a.supportedFeatures & HALightAttributes.featureTransition != 0,
            supportsEffects: a.supportedFeatures & HALightAttributes.featureEffect != 0 || !effects.isEmpty,
            effects: effects)
    }

    /// Legacy `supported_features` bits (before colour modes, removed 2024):
    /// SUPPORT_BRIGHTNESS = 1, SUPPORT_COLOR_TEMP = 2, SUPPORT_COLOR = 16.
    static let legacyBrightness = 1, legacyColorTemp = 2, legacyColor = 16

    /// `supported_color_modes`, or for cores/integrations that predate it, the modes implied by
    /// the legacy feature bits; finally brightness (if reported) or on/off.
    static func supportedModes(_ a: HALightAttributes) -> Set<ColorMode> {
        var modes = Set(a.supportedColorModes.compactMap(colorMode))
        guard modes.isEmpty, a.supportedColorModes.isEmpty else {
            return modes.isEmpty ? [.onOff] : modes
        }
        let f = a.supportedFeatures
        if f & legacyColor != 0 { modes.insert(.hs) }
        if f & legacyColorTemp != 0 { modes.insert(.colorTemp) }
        if modes.isEmpty, f & legacyBrightness != 0 || a.brightness != nil { modes = [.brightness] }
        return modes.isEmpty ? [.onOff] : modes
    }

    /// Effect names that suggest strobing; the UI shows the photosensitivity warning first.
    /// HA effect names are free-form per integration, so this is a keyword heuristic.
    public static func isFastEffect(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["strobe", "flash", "blink", "party", "disco", "lightning", "police", "fireworks", "flicker", "sparkle", "fast"]
            .contains { n.contains($0) }
    }

    // MARK: State

    public static func lightState(for state: HAEntityState, now: Date = Date()) -> LightState {
        let a = HALightAttributes(state.attributes)
        var out = LightState(
            isOn: state.state == "on",
            reachable: state.isAvailable,
            updatedAt: state.lastUpdated ?? now)
        guard out.isOn else {
            // HA clears colour/brightness attributes while off.
            return out
        }
        out.brightness = a.brightness.map { min(max(Double($0) / 255, 0), 1) }
        out.colorMode = a.colorMode.flatMap(colorMode) ?? inferredColorMode(a)
        out.kelvin = a.colorTempKelvin
        if let hs = a.hsColor, hs.count == 2 { out.hs = HS(h: hs[0], s: hs[1] / 100).clamped }
        if let rgb = a.rgbColor, rgb.count == 3 { out.rgb = RGB(r: byte(rgb[0]), g: byte(rgb[1]), b: byte(rgb[2])) }
        if let v = a.rgbwColor, v.count == 4 { out.rgbw = RGBW(r: byte(v[0]), g: byte(v[1]), b: byte(v[2]), w: byte(v[3])) }
        if let v = a.rgbwwColor, v.count == 5 {
            out.rgbww = RGBWW(r: byte(v[0]), g: byte(v[1]), b: byte(v[2]), cw: byte(v[3]), ww: byte(v[4]))
        }
        if let xy = a.xyColor, xy.count == 2 { out.xy = XY(x: xy[0], y: xy[1]) }
        if let effect = a.effect, effect != effectOff { out.effect = effect }
        return out
    }

    /// Legacy states without `color_mode`: the first supported mode whose attribute is present.
    private static func inferredColorMode(_ a: HALightAttributes) -> ColorMode? {
        guard a.colorMode == nil else { return nil }
        let modes = supportedModes(a)
        if modes.contains(.hs), a.hsColor != nil { return .hs }
        if modes.contains(.xy), a.xyColor != nil { return .xy }
        if modes.contains(.rgb), a.rgbColor != nil { return .rgb }
        if modes.contains(.colorTemp), a.colorTempKelvin != nil { return .colorTemp }
        if modes.contains(.brightness) { return .brightness }
        return modes.contains(.onOff) ? .onOff : nil
    }

    private static func byte(_ v: Int) -> UInt8 { UInt8(clamping: v) }

    // MARK: Commands

    /// Builds the `light.turn_on` / `light.turn_off` call for `command` (normalised for the light
    /// first, so exactly one supported colour attribute is sent). Returns nil for an empty command.
    ///
    /// - `on: false`, or brightness 0 -> `light.turn_off` (+ `transition`).
    /// - otherwise `light.turn_on` with `brightness_pct` (0-100, at least 1 for any positive
    ///   brightness; `brightness_pct: 0` would turn the light off), one of `color_temp_kelvin`,
    ///   `hs_color` (`[h, s*100]`), `rgb_color`, `rgbw_color`, `rgbww_color`, `xy_color`, plus
    ///   `effect` and `transition` (seconds).
    public static func serviceCall(
        for command: LightCommand, entityID: String, capabilities: LightCapabilities
    ) -> HAServiceCall? {
        let cmd = command.normalized(for: capabilities)
        guard !cmd.isEmpty else { return nil }
        let target = HAServiceTarget(entityIDs: [entityID])
        var data: [String: HAJSONValue] = [:]
        if let ms = cmd.transitionMilliseconds { data["transition"] = .double(Double(ms) / 1000) }

        if cmd.on == false || cmd.brightness == 0 {
            return HAServiceCall(domain: "light", service: "turn_off", serviceData: data, target: target)
        }
        if let b = cmd.brightness {
            let pct = (b * 10000).rounded() / 100
            data["brightness_pct"] = .double(max(pct, 1))
        }
        switch cmd.color {
        case .kelvin(let k)?: data["color_temp_kelvin"] = .int(k)
        case .hs(let hs)?: data["hs_color"] = [.double(round2(hs.h)), .double(round2(hs.s * 100))]
        case .rgb(let v)?: data["rgb_color"] = [.int(Int(v.r)), .int(Int(v.g)), .int(Int(v.b))]
        case .rgbw(let v)?: data["rgbw_color"] = [.int(Int(v.r)), .int(Int(v.g)), .int(Int(v.b)), .int(Int(v.w))]
        case .rgbww(let v)?:
            data["rgbww_color"] = [.int(Int(v.r)), .int(Int(v.g)), .int(Int(v.b)), .int(Int(v.cw)), .int(Int(v.ww))]
        case .xy(let xy)?: data["xy_color"] = [.double(round4(xy.x)), .double(round4(xy.y))]
        case nil: break
        }
        if let effect = cmd.effect { data["effect"] = .string(effect) }
        return HAServiceCall(domain: "light", service: "turn_on", serviceData: data, target: target)
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
