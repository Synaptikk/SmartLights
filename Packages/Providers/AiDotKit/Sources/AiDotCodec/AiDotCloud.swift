import Foundation

/// Protocol constants (python-aidot 0.3.59 `login_const.py`, `const.py`, `discover.py`, `device_client.py`).
public enum AiDotConstants {
    public static let appId = "1383974540041977857"
    /// `terminalId` raw value python-aidot falls back to when it cannot persist a machine id.
    public static let fallbackTerminalRawId = "gvz3gjae10l4zii00t7y0"
    public static let webVersion = "0.5.0"
    public static let area = "Asia/Shanghai"
    public static let utc = "UTC+8"
    public static let discoveryPort: UInt16 = 6666
    public static let tcpPort: UInt16 = 10000
    /// First-generation RGBW bulb that needs `getDevAttrReq` as keepalive every 10 s.
    public static let firstGenerationModel = "lk.WIFI-RGBWLight-D0006"
    /// Attributes polled for the first-generation model (`syncProperties`).
    public static let firstGenerationSyncProperties = ["OnOff", "Dimming", "RGBW", "CCT"]
    public static let pingInterval: Duration = .seconds(30)
    public static let firstGenerationPingInterval: Duration = .seconds(10)
    /// Missed keepalives before the session is reset (python: `ping_count >= 3`).
    public static let maxMissedPings = 3
    /// Discovery repeat schedule: 5 fast rounds every 6 s, then every 120 s.
    public static let discoveryFastInterval: Duration = .seconds(6)
    public static let discoveryFastRounds = 5
    public static let discoverySlowInterval: Duration = .seconds(120)
    /// Cloud device list refresh period (HA integration re-checks every 6 h).
    public static let deviceListRefreshInterval: Duration = .seconds(6 * 3600)
}

/// Server error codes (python-aidot `ServerErrorCode` + codes handled inline in `client.py`).
public enum AiDotServerCode {
    public static let tokenExpired = 21026
    public static let loginInvalid = 21025
    public static let userPasswordIncorrect = 560080
    /// Treated as authentication failure by `async_session_get/post`.
    public static let authFailureCodes: Set<Int> = [21025, 21027, 21041]
}

// MARK: - Errors

/// Cloud errors. Messages never contain credentials or tokens.
public enum AiDotCloudError: Error, Sendable, Equatable, LocalizedError {
    /// 21026: access token expired; refresh with `/users/refreshToken`.
    case tokenExpired
    /// 21025: session invalid (refresh failed, or another login invalidated it).
    case loginInvalid
    /// 560080: wrong username or password.
    case badCredentials
    /// 21027 / 21041 or another auth rejection.
    case authenticationFailed(code: Int)
    /// Any other non-2xx answer.
    case server(status: Int, code: Int?, message: String?)
    case malformedResponse(String)

    /// Maps an HTTP status + JSON body to an error, or `nil` for a successful response.
    /// Known auth codes are honoured even on 2xx; other codes only on HTTP >= 400 (as python-aidot,
    /// which inspects `code` only after `raise_for_status`).
    public static func classify(status: Int, body: Data) -> AiDotCloudError? {
        let json = try? AiDotJSON.parse(body)
        let code = json?["code"]?.intValue
        let message = json?["desc"]?.looseString ?? json?["message"]?.looseString ?? json?["msg"]?.looseString
        let isError = status >= 400 || status < 200
        switch code {
        case AiDotServerCode.tokenExpired?: return .tokenExpired
        case AiDotServerCode.loginInvalid?: return .loginInvalid
        case AiDotServerCode.userPasswordIncorrect?: return .badCredentials
        case let c? where AiDotServerCode.authFailureCodes.contains(c): return .authenticationFailed(code: c)
        default:
            guard isError else { return nil }
            if status == 401 || status == 403 { return .authenticationFailed(code: code ?? status) }
            return .server(status: status, code: code, message: message.map { String($0.prefix(200)) })
        }
    }

    /// Whether the user has to sign in again (no refresh possible).
    public var requiresReauthentication: Bool {
        switch self {
        case .loginInvalid, .badCredentials, .authenticationFailed: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .tokenExpired: "AiDot session expired"
        case .loginInvalid: "AiDot signed you out (another sign-in with this account may have replaced this one). Sign in again."
        case .badCredentials: "Wrong AiDot e-mail or password"
        case .authenticationFailed(let code): "AiDot rejected the sign-in (code \(code))"
        case .server(let status, let code, let message):
            "AiDot cloud error HTTP \(status)\(code.map { " code \($0)" } ?? "")\(message.map { ": \($0)" } ?? "")"
        case .malformedResponse(let what): "Unexpected AiDot cloud response: \(what)"
        }
    }
}

