import Foundation

/// Errors shared across providers. Messages must never contain secrets.
public enum LightCoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidLightID(String)
    case providerNotRegistered(Brand)
    case lightNotFound(LightID)
    case unsupported(String)
    /// The user dismissed a pairing prompt.
    case userCancelled
    case timeout
    /// Stored credentials are missing or rejected; the UI should re-run the account flow.
    case authenticationRequired(Brand)
    case unreachable(String)
    case transport(String)
    case protocolError(String)
    case storage(String)
    /// Several lights in a group command failed (first message per light).
    case partialFailure([LightID: String])

    public var errorDescription: String? {
        switch self {
        case .invalidLightID(let s): "Invalid light id '\(s)'"
        case .providerNotRegistered(let b): "\(b.displayName) is not set up"
        case .lightNotFound(let id): "Light \(id) not found"
        case .unsupported(let s): "Not supported: \(s)"
        case .userCancelled: "Cancelled"
        case .timeout: "Timed out"
        case .authenticationRequired(let b): "\(b.displayName) needs you to sign in again"
        case .unreachable(let s): "Unreachable: \(s)"
        case .transport(let s): "Network error: \(s)"
        case .protocolError(let s): "Unexpected device response: \(s)"
        case .storage(let s): "Storage error: \(s)"
        case .partialFailure(let failures): "\(failures.count) light(s) did not respond"
        }
    }
}
