import Foundation

/// Namespaces used by the light provider (meross_lan `merossclient/protocol/namespaces`).
public enum MerossNamespace {
    public static let systemAll = "Appliance.System.All"
    public static let systemAbility = "Appliance.System.Ability"
    public static let controlLight = "Appliance.Control.Light"
    public static let controlLightEffect = "Appliance.Control.Light.Effect"
    public static let controlToggle = "Appliance.Control.Toggle"
    public static let controlToggleX = "Appliance.Control.ToggleX"
    public static let encryptECDHE = "Appliance.Encrypt.ECDHE"
}

/// Header methods. Requests use GET/SET; devices answer GETACK/SETACK, ERROR, or PUSH.
public enum MerossMethod: String, Sendable, Hashable, Codable {
    case get = "GET"
    case set = "SET"
    case getAck = "GETACK"
    case setAck = "SETACK"
    case push = "PUSH"
    case error = "ERROR"
}

public enum MerossConstants {
    /// `header.from` / `triggerSrc` used by meross_lan for HTTP (devices accept any string).
    public static let defaultFrom = "MerossClient"
    /// Local HTTP endpoint on every Meross Wi-Fi device.
    public static let configPath = "/config"
    public static let httpPort: UInt16 = 80
    /// `payload.error.code` when the signature (device key) is wrong.
    public static let errorInvalidKey = 5001
    /// MAC prefixes (OUI) seen on Meross devices; meross_lan's DHCP matchers (`manifest.json`).
    public static let macPrefixes = ["48E1E9", "C4E7AE", "34298F1"]

    /// Whether `mac` (any separator/case) starts with a known Meross OUI.
    public static func isMerossMAC(_ mac: String) -> Bool {
        let hex = mac.uppercased().filter(\.isHexDigit)
        return macPrefixes.contains { hex.hasPrefix($0) }
    }
}

/// A request to `POST http://<ip>/config`:
/// `{"header": {messageId, namespace, method, payloadVersion, triggerSrc, from, timestamp, timestampMs, sign}, "payload": ...}`
/// with `sign = md5(messageId + key + timestamp)` (timestamp in whole seconds).
public struct MerossRequest: Sendable, Hashable {
    public var namespace: String
    public var method: MerossMethod
    public var payload: MerossJSON
    public var messageId: String
    public var timestamp: Int
    public var from: String

    public init(namespace: String, method: MerossMethod, payload: MerossJSON,
                messageId: String = MerossRequest.newMessageId(), timestamp: Int = Int(Date().timeIntervalSince1970),
                from: String = MerossConstants.defaultFrom) {
        self.namespace = namespace
        self.method = method
        self.payload = payload
        self.messageId = messageId
        self.timestamp = timestamp
        self.from = from
    }

    /// 32 lowercase hex chars (meross_lan `MerossMessage.generate_id`).
    public static func newMessageId() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// `md5(messageId + key + timestamp)`, lowercase hex.
    public static func signature(messageId: String, key: String, timestamp: Int) -> String {
        MerossCrypto.md5Hex(messageId + key + String(timestamp))
    }

    public func header(key: String) -> MerossJSON {
        [
            "messageId": .string(messageId),
            "namespace": .string(namespace),
            "method": .string(method.rawValue),
            "payloadVersion": 1,
            "triggerSrc": .string(from),
            "from": .string(from),
            "timestamp": .int(timestamp),
            "timestampMs": 0,
            "sign": .string(Self.signature(messageId: messageId, key: key, timestamp: timestamp)),
        ]
    }

    /// The JSON body signed with `key` (the account key; "" for un-keyed legacy firmware).
    public func encoded(key: String) -> Data {
        MerossJSON.object(["header": header(key: key), "payload": payload]).encoded()
    }

    // MARK: Common requests

