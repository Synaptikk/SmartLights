import Foundation

/// Application return codes carried in the JSON `code` field (xled-docs "Application responses").
/// HTTP 200 with a non-OK code means the device received the request but rejected it.
public enum TwinklyAppCode {
    public static let ok = 1000
    /// Undocumented codes xled-docs lists as "Ok?" (seen on some firmware).
    public static let okLike: Set<Int> = [1000, 1107, 1108]

    public static func message(for code: Int) -> String {
        switch code {
        case 1001, 1102: "error"
        case 1101: "invalid argument value"
        case 1103: "value too long or missing key"
        case 1104: "malformed JSON"
        case 1105: "invalid argument key"
        case 1205: "firmware checksum mismatch"
        default: "code \(code)"
        }
    }
}

/// `{"code": 1000}` envelope present in every response.
public struct TwinklyCodeResponse: Decodable, Sendable, Hashable {
    public var code: Int?
}

// MARK: - Login

/// `POST /xled/v1/login` body.
public struct TwinklyLoginRequest: Codable, Sendable, Hashable {
    /// 32 random bytes, base64.
    public var challenge: String

    public init(challenge: String) { self.challenge = challenge }
}

public struct TwinklyLoginResponse: Codable, Sendable, Hashable {
    /// 8 random bytes, base64. Sent as `X-Auth-Token`. Never log.
    public var authenticationToken: String
    /// Lifetime in seconds (14400 on every firmware seen by xled).
    public var expiresIn: Int?
    /// Echoed back to `/verify`.
    public var challengeResponse: String?
    public var code: Int?

    enum CodingKeys: String, CodingKey {
        case authenticationToken = "authentication_token"
        case expiresIn = "authentication_token_expires_in"
        case challengeResponse = "challenge-response"
        case code
    }

    public init(authenticationToken: String, expiresIn: Int?, challengeResponse: String?, code: Int? = TwinklyAppCode.ok) {
        self.authenticationToken = authenticationToken
        self.expiresIn = expiresIn
        self.challengeResponse = challengeResponse
        self.code = code
    }
}

/// `POST /xled/v1/verify` body.
public struct TwinklyVerifyRequest: Codable, Sendable, Hashable {
    public var challengeResponse: String?

    enum CodingKeys: String, CodingKey {
        case challengeResponse = "challenge-response"
    }

    public init(challengeResponse: String?) { self.challengeResponse = challengeResponse }
}

// MARK: - Device info

/// `GET /xled/v1/gestalt` (no token needed). Fields vary by firmware family (D, F, G); all optional.
public struct TwinklyGestalt: Codable, Sendable, Hashable {
    public var productName: String?
    public var productCode: String?
    public var deviceName: String?
    public var hardwareID: String?
    /// `aa:bb:cc:dd:ee:ff`. Gen II reports the access-point-mode address; still stable per device.
    public var mac: String?
    public var uuid: String?
    public var numberOfLED: Int?
    /// `RGB` or `RGBW`.
    public var ledProfile: String?
    /// `F`, `G` on Gen II; absent on family D.
    public var firmwareFamily: String?
    public var hardwareVersion: String?
    public var code: Int?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productCode = "product_code"
        case deviceName = "device_name"
        case hardwareID = "hw_id"
        case mac, uuid
        case numberOfLED = "number_of_led"
        case ledProfile = "led_profile"
        case firmwareFamily = "fw_family"
        case hardwareVersion = "hardware_version"
        case code
    }

    public init(productName: String? = "Twinkly", productCode: String? = nil, deviceName: String? = nil,
                hardwareID: String? = nil, mac: String? = nil, uuid: String? = nil, numberOfLED: Int? = nil,
                ledProfile: String? = nil, firmwareFamily: String? = nil, hardwareVersion: String? = nil,
                code: Int? = TwinklyAppCode.ok) {
        self.productName = productName
        self.productCode = productCode
        self.deviceName = deviceName
        self.hardwareID = hardwareID
        self.mac = mac
        self.uuid = uuid
        self.numberOfLED = numberOfLED
        self.ledProfile = ledProfile
        self.firmwareFamily = firmwareFamily
        self.hardwareVersion = hardwareVersion
        self.code = code
    }

    /// Lower-case 12-hex MAC (stable id), nil if missing or malformed.
    public var stableID: String? { mac.flatMap(TwinklyIdentifiers.normalizeMAC) }
}

/// `GET /xled/v1/fw/version` (no token needed).
public struct TwinklyFirmwareResponse: Codable, Sendable, Hashable {
    public var version: String
    public var code: Int?

    public init(version: String, code: Int? = TwinklyAppCode.ok) {
        self.version = version
        self.code = code
    }
}

/// Dotted firmware version (`2.8.3`), compared numerically.
public struct TwinklyFirmwareVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        components = parts.compactMap { $0 }
    }

    public init(_ components: Int...) { self.components = components }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: TwinklyFirmwareVersion, rhs: TwinklyFirmwareVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// `/led/color` exists since 2.7.1.
    public static let colorEndpoint = TwinklyFirmwareVersion(2, 7, 1)
    /// `/led/out/brightness` exists since 2.3.5 (family D; F and G got it at 2.4.2 / 2.4.21).
    public static let brightnessEndpoint = TwinklyFirmwareVersion(2, 3, 5)
}

