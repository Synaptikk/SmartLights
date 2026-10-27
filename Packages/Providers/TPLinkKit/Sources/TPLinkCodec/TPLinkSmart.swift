import Foundation

/// SMART protocol (Tapo, newer Kasa): JSON-RPC-like requests carried by KLAP.
///
/// Request: `{"method":"get_device_info","params":{...},"request_time_milis":<ms>,"terminal_uuid":"..."}`.
/// Response: `{"error_code":0,"result":{...}}`; `set_*` methods usually return no `result`.
public enum TPLinkSmart {
    public static func request(method: String, params: TPLinkJSON? = nil, timeMillis: Int64, terminalUUID: String) -> TPLinkJSON {
        var members: [String: TPLinkJSON] = [
            "method": .string(method),
            "request_time_milis": .int(timeMillis),
            "terminal_uuid": .string(terminalUUID),
        ]
        if let params, params != .emptyObject, params != .null { members["params"] = params }
        return .object(members)
    }

    /// Checks `error_code` and returns `result` (`.null` when absent).
    public static func result(of response: TPLinkJSON, method: String) throws -> TPLinkJSON {
        guard response.objectValue != nil else { throw TPLinkCodecError.invalidJSON("SMART response is not an object") }
        let code = response["error_code"]?.intValue ?? TPLinkSmartErrorCode.internalUnknown.rawValue
        guard code == 0 else { throw TPLinkCodecError.smartError(method: method, code: TPLinkSmartErrorCode(rawValue: code)) }
        return response["result"] ?? .null
    }

    /// A terminal UUID like python-kasa's: base64 of an MD5 of random bytes (stable per provider).
    public static func makeTerminalUUID(_ seed: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) -> String {
        TPLinkKLAP.md5(seed).base64EncodedString()
    }
}

/// SMART `error_code` values that matter for control (python-kasa `SmartErrorCode`).
public struct TPLinkSmartErrorCode: RawRepresentable, Sendable, Hashable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let success = Self(rawValue: 0)
    public static let sessionTimeout = Self(rawValue: 9999)
    public static let multiRequestFailed = Self(rawValue: 1200)
    public static let httpTransportFailed = Self(rawValue: 1112)
    public static let loginFailed = Self(rawValue: 1111)
    public static let handshakeFailed = Self(rawValue: 1100)
    public static let transportUnknownCredentials = Self(rawValue: 1003)
    public static let transportNotAvailable = Self(rawValue: 1002)
    public static let unspecific = Self(rawValue: -1001)
    public static let unknownMethod = Self(rawValue: -1002)
    public static let jsonDecodeFail = Self(rawValue: -1003)
    public static let aesDecodeFail = Self(rawValue: -1005)
    public static let paramsError = Self(rawValue: -1008)
    public static let invalidNonce = Self(rawValue: -1012)
    public static let loginError = Self(rawValue: -1501)
    public static let sessionExpired = Self(rawValue: -40401)
    public static let homeKitLoginFail = Self(rawValue: -40412)
    public static let internalUnknown = Self(rawValue: -100_000)

    /// The session is gone: re-handshake and retry (python-kasa `SMART_RETRYABLE_ERRORS`).
    public var requiresNewSession: Bool {
        [Self.sessionTimeout, .sessionExpired, .transportNotAvailable, .httpTransportFailed, .unspecific, .invalidNonce].contains(self)
    }

    /// Credentials rejected (python-kasa `SMART_AUTHENTICATION_ERRORS`).
    public var isAuthentication: Bool {
        [Self.loginError, .loginFailed, .aesDecodeFail, .handshakeFailed, .transportUnknownCredentials, .homeKitLoginFail].contains(self)
    }

    public var name: String {
        switch self {
        case .success: "SUCCESS"
        case .sessionTimeout: "SESSION_TIMEOUT_ERROR"
        case .multiRequestFailed: "MULTI_REQUEST_FAILED_ERROR"
        case .httpTransportFailed: "HTTP_TRANSPORT_FAILED_ERROR"
        case .loginFailed: "LOGIN_FAILED_ERROR"
        case .handshakeFailed: "HAND_SHAKE_FAILED_ERROR"
        case .transportUnknownCredentials: "TRANSPORT_UNKNOWN_CREDENTIALS_ERROR"
        case .transportNotAvailable: "TRANSPORT_NOT_AVAILABLE_ERROR"
        case .unspecific: "UNSPECIFIC_ERROR"
        case .unknownMethod: "UNKNOWN_METHOD_ERROR"
        case .jsonDecodeFail: "JSON_DECODE_FAIL_ERROR"
        case .aesDecodeFail: "AES_DECODE_FAIL_ERROR"
        case .paramsError: "PARAMS_ERROR"
        case .invalidNonce: "INVALID_NONCE"
        case .loginError: "LOGIN_ERROR"
        case .sessionExpired: "SESSION_EXPIRED"
        case .homeKitLoginFail: "HOMEKIT_LOGIN_FAIL"
        default: "ERROR"
        }
    }
}

