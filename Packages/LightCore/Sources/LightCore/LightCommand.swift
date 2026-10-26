import Foundation

/// The single colour attribute a command carries.
public enum ColorAttribute: Codable, Sendable, Hashable {
    case kelvin(Int)
    case hs(HS)
    case rgb(RGB)
    case rgbw(RGBW)
    case rgbww(RGBWW)
    case xy(XY)

    /// The colour mode this attribute addresses.
    public var colorMode: ColorMode {
        switch self {
        case .kelvin: .colorTemp
        case .hs: .hs
        case .rgb: .rgb
        case .rgbw: .rgbw
        case .rgbww: .rgbww
        case .xy: .xy
        }
    }
}

/// A state change for one light (or a group). Exactly one colour attribute per command;
/// providers call `normalized(for:)` so the device receives an attribute it supports.
/// Unset fields mean "leave unchanged".
public struct LightCommand: Codable, Sendable, Hashable {
    public var on: Bool?
    /// `0...1`.
    public var brightness: Double?
    public var color: ColorAttribute?
    /// Effect id from `LightCapabilities.effects`.
    public var effect: String?
    public var transition: Duration?

    public init(
        on: Bool? = nil,
        brightness: Double? = nil,
        color: ColorAttribute? = nil,
        effect: String? = nil,
        transition: Duration? = nil
    ) {
        self.on = on
        self.brightness = brightness
        self.color = color
        self.effect = effect
        self.transition = transition
    }

    public static let turnOn = LightCommand(on: true)
    public static let turnOff = LightCommand(on: false)

    /// True when the command changes nothing.
    public var isEmpty: Bool {
        on == nil && brightness == nil && color == nil && effect == nil
    }

    /// Transition in milliseconds (handy for wire formats), nil if unset.
    public var transitionMilliseconds: Int? {
        guard let transition else { return nil }
        let (seconds, attoseconds) = transition.components
        return max(0, Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000))
    }

    /// Returns a command the given light can execute:
    /// - brightness clamped to `0...1`, dropped for on/off-only devices;
    /// - colour converted to exactly one supported attribute (HA conversion preferences),
    ///   colour temperature clamped to the light's Kelvin range, xy clamped to its gamut;
    ///   dropped if the light has no colour/temperature support;
    /// - effect dropped unless supported (and, if the light lists effects, known);
    /// - transition dropped unless supported.
    public func normalized(for capabilities: LightCapabilities) -> LightCommand {
        var out = self
        let modes = capabilities.supportedColorModes

        if let b = brightness {
            out.brightness = capabilities.supportsBrightness ? (b.isFinite ? min(max(b, 0), 1) : nil) : nil
        }
        if let effect {
            let known = capabilities.effects.isEmpty || capabilities.effects.contains { $0.id == effect }
            out.effect = capabilities.supportsEffects && known ? effect : nil
        }
        if !capabilities.supportsTransition { out.transition = nil }
        out.color = color.flatMap { Self.convert($0, modes: modes, capabilities: capabilities) }
        return out
    }

    // MARK: - Conversion

    /// Order of preference for each source mode (follows HA `light/__init__.py`).
    private static func preference(for mode: ColorMode) -> [ColorMode] {
        switch mode {
        case .hs: [.hs, .xy, .rgb, .rgbw, .rgbww, .colorTemp]
        case .xy: [.xy, .hs, .rgb, .rgbw, .rgbww, .colorTemp]
        case .rgb: [.rgb, .rgbw, .rgbww, .hs, .xy, .colorTemp]
        case .rgbw: [.rgbw, .rgb, .rgbww, .hs, .xy, .colorTemp]
        case .rgbww: [.rgbww, .rgb, .rgbw, .hs, .xy, .colorTemp]
        case .colorTemp: [.colorTemp, .rgbww, .xy, .hs, .rgb, .rgbw]
        case .onOff, .brightness, .white: []
        }
    }

    private static func convert(_ attr: ColorAttribute, modes: Set<ColorMode>, capabilities: LightCapabilities) -> ColorAttribute? {
        guard let target = preference(for: attr.colorMode).first(where: modes.contains) else { return nil }
        let gamut = capabilities.gamut
        let range = capabilities.kelvinRange

        // Same mode: only sanitise.
        if target == attr.colorMode {
            switch attr {
            case .kelvin(let k): return .kelvin(capabilities.clampKelvin(k))
            case .hs(let hs): return .hs(hs.clamped)
            case .xy(let xy): return .xy(gamut?.clamp(xy) ?? xy)
            case .rgb, .rgbw, .rgbww: return attr
            }
        }

        // Colour temperature target: estimate CCT from the colour's chromaticity.
        if target == .colorTemp {
            let xy = ColorMath.rgbToXY(rgb(of: attr, kelvinRange: range))
            guard xy.x + xy.y > 0 else { return nil }
            return .kelvin(capabilities.clampKelvin(ColorMath.xyToKelvin(xy)))
        }

        // Kelvin source on a colour-only light.
        if case .kelvin(let k) = attr {
            let kelvin = capabilities.clampKelvin(k)
            switch target {
            case .rgbww: return .rgbww(ColorMath.kelvinToRGBWW(kelvin, brightness: 255, minKelvin: range.lowerBound, maxKelvin: range.upperBound))
            case .xy: return .xy(gamut?.clamp(ColorMath.kelvinToXY(kelvin)) ?? ColorMath.kelvinToXY(kelvin))
            case .hs: return .hs(ColorMath.kelvinToHS(kelvin))
            case .rgb: return .rgb(ColorMath.kelvinToRGB(kelvin))
            case .rgbw: return .rgbw(ColorMath.rgbToRGBW(ColorMath.kelvinToRGB(kelvin)))
            default: return nil
            }
        }

        // Chromatic source -> other chromatic target.
        if target == .xy {
            switch attr {
            case .hs(let hs): return .xy(ColorMath.hsToXY(hs, gamut: gamut))
            default: return .xy(ColorMath.rgbToXY(rgb(of: attr, kelvinRange: range), gamut: gamut))
            }
        }
        if target == .hs {
            switch attr {
            case .xy(let xy): return .hs(ColorMath.xyToHS(xy, gamut: gamut))
            default: return .hs(ColorMath.rgbToHS(rgb(of: attr, kelvinRange: range)))
            }
        }
        let rgb = rgb(of: attr, kelvinRange: range)
        switch target {
        case .rgb: return .rgb(rgb)
        case .rgbw: return .rgbw(ColorMath.rgbToRGBW(rgb))
        case .rgbww: return .rgbww(ColorMath.rgbToRGBWW(rgb, minKelvin: range.lowerBound, maxKelvin: range.upperBound))
        default: return nil
        }
    }

    /// Full-value RGB representation of any colour attribute.
    private static func rgb(of attr: ColorAttribute, kelvinRange: ClosedRange<Int>) -> RGB {
        switch attr {
        case .kelvin(let k): ColorMath.kelvinToRGB(k)
        case .hs(let hs): ColorMath.hsToRGB(hs)
        case .rgb(let rgb): rgb
        case .rgbw(let v): ColorMath.rgbwToRGB(v)
        case .rgbww(let v): ColorMath.rgbwwToRGB(v, minKelvin: kelvinRange.lowerBound, maxKelvin: kelvinRange.upperBound)
        case .xy(let xy): ColorMath.xyToRGB(xy)
        }
    }
}
