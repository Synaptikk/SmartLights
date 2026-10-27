import Foundation
import LightCore

/// Hue-specific errors. Messages never contain the application key.
public enum HueError: Error, Sendable, Equatable, LocalizedError {
    /// v1 error 101 while pairing: the round link button was not pressed (in time).
    case linkButtonNotPressed
    /// HTTP 401/403 on CLIP v2 or v1 error 1: the app key is wrong or was removed.
    case unauthorized
    /// HTTP 404 on `/clip/v2/resource` or `/eventstream/clip/v2`: firmware without CLIP v2.
    case v2Unsupported
    /// HTTP 429 or 503 after all retries.
    case bridgeBusy
    /// HTTP 404 on a specific resource.
    case resourceNotFound(String)
    /// HTTP 400/405/... with the CLIP `errors[].description` text.
    case requestRejected(status: Int, description: String)
    /// Other v1 error.
    case v1Error(type: Int, description: String)
    /// HTTP 5xx (other than a retried 503).
    case server(status: Int, description: String)
    case invalidResponse(String)
    /// The certificate CN or `/api/config` bridge id is not the bridge we expected.
    case bridgeIdentityMismatch(expected: String, found: String?)
    /// No application key stored for this bridge (pair first).
    case notPaired(bridgeID: String)
    case unknownBridge(String)

    public var errorDescription: String? {
        switch self {
        case .linkButtonNotPressed: "The link button on the Hue Bridge was not pressed"
        case .unauthorized: "The Hue Bridge no longer accepts SmartLights; pair again"
        case .v2Unsupported: "This Hue Bridge firmware does not support the v2 API; update it in the Hue app"
        case .bridgeBusy: "The Hue Bridge is busy; try again"
        case .resourceNotFound(let s): "Hue resource not found: \(s)"
        case .requestRejected(let status, let d): "Hue Bridge rejected the request (\(status)): \(d)"
        case .v1Error(let type, let d): "Hue Bridge error \(type): \(d)"
        case .server(let status, let d): "Hue Bridge error (\(status)): \(d)"
        case .invalidResponse(let s): "Unexpected Hue Bridge response: \(s)"
        case .bridgeIdentityMismatch(let expected, let found):
            "Expected Hue Bridge \(expected) but found \(found ?? "an unknown device")"
        case .notPaired(let id): "Hue Bridge \(id) is not paired"
        case .unknownBridge(let id): "Unknown Hue Bridge \(id)"
        }
    }

    /// Whether the request should be retried after a short backoff (aiohue: 429/503).
    public static func isBusyStatus(_ status: Int) -> Bool { status == 429 || status == 503 }

    /// Maps an HTTP status + CLIP v2 body to an error; nil for 2xx.
    /// - Parameter isCollectionRequest: true for `/clip/v2/resource` (all) and the event stream,
    ///   where 404 means "no v2 API" rather than "no such resource".
    public static func from(status: Int, body: Data, path: String, isCollectionRequest: Bool = false) -> HueError? {
        if (200..<300).contains(status) { return nil }
        let description = Self.describe(body)
        switch status {
        case 401, 403: return .unauthorized
        case 404: return isCollectionRequest ? .v2Unsupported : .resourceNotFound(path)
        case 429, 503: return .bridgeBusy
        case 500..<600: return .server(status: status, description: description)
        default: return .requestRejected(status: status, description: description)
        }
    }

    /// CLIP v2 error descriptions from a response body (or a truncated text body).
    public static func describe(_ body: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ResourceEnvelope<JSONValue>.self, from: body),
            !envelope.errorDescription.isEmpty
        {
            return envelope.errorDescription
        }
        return String(decoding: body.prefix(256), as: UTF8.self)
    }

    /// Mapping onto the cross-provider error type.
    public var lightCoreError: LightCoreError {
        switch self {
        case .linkButtonNotPressed: .timeout
        case .unauthorized, .notPaired: .authenticationRequired(.hue)
        case .v2Unsupported: .unsupported(errorDescription ?? "CLIP v2")
        case .bridgeBusy: .transport(errorDescription ?? "busy")
        case .resourceNotFound(let s): .protocolError("not found: \(s)")
        case .requestRejected, .v1Error, .server, .invalidResponse: .protocolError(errorDescription ?? "")
        case .bridgeIdentityMismatch: .protocolError(errorDescription ?? "identity mismatch")
        case .unknownBridge(let id): .unreachable("Hue Bridge \(id)")
        }
    }
}
