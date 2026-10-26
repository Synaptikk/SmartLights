import Foundation

/// HTTP method (pure value, shared by ``HTTPClient`` on Apple platforms).
public struct HTTPMethod: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let get = HTTPMethod(rawValue: "GET")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let delete = HTTPMethod(rawValue: "DELETE")
}

/// Errors produced by NetKit HTTP helpers. Bodies are truncated to 512 bytes and never contain
/// request headers, so they are safe to log (servers do not echo app keys in error bodies).
public enum HTTPError: Error, Sendable, Equatable {
    case invalidURL(String)
    case invalidResponse
    case unauthorized(status: Int, body: String)          // 401
    case forbidden(body: String)                          // 403 (Hue: wrong/removed app key)
    case notFound(body: String)                           // 404
    case rateLimited(status: Int, retryAfter: Duration?)  // 429, 503 with Retry-After
    case client(status: Int, body: String)                // other 4xx
    case server(status: Int, body: String)                // 5xx
    case unexpectedStatus(status: Int, body: String)      // 1xx/3xx
    case decoding(String)
    case transport(String)
    case timedOut

    /// Whether retrying (after backoff) can reasonably succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport, .timedOut: return true
        default: return false
        }
    }

    /// Maps a status code to an error, or `nil` for 2xx.
    public static func check(status: Int, body: Data = Data(), retryAfter: String? = nil) -> HTTPError? {
        if (200..<300).contains(status) { return nil }
        let text = String(decoding: body.prefix(512), as: UTF8.self)
        switch status {
        case 401: return .unauthorized(status: status, body: text)
        case 403: return .forbidden(body: text)
        case 404: return .notFound(body: text)
        case 429: return .rateLimited(status: status, retryAfter: parseRetryAfter(retryAfter))
        case 503 where retryAfter != nil: return .rateLimited(status: status, retryAfter: parseRetryAfter(retryAfter))
        case 400..<500: return .client(status: status, body: text)
        case 500..<600: return .server(status: status, body: text)
        default: return .unexpectedStatus(status: status, body: text)
        }
    }

    /// Parses a delta-seconds `Retry-After` header (HTTP-date form returns `nil`).
    public static func parseRetryAfter(_ value: String?) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), let seconds = Int(value), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}