// MARK: - Requests

/// A transport-neutral HTTP request.
public struct AiDotHTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path below the `/v35` base, including any query (`/devices?houseId=...`).
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Absolute URL below `baseURL` (e.g. `https://prod-us-api.arnoo.com/v35`).
    public func url(baseURL: URL) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }
}

/// Builders for the cloud calls python-aidot makes (`client.py`).
public enum AiDotAPI {
    /// `{Appid, Terminal: app}` plus `Token` when signed in. No Authorization header.
    public static func headers(token: String? = nil) -> [String: String] {
        var h = ["Appid": AiDotConstants.appId, "Terminal": "app"]
        if let token { h["Token"] = token }
        return h
    }

    private static func jsonHeaders(token: String? = nil) -> [String: String] {
        var h = headers(token: token)
        h["Content-Type"] = "application/json"
        return h
    }

    /// Login body in python-aidot field order.
    public static func loginBody(country: AiDotCountry, username: String, encryptedPassword: String, terminalId: String) -> AiDotJSON {
        .obj([
            "countryKey": .string(country.countryKey),
            "username": .string(username),
            "password": .string(encryptedPassword),
            "terminalId": .string(terminalId),
            "webVersion": .string(AiDotConstants.webVersion),
            "area": .string(AiDotConstants.area),
            "UTC": .string(AiDotConstants.utc),
        ])
    }

    /// `POST /users/loginWithFreeVerification`. `encryptedPassword` from `AiDotCrypto.encryptPassword`.
    public static func login(country: AiDotCountry, username: String, encryptedPassword: String, terminalId: String) -> AiDotHTTPRequest {
        let body = loginBody(country: country, username: username, encryptedPassword: encryptedPassword, terminalId: terminalId)
        return AiDotHTTPRequest(method: "POST", path: "/users/loginWithFreeVerification", headers: jsonHeaders(), body: body.pythonData)
    }

    /// `POST /users/refreshToken` with `{refreshToken}`.
    public static func refreshToken(_ refreshToken: String) -> AiDotHTTPRequest {
        AiDotHTTPRequest(method: "POST", path: "/users/refreshToken", headers: jsonHeaders(),
                         body: AiDotJSON.obj(["refreshToken": .string(refreshToken)]).pythonData)
    }

    /// `GET /houses`.
    public static func houses(token: String) -> AiDotHTTPRequest {
        AiDotHTTPRequest(method: "GET", path: "/houses", headers: headers(token: token))
    }

    /// `GET /devices?houseId=<id>`.
    public static func devices(houseId: String, token: String) -> AiDotHTTPRequest {
        AiDotHTTPRequest(method: "GET", path: "/devices?houseId=\(escape(houseId))", headers: headers(token: token))
    }

    /// `GET /products/<id1,id2,...>` (python joins every device's productId, duplicates included).
    public static func products(ids: [String], token: String) -> AiDotHTTPRequest {
        AiDotHTTPRequest(method: "GET", path: "/products/\(ids.map(escape).joined(separator: ","))", headers: headers(token: token))
    }

    /// `terminalId`: md5 hex of a per-install random id.
    public static func terminalId(rawId: String) -> String { AiDotCrypto.md5Hex(rawId) }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Response decoding

    /// Throws ``AiDotCloudError`` for error responses, otherwise parses the body.
    public static func checkedJSON(status: Int, body: Data) throws -> AiDotJSON {
        if let error = AiDotCloudError.classify(status: status, body: body) { throw error }
        do {
            return try AiDotJSON.parse(body)
        } catch {
            throw AiDotCloudError.malformedResponse("invalid JSON (HTTP \(status))")
        }
    }

    public static func decodeLogin(status: Int, body: Data) throws -> AiDotLoginResponse {
        let json = try checkedJSON(status: status, body: body)
        guard let r = AiDotLoginResponse(json: json) else { throw AiDotCloudError.malformedResponse("login without id/accessToken") }
        return r
    }

    public static func decodeRefresh(status: Int, body: Data) throws -> AiDotTokenPair {
        let json = try checkedJSON(status: status, body: body)
        guard let access = json["accessToken"]?.stringValue, !access.isEmpty else {
            throw AiDotCloudError.malformedResponse("refresh without accessToken")
        }
        return AiDotTokenPair(accessToken: access, refreshToken: json["refreshToken"]?.stringValue)
    }

