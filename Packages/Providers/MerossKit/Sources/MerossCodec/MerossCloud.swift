import Foundation

/// Meross cloud regions (meross_lan `cloudapi.API_URL_MAP`). Login redirects (apiStatus 1030)
/// to the account's home domain, which is then used for every other call.
public enum MerossRegion: String, Sendable, Hashable, Codable, CaseIterable {
    case us
    case eu
    case ap

    public var baseURL: URL {
        switch self {
        case .us: URL(string: "https://iotx-us.meross.com")!
        case .eu: URL(string: "https://iotx-eu.meross.com")!
        case .ap: URL(string: "https://iotx-ap.meross.com")!
        }
    }

    public var displayName: String {
        switch self {
        case .us: "Americas"
        case .eu: "Europe"
        case .ap: "Asia-Pacific"
        }
    }
}

/// A cloud request: always `POST <base><path>` with a JSON body (`MerossCloudAPI.signedBody`).
public struct MerossCloudRequest: Sendable, Hashable {
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(path: String, headers: [String: String], body: Data) {
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func url(baseURL: URL) -> URL? { URL(string: baseURL.absoluteString.trimmingSuffix("/") + path) }
}

/// What `/v1/Auth/signIn` returns. `key` signs every local message; `token` authorizes cloud calls.
public struct MerossCredentials: Sendable, Hashable, Codable {
    public var userId: String
    public var email: String
    public var key: String
    public var token: String
    /// Account home API domain, e.g. `https://iotx-eu.meross.com`.
    public var domain: String?
    public var mqttDomain: String?

    public init(userId: String, email: String, key: String, token: String, domain: String? = nil, mqttDomain: String? = nil) {
        self.userId = userId
        self.email = email
        self.key = key
        self.token = token
        self.domain = domain
        self.mqttDomain = mqttDomain
    }
}

/// One entry of `/v1/Device/devList` (MerossIot `HttpDeviceInfo`).
public struct MerossCloudDevice: Sendable, Hashable, Codable {
    public var uuid: String
    public var name: String
    public var deviceType: String
    public var subType: String?
    /// 0 never online, 1 online, 2 offline, 3 upgrading (cloud view).
    public var onlineStatus: Int?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    public var region: String?

    public init(uuid: String, name: String, deviceType: String, subType: String? = nil, onlineStatus: Int? = nil,
                firmwareVersion: String? = nil, hardwareVersion: String? = nil, region: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.deviceType = deviceType
        self.subType = subType
        self.onlineStatus = onlineStatus
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.region = region
    }

    init?(json: MerossJSON) {
        guard let uuid = json["uuid"]?.stringValue, !uuid.isEmpty else { return nil }
        self.uuid = uuid
        name = json["devName"]?.stringValue ?? "Meross \(json["deviceType"]?.stringValue ?? "device")"
        deviceType = json["deviceType"]?.stringValue ?? ""
        subType = json["subType"]?.stringValue
        onlineStatus = json["onlineStatus"]?.intValue
        firmwareVersion = json["fmwareVersion"]?.stringValue
        hardwareVersion = json["hdwareVersion"]?.stringValue
        region = json["region"]?.stringValue
    }
}

/// Cloud `apiStatus` errors (MerossIot `ErrorCodes`, meross_lan `APISTATUS_*`).
public enum MerossCloudError: Error, Sendable, Equatable, LocalizedError {
    case wrongCredentials(Int)
    /// 1030: the account lives on another domain.
    case redirect(domain: String)
    case mfaRequired
    case wrongMFA
    /// 1019/1022/1200/1003/1301: sign in again (LAN control keeps working with the stored key).
    case tokenInvalid(Int)
    /// 1028/1042: too many requests; Meross may lock the account if this repeats.
    case rateLimited(Int)
    case api(Int, String?)
    case http(Int)
    case malformed(String)

    public static let tokenErrorCodes: Set<Int> = [1003, 1019, 1022, 1200, 1301]

    public static func classify(apiStatus: Int, data: MerossJSON?, info: String?) -> MerossCloudError {
        switch apiStatus {
        case 1000, 1001, 1002, 1004, 1005, 1006, 1008: .wrongCredentials(apiStatus)
        case 1030: .redirect(domain: data?["domain"]?.stringValue ?? "")
        case 1033: .mfaRequired
        case 1032: .wrongMFA
        case 1028, 1042: .rateLimited(apiStatus)
        case _ where tokenErrorCodes.contains(apiStatus): .tokenInvalid(apiStatus)
        default: .api(apiStatus, info)
        }
    }

    public var requiresReauthentication: Bool {
        if case .tokenInvalid = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .wrongCredentials: "Wrong Meross e-mail or password"
        case .redirect(let d): "Meross account is served by \(d)"
        case .mfaRequired: "Meross asks for the two-factor code"
        case .wrongMFA: "Wrong two-factor code"
        case .tokenInvalid(let c): "Meross sign-in expired (\(c))"
        case .rateLimited(let c): "Meross is rate limiting this account (\(c)); wait before trying again"
        case .api(let c, let info): "Meross cloud error \(c)\(info.map { ": \($0)" } ?? "")"
        case .http(let s): "Meross cloud answered HTTP \(s)"
        case .malformed(let s): "Unexpected Meross cloud reply: \(s)"
        }
    }
}

