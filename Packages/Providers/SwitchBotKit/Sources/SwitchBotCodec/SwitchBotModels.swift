import Foundation
import LightCore

/// Errors from the SwitchBot cloud. Messages never contain the token or secret.
public enum SwitchBotError: Error, Sendable, Equatable, LocalizedError {
    /// HTTP 401 "Unauthorized": bad token/secret/signature, or the daily request limit was exceeded.
    case unauthorized
    /// HTTP 429.
    case tooManyRequests
    case http(Int)
    /// `statusCode` other than 100 (151 device type error, 152 not found, 160 command not supported,
    /// 161 device offline, 171 hub offline, 190 internal error / bad command format).
    case api(code: Int, message: String?)
    case malformed(String)
    /// Our own daily budget (`SwitchBotAPI.dailyRequestLimit`) is used up.
    case budgetExhausted

    /// Device or its hub is offline.
    public var isOffline: Bool {
        if case .api(let code, _) = self { return code == 161 || code == 171 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "SwitchBot rejected the token/secret (or the 10,000 requests/day limit was reached)"
        case .tooManyRequests: "SwitchBot is rate limiting requests"
        case .http(let s): "SwitchBot answered HTTP \(s)"
        case .api(let code, let message):
            switch code {
            case 151: "SwitchBot: device type error"
            case 152: "SwitchBot: device not found"
            case 160: "SwitchBot: command not supported by this device"
            case 161: "SwitchBot: device offline"
            case 171: "SwitchBot: hub offline"
            case 190: "SwitchBot: device internal error or invalid command (\(message ?? ""))"
            default: "SwitchBot error \(code)\(message.map { ": \($0)" } ?? "")"
            }
        case .malformed(let s): "Unexpected SwitchBot reply: \(s)"
        case .budgetExhausted: "SwitchBot daily request budget used up; try again later"
        }
    }
}

/// A physical device from `GET /v1.1/devices` (`body.deviceList[]`).
public struct SwitchBotDevice: Sendable, Hashable, Codable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    /// BLE devices are only reachable through the cloud when Cloud Services is on (and a hub is present).
    public var enableCloudService: Bool?
    /// `000000000000` for Wi-Fi devices and hubs.
    public var hubDeviceId: String?

    public init(deviceId: String, deviceName: String, deviceType: String, enableCloudService: Bool? = nil, hubDeviceId: String? = nil) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.enableCloudService = enableCloudService
        self.hubDeviceId = hubDeviceId
    }

    /// Whether a hub relays this device (BLE-only lights).
    public var usesHub: Bool {
        guard let hub = hubDeviceId, !hub.isEmpty else { return false }
        return hub.contains { $0 != "0" } && hub != deviceId
    }

    public var lightKind: SwitchBotLightKind? { SwitchBotLightKind(deviceType: deviceType) }
}

/// Decoded `{statusCode, message, body}` envelope.
public enum SwitchBotResponse {
    private struct Envelope<Body: Decodable>: Decodable {
        var statusCode: Int?
        var message: String?
        var body: Body?
    }

    /// Accepts any JSON value (command replies carry `{}` or arbitrary bodies).
    private struct Empty: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private struct DeviceListBody: Decodable {
        var deviceList: [SwitchBotDevice]?
    }

    /// Checks HTTP status and `statusCode == 100`.
    public static func check(status: Int, body: Data) throws {
        _ = try decode(Empty.self, status: status, body: body, requireBody: false)
    }

    public static func decodeDevices(status: Int, body: Data) throws -> [SwitchBotDevice] {
        let list = try decode(DeviceListBody.self, status: status, body: body, requireBody: true)
        return list?.deviceList ?? []
    }

    public static func decodeStatus(status: Int, body: Data) throws -> SwitchBotLightStatus {
        guard let s = try decode(SwitchBotLightStatus.self, status: status, body: body, requireBody: true) else {
            throw SwitchBotError.malformed("missing body")
        }
        return s
    }

