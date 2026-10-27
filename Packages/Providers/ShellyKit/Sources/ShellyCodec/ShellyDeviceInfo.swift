import Foundation

/// Identity of a Shelly device from `GET /shelly` (both generations, never needs auth) or the
/// Gen2+ `Shelly.GetDeviceInfo` result.
///
/// Gen1: `{"type":"SHBDUO-1","mac":"A4CF12F3F1B2","auth":true,"fw":"20230913-114008/v1.14.0-gcb84623"}`
/// Gen2+: `{"id":"shellyplusrgbwpm-a0a3b3c4d5e6","mac":"A0A3B3C4D5E6","model":"SNDC-0D4P10WW",
/// "gen":2,"ver":"1.4.4","app":"PlusRGBWPM","auth_en":true,"auth_domain":"shellyplusrgbwpm-a0a3b3c4d5e6"}`
public struct ShellyDeviceInfo: Sendable, Hashable, Codable {
    /// 12 lowercase hex digits: the stable id.
    public var mac: String
    /// 1, 2, 3, 4... Gen2 and later speak JSON-RPC.
    public var generation: Int
    /// Gen1 `type` ("SHBDUO-1") or Gen2+ `model` ("SNDC-0D4P10WW").
    public var model: String
    /// Gen2+ `app` ("PlusRGBWPM").
    public var app: String?
    /// Gen2+ device id ("shellyplusrgbwpm-a0a3b3c4d5e6").
    public var deviceID: String?
    public var name: String?
    public var firmware: String?
    /// A password is set (Gen1 `auth`, Gen2+ `auth_en`).
    public var authRequired: Bool
    /// Gen2+ digest realm (`auth_domain`, defaults to the device id).
    public var authDomain: String?

    public init(
        mac: String, generation: Int, model: String, app: String? = nil, deviceID: String? = nil, name: String? = nil,
        firmware: String? = nil, authRequired: Bool = false, authDomain: String? = nil
    ) {
        self.mac = mac
        self.generation = generation
        self.model = model
        self.app = app
        self.deviceID = deviceID
        self.name = name
        self.firmware = firmware
        self.authRequired = authRequired
        self.authDomain = authDomain
    }

    public var usesRPC: Bool { generation >= 2 }

    /// Display model ("Shelly Duo (SHBDUO-1)", "Shelly PlusRGBWPM").
    public var displayModel: String {
        if let known = ShellyDeviceInfo.gen1Names[model] { return "\(known) (\(model))" }
        if let app { return "Shelly \(app)" }
        return "Shelly \(model)"
    }

    /// Parses `/shelly` (or `Shelly.GetDeviceInfo`) JSON.
    public static func parse(_ json: ShellyJSON) -> ShellyDeviceInfo? {
        guard let rawMAC = json["mac"]?.string, let mac = normalizeMAC(rawMAC) else { return nil }
        if let gen = json["gen"]?.int, gen >= 2 {
            let id = json["id"]?.string
            return ShellyDeviceInfo(
                mac: mac, generation: gen, model: json["model"]?.string ?? json["app"]?.string ?? "unknown",
                app: json["app"]?.string, deviceID: id, name: json["name"]?.string, firmware: json["ver"]?.string,
                authRequired: json["auth_en"]?.bool ?? false, authDomain: json["auth_domain"]?.string ?? id
            )
        }
        guard let type = json["type"]?.string else { return nil }
        return ShellyDeviceInfo(mac: mac, generation: 1, model: type, firmware: json["fw"]?.string,
                                authRequired: json["auth"]?.bool ?? false)
    }

    public static func parse(_ data: Data) -> ShellyDeviceInfo? {
        (try? ShellyJSON.parse(data)).flatMap(parse)
    }

    /// `A4CF12F3F1B2` / `a4:cf:12:f3:f1:b2` -> `a4cf12f3f1b2`.
    public static func normalizeMAC(_ s: String) -> String? {
        let hex = s.lowercased().filter { $0 != ":" && $0 != "-" }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// A Bonjour/mDNS instance name that belongs to a Shelly (`shellyduo-A4CF12F3F1B2`,
    /// `ShellyBulbDuo-F3F1B2`, `shellyplusrgbwpm-a0a3b3c4d5e6`). Used to filter `_http._tcp`.
    public static func isShellyServiceName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("shelly")
    }

    /// Gen1 light models SmartLights maps (types from Shelly's Gen1 API docs / aioshelly).
    public static let gen1Names: [String: String] = [
        "SHBDUO-1": "Shelly Duo",
        "SHVIN-1": "Shelly Vintage",
        "SHBLB-1": "Shelly Bulb",
        "SHCB-1": "Shelly Duo RGBW",
        "SHRGBW2": "Shelly RGBW2",
        "SHDM-1": "Shelly Dimmer",
        "SHDM-2": "Shelly Dimmer 2",
    ]
}
