import SwiftUI
import LightCore

extension Brand {
    /// Compact name for badges. Text only: no vendor logos (Hue terms).
    var shortName: String {
        switch self {
        case .hue: "Hue"
        case .wiz: "WiZ"
        case .aidot: "AiDot"
        case .appleHome: "Home"
        case .tplink: "TP-Link"
        case .tuya: "Tuya"
        case .homeAssistant: "HA"
        case .dirigera: "IKEA"
        default: displayName
        }
    }
}

extension RGB {
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension HS {
    var color: Color {
        Color(hue: clamped.h / 360, saturation: clamped.s, brightness: 1)
    }
}

extension Light {
    /// Badge text: the brand, or the accessory maker for Apple Home lights.
    var badgeText: String {
        if brand == .appleHome, let manufacturer, !manufacturer.isEmpty { return manufacturer }
        return brand.shortName
    }

    var brightnessPercent: Int {
        Int(((state.brightness ?? 1) * 100).rounded())
    }

    /// The colour the light is showing (full value), or a neutral warm white.
    var displayRGB: RGB {
        let s = state
        let range = capabilities.kelvinRange
        switch s.colorMode {
        case .hs: if let hs = s.hs { return ColorMath.hsToRGB(hs) }
        case .rgb: if let rgb = s.rgb { return rgb }
        case .rgbw: if let v = s.rgbw { return ColorMath.rgbwToRGB(v) }
        case .rgbww: if let v = s.rgbww { return ColorMath.rgbwwToRGB(v, minKelvin: range.lowerBound, maxKelvin: range.upperBound) }
        case .xy: if let xy = s.xy { return ColorMath.xyToRGB(xy, gamut: capabilities.gamut) }
        case .colorTemp: if let k = s.kelvin { return ColorMath.kelvinToRGB(k) }
        default: break
        }
        return ColorMath.kelvinToRGB(2700)
    }

    var displayColor: Color { displayRGB.color }

    /// Current colour as hue/saturation for the colour wheel.
    var currentHS: HS {
        let s = state
        if let hs = s.hs { return hs.clamped }
        if let xy = s.xy { return ColorMath.xyToHS(xy, gamut: capabilities.gamut) }
        return ColorMath.rgbToHS(displayRGB)
    }

    /// Short state summary for rows and VoiceOver ("On, 60%", "Off", "Not responding").
    var stateSummary: String {
        guard state.reachable else { return "Not responding" }
        guard state.isOn else { return "Off" }
        guard capabilities.supportsBrightness else { return "On" }
        return "On, \(brightnessPercent)%"
    }
}
