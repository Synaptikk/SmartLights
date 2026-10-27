import Foundation

/// Paths of the Elgato local HTTP API (port 9123, no authentication).
/// Sources: python-elgato (https://github.com/frenck/python-elgato), HA `elgato` integration.
public enum ElgatoAPI {
    public static let defaultPort: UInt16 = 9123
    /// `GET` -> `ElgatoLightsDocument`; `PUT` an `ElgatoLightsDocument` with only the fields to change.
    public static let lights = "/elgato/lights"
    /// `GET` -> `ElgatoAccessoryInfo`.
    public static let accessoryInfo = "/elgato/accessory-info"
    /// `GET` -> `ElgatoSettings` (power-on defaults, fade durations).
    public static let settings = "/elgato/lights/settings"
    /// `POST` (empty body): the light blinks a few times.
    public static let identify = "/elgato/identify"
}

/// `/elgato/lights` body: `{"numberOfLights":1,"lights":[{"on":1,"brightness":21,"temperature":297}]}`.
/// Light Strips in colour mode report `hue`/`saturation` instead of `temperature`.
public struct ElgatoLightsDocument: Codable, Sendable, Equatable {
    public var numberOfLights: Int
    public var lights: [ElgatoLightState]

    public init(lights: [ElgatoLightState]) {
        self.numberOfLights = lights.count
        self.lights = lights
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lights = try c.decode([ElgatoLightState].self, forKey: .lights)
        numberOfLights = try c.decodeIfPresent(Int.self, forKey: .numberOfLights) ?? lights.count
    }

    public static func decode(_ data: Data) throws -> ElgatoLightsDocument {
        try JSONDecoder().decode(ElgatoLightsDocument.self, from: data)
    }

    /// Compact JSON with sorted keys (stable for tests and logs).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// One light entry. Every field is optional so the same type serves as a partial `PUT` body
/// (unset fields are omitted from the JSON and left unchanged by the light).
public struct ElgatoLightState: Codable, Sendable, Equatable {
    /// `1` on, `0` off.
    public var on: Int?
    /// `0...100` (percent).
    public var brightness: Int?
    /// Colour temperature in mireds, `143...344` (about 7000 K ... 2900 K).
    public var temperature: Int?
    /// Light Strip colour mode: hue in degrees `0...360`.
    public var hue: Double?
    /// Light Strip colour mode: saturation `0...100`.
    public var saturation: Double?

    public init(on: Int? = nil, brightness: Int? = nil, temperature: Int? = nil, hue: Double? = nil, saturation: Double? = nil) {
        self.on = on
        self.brightness = brightness
        self.temperature = temperature
        self.hue = hue
        self.saturation = saturation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Firmware sends `on` as 0/1; accept a JSON bool as well.
        if let i = try? c.decodeIfPresent(Int.self, forKey: .on) {
            on = i
        } else if let b = try? c.decodeIfPresent(Bool.self, forKey: .on) {
            on = b ? 1 : 0
        }
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness).map { Int($0.rounded()) }
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature).map { Int($0.rounded()) }
        hue = try c.decodeIfPresent(Double.self, forKey: .hue)
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation)
    }

    public var isOn: Bool { (on ?? 0) != 0 }

    /// True when no field is set (nothing to `PUT`).
    public var isEmpty: Bool { on == nil && brightness == nil && temperature == nil && hue == nil && saturation == nil }

    /// Overlays the fields set in `change` (a partial `PUT`) on this state. Setting a colour
    /// temperature leaves colour mode (hue/saturation cleared) and vice versa, as the Light Strip does.
    public func merging(_ change: ElgatoLightState) -> ElgatoLightState {
        var out = self
        if let v = change.on { out.on = v }
        if let v = change.brightness { out.brightness = v }
        if let v = change.temperature {
            out.temperature = v
            if change.hue == nil { out.hue = nil; out.saturation = nil }
        }
        if let v = change.hue { out.hue = v; if change.temperature == nil { out.temperature = nil } }
        if let v = change.saturation { out.saturation = v }
        return out
    }
}

