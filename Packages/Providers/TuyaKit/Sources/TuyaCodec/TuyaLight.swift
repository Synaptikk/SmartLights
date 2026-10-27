import Foundation
import LightCore

public enum TuyaDPS {
    /// dps named in device22 queries for lights (legacy 1-5 and v2 20-25).
    public static let lightQuery = ["1", "2", "3", "4", "5", "20", "21", "22", "23", "24", "25"]
    /// `work_mode` values.
    public static let modeWhite = "white"
    public static let modeColour = "colour"
    public static let modeScene = "scene"
    public static let modeMusic = "music"
}

/// tinytuya `BulbDevice` types.
public enum TuyaBulbType: String, Sendable, Codable, CaseIterable {
    /// dps 20 switch_led, 21 work_mode, 22 bright_value_v2 (10-1000), 23 temp_value_v2 (0-1000),
    /// 24 colour_data_v2 (`hhhhssssvvvv`, h 0-360, s/v 0-1000), 25 scene_data_v2.
    case b = "B"
    /// dps 1 switch, 2 mode, 3 brightness (25-255), 4 colour temp (0-255), 5 colour (`rrggbbhhhhssvv`).
    case a = "A"
    /// dps 1 switch, 2 brightness (25-255), 3 colour temp (0-255): dimmable/CCT filament bulbs.
    case c = "C"
    /// Has both 1 and 20 (probably not a bulb) or nothing recognisable: switch only.
    case switchOnly = "None"
}

public enum TuyaColourFormat: String, Sendable, Codable {
    /// `hhhhssssvvvv`: h 0-360, s/v 0-1000 (type B).
    case hsv16
    /// `rrggbbhhhhssvv`: rgb 0-255, h 0-360, s/v 0-255 (type A).
    case rgb8
}

/// Which dp holds what (tinytuya `DEFAULT_DPSET` + `detect_bulb`).
public struct TuyaDPSet: Sendable, Codable, Equatable {
    public var type: TuyaBulbType
    public var switchDP: String
    public var modeDP: String?
    public var brightnessDP: String?
    public var colourTempDP: String?
    public var colourDP: String?
    public var sceneDP: String?
    /// Brightness value range (`value_min...value_max`); colour temperature uses `0...valueMax`.
    public var valueMin: Int
    public var valueMax: Int
    public var colourFormat: TuyaColourFormat

    public init(type: TuyaBulbType, switchDP: String, modeDP: String? = nil, brightnessDP: String? = nil,
                colourTempDP: String? = nil, colourDP: String? = nil, sceneDP: String? = nil,
                valueMin: Int, valueMax: Int, colourFormat: TuyaColourFormat) {
        self.type = type
        self.switchDP = switchDP
        self.modeDP = modeDP
        self.brightnessDP = brightnessDP
        self.colourTempDP = colourTempDP
        self.colourDP = colourDP
        self.sceneDP = sceneDP
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.colourFormat = colourFormat
    }

    public static func defaults(for type: TuyaBulbType) -> TuyaDPSet {
        switch type {
        case .b: TuyaDPSet(type: .b, switchDP: "20", modeDP: "21", brightnessDP: "22", colourTempDP: "23", colourDP: "24",
                           sceneDP: "25", valueMin: 10, valueMax: 1000, colourFormat: .hsv16)
        case .a: TuyaDPSet(type: .a, switchDP: "1", modeDP: "2", brightnessDP: "3", colourTempDP: "4", colourDP: "5",
                           sceneDP: "6", valueMin: 25, valueMax: 255, colourFormat: .rgb8)
        case .c: TuyaDPSet(type: .c, switchDP: "1", brightnessDP: "2", colourTempDP: "3", valueMin: 25, valueMax: 255,
                           colourFormat: .rgb8)
        case .switchOnly: TuyaDPSet(type: .switchOnly, switchDP: "1", valueMin: 0, valueMax: 255, colourFormat: .rgb8)
        }
    }

