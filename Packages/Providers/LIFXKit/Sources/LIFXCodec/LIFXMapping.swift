import Foundation
import LightCore

/// Pure mapping between LIFX wire values and the SmartLights domain model (`LightCore`).
public enum LIFXMapping {
    /// Wire range for HSBK kelvin per the LAN docs; product tables narrow or (fw 4.148+) widen it.
    public static let defaultKelvinRange = 1500...9000
    /// Effect ids exposed for colour lights (implemented with `SetWaveform`).
    public static let breatheEffect = EffectDescriptor(id: "breathe", name: "Breathe")
    public static let pulseEffect = EffectDescriptor(id: "pulse", name: "Pulse", isFast: true)

    /// Builds the stable `LightID` (`"lifx:<serial hex>"`).
    public static func lightID(_ serial: LIFXSerial) -> LightID {
        LightID(brand: .lifx, stableId: serial.hex)!
    }

    /// Serial from a `LightID` of brand `.lifx`.
    public static func serial(of id: LightID) -> LIFXSerial? {
        guard id.brand == .lifx else { return nil }
        return LIFXSerial(id.stableId)
    }

    // MARK: Capabilities

    /// Capabilities of a (firmware-resolved) product:
    /// colour products -> `[.hs, .colorTemp]`; tunable white -> `[.colorTemp]`;
    /// fixed white -> `[.brightness]`; relay-only devices (Switch) -> `[.onOff]`.
    public static func capabilities(for product: LIFXProduct) -> LightCapabilities {
        guard product.isLight else { return .onOff }
        let range = product.kelvinRange ?? defaultKelvinRange
        if product.features.contains(.color) {
            return LightCapabilities(
                supportedColorModes: [.hs, .colorTemp],
                minKelvin: range.lowerBound,
                maxKelvin: range.upperBound,
                supportsTransition: true,
                effects: [breatheEffect, pulseEffect]
            )
        }
        if range.lowerBound < range.upperBound {
            return LightCapabilities(supportedColorModes: [.colorTemp], minKelvin: range.lowerBound,
                                     maxKelvin: range.upperBound, supportsTransition: true)
        }
        return LightCapabilities(supportedColorModes: [.brightness], minKelvin: range.lowerBound,
                                 maxKelvin: range.upperBound, supportsTransition: true)
    }

    // MARK: State

    /// `LightState` from a `LightState` (107) reply.
    /// Saturation 0 on a colour light means white (`.colorTemp`); otherwise `.hs` with an RGB hint.
    public static func state(from payload: LIFXLightStatePayload, product: LIFXProduct, at date: Date = Date()) -> LightState {
        state(color: payload.color, power: payload.power, product: product, at: date)
    }

    public static func state(color: HSBK, power: UInt16, product: LIFXProduct, at date: Date = Date()) -> LightState {
        let caps = capabilities(for: product)
        var s = LightState(isOn: power > 0, reachable: true, updatedAt: date)
        guard caps.supportsBrightness else {
            s.colorMode = .onOff
            return s
        }
        s.brightness = color.brightnessFraction
        if caps.supportsColor && color.saturation > 0 {
            let hs = HS(h: color.hueDegrees, s: color.saturationFraction)
            s.colorMode = .hs
            s.hs = hs
            s.rgb = ColorMath.hsToRGB(hs)
        } else if caps.supportsColorTemp {
            s.colorMode = .colorTemp
            s.kelvin = caps.clampKelvin(Int(color.kelvin))
        } else {
            s.colorMode = .brightness
        }
        return s
    }

    /// HSBK that reproduces a domain colour attribute (any attribute; converted with `ColorMath`).
    /// `base` supplies the components the attribute does not define (brightness, white point).
    public static func hsbk(applying attribute: ColorAttribute, to base: HSBK, kelvinRange: ClosedRange<Int>) -> HSBK {
        var out = base
        func setHS(_ hs: HS) {
            let c = hs.clamped
            out.hue = HSBK.encodeHue(c.h)
            out.saturation = HSBK.encodeUnit(c.s)
        }
        switch attribute {
        case .kelvin(let k):
            out.saturation = 0
            out.kelvin = UInt16(clamping: min(max(k, kelvinRange.lowerBound), kelvinRange.upperBound))
        case .hs(let hs): setHS(hs)
        case .rgb(let rgb): setHS(ColorMath.rgbToHS(rgb))
        case .rgbw(let v): setHS(ColorMath.rgbToHS(ColorMath.rgbwToRGB(v)))
        case .rgbww(let v):
            setHS(ColorMath.rgbToHS(ColorMath.rgbwwToRGB(v, minKelvin: kelvinRange.lowerBound, maxKelvin: kelvinRange.upperBound)))
        case .xy(let xy): setHS(ColorMath.xyToHS(xy))
        }
        if !kelvinRange.contains(Int(out.kelvin)) {
            out.kelvin = UInt16(clamping: min(max(Int(out.kelvin), kelvinRange.lowerBound), kelvinRange.upperBound))
        }
        return out
    }