    private static func decode<B: Decodable>(_ type: B.Type, status: Int, body: Data, requireBody: Bool) throws -> B? {
        switch status {
        case 200..<300: break
        case 401: throw SwitchBotError.unauthorized
        case 429: throw SwitchBotError.tooManyRequests
        default: throw SwitchBotError.http(status)
        }
        let envelope: Envelope<B>
        do {
            envelope = try JSONDecoder().decode(Envelope<B>.self, from: body)
        } catch {
            // `{"message": "Unauthorized"}` can come with HTTP 200 from some gateways.
            if let m = try? JSONDecoder().decode(Envelope<Empty>.self, from: body), m.message == "Unauthorized" {
                throw SwitchBotError.unauthorized
            }
            throw SwitchBotError.malformed("undecodable body")
        }
        guard let code = envelope.statusCode else {
            if envelope.message == "Unauthorized" { throw SwitchBotError.unauthorized }
            throw SwitchBotError.malformed("missing statusCode")
        }
        guard code == 100 else { throw SwitchBotError.api(code: code, message: envelope.message) }
        if requireBody, envelope.body == nil { throw SwitchBotError.malformed("missing body") }
        return envelope.body
    }
}

/// `GET /devices/{id}/status` body for lights.
public struct SwitchBotLightStatus: Sendable, Hashable, Decodable {
    public var deviceId: String?
    public var deviceType: String?
    public var hubDeviceId: String?
    /// "on"/"off" (case varies by model).
    public var power: String?
    public var brightness: Int?
    /// `"r:g:b"`.
    public var color: String?
    public var colorTemperature: Int?
    public var version: String?

    public init(power: String? = nil, brightness: Int? = nil, color: String? = nil, colorTemperature: Int? = nil) {
        self.power = power
        self.brightness = brightness
        self.color = color
        self.colorTemperature = colorTemperature
    }

    enum CodingKeys: String, CodingKey {
        case deviceId, deviceType, hubDeviceId, power, brightness, color, colorTemperature, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try? c.decodeIfPresent(String.self, forKey: .deviceId)
        deviceType = try? c.decodeIfPresent(String.self, forKey: .deviceType)
        hubDeviceId = try? c.decodeIfPresent(String.self, forKey: .hubDeviceId)
        power = try? c.decodeIfPresent(String.self, forKey: .power)
        brightness = Self.flexibleInt(c, .brightness)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        colorTemperature = Self.flexibleInt(c, .colorTemperature)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
    }

    /// Numbers sometimes arrive as strings or doubles.
    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(v.rounded()) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    public var isOn: Bool? {
        guard let power else { return nil }
        switch power.lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// Parses `"r:g:b"`.
    public var rgb: RGB? {
        guard let color else { return nil }
        let parts = color.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return RGB(r: UInt8(parts[0]), g: UInt8(parts[1]), b: UInt8(parts[2]))
    }
}

/// Light device types the provider controls, with their colour features (per-device docs in
/// `SwitchBotAPI/devices/lighting/*.md`).
public struct SwitchBotLightKind: Sendable, Hashable {
    public var deviceType: String
    public var hasColor: Bool
    public var hasColorTemperature: Bool
    /// Lowest `setBrightness` value the docs allow (1 for most, 0 for some newer lamps).
    public var minBrightness: Int

    public static let kelvinRange = 2700...6500

    /// Types from the v1.1 docs. Color Bulb, Strip Light and Ceiling Light are the T3.3 targets;
    /// the rest share the same command set (turnOn/turnOff/setBrightness/setColor/setColorTemperature).
    public static let table: [String: SwitchBotLightKind] = {
        let rows: [(String, Bool, Bool, Int)] = [
            ("Color Bulb", true, true, 1),
            ("Strip Light", true, false, 1),
            ("Strip Light 3", true, true, 0),
            ("Ceiling Light", false, true, 1),
            ("Ceiling Light Pro", false, true, 1),
            ("Floor Lamp", true, true, 0),
            ("RGBICWW Strip Light", true, true, 0),
            ("RGBICWW Floor Lamp", true, true, 0),
            ("RGBIC Neon Rope Light", true, false, 0),
            ("RGBIC Neon Wire Rope Light", true, false, 0),
            ("Permanent Outdoor Lights", true, true, 0),
            ("Candle Warmer Lamp", false, false, 0),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.0.lowercased(), SwitchBotLightKind(deviceType: $0.0, hasColor: $0.1, hasColorTemperature: $0.2, minBrightness: $0.3))
        })
    }()

    public init(deviceType: String, hasColor: Bool, hasColorTemperature: Bool, minBrightness: Int) {
        self.deviceType = deviceType
        self.hasColor = hasColor
        self.hasColorTemperature = hasColorTemperature
        self.minBrightness = minBrightness
    }

    public init?(deviceType: String) {
        guard let kind = Self.table[deviceType.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        self = kind
    }

    public var capabilities: LightCapabilities {
        var modes: Set<ColorMode> = []
        if hasColor { modes.insert(.rgb) }
        if hasColorTemperature { modes.insert(.colorTemp) }
        if modes.isEmpty { modes.insert(.brightness) }
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: hasColorTemperature ? Self.kelvinRange.lowerBound : nil,
            maxKelvin: hasColorTemperature ? Self.kelvinRange.upperBound : nil)
    }
}