    /// `detect_bulb`: B if 20+21, A/C if 1+2 (dp 2 a string -> A), otherwise switch-only. Optional dps are
    /// kept only when the device reported them (a soft-white bulb has 20/21/22 but no 23/24).
    public static func detect(from dps: [String: TuyaJSON]) -> TuyaDPSet {
        let type: TuyaBulbType
        if dps["20"] != nil && dps["1"] != nil {
            type = .switchOnly
        } else if dps["20"] != nil && dps["21"] != nil {
            type = .b
        } else if dps["1"] != nil, let two = dps["2"] {
            type = two.stringValue != nil ? .a : .c
        } else {
            type = .switchOnly
        }
        var set = defaults(for: type)
        if type == .switchOnly {
            set.switchDP = dps["20"] != nil && dps["1"] == nil ? "20" : "1"
            return set
        }
        func present(_ dp: String?) -> String? { dp.flatMap { dps[$0] != nil ? $0 : nil } }
        set.modeDP = present(set.modeDP)
        set.brightnessDP = present(set.brightnessDP)
        set.colourTempDP = present(set.colourTempDP)
        set.colourDP = present(set.colourDP)
        set.sceneDP = present(set.sceneDP)
        return set
    }

    public var hasColour: Bool { colourDP != nil && (modeDP != nil || type == .a) }
    public var hasColourTemp: Bool { colourTempDP != nil }
    public var hasBrightness: Bool { brightnessDP != nil }
}

/// Colour strings (tinytuya `BulbDevice.rgb_to_hexvalue` / `hsv_to_hexvalue` / `hexvalue_to_*`).
public enum TuyaColour {
    /// `rgb_to_hexvalue(r, g, b, hexformat)`.
    public static func hex(r: Int, g: Int, b: Int, format: TuyaColourFormat) -> String {
        let (h, s, v) = rgbToHSV(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        switch format {
        case .rgb8:
            return String(format: "%02x%02x%02x%04x%02x%02x", r, g, b, Int(h * 360), Int(s * 255), Int(v * 255))
        case .hsv16:
            return String(format: "%04x%04x%04x", Int(h * 360), Int(s * 1000), Int(v * 1000))
        }
    }

    /// `hsv_to_hexvalue(h, s, v, "hsv16")` with h, s, v in `0...1`.
    public static func hsv16(h: Double, s: Double, v: Double) -> String {
        String(format: "%04x%04x%04x", Int(clamp01(h) * 360), Int(clamp01(s) * 1000), Int(clamp01(v) * 1000))
    }

    /// Colour string for hue (degrees), saturation and value (`0...1`).
    public static func hex(hue: Double, saturation: Double, value: Double, format: TuyaColourFormat) -> String {
        let h = (hue.isFinite ? hue : 0).truncatingRemainder(dividingBy: 360)
        let hue01 = (h < 0 ? h + 360 : h) / 360
        switch format {
        case .hsv16:
            return String(format: "%04x%04x%04x", Int((hue01 * 360).rounded()), Int((clamp01(saturation) * 1000).rounded()),
                          Int((clamp01(value) * 1000).rounded()))
        case .rgb8:
            let (r, g, b) = hsvToRGB(hue01, clamp01(saturation), clamp01(value))
            let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
            return String(format: "%02x%02x%02x%04x%02x%02x", ri, gi, bi, Int((hue01 * 360).rounded()),
                          Int((clamp01(saturation) * 255).rounded()), Int((clamp01(value) * 255).rounded()))
        }
    }

    /// `hexvalue_to_hsv` (format auto-detected from the length when nil): h, s, v in `0...1`.
    public static func hsv(fromHex hex: String, format: TuyaColourFormat? = nil) -> (h: Double, s: Double, v: Double)? {
        let chars = Array(hex)
        guard let fmt = format ?? detectFormat(chars.count) else { return nil }
        func field(_ a: Int, _ b: Int) -> Int? { b <= chars.count ? Int(String(chars[a..<b]), radix: 16) : nil }
        switch fmt {
        case .hsv16:
            guard let h = field(0, 4), let s = field(4, 8), let v = field(8, 12) else { return nil }
            return (Double(h) / 360, Double(s) / 1000, Double(v) / 1000)
        case .rgb8:
            if chars.count < 14 {
                guard let r = field(0, 2), let g = field(2, 4), let b = field(4, 6) else { return nil }
                return rgbToHSV(Double(r) / 255, Double(g) / 255, Double(b) / 255)
            }
            guard let h = field(6, 10), let s = field(10, 12), let v = field(12, 14) else { return nil }
            return (Double(h) / 360, Double(s) / 255, Double(v) / 255)
        }
    }

    /// `hexvalue_to_rgb`.
    public static func rgb(fromHex hex: String, format: TuyaColourFormat? = nil) -> (r: Int, g: Int, b: Int)? {
        let chars = Array(hex)
        guard let fmt = format ?? detectFormat(chars.count) else { return nil }
        func field(_ a: Int, _ b: Int) -> Int? { b <= chars.count ? Int(String(chars[a..<b]), radix: 16) : nil }
        switch fmt {
        case .rgb8:
            guard let r = field(0, 2), let g = field(2, 4), let b = field(4, 6) else { return nil }
            return (r, g, b)
        case .hsv16:
            guard let (h, s, v) = hsv(fromHex: hex, format: .hsv16) else { return nil }
            let (r, g, b) = hsvToRGB(h, s, v)
            return (Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }

    static func detectFormat(_ count: Int) -> TuyaColourFormat? {
        switch count {
        case 6, 14: .rgb8
        case 12: .hsv16
        default: nil
        }
    }

    /// Python `colorsys.rgb_to_hsv`.
    public static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        let v = maxc
        guard minc != maxc else { return (0, 0, v) }
        let range = maxc - minc
        let s = range / maxc
        let rc = (maxc - r) / range, gc = (maxc - g) / range, bc = (maxc - b) / range
        var h: Double
        if r == maxc {
            h = bc - gc
        } else if g == maxc {
            h = 2 + rc - bc
        } else {
            h = 4 + gc - rc
        }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, s, v)
    }

    /// Python `colorsys.hsv_to_rgb`.
    public static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        guard s != 0 else { return (v, v, v) }
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch ((i % 6) + 6) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func clamp01(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 1) : 0 }
}

