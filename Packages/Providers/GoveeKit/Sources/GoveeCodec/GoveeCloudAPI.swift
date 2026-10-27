import Foundation

/// A transport-neutral HTTP request (built by `GoveeCloudAPI`, executed by the provider's transport).
public struct GoveeHTTPRequest: Sendable, Hashable {
    public var method: String
    /// Path relative to the API base URL, e.g. `/router/api/v1/user/devices`.
    public var path: String
    /// Includes `Govee-API-Key`: never log `headers`.
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Safe for logs: method and path only.
    public var logDescription: String { "\(method) \(path)" }
}

/// A transport-neutral HTTP response.
public struct GoveeHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Errors of the Developer API. Messages never contain the API key.
public enum GoveeCloudError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 401: missing/invalid `Govee-API-Key`.
    case unauthorized
    /// 429 (per-minute or daily limit). `retryAfter` in seconds when the server says.
    case rateLimited(retryAfter: Int?)
    /// The provider's own daily budget would be exceeded (no request was sent).
    case budgetExhausted
    case badRequest(String)
    case notFound(String)
    case server(status: Int, String)
    /// HTTP 200 with a non-200 `code` in the body.
    case api(code: Int, message: String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unauthorized: "Govee API key rejected (401)"
        case .rateLimited(let s): "Govee rate limit reached" + (s.map { ", retry in \($0) s" } ?? "")
        case .budgetExhausted: "Govee daily request budget used up"
        case .badRequest(let m): "Govee rejected the request (400): \(m)"
        case .notFound(let m): "Govee device or capability not found (404): \(m)"
        case .server(let status, let m): "Govee server error \(status): \(m)"
        case .api(let code, let m): "Govee API error \(code): \(m)"
        case .decoding(let m): "Unexpected Govee response: \(m)"
        }
    }
}

/// Rate-limit headers. The Developer API documents per-endpoint limits but not the header names;
/// several spellings are seen in the wild (`API-RateLimit-*` on the v1/router API, `X-RateLimit-*`
/// on the gateway, `Rate-Limit-*`). All are parsed; `[verify]` against a real key.
public struct GoveeRateLimitInfo: Sendable, Hashable {
    public var limit: Int?
    public var remaining: Int?
    /// When the window resets (absolute; derived from epoch seconds or delta seconds).
    public var reset: Date?

    public init(limit: Int? = nil, remaining: Int? = nil, reset: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
    }

    public var isEmpty: Bool { limit == nil && remaining == nil && reset == nil }

    static let prefixes = ["API-RateLimit-", "X-RateLimit-", "RateLimit-", "Rate-Limit-", "X-Rate-Limit-"]

    /// Parses the first header family present. Reset values above 10^9 are epoch seconds
    /// (10^12: epoch milliseconds), smaller values are seconds from `now`.
    public static func parse(_ response: GoveeHTTPResponse, now: Date = Date()) -> GoveeRateLimitInfo? {
        for prefix in prefixes {
            let limit = response.header(prefix + "Limit").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let remaining = response.header(prefix + "Remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let resetRaw = response.header(prefix + "Reset").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard limit != nil || remaining != nil || resetRaw != nil else { continue }
            var reset: Date?
            if let r = resetRaw {
                if r > 1e12 { reset = Date(timeIntervalSince1970: r / 1000) }
                else if r > 1e9 { reset = Date(timeIntervalSince1970: r) }
                else { reset = now.addingTimeInterval(r) }
            }
            return GoveeRateLimitInfo(limit: limit, remaining: remaining, reset: reset)
        }
        return nil
    }
}

/// Govee Developer API (v2 "router" API) request builders and response parsers.
/// Docs: https://developer.govee.com/reference/get-you-devices , /control-you-devices ,
/// /get-devices-status . Header `Govee-API-Key`. Documented limits: devices 30/min per account;
/// control 2/s (burst 6) per device and 12/s (burst 80) per account; state 30/min per device;
/// overall ~10,000 requests/day per key (widely reported, not documented).
public enum GoveeCloudAPI {
    public static let baseURL = URL(string: "https://openapi.api.govee.com")!
    public static let apiKeyHeader = "Govee-API-Key"
    public static let devicesPath = "/router/api/v1/user/devices"
    public static let controlPath = "/router/api/v1/device/control"
    public static let statePath = "/router/api/v1/device/state"
    public static let scenesPath = "/router/api/v1/device/scenes"

    static func headers(apiKey: String, hasBody: Bool) -> [String: String] {
        var h = [apiKeyHeader: apiKey, "Accept": "application/json"]
        if hasBody { h["Content-Type"] = "application/json" }
        return h
    }

    public static func devicesRequest(apiKey: String) -> GoveeHTTPRequest {
        GoveeHTTPRequest(method: "GET", path: devicesPath, headers: headers(apiKey: apiKey, hasBody: false))
    }

    public static func controlRequest(apiKey: String, requestID: String, sku: String, device: String,
                                      capability: GoveeCapabilityCommand) -> GoveeHTTPRequest {
        let body = GoveeControlRequest(requestId: requestID, sku: sku, device: device, capability: capability)
        return GoveeHTTPRequest(method: "POST", path: controlPath, headers: headers(apiKey: apiKey, hasBody: true),
                                body: try? GoveeJSONCoding.encoder().encode(body))
    }

    public static func stateRequest(apiKey: String, requestID: String, sku: String, device: String) -> GoveeHTTPRequest {
        let body = GoveeStateRequest(requestId: requestID, sku: sku, device: device)
        return GoveeHTTPRequest(method: "POST", path: statePath, headers: headers(apiKey: apiKey, hasBody: true),
                                body: try? GoveeJSONCoding.encoder().encode(body))
    }

    /// Maps HTTP status to `GoveeCloudError` (nil for 2xx).
    public static func error(for response: GoveeHTTPResponse) -> GoveeCloudError? {
        let text = String(decoding: response.body.prefix(512), as: UTF8.self)
        switch response.status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 429:
            let retry = response.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: retry)
        case 404: return .notFound(text)
        case 400..<500: return .badRequest(text)
        default: return .server(status: response.status, text)
        }
    }

    /// Body-level `code` (Govee sometimes answers HTTP 200 with `code` 4xx).
    static func checkBodyCode(_ code: Int, message: String?) throws {
        switch code {
        case 200, 0: return
        case 401, 403: throw GoveeCloudError.unauthorized
        case 429: throw GoveeCloudError.rateLimited(retryAfter: nil)
        default: throw GoveeCloudError.api(code: code, message: message ?? "")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ response: GoveeHTTPResponse) throws -> T {
        if let error = error(for: response) { throw error }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw GoveeCloudError.decoding(String(describing: error).prefix(300).description)
        }
    }

    public static func decodeDevices(_ response: GoveeHTTPResponse) throws -> [GoveeCloudDevice] {
        let list = try decode(GoveeCloudDeviceList.self, response)
        try checkBodyCode(list.code, message: list.message)
        return list.data
    }

    public static func decodeControl(_ response: GoveeHTTPResponse) throws -> GoveeControlResponse {
        let control = try decode(GoveeControlResponse.self, response)
        try checkBodyCode(control.code, message: control.msg)
        if let status = control.status, status.lowercased() != "success" {
            throw GoveeCloudError.api(code: control.code, message: status)
        }
        return control
    }

    public static func decodeState(_ response: GoveeHTTPResponse) throws -> [GoveeCapabilityState] {
        let state = try decode(GoveeStateResponse.self, response)
        try checkBodyCode(state.code, message: state.msg)
        return state.payload?.capabilities ?? []
    }
}