/// Status <-> `LightState`, `LightCommand` -> commands.
public enum SwitchBotMapping {
    /// The status reports both `color` and `colorTemperature`, not which one is active. We keep the
    /// mode of the last command (`previousMode`); otherwise white `255:255:255` (or no colour) means
    /// temperature mode on lamps that have both.
    public static func state(from status: SwitchBotLightStatus, kind: SwitchBotLightKind, previousMode: ColorMode?,
                             reachable: Bool, at date: Date = Date()) -> LightState {
        var state = LightState(isOn: status.isOn ?? false, reachable: reachable, updatedAt: date)
        if let b = status.brightness { state.brightness = Double(min(max(b, 0), 100)) / 100 }
        let rgb = kind.hasColor ? status.rgb : nil
        let kelvin = kind.hasColorTemperature ? status.colorTemperature.map { min(max($0, 1000), 10000) } : nil
        state.rgb = rgb
        state.kelvin = kelvin
        let modes = kind.capabilities.supportedColorModes
        if let previousMode, modes.contains(previousMode) {
            state.colorMode = previousMode
        } else if kind.hasColor && kind.hasColorTemperature {
            state.colorMode = (rgb == nil || rgb == .white) && kelvin != nil ? .colorTemp : .rgb
        } else {
            state.colorMode = kind.hasColor ? .rgb : kind.hasColorTemperature ? .colorTemp : .brightness
        }
        return state
    }

    /// One API call per changed attribute, in order: power on (if needed), colour, brightness.
    /// Off (or brightness 0) is a single `turnOff`. Effects are not supported.
    public static func commands(for command: LightCommand, kind: SwitchBotLightKind, currentlyOn: Bool) -> [SwitchBotCommand] {
        let normalized = command.normalized(for: kind.capabilities)
        if normalized.on == false || (normalized.brightness.map { $0 <= 0 } ?? false) { return [.turnOff] }
        var out: [SwitchBotCommand] = []
        switch normalized.color {
        case .rgb(let rgb)?: out.append(.setColor(r: rgb.r, g: rgb.g, b: rgb.b))
        case .kelvin(let k)?: out.append(.setColorTemperature(min(max(k, SwitchBotLightKind.kelvinRange.lowerBound), SwitchBotLightKind.kelvinRange.upperBound)))
        default: break
        }
        if let b = normalized.brightness {
            out.append(.setBrightness(min(max(Int((b * 100).rounded()), max(1, kind.minBrightness)), 100)))
        }
        if normalized.on == true || (!out.isEmpty && !currentlyOn) {
            out.insert(.turnOn, at: 0)
        }
        return out
    }

    /// Optimistic state after `commands` succeeded.
    public static func apply(_ commands: [SwitchBotCommand], to state: LightState, at date: Date = Date()) -> LightState {
        var s = state
        for c in commands {
            switch (c.command, c.parameter) {
            case ("turnOn", _): s.isOn = true
            case ("turnOff", _): s.isOn = false
            case ("setBrightness", .int(let v)): s.brightness = Double(v) / 100
            case ("setColor", .string(let v)):
                s.rgb = SwitchBotLightStatus(color: v).rgb
                s.colorMode = .rgb
            case ("setColorTemperature", .int(let k)):
                s.kelvin = k
                s.colorMode = .colorTemp
            default: break
            }
        }
        s.updatedAt = date
        return s
    }
}
