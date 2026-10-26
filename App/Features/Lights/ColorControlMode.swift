import Foundation
import LightCore

/// The colour controls offered in the light detail view.
enum ColorControlMode: String, CaseIterable, Identifiable {
    case white
    case temperature
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "White"
        case .temperature: "Temperature"
        case .color: "Colour"
        }
    }
}

/// Transition durations offered by the detail view (only for lights that support transitions).
enum TransitionOption: String, CaseIterable, Identifiable {
    case providerDefault
    case instant
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault: "Default"
        case .instant: "Instant"
        case .short: "0.4 s"
        case .medium: "1 s"
        case .long: "3 s"
        }
    }

    var duration: Duration? {
        switch self {
        case .providerDefault: nil
        case .instant: .zero
        case .short: .milliseconds(400)
        case .medium: .seconds(1)
        case .long: .seconds(3)
        }
    }
}

extension LightCapabilities {
    /// Colour controls this light supports, in display order.
    var colorControlModes: [ColorControlMode] {
        var modes: [ColorControlMode] = []
        let hasWhiteChannel = supportedColorModes.contains(.white)
            || supportedColorModes.contains(.rgbw)
            || supportedColorModes.contains(.rgbww)
        if hasWhiteChannel && !supportsColorTemp { modes.append(.white) }
        if supportsColorTemp { modes.append(.temperature) }
        if supportsColor { modes.append(.color) }
        return modes
    }

    /// The colour attribute for "plain white" on a light without a temperature control.
    var plainWhite: ColorAttribute {
        if supportedColorModes.contains(.rgbw) { return .rgbw(RGBW(r: 0, g: 0, b: 0, w: 255)) }
        if supportedColorModes.contains(.rgbww) { return .rgbww(RGBWW(r: 0, g: 0, b: 0, cw: 255, ww: 255)) }
        if supportsColorTemp { return .kelvin(clampKelvin(4000)) }
        return .rgb(.white)
    }
}

extension Light {
    /// The control mode matching the light's current state.
    var currentControlMode: ColorControlMode? {
        let available = capabilities.colorControlModes
        let mode: ColorControlMode?
        switch state.colorMode {
        case .colorTemp: mode = .temperature
        case .white: mode = .white
        case .rgbw where state.rgbw.map({ $0.r == 0 && $0.g == 0 && $0.b == 0 }) == true: mode = .white
        case .some(let m) where m.isColor: mode = .color
        default: mode = nil
        }
        if let mode, available.contains(mode) { return mode }
        return available.first
    }
}