    public static func decodeHouses(status: Int, body: Data) throws -> [AiDotHouse] {
        let json = try checkedJSON(status: status, body: body)
        guard let items = json.arrayValue else { throw AiDotCloudError.malformedResponse("houses is not a list") }
        return items.compactMap(AiDotHouse.init(json:))
    }

    public static func decodeDevices(status: Int, body: Data) throws -> [AiDotDeviceRecord] {
        let json = try checkedJSON(status: status, body: body)
        if json.isNull { return [] }
        guard let items = json.arrayValue else { throw AiDotCloudError.malformedResponse("devices is not a list") }
        return items.compactMap(AiDotDeviceRecord.init(json:))
    }

    public static func decodeProducts(status: Int, body: Data) throws -> [AiDotProduct] {
        let json = try checkedJSON(status: status, body: body)
        guard let items = json.arrayValue else { throw AiDotCloudError.malformedResponse("products is not a list") }
        return items.compactMap(AiDotProduct.init(json:))
    }

    /// python-aidot `async_get_all_device`: owner houses only, products attached by `productId`.
    public static func ownedHouses(_ houses: [AiDotHouse]) -> [AiDotHouse] {
        houses.filter { $0.isOwner != false }
    }

    public static func attachProducts(_ products: [AiDotProduct], to devices: [AiDotDeviceRecord]) -> [AiDotDeviceRecord] {
        devices.map { device in
            var d = device
            if let p = products.first(where: { $0.id == device.productId }) { d.product = p }
            return d
        }
    }
}

// MARK: - Models

public struct AiDotTokenPair: Sendable, Equatable {
    public var accessToken: String
    /// `nil` when the server did not rotate it.
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Fields of the login response the app uses. Never log the tokens.
public struct AiDotLoginResponse: Sendable, Equatable {
    /// `id`: the userId used in LAN `loginReq` and `srcAddr`.
    public var userId: String
    public var accessToken: String
    public var refreshToken: String
    public var username: String?

    public init(userId: String, accessToken: String, refreshToken: String, username: String? = nil) {
        self.userId = userId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.username = username
    }

    public init?(json: AiDotJSON) {
        guard let id = json["id"]?.looseString, !id.isEmpty,
              let access = json["accessToken"]?.stringValue, !access.isEmpty else { return nil }
        self.userId = id
        self.accessToken = access
        self.refreshToken = json["refreshToken"]?.stringValue ?? ""
        self.username = json["username"]?.stringValue
    }
}

public struct AiDotHouse: Sendable, Equatable {
    public var id: String
    public var name: String?
    /// `false` for houses shared with the user; python-aidot skips those (the devices only accept
    /// the owner's userId on the LAN).
    public var isOwner: Bool?
    public var isDefault: Bool?

    public init(id: String, name: String? = nil, isOwner: Bool? = nil, isDefault: Bool? = nil) {
        self.id = id
        self.name = name
        self.isOwner = isOwner
        self.isDefault = isDefault
    }

    public init?(json: AiDotJSON) {
        guard let id = json["id"]?.looseString else { return nil }
        self.init(id: id, name: json["name"]?.stringValue, isOwner: json["isOwner"]?.boolValue, isDefault: json["isDefault"]?.boolValue)
    }
}

/// `serviceModules[]` entry of a product.
public struct AiDotServiceModule: Sendable, Equatable {
    public struct Property: Sendable, Equatable {
        public var identifier: String?
        public var minValue: Int?
        public var maxValue: Int?
        public init(identifier: String? = nil, minValue: Int? = nil, maxValue: Int? = nil) {
            self.identifier = identifier
            self.minValue = minValue
            self.maxValue = maxValue
        }
    }

    /// e.g. `control.light.rgbw`, `control.light.cct`.
    public var identity: String
    public var properties: [Property]

    public init(identity: String, properties: [Property] = []) {
        self.identity = identity
        self.properties = properties
    }

    public static let rgbwIdentity = "control.light.rgbw"
    public static let cctIdentity = "control.light.cct"
}

public struct AiDotProduct: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var type: String?
    public var modelId: String?
    public var isDirectDevice: Int?
    public var serviceModules: [AiDotServiceModule]
    public var raw: AiDotJSON

