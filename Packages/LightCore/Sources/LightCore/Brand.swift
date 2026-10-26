import Foundation

/// Every lighting ecosystem SmartLights can talk to.
///
/// The raw value is the stable, lowercase prefix used in `LightID` strings
/// (`"wiz:a8bb5006033d"`), in persisted data and in Keychain service names.
/// Never change an existing raw value.
public enum Brand: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case hue
    case wiz
    case aidot
    /// Any accessory reached through Apple's HomeKit framework (incl. Matter).
    /// The accessory manufacturer is carried in `Light.manufacturer`.
    case appleHome = "applehome"
    case lifx
    case nanoleaf
    case govee
    case yeelight
    case elgato
    case shelly
    case wled
    case magicHome = "magichome"
    case tplink
    case tuya
    case meross
    case switchbot
    case twinkly
    case dirigera
    case homeAssistant = "homeassistant"

    /// Name shown in the UI ("Philips Hue", "WiZ", ...).
    public var displayName: String {
        switch self {
        case .hue: "Philips Hue"
        case .wiz: "WiZ"
        case .aidot: "AiDot / Linkind"
        case .appleHome: "Apple Home"
        case .lifx: "LIFX"
        case .nanoleaf: "Nanoleaf"
        case .govee: "Govee"
        case .yeelight: "Yeelight"
        case .elgato: "Elgato"
        case .shelly: "Shelly"
        case .wled: "WLED"
        case .magicHome: "Magic Home"
        case .tplink: "TP-Link Kasa / Tapo"
        case .tuya: "Tuya / Smart Life"
        case .meross: "Meross"
        case .switchbot: "SwitchBot"
        case .twinkly: "Twinkly"
        case .dirigera: "IKEA Dirigera"
        case .homeAssistant: "Home Assistant"
        }
    }

    /// Company / project behind the ecosystem. For `.appleHome` this is the
    /// platform vendor; the accessory maker lives in `Light.manufacturer`.
    public var vendor: String {
        switch self {
        case .hue: "Signify"
        case .wiz: "WiZ Connected (Signify)"
        case .aidot: "Linkind (AiDot)"
        case .appleHome: "Apple"
        case .lifx: "LIFX (Feit Electric)"
        case .nanoleaf: "Nanoleaf"
        case .govee: "Govee"
        case .yeelight: "Yeelight"
        case .elgato: "Elgato (Corsair)"
        case .shelly: "Shelly Group"
        case .wled: "WLED project"
        case .magicHome: "Zengge (Magic Home)"
        case .tplink: "TP-Link"
        case .tuya: "Tuya"
        case .meross: "Meross"
        case .switchbot: "SwitchBot (Wonderlabs)"
        case .twinkly: "Twinkly (LEDWORKS)"
        case .dirigera: "IKEA"
        case .homeAssistant: "Home Assistant"
        }
    }

    /// Sorts by display name (for brand pickers).
    public static func < (lhs: Brand, rhs: Brand) -> Bool {
        lhs.displayName.lowercased() < rhs.displayName.lowercased()
    }
}
