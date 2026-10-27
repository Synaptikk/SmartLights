import Foundation
import NetKit

/// Errors from encoding/decoding Open API payloads. Messages never contain the auth token.
public enum NanoleafCodecError: Error, Sendable, Equatable {
    /// The token is empty or contains characters that are not allowed in a URL path segment.
    case invalidToken
    case decoding(String)
}

/// One HTTP request against the controller (`http://<host>:16021<path>`).
///
/// `path` contains the auth token; never log it, use `redactedPath`.
public struct NanoleafRequest: Sendable, Hashable {
    public var method: HTTPMethod
    /// Absolute path including the query string, e.g. `/api/v1/<token>/events?id=1,2,3,4`.
    public var path: String
    public var body: Data?

    public init(method: HTTPMethod, path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    /// `path` with the token replaced by `<token>`, safe for logs.
    public var redactedPath: String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "api", "v1", "<token or new>", ...]
        guard parts.count > 3, parts[1] == "api", parts[2] == "v1", parts[3] != "new", !parts[3].isEmpty else {
            return path
        }
        var copy = parts.map(String.init)
        copy[3] = "<token>"
        return copy.joined(separator: "/")
    }
}

/// Body of `PUT /api/v1/{token}/state`. Unset fields are not sent.
///
/// Wire format: `{"on":{"value":true}, "brightness":{"value":80,"duration":2}, "hue":{"value":120},
/// "sat":{"value":100}, "ct":{"value":2700}}`. `duration` (seconds) is only supported on brightness.
public struct NanoleafStateUpdate: Sendable, Hashable, Encodable {
    public var on: Bool?
    /// 0-100 (device `brightness.min...max`).
    public var brightness: Int?
    /// Fade time in seconds for `brightness`.
    public var duration: Int?
    /// 0-359 degrees.
    public var hue: Int?
    /// 0-100.
    public var sat: Int?
    /// Kelvin (1200-6500 on most controllers).
    public var ct: Int?

    public init(on: Bool? = nil, brightness: Int? = nil, duration: Int? = nil, hue: Int? = nil, sat: Int? = nil,
                ct: Int? = nil) {
        self.on = on
        self.brightness = brightness
        self.duration = duration
        self.hue = hue
        self.sat = sat
        self.ct = ct
    }

    public var isEmpty: Bool { on == nil && brightness == nil && hue == nil && sat == nil && ct == nil }

    private struct Value: Encodable {
        var value: Int?
        var bool: Bool?
        var duration: Int?

        enum CodingKeys: String, CodingKey { case value, duration }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let bool { try c.encode(bool, forKey: .value) } else { try c.encodeIfPresent(value, forKey: .value) }
            try c.encodeIfPresent(duration, forKey: .duration)
        }
    }

    enum CodingKeys: String, CodingKey { case on, brightness, hue, sat, ct }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let on { try c.encode(Value(bool: on), forKey: .on) }
        if let brightness {
            try c.encode(Value(value: brightness, duration: duration.map { Swift.max(0, $0) }), forKey: .brightness)
        }
        if let hue { try c.encode(Value(value: hue), forKey: .hue) }
        if let sat { try c.encode(Value(value: sat), forKey: .sat) }
        if let ct { try c.encode(Value(value: ct), forKey: .ct) }
    }

    /// One update per attribute (for firmware that rejects combined writes). Order: on, brightness,
    /// hue+sat (kept together so the colour does not flash through an intermediate value), ct.
    public func split() -> [NanoleafStateUpdate] {
        var parts: [NanoleafStateUpdate] = []
        if let on { parts.append(NanoleafStateUpdate(on: on)) }
        if let brightness { parts.append(NanoleafStateUpdate(brightness: brightness, duration: duration)) }
        if hue != nil || sat != nil { parts.append(NanoleafStateUpdate(hue: hue, sat: sat)) }
        if let ct { parts.append(NanoleafStateUpdate(ct: ct)) }
        return parts
    }

    /// Deterministic JSON (sorted keys).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// SSE event classes for `GET /api/v1/{token}/events?id=...`.