    public static func getAll() -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.systemAll, method: .get, payload: ["all": [:]])
    }

    public static func getAbility() -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.systemAbility, method: .get, payload: ["ability": [:]])
    }

    public static func getLight(channel: Int = 0) -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.controlLight, method: .get, payload: ["light": ["channel": .int(channel)]])
    }

    /// `Appliance.Control.ToggleX` SET `{"togglex": {"channel": c, "onoff": 0|1}}`.
    public static func toggleX(on: Bool, channel: Int = 0) -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.controlToggleX, method: .set,
                      payload: ["togglex": ["channel": .int(channel), "onoff": .int(on ? 1 : 0)]])
    }

    /// Legacy `Appliance.Control.Toggle` SET `{"channel": c, "toggle": {"channel": c, "onoff": 0|1}}`.
    public static func toggle(on: Bool, channel: Int = 0) -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.controlToggle, method: .set,
                      payload: ["channel": .int(channel), "toggle": ["channel": .int(channel), "onoff": .int(on ? 1 : 0)]])
    }

    /// `Appliance.Control.Light` SET `{"light": {...}}`.
    public static func setLight(_ light: MerossLightPayload) -> MerossRequest {
        MerossRequest(namespace: MerossNamespace.controlLight, method: .set, payload: ["light": light.json])
    }
}

/// A parsed device answer (or push).
public struct MerossResponse: Sendable, Hashable {
    public var namespace: String
    public var method: MerossMethod?
    public var messageId: String?
    public var timestamp: Int?
    public var sign: String?
    /// `header.uuid` if present, else the uuid in `from` (`/appliance/<uuid>/publish`).
    public var uuid: String?
    public var payload: MerossJSON

    public init(namespace: String, method: MerossMethod?, messageId: String? = nil, timestamp: Int? = nil,
                sign: String? = nil, uuid: String? = nil, payload: MerossJSON) {
        self.namespace = namespace
        self.method = method
        self.messageId = messageId
        self.timestamp = timestamp
        self.sign = sign
        self.uuid = uuid
        self.payload = payload
    }

    public static func parse(_ data: Data) throws -> MerossResponse {
        let json: MerossJSON
        do {
            json = try MerossJSON.decode(data)
        } catch {
            throw MerossDeviceError.malformed("not JSON")
        }
        guard let header = json["header"], let namespace = header["namespace"]?.stringValue else {
            throw MerossDeviceError.malformed("missing header.namespace")
        }
        var uuid = header["uuid"]?.stringValue
        if uuid == nil, let from = header["from"]?.stringValue {
            uuid = Self.uuid(fromTopic: from)
        }
        return MerossResponse(
            namespace: namespace, method: header["method"]?.stringValue.flatMap(MerossMethod.init(rawValue:)),
            messageId: header["messageId"]?.stringValue, timestamp: header["timestamp"]?.intValue,
            sign: header["sign"]?.stringValue, uuid: uuid, payload: json["payload"] ?? .null)
    }

    /// `/appliance/<uuid>/publish` -> `<uuid>`.
    static func uuid(fromTopic topic: String) -> String? {
        let parts = topic.split(separator: "/")
        guard parts.count >= 2, parts[0] == "appliance" else { return nil }
        return String(parts[1])
    }

    /// Throws for `method == ERROR` (invalid key -> `.invalidKey`).
    @discardableResult
    public func checked() throws -> MerossResponse {
        guard method == .error else { return self }
        let code = payload["error"]?["code"]?.intValue
        if code == MerossConstants.errorInvalidKey { throw MerossDeviceError.invalidKey }
        throw MerossDeviceError.deviceError(code: code, detail: payload["error"]?["detail"]?.stringValue)
    }

    /// Whether the reply was signed with `key` (devices sign their answers the same way).
    public func isSigned(with key: String) -> Bool {
        guard let messageId, let timestamp, let sign else { return false }
        return MerossRequest.signature(messageId: messageId, key: key, timestamp: timestamp) == sign
    }
}

public enum MerossDeviceError: Error, Sendable, Equatable, LocalizedError {
    /// `payload.error.code == 5001`: the device key does not match.
    case invalidKey
    case deviceError(code: Int?, detail: String?)
    case malformed(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The Meross device rejected the key (sign in again or re-enter the key)"
        case .deviceError(let code, let detail): "Meross device error \(code.map(String.init) ?? "?")\(detail.map { ": \($0)" } ?? "")"
        case .malformed(let s): "Unexpected Meross reply: \(s)"
        case .http(let status): "Meross device answered HTTP \(status)"
        }
    }
}
