import Foundation
import LightCore

/// One xled REST call, independent of host and transport.
public struct TwinklyRequest: Sendable, Hashable, CustomStringConvertible {
    public var method: String
    /// Absolute path, e.g. `/xled/v1/led/mode`.
    public var path: String
    /// JSON body (POST only).
    public var body: Data?
    /// Whether the call needs `X-Auth-Token` (everything except login, gestalt, fw version, status).
    public var authenticated: Bool

    public init(method: String, path: String, body: Data? = nil, authenticated: Bool) {
        self.method = method
        self.path = path
        self.body = body
        self.authenticated = authenticated
    }

    public var description: String { "\(method) \(path)" }

    /// The JSON body as text (tests, diagnostics; never contains secrets).
    public var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

/// Builders for the xled endpoints SmartLights uses
/// (https://xled-docs.readthedocs.io/en/latest/rest_api.html).
public enum TwinklyAPI {
    public static let base = "/xled/v1"
    /// Header carrying the token on authenticated calls.
    public static let tokenHeader = "X-Auth-Token"

    public enum Path {
        public static let login = "\(base)/login"
        public static let verify = "\(base)/verify"
        public static let gestalt = "\(base)/gestalt"
        public static let firmwareVersion = "\(base)/fw/version"
        public static let mode = "\(base)/led/mode"
        public static let color = "\(base)/led/color"
        public static let brightness = "\(base)/led/out/brightness"
        public static let effects = "\(base)/led/effects"
        public static let currentEffect = "\(base)/led/effects/current"
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Every body here is a flat struct of strings and ints; encoding cannot fail.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func login(challenge: String) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.login, body: encode(TwinklyLoginRequest(challenge: challenge)), authenticated: false)
    }

    /// Sent with the new token in `X-Auth-Token`; a successful verify invalidates any older token.
    public static func verify(challengeResponse: String?) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.verify, body: encode(TwinklyVerifyRequest(challengeResponse: challengeResponse)),
                       authenticated: true)
    }

    public static let gestalt = TwinklyRequest(method: "GET", path: Path.gestalt, authenticated: false)
    public static let firmwareVersion = TwinklyRequest(method: "GET", path: Path.firmwareVersion, authenticated: false)
    public static let getMode = TwinklyRequest(method: "GET", path: Path.mode, authenticated: true)
    public static let getColor = TwinklyRequest(method: "GET", path: Path.color, authenticated: true)
    public static let getBrightness = TwinklyRequest(method: "GET", path: Path.brightness, authenticated: true)
    public static let getEffects = TwinklyRequest(method: "GET", path: Path.effects, authenticated: true)
    public static let getCurrentEffect = TwinklyRequest(method: "GET", path: Path.currentEffect, authenticated: true)

    public static func setMode(_ mode: TwinklyMode, effectID: Int? = nil) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.mode, body: encode(TwinklyModeRequest(mode: mode, effectID: effectID)),
                       authenticated: true)
    }

    public static func setColor(_ color: TwinklyColorRequest) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.color, body: encode(color), authenticated: true)
    }

    /// `percent` 0...100 (absolute).
    public static func setBrightness(percent: Int) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.brightness,
                       body: encode(TwinklyBrightnessRequest(value: min(max(percent, 0), 100))), authenticated: true)
    }

    public static func setCurrentEffect(_ id: Int) -> TwinklyRequest {
        TwinklyRequest(method: "POST", path: Path.currentEffect, body: encode(TwinklyEffectCurrent(effectID: id)),
                       authenticated: true)
    }

    /// Decodes a JSON response and checks its application `code` (absent counts as OK).
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope: TwinklyCodeResponse
        do {
            envelope = try JSONDecoder().decode(TwinklyCodeResponse.self, from: data)
        } catch {
            throw TwinklyError.malformedResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let code = envelope.code, !TwinklyAppCode.okLike.contains(code) { throw TwinklyError.application(code: code) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TwinklyError.malformedResponse(String(describing: error))
        }
    }

    /// Checks only the application `code` of a response.
    public static func checkCode(_ data: Data) throws {
        _ = try decode(TwinklyCodeResponse.self, from: data)
    }

    /// 32 random bytes, base64 (the `challenge` of `/login`).
    public static func makeChallenge<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    public static func makeChallenge() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeChallenge(using: &generator)
    }
}

/// Twinkly-specific failures. Messages never contain tokens.
public enum TwinklyError: Error, Sendable, Equatable, CustomStringConvertible {
    /// HTTP 401 even right after a fresh login.
    case unauthorized
    /// HTTP 404 "Resource not found." (endpoint missing on this firmware).
    case endpointUnavailable(String)
    case httpStatus(Int)
    /// HTTP 200 with a non-OK application `code`.
    case application(code: Int)
    case malformedResponse(String)
    /// `/gestalt` answered but carried no usable MAC.
    case missingIdentity
    /// The host answered with a different device than expected (IP reused).
    case identityMismatch(expected: String, found: String)

    public var description: String {
        switch self {
        case .unauthorized: "Twinkly rejected the token"
        case .endpointUnavailable(let p): "Endpoint \(p) not available on this firmware"
        case .httpStatus(let s): "HTTP \(s)"
        case .application(let code): "Twinkly error \(code) (\(TwinklyAppCode.message(for: code)))"
        case .malformedResponse(let s): "Malformed response: \(s)"
        case .missingIdentity: "Device did not report a MAC address"
        case .identityMismatch(let e, let f): "Expected device \(e), found \(f)"
        }
    }

    /// Mapping to the shared error type callers see.
    public var lightCoreError: LightCoreError {
        switch self {
        case .unauthorized: .authenticationRequired(.twinkly)
        case .endpointUnavailable(let p): .unsupported("Twinkly firmware lacks \(p)")
        case .httpStatus, .application, .malformedResponse, .missingIdentity, .identityMismatch: .protocolError(description)
        }
    }
}

/// Stable ids: the MAC from `/gestalt`, lower-case hex without separators.
public enum TwinklyIdentifiers {
    /// `"5c:cf:7f:33:aa:ff"` / `"5CCF7F33AAFF"` / `"5c-cf-..."` -> `"5ccf7f33aaff"`.
    public static func normalizeMAC(_ mac: String) -> String? {
        let hex = mac.lowercased().filter { $0.isHexDigit }
        let separatorsOK = mac.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" || $0 == "." }
        guard hex.count == 12, separatorsOK, hex != "000000000000" else { return nil }
        return hex
    }

    public static func lightID(mac: String) -> LightID? {
        normalizeMAC(mac).flatMap { LightID(brand: .twinkly, stableId: $0) }
    }
}

/// Host strings typed by the user or cached: `ip`, `ip:port`, `[v6]:port`, `http://ip[:port]/`, `name.local`.
public enum TwinklyEndpoint {
    public static func parse(_ input: String) -> (host: String, port: Int?) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let i = s.firstIndex(of: ":"), let port = Int(s[s.index(after: i)...]) {
            return (String(s[..<i]), port)
        }
        return (s, nil)
    }

    /// `http://host[:port]<path>`; nil `port` or 80 means the default port.
    public static func url(host: String, port: Int?, path: String) -> URL? {
        let h = host.contains(":") ? "[\(host)]" : host
        let p = port.flatMap { $0 == 80 ? nil : ":\($0)" } ?? ""
        return URL(string: "http://\(h)\(p)\(path)")
    }
}
