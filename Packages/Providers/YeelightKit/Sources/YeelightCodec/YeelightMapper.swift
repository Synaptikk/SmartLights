import Foundation
import LightCore

/// Conversions between Yeelight wire values and the LightCore model.
public enum YeelightMapper {
    /// Device brightness range.
    public static let brightnessRange = 1...100

    // MARK: Value conversions

    /// RGB -> Yeelight integer `r * 65536 + g * 256 + b`.
    public static func rgbInt(_ rgb: RGB) -> Int {
        Int(rgb.r) << 16 | Int(rgb.g) << 8 | Int(rgb.b)
    }

    /// Yeelight integer -> RGB (values outside 0...0xFFFFFF are clamped).
    public static func rgb(fromInt value: Int) -> RGB {
        let v = YeelightCommands.clampRGB(value)
        return RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    /// Brightness `0...1` -> 1...100.
    public static func deviceBrightness(_ brightness: Double) -> Int {
        ColorMath.deviceValue(forBrightness: brightness, in: brightnessRange)
    }

    /// 1...100 -> brightness `0...1`.
    public static func brightness(fromDevice value: Int) -> Double {
        ColorMath.brightness(fromDeviceValue: value, in: brightnessRange)
    }

    /// HS (degrees, 0...1) -> device hue 0...359 and saturation 0...100.
    public static func deviceHS(_ hs: HS) -> (hue: Int, saturation: Int) {
        let c = hs.clamped
        return (YeelightCommands.clampHue(Int(c.h.rounded())), YeelightCommands.clampPercent(Int((c.s * 100).rounded())))
    }

    // MARK: State

    /// Merges reported properties (a full `get_prop` result, SSDP headers or a partial `props`
    /// notification) into `base`. Unknown/empty values are ignored.
    public static func state(
        merging props: [String: YeelightValue],
        into base: LightState,
        kind: YeelightLightKind,
        now: Date = Date()
    ) -> LightState {
        var s = base
        if let power = props["power"]?.stringValue?.lowercased() {
            if power == "on" { s.isOn = true } else if power == "off" { s.isOn = false }
        }
        if let bright = props["bright"]?.intValue, bright > 0 {
            s.brightness = brightness(fromDevice: bright)
        }
        switch kind {
        case .mono:
            s.colorMode = .brightness
        case .colorTemperature:
            if let ct = props["ct"]?.intValue, ct > 0 { s.kelvin = ct }
            s.colorMode = .colorTemp
        case .color:
            if let ct = props["ct"]?.intValue, ct > 0 { s.kelvin = ct }
            if let v = props["rgb"]?.intValue, v >= 0 { s.rgb = rgb(fromInt: v) }
            let hue = props["hue"]?.intValue
            let sat = props["sat"]?.intValue
            if hue != nil || sat != nil {
                let old = s.hs ?? HS(h: 0, s: 0)
                s.hs = HS(h: Double(hue ?? Int(old.h.rounded())), s: Double(sat ?? Int((old.s * 100).rounded())) / 100).clamped
            }
            if let mode = props["color_mode"]?.intValue.flatMap(YeelightColorMode.init(rawValue:)) {
                switch mode {
                case .rgb: s.colorMode = .rgb
                case .colorTemperature: s.colorMode = .colorTemp
                case .hsv: s.colorMode = .hs
                }
            } else if props["rgb"] != nil {
                s.colorMode = .rgb
            } else if props["hue"] != nil || props["sat"] != nil {
                s.colorMode = .hs
            } else if props["ct"] != nil {
                s.colorMode = .colorTemp
            }
        }
        s.reachable = true
        s.updatedAt = now
        return s
    }

    /// Pairs `get_prop` names with result values (`""` = unsupported property, dropped).
    public static func properties(names: [String], values: [YeelightValue]) -> [String: YeelightValue] {
        var out: [String: YeelightValue] = [:]
        for (name, value) in zip(names, values) {
            if case .string(let s) = value, s.isEmpty { continue }
            if case .null = value { continue }
            out[name] = value
        }
        return out
    }

    // MARK: Commands

    /// Turns a `LightCommand` into the fewest Yeelight calls, in order.
    ///
    /// - `on: false` (or brightness 0) -> one `set_power off`.
    /// - Colour while the light is off (or state unknown) and the command turns it on -> one
    ///   `set_scene` (colour + brightness + power in a single call).
    /// - Colour and brightness while on, without an explicit transition -> one `set_scene`.
    /// - Brightness-only "turn on" of a colour/CT light whose current colour is known -> one
    ///   `set_scene` with that colour.
    /// - Otherwise `set_power on` (if needed), then `set_ct_abx`/`set_hsv`/`set_rgb`, then
    ///   `set_bright`, each with the command's transition (smooth) or the default timing.
    /// - A colour for a light that is off and not being turned on is dropped (the device only accepts
    ///   colour setters in the on state).
    ///
    /// - Parameters:
    ///   - current: last known state; nil = unknown (treated as off).
    ///   - support: the device's `support` list; empty = unknown (everything assumed supported).
    public static func calls(
        for command: LightCommand,
        capabilities: LightCapabilities,
        current: LightState?,
        support: Set<String> = [],
        defaultTiming: YeelightTiming = .default
    ) -> [YeelightCall] {
        let cmd = command.normalized(for: capabilities)
        let timing = YeelightTiming.forTransition(milliseconds: cmd.transitionMilliseconds, fallback: defaultTiming)
        let explicitTransition = cmd.transition != nil
        let isOn = current?.isOn ?? false

        if cmd.on == false || (cmd.brightness.map { $0 <= 0 } ?? false && cmd.on != true) {
            return [YeelightCommands.setPower(false, timing: timing)]
        }
        let bright: Int? = cmd.brightness.flatMap { $0 > 0 ? deviceBrightness($0) : nil }
        let wantsOn = cmd.on == true || bright != nil
        let canScene = YeelightCapabilities.supports("set_scene", in: support)

        if wantsOn && !isOn {
            if let color = cmd.color, canScene, let scene = scene(for: color, brightness: bright ?? currentBrightness(current)) {
                return [YeelightCommands.setScene(scene)]
            }
            if cmd.color == nil, let bright, canScene, let known = current?.colorAttribute,
               capabilities.supportedColorModes.contains(known.colorMode),
               let scene = scene(for: known, brightness: bright) {
                return [YeelightCommands.setScene(scene)]
            }
            var out = [YeelightCommands.setPower(true, timing: timing)]
            if let color = cmd.color, let call = colorCall(color, timing: timing) { out.append(call) }
            if let bright { out.append(YeelightCommands.setBright(bright, timing: timing)) }
            return out
        }

        guard isOn || wantsOn else { return [] } // off and staying off: colour cannot be applied

        if let color = cmd.color, let bright, !explicitTransition, canScene, let scene = scene(for: color, brightness: bright) {
            return [YeelightCommands.setScene(scene)]
        }
        var out: [YeelightCall] = []
        if let color = cmd.color, let call = colorCall(color, timing: timing) { out.append(call) }
        if let bright { out.append(YeelightCommands.setBright(bright, timing: timing)) }
        if out.isEmpty, cmd.on == true { out.append(YeelightCommands.setPower(true, timing: timing)) }
        return out
    }

    static func currentBrightness(_ state: LightState?) -> Int {
        guard let b = state?.brightness, b > 0 else { return 100 }
        return deviceBrightness(b)
    }

    static func scene(for color: ColorAttribute, brightness: Int) -> YeelightCommands.Scene? {
        switch color {
        case .kelvin(let k): return .colorTemperature(kelvin: k, brightness: brightness)
        case .hs(let hs):
            let d = deviceHS(hs)
            return .hsv(hue: d.hue, saturation: d.saturation, brightness: brightness)
        case .rgb(let rgb): return .color(rgb: rgbInt(rgb), brightness: brightness)
        case .rgbw, .rgbww, .xy: return nil
        }
    }

    static func colorCall(_ color: ColorAttribute, timing: YeelightTiming) -> YeelightCall? {
        switch color {
        case .kelvin(let k): return YeelightCommands.setCTAbx(k, timing: timing)
        case .hs(let hs):
            let d = deviceHS(hs)
            return YeelightCommands.setHSV(hue: d.hue, saturation: d.saturation, timing: timing)
        case .rgb(let rgb): return YeelightCommands.setRGB(rgbInt(rgb), timing: timing)
        case .rgbw, .rgbww, .xy: return nil
        }
    }
}