// MARK: - LED state

/// LED operation mode (`/xled/v1/led/mode`).
public enum TwinklyMode: Sendable, Hashable, Codable, CustomStringConvertible {
    case off, color, demo, effect, movie, playlist, rt
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "color": self = .color
        case "demo": self = .demo
        case "effect": self = .effect
        case "movie": self = .movie
        case "playlist": self = .playlist
        case "rt": self = .rt
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .off: "off"
        case .color: "color"
        case .demo: "demo"
        case .effect: "effect"
        case .movie: "movie"
        case .playlist: "playlist"
        case .rt: "rt"
        case .other(let s): s
        }
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct TwinklyModeResponse: Codable, Sendable, Hashable {
    public var mode: TwinklyMode
    public var code: Int?

    public init(mode: TwinklyMode, code: Int? = TwinklyAppCode.ok) {
        self.mode = mode
        self.code = code
    }
}

/// `POST /xled/v1/led/mode` body; `effect_id` only with `mode: effect`.
public struct TwinklyModeRequest: Codable, Sendable, Hashable {
    public var mode: TwinklyMode
    public var effectID: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case effectID = "effect_id"
    }

    public init(mode: TwinklyMode, effectID: Int? = nil) {
        self.mode = mode
        self.effectID = effectID
    }
}

/// `GET /xled/v1/led/color` (since 2.7.1): HSV (hue 0..359, saturation/value 0..255) and RGB.
public struct TwinklyColorResponse: Codable, Sendable, Hashable {
    public var hue: Int?
    public var saturation: Int?
    public var value: Int?
    public var red: Int?
    public var green: Int?
    public var blue: Int?
    public var code: Int?

    public init(hue: Int? = nil, saturation: Int? = nil, value: Int? = nil, red: Int? = nil, green: Int? = nil,
                blue: Int? = nil, code: Int? = TwinklyAppCode.ok) {
        self.hue = hue
        self.saturation = saturation
        self.value = value
        self.red = red
        self.green = green
        self.blue = blue
        self.code = code
    }
}

/// `POST /xled/v1/led/color` body: either the HSV or the RGB triple.
public enum TwinklyColorRequest: Sendable, Hashable, Encodable {
    /// hue 0..359, saturation 0..255, value 0..255.
    case hsv(hue: Int, saturation: Int, value: Int)
    case rgb(red: Int, green: Int, blue: Int)

    enum CodingKeys: String, CodingKey {
        case hue, saturation, value, red, green, blue
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hsv(let h, let s, let v):
            try c.encode(h, forKey: .hue)
            try c.encode(s, forKey: .saturation)
            try c.encode(v, forKey: .value)
        case .rgb(let r, let g, let b):
            try c.encode(r, forKey: .red)
            try c.encode(g, forKey: .green)
            try c.encode(b, forKey: .blue)
        }
    }
}

/// `GET /xled/v1/led/out/brightness`: `value` 0..100, `mode` `enabled`/`disabled`
/// (disabled = no dimming, full brightness whatever `value` says).
public struct TwinklyBrightnessResponse: Codable, Sendable, Hashable {
    public var value: Int?
    public var mode: String?
    public var code: Int?

    public init(value: Int?, mode: String? = "enabled", code: Int? = TwinklyAppCode.ok) {
        self.value = value
        self.mode = mode
        self.code = code
    }

    /// `0...1`.
    public var brightness: Double {
        guard mode != "disabled", let value else { return 1 }
        return Double(min(max(value, 0), 100)) / 100
    }
}

/// `POST /xled/v1/led/out/brightness` body. `type` `A` = absolute.
public struct TwinklyBrightnessRequest: Codable, Sendable, Hashable {
    public var mode: String
    public var type: String
    public var value: Int

    public init(value: Int, mode: String = "enabled", type: String = "A") {
        self.mode = mode
        self.type = type
        self.value = value
    }
}

/// `GET /xled/v1/led/effects`: `effects_number` (5 before 2.5.6, 15 after), `unique_ids` since 2.5.6.
public struct TwinklyEffectsResponse: Codable, Sendable, Hashable {
    public var effectsNumber: Int?
    public var uniqueIDs: [String]?
    public var code: Int?

    enum CodingKeys: String, CodingKey {
        case effectsNumber = "effects_number"
        case uniqueIDs = "unique_ids"
        case code
    }

    public init(effectsNumber: Int?, uniqueIDs: [String]? = nil, code: Int? = TwinklyAppCode.ok) {
        self.effectsNumber = effectsNumber
        self.uniqueIDs = uniqueIDs
        self.code = code
    }

    public var count: Int { max(effectsNumber ?? 0, uniqueIDs?.count ?? 0) }
}

/// `GET`/`POST /xled/v1/led/effects/current`.
public struct TwinklyEffectCurrent: Codable, Sendable, Hashable {
    public var effectID: Int?
    public var code: Int?

    enum CodingKeys: String, CodingKey {
        case effectID = "effect_id"
        case code
    }

    public init(effectID: Int?, code: Int? = nil) {
        self.effectID = effectID
        self.code = code
    }
}
