import Foundation

// v1 endpoints still needed with CLIP v2: link-button pairing (`POST /api`) and the
// unauthenticated `GET /api/config` identity probe. Plus the discovery.meethue.com broker.

/// Body of `POST /api` (pairing).
public struct HuePairingRequest: Codable, Sendable, Hashable {
    /// `<app>#<device>`, e.g. `SmartLights#iphone` (max 40 chars per the v1 docs).
    public var devicetype: String
    /// Ask for the Entertainment PSK (`clientkey`) as well.
    public var generateclientkey: Bool

    public init(devicetype: String = "SmartLights#iphone", generateclientkey: Bool = true) {
        self.devicetype = devicetype
        self.generateclientkey = generateclientkey
    }
}

/// Outcome of one `POST /api` attempt.
public enum HuePairingResult: Sendable, Hashable {
    /// `username` is the application key (`hue-application-key`); `clientKey` is the 32-hex
    /// Entertainment PSK (present when `generateclientkey` was true).
    case success(username: String, clientKey: String?)
    /// v1 error 101: the round link button has not been pressed (keep polling).
    case linkButtonNotPressed
    /// Any other v1 error.
    case error(type: Int, description: String)
}

public enum HuePairing {
    /// v1 error type for "link button not pressed".
    public static let linkButtonErrorType = 101

    /// Parses `[{"success":{"username":..,"clientkey":..}}]` or `[{"error":{"type":101,..}}]`.
    public static func parse(_ data: Data) throws -> HuePairingResult {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HueError.invalidResponse("pairing response is not JSON")
        }
        let entries: [JSONValue]
        switch value {
        case .array(let items): entries = items
        case .object: entries = [value]
        default: throw HueError.invalidResponse("unexpected pairing response")
        }
        // A success anywhere wins; otherwise report the first error.
        for entry in entries {
            if let success = entry["success"], let username = success["username"]?.stringValue, !username.isEmpty {
                return .success(username: username, clientKey: success["clientkey"]?.stringValue)
            }
        }
        for entry in entries {
            if let error = entry["error"] {
                let type: Int
                switch error["type"] {
                case .int(let t): type = t
                case .double(let d): type = Int(d)
                case .string(let s): type = Int(s) ?? -1
                default: type = -1
                }
                if type == linkButtonErrorType { return .linkButtonNotPressed }
                return .error(type: type, description: error["description"]?.stringValue ?? "")
            }
        }
        throw HueError.invalidResponse("pairing response has neither success nor error")
    }
}

/// `GET /api/config` (no auth). All fields optional; `bridgeid` is what we key on.
public struct HueBridgeConfig: Codable, Sendable, Hashable {
    public var name: String?
    /// 16 hex chars, e.g. `001788FFFE23ABCD`.
    public var bridgeid: String?
    /// `BSB002` (Hue Bridge v2, square) or `BSB003` (Hue Bridge Pro); `BSB001` = v1 round bridge.
    public var modelid: String?
    public var swversion: String?
    public var apiversion: String?
    public var mac: String?
    public var datastoreversion: String?
    public var factorynew: Bool?

    public init(
        name: String? = nil, bridgeid: String? = nil, modelid: String? = nil, swversion: String? = nil,
        apiversion: String? = nil, mac: String? = nil
    ) {
        self.name = name
        self.bridgeid = bridgeid
        self.modelid = modelid
        self.swversion = swversion
        self.apiversion = apiversion
        self.mac = mac
    }

    /// Normalised (upper-case) bridge id, if present and well-formed.
    public var bridgeID: String? { bridgeid.flatMap(HueBridgeID.normalize) }

    public var isBridgePro: Bool { modelid?.uppercased() == "BSB003" }
    /// The original round bridge (no CLIP v2, no updates since 2020).
    public var isLegacyV1Bridge: Bool { modelid?.uppercased() == "BSB001" }

    /// Human-readable model.
    public var modelName: String {
        switch modelid?.uppercased() {
        case "BSB001": "Hue Bridge v1"
        case "BSB002": "Hue Bridge"
        case "BSB003": "Hue Bridge Pro"
        case let other?: other
        case nil: "Hue Bridge"
        }
    }
}

/// One entry of `GET https://discovery.meethue.com/`.
public struct HueDiscoveryEntry: Codable, Sendable, Hashable {
    public var id: String?
    public var internalipaddress: String?
    public var port: Int?

    public init(id: String?, internalipaddress: String?, port: Int? = nil) {
        self.id = id
        self.internalipaddress = internalipaddress
        self.port = port
    }

    public var bridgeID: String? { id.flatMap(HueBridgeID.normalize) }

    /// Parses the broker response leniently (bad entries are dropped).
    public static func parseList(_ data: Data) throws -> [HueDiscoveryEntry] {
        do {
            return try JSONDecoder().decode(LossyArray<HueDiscoveryEntry>.self, from: data).elements
                .filter { $0.internalipaddress?.isEmpty == false }
        } catch {
            throw HueError.invalidResponse("discovery.meethue.com response is not a JSON array")
        }
    }
}

/// Bridge id helpers. Bridge ids are 16 hex chars derived from the Zigbee MAC
/// (`001788FFFExxxxxx`); SmartLights stores them upper-case.
public enum HueBridgeID {
    /// Upper-cased id if it is 16 hex characters, otherwise nil.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 16, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }

    public static func isValid(_ raw: String) -> Bool { normalize(raw) != nil }
}
