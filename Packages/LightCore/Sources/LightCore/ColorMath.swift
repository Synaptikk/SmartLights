import Foundation

/// Colour-space conversions shared by every provider.
///
/// Formulas follow Home Assistant's `homeassistant/util/color.py` (Apache-2.0), which in turn
/// uses the Philips Hue "RGB to xy Color conversion" design note (wide-gamut D65 matrices,
/// gamut clamping by closest point on the triangle edge, adapted from benknight/rgbxy, MIT)
/// and Tanner Helland's Kelvin -> RGB approximation. The API shape (hex/HSV/xy/mired helpers)
/// follows house-control's `ColorMath` (MIT). See NOTICES.md.
///
/// Conventions: hue in degrees `0..<360`; saturation, value and brightness in `0...1`;
/// 8-bit channels in `RGB`/`RGBW`/`RGBWW`.
public enum ColorMath {

    // MARK: HSV

    /// RGB -> (h 0..<360, s 0...1, v 0...1). Same algorithm as Python's `colorsys.rgb_to_hsv`.
    public static func rgbToHSV(_ rgb: RGB) -> (h: Double, s: Double, v: Double) {
        let r = Double(rgb.r) / 255, g = Double(rgb.g) / 255, b = Double(rgb.b) / 255
        let maxc = max(r, g, b), minc = min(r, g, b)
        let v = maxc
        guard maxc != minc else { return (0, 0, v) }
        let s = (maxc - minc) / maxc
        let rc = (maxc - r) / (maxc - minc)
        let gc = (maxc - g) / (maxc - minc)
        let bc = (maxc - b) / (maxc - minc)
        var h: Double
        if r == maxc { h = bc - gc } else if g == maxc { h = 2.0 + rc - bc } else { h = 4.0 + gc - rc }
        h = (h / 6.0).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }
        return (h * 360, s, v)
    }

    /// (h degrees, s 0...1, v 0...1) -> RGB, rounding to nearest (HA `color_hsv_to_RGB`).
    public static func hsvToRGB(h: Double, s: Double, v: Double) -> RGB {
        let (r, g, b) = hsvToRGBComponents(h: h, s: s, v: v)
        return RGB(clamping: r * 255, g * 255, b * 255)
    }

    /// HS at full value -> RGB.
    public static func hsToRGB(_ hs: HS) -> RGB {
        let c = hs.clamped
        return hsvToRGB(h: c.h, s: c.s, v: 1)
    }

    /// RGB -> HS (value discarded).
    public static func rgbToHS(_ rgb: RGB) -> HS {
        let hsv = rgbToHSV(rgb)
        return HS(h: hsv.h, s: hsv.s)
    }

    /// Python `colorsys.hsv_to_rgb` with h in degrees.
    static func hsvToRGBComponents(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let s = min(max(s, 0), 1), v = min(max(v, 0), 1)
        guard s > 0 else { return (v, v, v) }
        var hn = (h / 360).truncatingRemainder(dividingBy: 1)
        if hn < 0 { hn += 1 }
        let i = Int((hn * 6).rounded(.down))
        let f = hn * 6 - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: CIE xy (Philips Hue)

    /// RGB -> xy plus relative luminance (`0...1`), clamped to `gamut` if given.
    /// Black returns xy (0, 0) and brightness 0 (as HA does).
    public static func rgbToXYBrightness(_ rgb: RGB, gamut: Gamut? = nil) -> (xy: XY, brightness: Double) {
        guard Int(rgb.r) + Int(rgb.g) + Int(rgb.b) > 0 else { return (XY(x: 0, y: 0), 0) }
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        // Wide RGB D65 conversion.
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        var xy = XY(x: X / sum, y: Y / sum)
        if let gamut, !isPoint(xy, in: gamut) {
            xy = closestPoint(to: xy, in: gamut)
        }
        return (xy, min(Y, 1))
    }

    /// RGB -> xy, clamped to `gamut` if given.
    public static func rgbToXY(_ rgb: RGB, gamut: Gamut? = nil) -> XY {
        rgbToXYBrightness(rgb, gamut: gamut).xy
    }

    /// xy (+ brightness `0...1`) -> RGB, normalised so the largest channel is at most 255.
    /// Truncates channels like HA `color_xy_brightness_to_RGB`.
    public static func xyToRGB(_ xy: XY, brightness: Double = 1, gamut: Gamut? = nil) -> RGB {
        var p = xy
        if let gamut, !isPoint(p, in: gamut) { p = closestPoint(to: p, in: gamut) }
        let Y = min(max(brightness, 0), 1)
        guard Y > 0 else { return .black }
        let vy = max(p.y, 1e-11)
        let X = (Y / vy) * p.x
        let Z = (Y / vy) * (1 - p.x - vy)
        var c = [
            X * 1.656492 - Y * 0.354851 - Z * 0.255038,
            -X * 0.707196 + Y * 1.655397 + Z * 0.036152,
            X * 0.051713 - Y * 0.121364 + Z * 1.011530,
        ]
        c = c.map { $0 <= 0.0031308 ? 12.92 * $0 : 1.055 * pow($0, 1 / 2.4) - 0.055 }
        c = c.map { max(0, $0.isFinite ? $0 : 0) }
        let top = c.max() ?? 0
        if top > 1 { c = c.map { $0 / top } }
        func channel(_ v: Double) -> UInt8 { UInt8(min(255, max(0, Int(v * 255)))) }
        return RGB(r: channel(c[0]), g: channel(c[1]), b: channel(c[2]))
    }

    /// HS -> xy via full-value RGB (HA `color_hs_to_xy`).
    public static func hsToXY(_ hs: HS, gamut: Gamut? = nil) -> XY {
        rgbToXY(hsToRGB(hs), gamut: gamut)
    }

    /// xy -> HS via RGB (HA `color_xy_to_hs`).
    public static func xyToHS(_ xy: XY, gamut: Gamut? = nil) -> HS {
        rgbToHS(xyToRGB(xy, gamut: gamut))
    }

    // MARK: Gamut geometry

    private static func cross(_ a: XY, _ b: XY) -> Double { a.x * b.y - a.y * b.x }

    /// Barycentric point-in-triangle test (HA `check_point_in_lamps_reach`).
    public static func isPoint(_ p: XY, in gamut: Gamut) -> Bool {
        let v1 = XY(x: gamut.green.x - gamut.red.x, y: gamut.green.y - gamut.red.y)
        let v2 = XY(x: gamut.blue.x - gamut.red.x, y: gamut.blue.y - gamut.red.y)
        let q = XY(x: p.x - gamut.red.x, y: p.y - gamut.red.y)
        let d = cross(v1, v2)
        guard d != 0 else { return false }
        let s = cross(q, v2) / d
        let t = cross(v1, q) / d
        let eps = 1e-12
        return s >= -eps && t >= -eps && s + t <= 1 + eps
    }

    private static func closestPointOnLine(_ a: XY, _ b: XY, _ p: XY) -> XY {
        let ap = XY(x: p.x - a.x, y: p.y - a.y)
        let ab = XY(x: b.x - a.x, y: b.y - a.y)
        let ab2 = ab.x * ab.x + ab.y * ab.y
        guard ab2 > 0 else { return a }
        let t = min(max((ap.x * ab.x + ap.y * ab.y) / ab2, 0), 1)
        return XY(x: a.x + ab.x * t, y: a.y + ab.y * t)
    }

    private static func distance(_ a: XY, _ b: XY) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// Closest point on the gamut triangle's edges (HA `get_closest_point_to_point`).
    public static func closestPoint(to p: XY, in gamut: Gamut) -> XY {
        let candidates = [
            closestPointOnLine(gamut.red, gamut.green, p),
            closestPointOnLine(gamut.blue, gamut.red, p),
            closestPointOnLine(gamut.green, gamut.blue, p),
        ]
        var best = candidates[0]
        for c in candidates.dropFirst() where distance(p, c) < distance(p, best) { best = c }
        return best
    }

    /// HA `check_valid_gamut`.
    public static func isValid(_ gamut: Gamut) -> Bool {
        let v1 = XY(x: gamut.green.x - gamut.red.x, y: gamut.green.y - gamut.red.y)
        let v2 = XY(x: gamut.blue.x - gamut.red.x, y: gamut.blue.y - gamut.red.y)
        let inUnit = [gamut.red, gamut.green, gamut.blue].allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
        return cross(v1, v2) > 0.0001 && inUnit
    }

    // MARK: Colour temperature

    /// Kelvin -> mired, floored (HA `color_temperature_kelvin_to_mired`). 2700 K -> 370.
    public static func kelvinToMired(_ kelvin: Int) -> Int {
        guard kelvin > 0 else { return 0 }
        return 1_000_000 / kelvin
    }

    /// Mired -> Kelvin, floored (HA `color_temperature_mired_to_kelvin`). 153 -> 6535.
    public static func miredToKelvin(_ mired: Int) -> Int {
        guard mired > 0 else { return 0 }
        return 1_000_000 / mired
    }

    /// Kelvin -> RGB components (0...255, unrounded), Tanner Helland approximation,
    /// input clamped to 1000...40000 K (HA `color_temperature_to_rgb`).
    public static func kelvinToRGBComponents(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let k = min(max(kelvin, 1000), 40000)
        let t = k / 100
        func clamp(_ v: Double) -> Double { min(max(v, 0), 255) }
        let r = t <= 66 ? 255 : clamp(329.698727446 * pow(t - 60, -0.1332047592))
        let g = clamp(t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492))
        let b: Double
        if t >= 66 { b = 255 } else if t <= 19 { b = 0 } else { b = clamp(138.5177312231 * log(t - 10) - 305.0447927307) }
        return (r, g, b)
    }

    /// Kelvin -> RGB (rounded).
    public static func kelvinToRGB(_ kelvin: Int) -> RGB {
        let c = kelvinToRGBComponents(Double(kelvin))
        return RGB(clamping: c.r, c.g, c.b)
    }

    /// Kelvin -> HS via Helland RGB (HA `color_temperature_to_hs`).
    public static func kelvinToHS(_ kelvin: Int) -> HS {
        let c = kelvinToRGBComponents(Double(kelvin))
        let maxc = max(c.r, c.g, c.b)
        guard maxc > 0 else { return HS(h: 0, s: 0) }
        // HSV from unrounded components for accuracy.
        let hsv = rgbToHSV(RGB(clamping: c.r, c.g, c.b))
        return HS(h: hsv.h, s: hsv.s)
    }

    /// Kelvin -> xy on the Planckian locus (Kim et al. cubic spline, 1667...25000 K).
    public static func kelvinToXY(_ kelvin: Int) -> XY {
        let t = min(max(Double(kelvin), 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return XY(x: x, y: y)
    }

    /// xy -> correlated colour temperature, McCamy's approximation (HA `color_xy_to_temperature`).
    /// Good between ~2000 K and 10000 K.
    public static func xyToKelvin(_ xy: XY) -> Int {
        let n = (xy.x - 0.3320) / (0.1858 - xy.y)
        let cct = 437 * pow(n, 3) + 3601 * pow(n, 2) + 6861 * n + 5517
        guard cct.isFinite else { return 0 }
        return Int(cct)
    }

    // MARK: White channels

    /// Scale `output` so its max equals the max of `input` (HA `match_max_scale`).
    static func matchMaxScale(_ input: [Double], _ output: [Double]) -> [UInt8] {
        let maxIn = input.max() ?? 0
        let maxOut = output.max() ?? 0
        let factor = maxOut == 0 ? 0 : maxIn / maxOut
        return output.map { UInt8(clampingChannel: ($0 * factor).rounded()) }
    }

    /// RGB -> RGBW: white = min channel, then rescale to keep the input's peak (HA `color_rgb_to_rgbw`).
    public static func rgbToRGBW(_ rgb: RGB) -> RGBW {
        let r = Double(rgb.r), g = Double(rgb.g), b = Double(rgb.b)
        let w = min(r, g, b)
        let out = matchMaxScale([r, g, b], [r - w, g - w, b - w, w])
        return RGBW(r: out[0], g: out[1], b: out[2], w: out[3])
    }

    /// RGBW -> RGB (HA `color_rgbw_to_rgb`).
    public static func rgbwToRGB(_ v: RGBW) -> RGB {
        let r = Double(v.r), g = Double(v.g), b = Double(v.b), w = Double(v.w)
        let out = matchMaxScale([r, g, b, w], [r + w, g + w, b + w])
        return RGB(r: out[0], g: out[1], b: out[2])
    }

    /// RGB -> RGBWW using the mid-range white mix of the light (HA `color_rgb_to_rgbww`).
    public static func rgbToRGBWW(_ rgb: RGB, minKelvin: Int, maxKelvin: Int) -> RGBWW {
        let maxMireds = Double(kelvinToMired(minKelvin))
        let minMireds = Double(kelvinToMired(maxKelvin))
        let mid = minMireds + (maxMireds - minMireds) / 2
        let midKelvin = mid > 0 ? (1_000_000 / mid).rounded(.down) : 0
        let w = kelvinToRGBComponents(midKelvin)
        let r = Double(rgb.r), g = Double(rgb.g), b = Double(rgb.b)
        let level = min(w.r > 0 ? r / w.r : 0, w.g > 0 ? g / w.g : 0, w.b > 0 ? b / w.b : 0)
        let white = (level * 255).rounded()
        let out = matchMaxScale([r, g, b], [r - w.r * level, g - w.g * level, b - w.b * level, white, white])
        return RGBWW(r: out[0], g: out[1], b: out[2], cw: out[3], ww: out[4])
    }

    /// RGBWW -> RGB (HA `color_rgbww_to_rgb`).
    public static func rgbwwToRGB(_ v: RGBWW, minKelvin: Int, maxKelvin: Int) -> RGB {
        let maxMireds = Double(kelvinToMired(minKelvin))
        let minMireds = Double(kelvinToMired(maxKelvin))
        let cw = Double(v.cw), ww = Double(v.ww)
        let ratio = cw + ww > 0 ? ww / (cw + ww) : 0.5
        let mired = minMireds + ratio * (maxMireds - minMireds)
        let kelvin = mired > 0 ? (1_000_000 / mired).rounded(.down) : 0
        let w = kelvinToRGBComponents(kelvin)
        let level = max(cw, ww) / 255
        let r = Double(v.r), g = Double(v.g), b = Double(v.b)
        let out = matchMaxScale([r, g, b, cw, ww], [r + w.r * level, g + w.g * level, b + w.b * level])
        return RGB(r: out[0], g: out[1], b: out[2])
    }

    /// Kelvin + brightness (0...255) -> cold/warm channels (HA `color_temperature_to_rgbww`).
    public static func kelvinToRGBWW(_ kelvin: Int, brightness: Int, minKelvin: Int, maxKelvin: Int) -> RGBWW {
        let maxMireds = Double(kelvinToMired(minKelvin))
        let minMireds = Double(kelvinToMired(maxKelvin))
        let temp = Double(kelvinToMired(min(max(kelvin, minKelvin), maxKelvin)))
        let bri = Double(min(max(brightness, 0), 255))
        let range = maxMireds - minMireds
        guard range != 0 else { return RGBWW(r: 0, g: 0, b: 0, cw: 0, ww: UInt8(bri)) }
        let cold = ((maxMireds - temp) / range) * bri
        let warm = bri - cold
        return RGBWW(r: 0, g: 0, b: 0, cw: UInt8(clampingChannel: cold), ww: UInt8(clampingChannel: warm))
    }

    /// Cold/warm channels -> (Kelvin, brightness 0...255) (HA `rgbww_to_color_temperature`).
    public static func rgbwwToKelvin(_ v: RGBWW, minKelvin: Int, maxKelvin: Int) -> (kelvin: Int, brightness: Int) {
        let maxMireds = Double(kelvinToMired(minKelvin))
        let minMireds = Double(kelvinToMired(maxKelvin))
        let cold = Double(v.cw), warm = Double(v.ww)
        let bri = warm / 255 + cold / 255
        guard bri > 0 else { return (minKelvin, 0) }
        let mired = (cold / 255 / bri) * (minMireds - maxMireds) + maxMireds
        let kelvin = (1_000_000 / mired).rounded(.down)
        return (Int(kelvin.rounded()), min(255, Int((bri * 255).rounded())))
    }

    // MARK: Brightness scaling

    /// Linear map between ranges, unclamped.
    public static func scale(_ value: Double, from source: ClosedRange<Double>, to target: ClosedRange<Double>) -> Double {
        let span = source.upperBound - source.lowerBound
        guard span != 0 else { return target.lowerBound }
        return target.lowerBound + (value - source.lowerBound) / span * (target.upperBound - target.lowerBound)
    }

    /// Brightness `0...1` -> device integer in `range` (e.g. WiZ 10...100, Hue 1...100, 1...254),
    /// using HA's `brightness_to_value` stepping: any positive brightness maps to at least
    /// `range.lowerBound`, and 1.0 maps to `range.upperBound`. 0 maps to `range.lowerBound`
    /// (send "off" separately).
    public static func deviceValue(forBrightness brightness: Double, in range: ClosedRange<Int>) -> Int {
        let b = brightness.isFinite ? min(max(brightness, 0), 1) : 0
        let states = Double(range.upperBound - range.lowerBound + 1)
        let v = Double(range.lowerBound - 1) + b * states
        // Small epsilon so exact steps (e.g. from `brightness(fromDeviceValue:)`) do not round up.
        return min(max(Int((v - 1e-9).rounded(.up)), range.lowerBound), range.upperBound)
    }

    /// Device integer in `range` -> brightness `0...1` (inverse of `deviceValue`).
    public static func brightness(fromDeviceValue value: Int, in range: ClosedRange<Int>) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let states = Double(range.upperBound - range.lowerBound + 1)
        return Double(clamped - (range.lowerBound - 1)) / states
    }

    /// Brightness `0...1` -> 0...255.
    public static func brightness255(_ brightness: Double) -> Int {
        Int(UInt8(clampingChannel: (brightness.isFinite ? brightness : 0) * 255))
    }

    /// 0...255 -> brightness `0...1`.
    public static func brightness(from255 value: Int) -> Double {
        Double(min(max(value, 0), 255)) / 255
    }

    /// Scale an RGB colour by brightness (for protocols without a separate dimmer).
    public static func scaled(_ rgb: RGB, by brightness: Double) -> RGB {
        let b = brightness.isFinite ? min(max(brightness, 0), 1) : 0
        return RGB(clamping: Double(rgb.r) * b, Double(rgb.g) * b, Double(rgb.b) * b)
    }

    // MARK: Hex

    /// "#rrggbb" or "rrggbb" -> RGB.
    public static func rgb(hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    /// RGB -> "#rrggbb".
    public static func hex(_ rgb: RGB) -> String {
        let digits = Array("0123456789abcdef")
        var out = "#"
        for c in [rgb.r, rgb.g, rgb.b] {
            out.append(digits[Int(c >> 4)])
            out.append(digits[Int(c & 0xF)])
        }
        return out
    }
}
