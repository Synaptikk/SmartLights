import Foundation

/// A vendor effect or scene surfaced as a named effect on a light.
public struct EffectDescriptor: Codable, Sendable, Hashable, Identifiable {
    /// Provider-specific id sent back in `LightCommand.effect` (e.g. WiZ scene id "4").
    public var id: String
    /// Human readable name ("Party", "Candlelight").
    public var name: String
    /// Strobe / fast-changing effect: the UI shows a photosensitivity warning first.
    public var isFast: Bool

    public init(id: String, name: String, isFast: Bool = false) {
        self.id = id
        self.name = name
        self.isFast = isFast
    }
}

/// What a light can do. Mirrors HA `supported_color_modes` + min/max colour temperature.
public struct LightCapabilities: Codable, Sendable, Hashable {
    public var supportedColorModes: Set<ColorMode>
    public var minKelvin: Int?
    public var maxKelvin: Int?
    public var supportsTransition: Bool
    public var supportsEffects: Bool
    /// Vendor effects/scenes exposed as named effects.
    public var effects: [EffectDescriptor]
    /// Colour gamut for xy conversions (Hue gamut A/B/C); nil = unknown/unbounded.
    public var gamut: Gamut?

    public init(
        supportedColorModes: Set<ColorMode>,
        minKelvin: Int? = nil,
        maxKelvin: Int? = nil,
        supportsTransition: Bool = false,
        supportsEffects: Bool = false,
        effects: [EffectDescriptor] = [],
        gamut: Gamut? = nil
    ) {
        self.supportedColorModes = supportedColorModes
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
        self.supportsTransition = supportsTransition
        self.supportsEffects = supportsEffects || !effects.isEmpty
        self.effects = effects
        self.gamut = gamut
    }

    /// A plain on/off device (smart plug).
    public static let onOff = LightCapabilities(supportedColorModes: [.onOff])
    /// Dimmable white without temperature control.
    public static let dimmable = LightCapabilities(supportedColorModes: [.brightness])

    public var supportsBrightness: Bool { supportedColorModes.contains { $0.supportsBrightness } }
    public var supportsColorTemp: Bool { supportedColorModes.contains(.colorTemp) }
    public var supportsColor: Bool { supportedColorModes.contains { $0.isColor } }

    /// Kelvin range; unknown bounds default to HA's 2000...6535 K.
    public var kelvinRange: ClosedRange<Int> {
        let lo = minKelvin ?? 2000
        let hi = maxKelvin ?? 6535
        return lo <= hi ? lo...hi : hi...lo
    }

    /// Clamp a requested colour temperature into this light's range.
    public func clampKelvin(_ kelvin: Int) -> Int {
        let range = kelvinRange
        return min(max(kelvin, range.lowerBound), range.upperBound)
    }
}