/// Last known dps of one light and their mapping to the LightCore model.
public struct TuyaLightModel: Sendable, Equatable {
    public var dpset: TuyaDPSet
    /// Colour temperature range the 0...max temp value is spread over (Tuya does not report it;
    /// 2700-6500 K is the common white-label range, as in HA localtuya).
    public var minKelvin: Int
    public var maxKelvin: Int
    public private(set) var dps: [String: TuyaJSON]

    public static let defaultKelvinRange = 2700...6500

    public init(dpset: TuyaDPSet, dps: [String: TuyaJSON] = [:], kelvinRange: ClosedRange<Int> = TuyaLightModel.defaultKelvinRange) {
        self.dpset = dpset
        self.dps = dps
        minKelvin = kelvinRange.lowerBound
        maxKelvin = kelvinRange.upperBound
    }

    /// Merges a status push or query result.
    public mutating func apply(_ update: [String: TuyaJSON]) {
        dps.merge(update) { _, new in new }
    }

    public var capabilities: LightCapabilities {
        var modes: Set<ColorMode> = []
        if dpset.hasColour { modes.insert(.hs) }
        if dpset.hasColourTemp { modes.insert(.colorTemp) }
        if modes.isEmpty { modes.insert(dpset.hasBrightness ? .brightness : .onOff) }
        return LightCapabilities(supportedColorModes: modes,
                                 minKelvin: dpset.hasColourTemp ? minKelvin : nil,
                                 maxKelvin: dpset.hasColourTemp ? maxKelvin : nil)
    }

    var brightnessRange: ClosedRange<Int> { dpset.valueMin...dpset.valueMax }
    /// Value range of the colour string's V component.
    var colourValueRange: ClosedRange<Int> { dpset.colourFormat == .hsv16 ? 10...1000 : 1...255 }

    /// Current `work_mode` ("white" when the bulb has no mode dp).
    public var mode: String {
        if let dp = dpset.modeDP, let m = dps[dp]?.stringValue { return m }
        return TuyaDPS.modeWhite
    }

    var colourHSV: (h: Double, s: Double, v: Double)? {
        guard let dp = dpset.colourDP, let hex = dps[dp]?.stringValue else { return nil }
        return TuyaColour.hsv(fromHex: hex, format: dpset.colourFormat)
    }