/// The parts of SMART `get_device_info` used for lights (Tapo L5xx/L6xx/L9xx, `SMART.TAPOBULB`).
public struct TPLinkSmartDeviceInfo: Sendable, Hashable {
    public var deviceID: String?
    /// `AA-BB-CC-DD-EE-FF` as sent.
    public var mac: String?
    /// e.g. `L530`; the region suffix of discovery (`L530E(EU)`) is not included.
    public var model: String?
    public var type: String?
    /// Decoded from base64 `nickname`.
    public var nickname: String?
    public var firmware: String?
    public var hardware: String?
    public var isOn: Bool
    /// 1...100 when present.
    public var brightness: Int?
    /// 0...360.
    public var hue: Int?
    /// 0...100.
    public var saturation: Int?
    /// Kelvin; 0 means colour (hue/saturation) mode.
    public var colorTemp: Int?
    public var colorTempRange: ClosedRange<Int>?
    /// A dynamic light effect (L9xx strips, L530 "dynamic_light_effect") is running.
    public var effectActive: Bool
    public var effectName: String?
    public var overheated: Bool

    public init(_ json: TPLinkJSON) throws {
        guard json.objectValue != nil else { throw TPLinkCodecError.missingField("get_device_info") }
        deviceID = json["device_id"]?.stringValue
        mac = json["mac"]?.stringValue
        model = json["model"]?.stringValue
        type = json["type"]?.stringValue
        nickname = json["nickname"]?.stringValue.flatMap(Self.decodeBase64)
        firmware = json["fw_ver"]?.stringValue
        hardware = json["hw_ver"]?.stringValue
        guard let on = json["device_on"]?.boolValue else { throw TPLinkCodecError.missingField("device_on") }
        isOn = on
        brightness = json["brightness"]?.intValue
        hue = json["hue"]?.intValue
        saturation = json["saturation"]?.intValue
        colorTemp = json["color_temp"]?.intValue
        if let range = json["color_temp_range"]?.arrayValue, range.count == 2,
           let lo = range[0].intValue, let hi = range[1].intValue {
            colorTempRange = min(lo, hi)...max(lo, hi)
        }
        let strip = json["lighting_effect"]
        let stripEffect = strip?["enable"]?.boolValue ?? false
        effectActive = (json["dynamic_light_effect_enable"]?.boolValue ?? false) || stripEffect
        effectName = stripEffect ? strip?["name"]?.stringValue : json["dynamic_light_effect_id"]?.stringValue
        overheated = json["overheated"]?.boolValue ?? false
    }

    /// Tapo encodes user-visible strings (nickname, ssid) as base64.
    static func decodeBase64(_ s: String) -> String? {
        guard let data = Data(base64Encoded: s), let text = String(data: data, encoding: .utf8) else { return s }
        return text
    }

    /// Has a usable colour-temperature range (a single value such as `[9000, 9000]` means none).
    public var hasVariableColorTemp: Bool { colorTempRange.map { $0.lowerBound < $0.upperBound } ?? false }
    public var hasColor: Bool { hue != nil && saturation != nil }
    public var isDimmable: Bool { brightness != nil }
}
