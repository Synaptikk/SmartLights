import Crypto
import Foundation

/// SwitchBot API v1.1 request signing and builders (https://github.com/OpenWonderLabs/SwitchBotAPI,
/// "Authentication" and "Devices").
///
/// Every request carries `Authorization: <token>`, `t` (13-digit ms timestamp), `nonce` (UUID) and
/// `sign = base64(HMAC-SHA256(key: secret, message: token + t + nonce))`.
public enum SwitchBotAPI {
    public static let baseURL = URL(string: "https://api.switch-bot.com")!
    public static let version = "v1.1"
    /// Requests per account per day; going over returns "Unauthorized".
    public static let dailyRequestLimit = 10_000

    /// `base64(HMAC-SHA256(secret, token + t + nonce))`. Not upper-cased: the README's Python/JS
    /// samples and Home Assistant's `switchbot_api` send the plain base64 (the prose says "upper case",
    /// which would alter base64; see docs/HARDWARE-NOTES.md).
    public static func sign(token: String, secret: String, t: Int64, nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data((token + String(t) + nonce).utf8),
                                                  using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }

    public static func headers(token: String, secret: String, t: Int64, nonce: String) -> [String: String] {
        [
            "Authorization": token,
            "sign": sign(token: token, secret: secret, t: t, nonce: nonce),
            "t": String(t),
            "nonce": nonce,
            "Content-Type": "application/json; charset=utf8",
        ]
    }

    public static func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// `GET /v1.1/devices`.
    public static func devices(token: String, secret: String, t: Int64 = nowMillis(), nonce: String = UUID().uuidString) -> SwitchBotRequest {
        SwitchBotRequest(method: "GET", path: "/\(version)/devices", headers: headers(token: token, secret: secret, t: t, nonce: nonce))
    }

    /// `GET /v1.1/devices/{deviceId}/status`.
    public static func status(deviceId: String, token: String, secret: String, t: Int64 = nowMillis(),
                              nonce: String = UUID().uuidString) -> SwitchBotRequest {
        SwitchBotRequest(method: "GET", path: "/\(version)/devices/\(escape(deviceId))/status",
                         headers: headers(token: token, secret: secret, t: t, nonce: nonce))
    }

    /// `POST /v1.1/devices/{deviceId}/commands` with `{"command", "parameter", "commandType"}`.
    public static func command(_ command: SwitchBotCommand, deviceId: String, token: String, secret: String,
                               t: Int64 = nowMillis(), nonce: String = UUID().uuidString) -> SwitchBotRequest {
        SwitchBotRequest(method: "POST", path: "/\(version)/devices/\(escape(deviceId))/commands",
                         headers: headers(token: token, secret: secret, t: t, nonce: nonce), body: command.body)
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}

public struct SwitchBotRequest: Sendable, Hashable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func url(baseURL: URL) -> URL? {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        return URL(string: base + path)
    }
}

/// One control command (`commandType: "command"`).
public struct SwitchBotCommand: Sendable, Hashable {
    public enum Parameter: Sendable, Hashable {
        case `default`
        case int(Int)
        case string(String)
    }

    public var command: String
    public var parameter: Parameter

    public init(_ command: String, _ parameter: Parameter = .default) {
        self.command = command
        self.parameter = parameter
    }

    public static let turnOn = SwitchBotCommand("turnOn")
    public static let turnOff = SwitchBotCommand("turnOff")
    /// `{1-100}` (some lamps accept 0).
    public static func setBrightness(_ value: Int) -> SwitchBotCommand { SwitchBotCommand("setBrightness", .int(value)) }
    /// `"{0-255}:{0-255}:{0-255}"`.
    public static func setColor(r: UInt8, g: UInt8, b: UInt8) -> SwitchBotCommand { SwitchBotCommand("setColor", .string("\(r):\(g):\(b)")) }
    /// `{2700-6500}`.
    public static func setColorTemperature(_ kelvin: Int) -> SwitchBotCommand { SwitchBotCommand("setColorTemperature", .int(kelvin)) }

    /// JSON body: `{"command": ..., "parameter": ..., "commandType": "command"}` (keys sorted).
    public var body: Data {
        let parameterJSON: String = switch parameter {
        case .default: "\"default\""
        case .int(let v): String(v)
        case .string(let s): Self.jsonString(s)
        }
        return Data("{\"command\":\(Self.jsonString(command)),\"commandType\":\"command\",\"parameter\":\(parameterJSON)}".utf8)
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