    public func lightState(reachable: Bool, at date: Date = Date()) -> LightState {
        var state = LightState(isOn: dps[dpset.switchDP]?.boolValue ?? false, reachable: reachable, updatedAt: date)
        let mode = self.mode
        if mode == TuyaDPS.modeColour, dpset.hasColour, let hsv = colourHSV {
            state.colorMode = .hs
            state.hs = HS(h: min(max(hsv.h * 360, 0), 360).truncatingRemainder(dividingBy: 360), s: min(max(hsv.s, 0), 1))
            state.brightness = ColorMath.brightness(fromDeviceValue: Int((hsv.v * Double(colourValueRange.upperBound)).rounded()),
                                                    in: colourValueRange)
            return state
        }
        if let dp = dpset.brightnessDP, let value = dps[dp]?.intValue {
            state.brightness = ColorMath.brightness(fromDeviceValue: value, in: brightnessRange)
        }
        if mode == TuyaDPS.modeWhite || dpset.modeDP == nil {
            if let dp = dpset.colourTempDP, let value = dps[dp]?.intValue {
                state.colorMode = .colorTemp
                state.kelvin = kelvin(fromTemp: value)
            } else {
                state.colorMode = dpset.hasBrightness ? .brightness : .onOff
            }
        } else {
            // scene / music / scene_N: a vendor effect is running.
            state.effect = mode
            state.colorMode = dpset.hasBrightness ? .brightness : .onOff
        }
        return state
    }

    public func kelvin(fromTemp value: Int) -> Int {
        let maxValue = Double(dpset.valueMax)
        let t = min(max(Double(value), 0), maxValue) / maxValue
        return Int((Double(minKelvin) + t * Double(maxKelvin - minKelvin)).rounded())
    }

    public func temp(fromKelvin kelvin: Int) -> Int {
        guard maxKelvin > minKelvin else { return 0 }
        let t = (Double(min(max(kelvin, minKelvin), maxKelvin) - minKelvin)) / Double(maxKelvin - minKelvin)
        return Int((t * Double(dpset.valueMax)).rounded())
    }

    /// The dps to send for `command` (normalised to this light's capabilities first). Brightness and colour
    /// go in one `CONTROL` so the bulb does not flash. Brightness 0 turns the light off.
    public func dps(for command: LightCommand) -> [String: TuyaJSON] {
        let cmd = command.normalized(for: capabilities)
        var out: [String: TuyaJSON] = [:]
        if let on = cmd.on { out[dpset.switchDP] = .bool(on) }
        var brightness = cmd.brightness
        if let b = brightness {
            if b <= 0 {
                if cmd.on != true { out[dpset.switchDP] = .bool(false) }
                brightness = nil
            } else if cmd.on == nil {
                out[dpset.switchDP] = .bool(true)
            }
        }
        switch cmd.color {
        case .kelvin(let k)?:
            if let mode = dpset.modeDP { out[mode] = .string(TuyaDPS.modeWhite) }
            if let dp = dpset.colourTempDP { out[dp] = .int(temp(fromKelvin: k)) }
            if let b = brightness, let dp = dpset.brightnessDP {
                out[dp] = .int(ColorMath.deviceValue(forBrightness: b, in: brightnessRange))
            }
        case .hs(let hs)?:
            guard let dp = dpset.colourDP else { break }
            if let mode = dpset.modeDP { out[mode] = .string(TuyaDPS.modeColour) }
            let v = brightness ?? currentColourBrightness
            out[dp] = .string(colourString(hue: hs.h, saturation: hs.s, brightness: v))
        default:
            guard let b = brightness else { break }
            if mode == TuyaDPS.modeColour, let dp = dpset.colourDP, let hsv = colourHSV {
                out[dp] = .string(colourString(hue: hsv.h * 360, saturation: hsv.s, brightness: b))
            } else if let dp = dpset.brightnessDP {
                out[dp] = .int(ColorMath.deviceValue(forBrightness: b, in: brightnessRange))
            }
        }
        return out
    }

    /// Brightness to keep when only the colour changes: the current colour V, else the white brightness.
    private var currentColourBrightness: Double {
        if mode == TuyaDPS.modeColour, let hsv = colourHSV, hsv.v > 0 { return hsv.v }
        if let dp = dpset.brightnessDP, let value = dps[dp]?.intValue {
            return ColorMath.brightness(fromDeviceValue: value, in: brightnessRange)
        }
        return 1
    }

    private func colourString(hue: Double, saturation: Double, brightness: Double) -> String {
        let range = colourValueRange
        let v = Double(ColorMath.deviceValue(forBrightness: brightness, in: range)) / Double(range.upperBound)
        return TuyaColour.hex(hue: hue, saturation: saturation, value: v, format: dpset.colourFormat)
    }
}