/// `/elgato/accessory-info`.
public struct ElgatoAccessoryInfo: Codable, Sendable, Equatable {
    public struct WiFiInfo: Codable, Sendable, Equatable {
        public var ssid: String?
        public var frequencyMHz: Int?
        public var rssi: Int?
    }

    /// "Elgato Key Light", "Elgato Key Light Air", "Elgato Light Strip", ...
    public var productName: String
    public var hardwareBoardType: Int?
    public var hardwareRevision: String?
    public var firmwareBuildNumber: Int?
    public var firmwareVersion: String?
    /// Stable identifier used as the SmartLights id (HA uses it as the unique id too).
    public var serialNumber: String
    /// Name given in Elgato Control Center (may be empty).
    public var displayName: String?
    public var features: [String]?
    /// Present on newer firmware ("3C:6A:9D:14:D0:F5").
    public var macAddress: String?
    public var wifiInfo: WiFiInfo?

    enum CodingKeys: String, CodingKey {
        case productName, hardwareBoardType, hardwareRevision, firmwareBuildNumber, firmwareVersion
        case serialNumber, displayName, features, macAddress
        case wifiInfo = "wifi-info"
    }

    public init(
        productName: String, serialNumber: String, displayName: String? = nil, firmwareVersion: String? = nil,
        firmwareBuildNumber: Int? = nil, hardwareBoardType: Int? = nil, hardwareRevision: String? = nil,
        features: [String]? = nil, macAddress: String? = nil, wifiInfo: WiFiInfo? = nil
    ) {
        self.productName = productName
        self.serialNumber = serialNumber
        self.displayName = displayName
        self.firmwareVersion = firmwareVersion
        self.firmwareBuildNumber = firmwareBuildNumber
        self.hardwareBoardType = hardwareBoardType
        self.hardwareRevision = hardwareRevision
        self.features = features
        self.macAddress = macAddress
        self.wifiInfo = wifiInfo
    }

    public static func decode(_ data: Data) throws -> ElgatoAccessoryInfo {
        try JSONDecoder().decode(ElgatoAccessoryInfo.self, from: data)
    }

    /// Display name if set, else the product name.
    public var name: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? productName : trimmed
    }
}

/// `/elgato/lights/settings`. Light Strips add `powerOnHue`/`powerOnSaturation`
/// (HA uses their presence to enable the HS colour mode).
public struct ElgatoSettings: Codable, Sendable, Equatable {
    public var powerOnBehavior: Int?
    public var powerOnBrightness: Int?
    public var powerOnTemperature: Int?
    public var powerOnHue: Double?
    public var powerOnSaturation: Double?
    public var switchOnDurationMs: Int?
    public var switchOffDurationMs: Int?
    public var colorChangeDurationMs: Int?

    public init(
        powerOnBehavior: Int? = nil, powerOnBrightness: Int? = nil, powerOnTemperature: Int? = nil,
        powerOnHue: Double? = nil, powerOnSaturation: Double? = nil, switchOnDurationMs: Int? = nil,
        switchOffDurationMs: Int? = nil, colorChangeDurationMs: Int? = nil
    ) {
        self.powerOnBehavior = powerOnBehavior
        self.powerOnBrightness = powerOnBrightness
        self.powerOnTemperature = powerOnTemperature
        self.powerOnHue = powerOnHue
        self.powerOnSaturation = powerOnSaturation
        self.switchOnDurationMs = switchOnDurationMs
        self.switchOffDurationMs = switchOffDurationMs
        self.colorChangeDurationMs = colorChangeDurationMs
    }

    public static func decode(_ data: Data) throws -> ElgatoSettings {
        try JSONDecoder().decode(ElgatoSettings.self, from: data)
    }
}
