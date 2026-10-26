import Foundation

/// Colour modes, mirroring Home Assistant's `ColorMode` (PLAN.md D7).
public enum ColorMode: String, Codable, CaseIterable, Sendable, Hashable {
    case onOff
    case brightness
    case colorTemp
    case hs
    case rgb
    case rgbw
    case rgbww
    case xy
    /// White channel at a fixed temperature (HA `ColorMode.WHITE`).
    case white

    /// Modes that can show an arbitrary chromatic colour.
    public static let colorModes: Set<ColorMode> = [.hs, .rgb, .rgbw, .rgbww, .xy]

    public var isColor: Bool { Self.colorModes.contains(self) }
    /// Every mode except `.onOff` implies dimming support.
    public var supportsBrightness: Bool { self != .onOff }
}

/// Hue (degrees, `0..<360`) and saturation (`0...1`).
public struct HS: Codable, Sendable, Hashable {
    public var h: Double
    public var s: Double

    public init(h: Double, s: Double) {
        self.h = h
        self.s = s
    }

    /// Hue wrapped into `0..<360`, saturation clamped into `0...1`.
    public var clamped: HS {
        guard h.isFinite else { return HS(h: 0, s: s.isFinite ? min(max(s, 0), 1) : 0) }
        var hue = h.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        return HS(h: hue, s: s.isFinite ? min(max(s, 0), 1) : 0)
    }
}

/// 8-bit RGB at full value (brightness is carried separately).
public struct RGB: Codable, Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Rounds to nearest and clamps each channel into `0...255`.
    public init(clamping r: Double, _ g: Double, _ b: Double) {
        self.init(r: UInt8(clampingChannel: r), g: UInt8(clampingChannel: g), b: UInt8(clampingChannel: b))
    }

    public static let white = RGB(r: 255, g: 255, b: 255)
    public static let black = RGB(r: 0, g: 0, b: 0)
}

/// 8-bit RGB + white channel.
public struct RGBW: Codable, Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var w: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, w: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.w = w
    }
}

/// 8-bit RGB + cold white + warm white.
public struct RGBWW: Codable, Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    /// Cold white channel.
    public var cw: UInt8
    /// Warm white channel.
    public var ww: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, cw: UInt8, ww: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.cw = cw
        self.ww = ww
    }
}

/// CIE 1931 chromaticity.
public struct XY: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Colour gamut triangle of a lamp in CIE xy space.
public struct Gamut: Codable, Sendable, Hashable {
    public var red: XY
    public var green: XY
    public var blue: XY

    public init(red: XY, green: XY, blue: XY) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Philips Hue gamut A (LivingColors, early LightStrips).
    public static let hueA = Gamut(red: XY(x: 0.704, y: 0.296), green: XY(x: 0.2151, y: 0.7106), blue: XY(x: 0.138, y: 0.08))
    /// Philips Hue gamut B (first-generation A19 colour bulbs).
    public static let hueB = Gamut(red: XY(x: 0.675, y: 0.322), green: XY(x: 0.409, y: 0.518), blue: XY(x: 0.167, y: 0.04))
    /// Philips Hue gamut C (current colour bulbs, LightStrip Plus, ...).
    public static let hueC = Gamut(red: XY(x: 0.6915, y: 0.3083), green: XY(x: 0.17, y: 0.7), blue: XY(x: 0.1532, y: 0.0475))

    /// Whether the lamp can reproduce `p` (triangle edges included).
    public func contains(_ p: XY) -> Bool { ColorMath.isPoint(p, in: self) }
    /// `p` if reproducible, otherwise the closest point on the triangle edge.
    public func clamp(_ p: XY) -> XY { contains(p) ? p : ColorMath.closestPoint(to: p, in: self) }
    /// Non-degenerate triangle with all coordinates in `0...1`.
    public var isValid: Bool { ColorMath.isValid(self) }
}

extension UInt8 {
    /// Rounds to nearest and clamps into `0...255`; NaN becomes 0.
    init(clampingChannel value: Double) {
        guard value.isFinite else {
            self = value == .infinity ? 255 : 0
            return
        }
        self = UInt8(Swift.min(Swift.max(value.rounded(), 0), 255))
    }
}
