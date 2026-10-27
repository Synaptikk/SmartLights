import Foundation
import LightCore

/// Pure mapping between TP-Link wire values and the LightCore model.
public enum TPLinkMapping {
    public static func lightID(_ stableID: String) -> LightID {
        LightID(brand: .tplink, stableId: stableID)!
    }

    public static func stableID(of id: LightID) -> String? {
        id.brand == .tplink ? id.stableId : nil
    }

    // MARK: Capabilities

    static func capabilities(modes: Set<ColorMode>, kelvin: ClosedRange<Int>?, transitions: Bool) -> LightCapabilities {
        let usesKelvin = modes.contains(.colorTemp)
        return LightCapabilities(
            supportedColorModes: modes.isEmpty ? [.onOff] : modes,
            minKelvin: usesKelvin ? kelvin?.lowerBound : nil,
            maxKelvin: usesKelvin ? kelvin?.upperBound : nil,
            supportsTransition: transitions
        )
    }

    /// Kasa (IOT) from sysinfo flags; Kelvin range from the model table (2700-6500 K if unknown).
    /// IOT bulbs and strips take a per-command `transition_period`.
    public static func capabilities(sysinfo: TPLinkIOTSysInfo) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        if sysinfo.isColor { modes.insert(.hs) }
        if sysinfo.isVariableColorTemp { modes.insert(.colorTemp) }
        if modes.isEmpty, sysinfo.isDimmable { modes.insert(.brightness) }
        let kelvin = sysinfo.model.flatMap(TPLinkModelTable.kelvinRange(model:)) ?? 2700...6500
        return capabilities(modes: modes, kelvin: kelvin, transitions: sysinfo.isBulb)
    }

    /// Tapo (SMART) from `get_device_info`. SMART `set_device_info` has no per-command transition
    /// (fades are a device setting, `on_off_gradually`).
    public static func capabilities(info: TPLinkSmartDeviceInfo) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        if info.hasColor { modes.insert(.hs) }
        if info.hasVariableColorTemp { modes.insert(.colorTemp) }
        if modes.isEmpty, info.isDimmable { modes.insert(.brightness) }
        let kelvin = info.hasVariableColorTemp ? info.colorTempRange : info.model.flatMap(TPLinkModelTable.kelvinRange(model:))
        return capabilities(modes: modes, kelvin: kelvin, transitions: false)
    }

    /// Before the first state read: from the model table (unknown models: dimmable).
    public static func capabilities(model: String?, family: TPLinkConnection.Family) -> LightCapabilities {
        guard let model, let info = TPLinkModelTable.lookup(model) else {
            return capabilities(modes: [.brightness], kelvin: nil, transitions: family == .iot)
        }
        return capabilities(modes: info.colorModes, kelvin: TPLinkModelTable.kelvinRange(model: model), transitions: family == .iot)
    }

    // MARK: State

    /// Kasa `light_state` -> `LightState`. `color_temp > 0` means white at that temperature,
    /// otherwise hue/saturation on colour bulbs. When off, the values are the bulb's on-state.
    public static func state(iot light: TPLinkIOTLightState, capabilities: LightCapabilities, at date: Date = Date()) -> LightState {
        state(isOn: light.isOn, brightness: light.brightness, hue: light.hue, saturation: light.saturation,
              colorTemp: light.colorTemp, capabilities: capabilities, effect: nil, at: date)
    }

    public static func state(smart info: TPLinkSmartDeviceInfo, capabilities: LightCapabilities, at date: Date = Date()) -> LightState {
        state(isOn: info.isOn, brightness: info.brightness, hue: info.hue, saturation: info.saturation,
              colorTemp: info.colorTemp, capabilities: capabilities, effect: info.effectActive ? info.effectName : nil, at: date)
    }

    static func state(isOn: Bool, brightness: Int?, hue: Int?, saturation: Int?, colorTemp: Int?,
                      capabilities: LightCapabilities, effect: String?, at date: Date) -> LightState {
        var s = LightState(isOn: isOn, reachable: true, updatedAt: date)
        if capabilities.supportsBrightness, let brightness {
            s.brightness = Double(min(max(brightness, 0), 100)) / 100
        }
        let modes = capabilities.supportedColorModes
        if modes.contains(.colorTemp), let ct = colorTemp, ct > 0 {
            s.colorMode = .colorTemp
            s.kelvin = capabilities.clampKelvin(ct)
        } else if modes.contains(.hs), let hue, let saturation {
            let hs = HS(h: Double(hue), s: Double(saturation) / 100).clamped
            s.colorMode = .hs
            s.hs = hs
            s.rgb = ColorMath.hsToRGB(hs)
        } else if modes.contains(.colorTemp), let ct = colorTemp, ct > 0 {
            s.colorMode = .colorTemp
            s.kelvin = capabilities.clampKelvin(ct)
        } else if capabilities.supportsBrightness {
            s.colorMode = .brightness
        } else {
            s.colorMode = .onOff
        }
        s.effect = effect
        return s
    }

    // MARK: Commands

    /// Device-neutral plan of one command (one wire request carries everything).
    public struct Plan: Sendable, Hashable {
        public var on: Bool?
        /// 1...100.
        public var brightness: Int?
        public var hue: Int?
        public var saturation: Int?
        public var kelvin: Int?
        public var transitionMs: Int?

        public init(on: Bool? = nil, brightness: Int? = nil, hue: Int? = nil, saturation: Int? = nil, kelvin: Int? = nil, transitionMs: Int? = nil) {
            self.on = on
            self.brightness = brightness
            self.hue = hue
            self.saturation = saturation
            self.kelvin = kelvin
            self.transitionMs = transitionMs
        }

        public var isEmpty: Bool { on == nil && brightness == nil && hue == nil && saturation == nil && kelvin == nil }
        public var setsColor: Bool { hue != nil || kelvin != nil }

        /// Kasa `transition_light_state` / `set_light_state` args. Colour sets `color_temp 0`.
        public var iotPatch: TPLinkIOTLightPatch {
            TPLinkIOTLightPatch(
                onOff: on,
                brightness: brightness,
                hue: hue,
                saturation: saturation,
                colorTemp: kelvin ?? (hue != nil ? 0 : nil),
                transitionPeriod: transitionMs
            )
        }

        /// Tapo `set_device_info` params. Colour sets `color_temp 0` (python-kasa `Color.set_hsv`).
        public var smartParams: TPLinkJSON {
            var m: [String: TPLinkJSON] = [:]
            if let on { m["device_on"] = .bool(on) }
            if let brightness { m["brightness"] = .int(Int64(brightness)) }
            if let hue, let saturation {
                m["hue"] = .int(Int64(hue))
                m["saturation"] = .int(Int64(saturation))
                m["color_temp"] = 0
            }
            if let kelvin { m["color_temp"] = .int(Int64(kelvin)) }
            return .object(m)
        }
    }

    /// Normalises `command` for the light and converts it to wire values.
    ///
    /// - `brightness 0` without `on` turns the light off (bulbs reject 0) and keeps its level;
    /// - brightness > 0 or a colour on an off light turns it on (one request: the bulbs apply
    ///   colour and power together, no flash);
    /// - colour is exactly one of hue/saturation or Kelvin (clamped to the light's range).
    public static func plan(_ command: LightCommand, capabilities: LightCapabilities, isOn: Bool) -> Plan {
        let c = command.normalized(for: capabilities)
        var plan = Plan()
        plan.on = c.on
        if let b = c.brightness {
            if b <= 0 {
                if c.on != true { plan.on = false }
            } else {
                plan.brightness = min(max(Int((b * 100).rounded()), 1), 100)
                if c.on == nil, !isOn { plan.on = true }
            }
        }
        if plan.on != false, let color = c.color {
            switch color {
            case .kelvin(let k):
                plan.kelvin = capabilities.clampKelvin(k)
            case .hs(let hs):
                let v = hs.clamped
                plan.hue = Int(v.h.rounded()) % 360
                plan.saturation = min(max(Int((v.s * 100).rounded()), 0), 100)
            default:
                // `normalized(for:)` only yields kelvin or hs for TP-Link capabilities.
                break
            }
            if plan.setsColor, c.on == nil, !isOn { plan.on = true }
        }
        if !plan.isEmpty, let ms = c.transitionMilliseconds, capabilities.supportsTransition {
            plan.transitionMs = ms
        }
        return plan
    }

    /// The state after a successful plan (optimistic cache update).
    public static func apply(_ plan: Plan, to state: LightState, at date: Date = Date()) -> LightState {
        var s = state
        if let on = plan.on { s.isOn = on }
        if let b = plan.brightness { s.brightness = Double(b) / 100 }
        if let k = plan.kelvin {
            s.colorMode = .colorTemp
            s.kelvin = k
            s.hs = nil
            s.rgb = nil
            s.effect = nil
        } else if let h = plan.hue, let sat = plan.saturation {
            let hs = HS(h: Double(h), s: Double(sat) / 100)
            s.colorMode = .hs
            s.hs = hs
            s.rgb = ColorMath.hsToRGB(hs)
            s.kelvin = nil
            s.effect = nil
        }
        s.reachable = true
        s.updatedAt = date
        return s
    }
}