    // MARK: Commands

    /// The wire messages for one `LightCommand`, in send order.
    public struct CommandPlan: Hashable, Sendable {
        /// New colour (SetColor 102), if colour or brightness changes.
        public var color: HSBK?
        /// New power (Light SetPower 117), if power changes or must be asserted.
        public var power: Bool?
        /// Transition in milliseconds (`LightCommand.transition`).
        public var durationMs: UInt32
        /// Effect (SetWaveform 103), sent last.
        public var waveform: LIFXWaveform?

        public init(color: HSBK? = nil, power: Bool? = nil, durationMs: UInt32 = 0, waveform: LIFXWaveform? = nil) {
            self.color = color
            self.power = power
            self.durationMs = durationMs
            self.waveform = waveform
        }

        public var isEmpty: Bool { color == nil && power == nil && waveform == nil }

        /// Messages to send, in order. When the light is being switched on, the colour is set
        /// instantly first and the power fades in with the transition (no fade from the old
        /// colour); otherwise SetColor carries the transition and SetPower follows.
        public func messages(currentlyOn: Bool) -> [LIFXMessage] {
            var out: [LIFXMessage] = []
            let turningOn = power == true && !currentlyOn
            if let color {
                out.append(.lightSetColor(color, durationMs: turningOn ? 0 : durationMs))
            }
            if let power {
                out.append(.lightSetPower(level: power ? 65535 : 0, durationMs: durationMs))
            }
            if let waveform { out.append(.lightSetWaveform(waveform)) }
            return out
        }
    }

    /// Plans a command for a light whose last known colour/power are `current`/`isOn`.
    ///
    /// - The command is first normalised for the product (`LightCommand.normalized(for:)`).
    /// - Brightness and colour are merged into one HSBK (one SetColor, no flash).
    /// - `brightness == 0` without `on` turns the light off and keeps its colour/brightness, so
    ///   turning it on again restores it; `brightness > 0` without `on` on an off light turns it on.
    /// - `effect` `"breathe"`/`"pulse"` adds a transient SetWaveform towards the target colour.
    public static func plan(_ command: LightCommand, current: HSBK, isOn: Bool, product: LIFXProduct) -> CommandPlan {
        let caps = capabilities(for: product)
        let cmd = command.normalized(for: caps)
        let range = caps.kelvinRange
        var plan = CommandPlan()
        if let ms = cmd.transitionMilliseconds { plan.durationMs = UInt32(clamping: ms) }

        var power = cmd.on
        var brightness = cmd.brightness
        if let b = brightness, b <= 0 {
            brightness = nil
            if power == nil { power = false }
        }
        if brightness != nil, power == nil, !isOn { power = true }

        if cmd.color != nil || brightness != nil {
            var color = current
            if let attr = cmd.color { color = hsbk(applying: attr, to: color, kelvinRange: range) }
            if let b = brightness { color.brightness = HSBK.encodeUnit(b) }
            if color != current { plan.color = color }
        }
        if let power, power != isOn || cmd.on != nil { plan.power = power }

        if let effect = cmd.effect {
            let target = plan.color ?? current
            switch effect {
            case breatheEffect.id:
                plan.waveform = LIFXWaveform(transient: true, color: dimmed(target), periodMs: 2000, cycles: 5, waveform: .sine)
            case pulseEffect.id:
                plan.waveform = LIFXWaveform(transient: true, color: dimmed(target), periodMs: 600, cycles: 5, waveform: .pulse)
            default:
                break
            }
            if plan.waveform != nil, !isOn, plan.power == nil { plan.power = true }
        }
        return plan
    }

    /// Waveform target: same hue at 20 % of the current brightness (the effect oscillates to it).
    private static func dimmed(_ c: HSBK) -> HSBK {
        var out = c
        out.brightness = c.brightness / 5
        return out
    }

    /// Applies an executed plan to the cached colour/power.
    public static func apply(_ plan: CommandPlan, current: HSBK, isOn: Bool) -> (color: HSBK, isOn: Bool) {
        (plan.color ?? current, plan.power ?? isOn)
    }
}