public enum NanoleafEventType: Int, Sendable, Hashable, CaseIterable, Comparable {
    case state = 1
    case layout = 2
    case effects = 3
    /// Touch gestures (Canvas, Shapes, Elements, Lines).
    case touch = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Request builders and response decoders for the Nanoleaf Open API v1.
public enum NanoleafAPI {
    /// TCP port of the Open API.
    public static let port = 16021
    /// Bonjour service type advertised by Wi-Fi controllers.
    public static let serviceType = "_nanoleafapi._tcp"

    /// Tokens are 32 alphanumeric characters; anything outside `[A-Za-z0-9_-]` is rejected so a token
    /// can never alter the request path.
    public static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 256 && token.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func base(_ token: String) throws -> String {
        guard isValidToken(token) else { throw NanoleafCodecError.invalidToken }
        return "/api/v1/\(token)"
    }

    /// `POST /api/v1/new`: succeeds (200) only within ~30 s after the power button was held 5-7 s;
    /// 403 otherwise.
    public static func addUser() -> NanoleafRequest {
        NanoleafRequest(method: .post, path: "/api/v1/new")
    }

    /// `GET /api/v1/` without a token. A controller answers 401; used to probe a manually typed host.
    public static func probe() -> NanoleafRequest {
        NanoleafRequest(method: .get, path: "/api/v1/")
    }

    /// `DELETE /api/v1/{token}`: revokes the token.
    public static func deleteUser(token: String) throws -> NanoleafRequest {
        NanoleafRequest(method: .delete, path: try base(token))
    }

    /// `GET /api/v1/{token}/`: full info.
    public static func info(token: String) throws -> NanoleafRequest {
        NanoleafRequest(method: .get, path: try base(token) + "/")
    }

    /// `PUT /api/v1/{token}/state`.
    public static func setState(token: String, _ update: NanoleafStateUpdate) throws -> NanoleafRequest {
        NanoleafRequest(method: .put, path: try base(token) + "/state", body: try update.jsonData())
    }

    /// `PUT /api/v1/{token}/effects` with `{"select": name}`.
    public static func selectEffect(token: String, name: String) throws -> NanoleafRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(["select": name])
        return NanoleafRequest(method: .put, path: try base(token) + "/effects", body: body)
    }

    /// `GET /api/v1/{token}/effects/effectsList` → JSON array of names.
    public static func effectsList(token: String) throws -> NanoleafRequest {
        NanoleafRequest(method: .get, path: try base(token) + "/effects/effectsList")
    }

    /// `PUT /api/v1/{token}/identify`: the panels flash briefly.
    public static func identify(token: String) throws -> NanoleafRequest {
        NanoleafRequest(method: .put, path: try base(token) + "/identify")
    }

    /// `GET /api/v1/{token}/events?id=1,2,3,4` (Server-Sent Events).
    public static func events(token: String, types: Set<NanoleafEventType> = Set(NanoleafEventType.allCases)) throws
        -> NanoleafRequest
    {
        let ids = (types.isEmpty ? Set(NanoleafEventType.allCases) : types).sorted().map { String($0.rawValue) }
        return NanoleafRequest(method: .get, path: try base(token) + "/events?id=" + ids.joined(separator: ","))
    }

    // MARK: - Decoding

    public static func decodeAuthToken(_ data: Data) throws -> String {
        let response = try decode(NanoleafAuthResponse.self, from: data)
        guard isValidToken(response.authToken) else { throw NanoleafCodecError.invalidToken }
        return response.authToken
    }

    public static func decodeInfo(_ data: Data) throws -> NanoleafInfo {
        try decode(NanoleafInfo.self, from: data)
    }

    public static func decodeEffectsList(_ data: Data) throws -> [String] {
        try decode([String].self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NanoleafCodecError.decoding("\(T.self): \(error)")
        }
    }
}
