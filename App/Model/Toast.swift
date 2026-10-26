import Foundation

/// A short transient message shown at the bottom of the screen.
struct Toast: Identifiable, Equatable, Sendable {
    let id = UUID()
    var message: String
    var isError: Bool
}

/// Connection/health info per provider, fed by `ProviderEvent`s (read by Diagnostics, T0.7).
struct ProviderHealth: Equatable, Sendable {
    var connected: Bool?
    var detail: String?
    var lastError: String?
    var lastEventAt: Date?
}