    public init?(json: AiDotJSON) {
        guard let id = json["id"]?.looseString else { return nil }
        self.id = id
        self.name = json["name"]?.stringValue
        self.type = json["type"]?.stringValue
        self.modelId = json["modelId"]?.stringValue
        self.isDirectDevice = json["isDirectDevice"]?.intValue
        self.serviceModules = (json["serviceModules"]?.arrayValue ?? []).compactMap { m in
            guard let identity = m["identity"]?.stringValue else { return nil }
            let props = (m["properties"]?.arrayValue ?? []).map {
                AiDotServiceModule.Property(identifier: $0["identifier"]?.stringValue, minValue: $0["minValue"]?.intValue,
                                            maxValue: $0["maxValue"]?.intValue)
            }
            return AiDotServiceModule(identity: identity, properties: props)
        }
        self.raw = json
    }
}

/// A device record from `GET /devices` (python-aidot `models/device_model.DeviceInformation`).
/// Contains secrets (`aesKey`, `password`): keep in memory or the Keychain only.
public struct AiDotDeviceRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var mac: String?
    public var type: String?
    public var modelId: String?
    public var productId: String?
    public var houseId: String?
    public var roomId: String?
    public var online: Bool?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    public var protocolVersion: String?
    /// `aesKey[0]` is the LAN session key.
    public var aesKey: [String?]
    /// Device password sent in `loginReq` / full `setDevAttrReq` payloads.
    public var password: String?
    /// When present python-aidot sends the full action payload (devId, userId, password...).
    public var simpleVersion: String?
    /// `properties`: `ipAddress`, `macAddress`, `OnOff`, `Dimming`, `CCT`, `RGBW`, ...
    public var properties: AiDotJSON
    public var product: AiDotProduct?

    public init?(json: AiDotJSON) {
        guard let id = json["id"]?.looseString, !id.isEmpty else { return nil }
        self.id = id
        self.name = json["name"]?.stringValue ?? id
        self.mac = json["mac"]?.stringValue
        self.type = json["type"]?.stringValue
        self.modelId = json["modelId"]?.stringValue
        self.productId = json["productId"]?.looseString
        self.houseId = json["houseId"]?.looseString
        self.roomId = json["roomId"]?.looseString
        self.online = json["online"]?.boolValue
        self.firmwareVersion = json["firmwareVersion"]?.looseString
        self.hardwareVersion = json["hardwareVersion"]?.looseString
        self.protocolVersion = json["protocolVersion"]?.looseString
        self.aesKey = (json["aesKey"]?.arrayValue ?? []).map { $0.stringValue }
        self.password = json["password"]?.stringValue
        if let sv = json["simpleVersion"], !sv.isNull { self.simpleVersion = sv.looseString ?? "" } else { self.simpleVersion = nil }
        self.properties = json["properties"] ?? .null
        self.product = json["product"].flatMap(AiDotProduct.init(json:))
    }

    /// The session key string (`aesKey[0]`), if present.
    public var sessionKey: String? { aesKey.first ?? nil }

    /// python-aidot / HA create LAN lights only for `type == "light"` with a non-null `aesKey[0]`.
    public var isLANLight: Bool { type == "light" && sessionKey != nil }

    public var isFirstGeneration: Bool { modelId == AiDotConstants.firstGenerationModel }

    /// Cloud-reported LAN IP (`properties.ipAddress`), validated as dotted IPv4.
    public var cloudIPAddress: String? {
        guard let ip = properties["ipAddress"]?.stringValue else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return ip
    }

    /// Re-serialises the record (with the attached product) for the Keychain-backed cache.
    public var json: AiDotJSON {
        var members: [AiDotJSON.Member] = [
            .init("id", .string(id)), .init("name", .string(name)),
        ]
        func add(_ k: String, _ v: String?) { if let v { members.append(.init(k, .string(v))) } }
        add("mac", mac); add("type", type); add("modelId", modelId); add("productId", productId)
        add("houseId", houseId); add("roomId", roomId)
        if let online { members.append(.init("online", .bool(online))) }
        add("firmwareVersion", firmwareVersion); add("hardwareVersion", hardwareVersion); add("protocolVersion", protocolVersion)
        members.append(.init("aesKey", .array(aesKey.map { $0.map(AiDotJSON.string) ?? .null })))
        add("password", password)
        add("simpleVersion", simpleVersion)
        members.append(.init("properties", properties))
        if let product { members.append(.init("product", product.raw)) }
        return .object(members)
    }
}