/// Cloud API (`/v1/Auth/signIn`, `/v1/Device/devList`, `/v1/Profile/Logout`).
///
/// Body: `{"params": base64(json(params)), "sign": md5(SECRET + timestamp + nonce + params), "timestamp": ms, "nonce": n}`.
/// Header `Authorization: Basic <token>` for authenticated calls ("Basic" alone for sign-in).
public enum MerossCloudAPI {
    /// Constant salt shared by MerossIot and meross_lan.
    public static let secret = "23x17ahWarFH6w29"
    public static let signInPath = "/v1/Auth/signIn"
    public static let deviceListPath = "/v1/Device/devList"
    public static let logoutPath = "/v1/Profile/Logout"
    public static let appType = "MerossIOT"
    public static let appVersion = "0.4.10.4"

    /// The signed envelope. `timestamp` is in milliseconds.
    public static func signedBody(params: MerossJSON, timestamp: Int, nonce: String) -> Data {
        let encodedParams = params.encoded().base64EncodedString()
        let sign = MerossCrypto.md5Hex(secret + String(timestamp) + nonce + encodedParams)
        return MerossJSON.object([
            "params": .string(encodedParams),
            "sign": .string(sign),
            "timestamp": .int(timestamp),
            "nonce": .string(nonce),
        ]).encoded()
    }

    /// 16 uppercase alphanumerics (MerossIot `_generate_nonce`).
    public static func newNonce() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet.randomElement(using: &g)! })
    }

    public static func headers(token: String?) -> [String: String] {
        [
            "Authorization": token.map { "Basic \($0)" } ?? "Basic",
            "vender": "meross",
            "AppType": appType,
            "AppVersion": appVersion,
            "AppLanguage": "EN",
            "Content-Type": "application/json",
        ]
    }

    /// `/v1/Auth/signIn` with `password = md5(password)`, `encryption: 1`.
    public static func signIn(email: String, password: String, region: MerossRegion, mfaCode: String? = nil,
                              timestamp: Int = nowMillis(), nonce: String = newNonce()) -> MerossCloudRequest {
        var params: [String: MerossJSON] = [
            "email": .string(email),
            "password": .string(MerossCrypto.md5Hex(password)),
            "accountCountryCode": .string(region.rawValue),
            "encryption": 1,
            "agree": 0,
        ]
        if let mfaCode, !mfaCode.isEmpty { params["mfaCode"] = .string(mfaCode) }
        return MerossCloudRequest(path: signInPath, headers: headers(token: nil),
                                  body: signedBody(params: .object(params), timestamp: timestamp, nonce: nonce))
    }

    public static func deviceList(token: String, timestamp: Int = nowMillis(), nonce: String = newNonce()) -> MerossCloudRequest {
        MerossCloudRequest(path: deviceListPath, headers: headers(token: token),
                           body: signedBody(params: [:], timestamp: timestamp, nonce: nonce))
    }

    public static func logout(token: String, timestamp: Int = nowMillis(), nonce: String = newNonce()) -> MerossCloudRequest {
        MerossCloudRequest(path: logoutPath, headers: headers(token: token),
                           body: signedBody(params: [:], timestamp: timestamp, nonce: nonce))
    }

    public static func nowMillis() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded()) }

    // MARK: Decoding

    /// Returns `data` for `apiStatus == 0`, throws `MerossCloudError` otherwise.
    public static func decode(status: Int, body: Data) throws -> MerossJSON {
        guard (200..<300).contains(status) else { throw MerossCloudError.http(status) }
        guard let json = try? MerossJSON.decode(body), json.objectValue != nil else {
            throw MerossCloudError.malformed("not a JSON object")
        }
        let apiStatus = json["apiStatus"]?.intValue ?? 0
        if apiStatus != 0 {
            throw MerossCloudError.classify(apiStatus: apiStatus, data: json["data"], info: json["info"]?.stringValue)
        }
        guard let data = json["data"] else { throw MerossCloudError.malformed("missing data") }
        return data
    }

    public static func decodeSignIn(status: Int, body: Data) throws -> MerossCredentials {
        let data = try decode(status: status, body: body)
        func field(_ name: String) throws -> String {
            guard let v = data[name]?.stringValue, !v.isEmpty else { throw MerossCloudError.malformed("missing \(name)") }
            return v
        }
        return MerossCredentials(userId: try field("userid"), email: try field("email"), key: try field("key"),
                                 token: try field("token"), domain: data["domain"]?.stringValue,
                                 mqttDomain: data["mqttDomain"]?.stringValue)
    }

    public static func decodeDeviceList(status: Int, body: Data) throws -> [MerossCloudDevice] {
        let data = try decode(status: status, body: body)
        guard let list = data.arrayValue else { throw MerossCloudError.malformed("devList is not an array") }
        return list.compactMap(MerossCloudDevice.init(json:))
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
