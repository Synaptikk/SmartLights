import Crypto
import Foundation
import LightCore

/// The hub's OAuth-style pairing (Leggin/dirigera `hub/auth.py`):
/// 1. `GET /v1/oauth/authorize?audience=homesmart.local&response_type=code&code_challenge=<S256>&code_challenge_method=S256`
///    -> `{"code": "..."}`;
/// 2. the user presses the action button on the bottom of the hub;
/// 3. `POST /v1/oauth/token` (form) `code=..&name=<client name>&grant_type=authorization_code&code_verifier=..`
///    -> `{"access_token": "..."}`. The token does not expire; send it as `Authorization: Bearer`.
public enum DirigeraPKCE {
    /// Verifier alphabet used by Leggin/dirigera (RFC 7636 unreserved characters).
    public static let alphabet = Array("_-~.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    public static let verifierLength = 128

    public static func makeVerifier<G: RandomNumberGenerator>(length: Int = verifierLength, using generator: inout G) -> String {
        String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    public static func makeVerifier(length: Int = verifierLength) -> String {
        var generator = SystemRandomNumberGenerator()
        return makeVerifier(length: length, using: &generator)
    }

    /// `base64url(SHA-256(verifier))` without padding (`code_challenge_method=S256`).
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `GET /v1/oauth/authorize` response.
public struct DirigeraAuthorizeResponse: Codable, Sendable, Hashable {
    public var code: String

    public init(code: String) { self.code = code }
}

/// `POST /v1/oauth/token` response.
public struct DirigeraTokenResponse: Codable, Sendable, Hashable {
    /// Never log.
    public var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }

    public init(accessToken: String) { self.accessToken = accessToken }
}

/// One REST call relative to `https://<hub>:8443`.
public struct DirigeraRequest: Sendable, Hashable, CustomStringConvertible {
    public var method: String
    /// Absolute path, e.g. `/v1/devices`.
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var contentType: String?
    /// Needs `Authorization: Bearer <token>`.
    public var authenticated: Bool

    public init(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil,
                authenticated: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.authenticated = authenticated
    }

    public var description: String { "\(method) \(path)" }
    public var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

/// Endpoints used by SmartLights.
public enum DirigeraAPI {
    public static let defaultPort = 8443
    public static let apiVersion = "v1"
    public static let audience = "homesmart.local"

    public static func authorize(challenge: String) -> DirigeraRequest {
        DirigeraRequest(method: "GET", path: "/v1/oauth/authorize", query: [
            URLQueryItem(name: "audience", value: audience),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ], authenticated: false)
    }

    /// `name` is how the client appears in the hub (Leggin uses the hostname).
    public static func token(code: String, verifier: String, name: String) -> DirigeraRequest {
        let fields = [("code", code), ("name", name), ("grant_type", "authorization_code"), ("code_verifier", verifier)]
        let body = fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
        return DirigeraRequest(method: "POST", path: "/v1/oauth/token", body: Data(body.utf8),
                               contentType: "application/x-www-form-urlencoded", authenticated: false)
    }

    public static let hubStatus = DirigeraRequest(method: "GET", path: "/v1/hub/status")
    /// Unauthenticated variant used as a discovery probe (expect 401 from a hub).
    public static let hubStatusProbe = DirigeraRequest(method: "GET", path: "/v1/hub/status", authenticated: false)
    public static let devices = DirigeraRequest(method: "GET", path: "/v1/devices")
    public static let scenes = DirigeraRequest(method: "GET", path: "/v1/scenes")

    public static func device(_ id: String) -> DirigeraRequest {
        DirigeraRequest(method: "GET", path: "/v1/devices/\(pathEscape(id))")
    }

    /// `PATCH /v1/devices/{id}` with `[{"attributes": {...}}]`.
    public static func patch(deviceID: String, attributes: [String: DirigeraJSON]) -> DirigeraRequest {
        let body: DirigeraJSON = [["attributes": .object(attributes)]]
        return DirigeraRequest(method: "PATCH", path: "/v1/devices/\(pathEscape(deviceID))", body: body.encoded(),
                               contentType: "application/json")
    }

    public static func triggerScene(_ id: String) -> DirigeraRequest {
        DirigeraRequest(method: "POST", path: "/v1/scenes/\(pathEscape(id))/trigger")
    }

    /// WebSocket path (`wss://<hub>:8443/v1`).
    public static let eventsPath = "/v1"

    static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Host strings: `ip`, `ip:port`, `[v6]:port`, `https://host:port/`, `gw2-xxxx.local`.
public enum DirigeraEndpoint {
    public static func parse(_ input: String) -> (host: String, port: Int?) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://", "wss://", "ws://"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        if s.filter({ $0 == ":" }).count == 1, let i = s.firstIndex(of: ":"), let port = Int(s[s.index(after: i)...]) {
            return (String(s[..<i]), port)
        }
        return (s, nil)
    }

    public static func url(scheme: String, host: String, port: Int?, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port ?? DirigeraAPI.defaultPort
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// `gw2-<id>.local` / Bonjour instance `gw2-<id>`: the hostname the hub announces.
    public static func isHubHostname(_ name: String) -> Bool { name.lowercased().hasPrefix("gw2-") }
}

/// Failures specific to the hub API. Messages never contain tokens.
public enum DirigeraError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 401/403 with a stored token: the token was revoked (hub reset or client removed).
    case unauthorized
    /// The action button was not pressed before the pairing window closed.
    case buttonNotPressed
    case httpStatus(Int, String)
    case malformedResponse(String)
    /// The hub presented a different certificate than the one pinned for it.
    case certificateChanged
    case missingHubIdentity

    public var description: String {
        switch self {
        case .unauthorized: "The hub rejected the stored token"
        case .buttonNotPressed: "The action button on the hub was not pressed in time"
        case .httpStatus(let s, let body): "HTTP \(s)\(body.isEmpty ? "" : ": \(body)")"
        case .malformedResponse(let s): "Malformed response: \(s)"
        case .certificateChanged: "The hub's certificate changed; remove the hub and add it again"
        case .missingHubIdentity: "The hub did not report its id"
        }
    }

    public var lightCoreError: LightCoreError {
        switch self {
        case .unauthorized: .authenticationRequired(.dirigera)
        case .buttonNotPressed: .timeout
        case .httpStatus, .malformedResponse, .certificateChanged, .missingHubIdentity: .protocolError(description)
        }
    }
}

/// Ids: lights `dirigera:<hubID>/<deviceID>`, scenes `dirigera:<hubID>/<sceneID>`.
public enum DirigeraIdentifiers {
    public static func lightID(hubID: String, deviceID: String) -> LightID? {
        LightID(brand: .dirigera, stableId: "\(hubID)/\(deviceID)")
    }

    public static func sceneID(hubID: String, sceneID: String) -> String { "dirigera:\(hubID)/\(sceneID)" }

    /// Splits `<hubID>/<deviceID>` (from a `LightID.stableId` or a scene id without the prefix).
    public static func split(_ stableID: String) -> (hubID: String, itemID: String)? {
        var s = stableID
        if s.lowercased().hasPrefix("dirigera:") { s.removeFirst("dirigera:".count) }
        guard let slash = s.firstIndex(of: "/") else { return nil }
        let hub = String(s[..<slash])
        let item = String(s[s.index(after: slash)...])
        guard !hub.isEmpty, !item.isEmpty else { return nil }
        return (hub, item)
    }
}
