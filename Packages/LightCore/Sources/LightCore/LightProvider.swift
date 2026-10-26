import Foundation

/// Something that happened inside a provider. Delivered via `LightProvider.events`.
public enum ProviderEvent: Sendable, Equatable {
    /// New authoritative state for a light (external change, poll result, push).
    case stateChanged(LightID, LightState)
    case lightAdded(Light)
    case lightUpdated(Light)
    case lightRemoved(LightID)
    case reachabilityChanged(LightID, reachable: Bool)
    /// Vendor scene list changed; call `scenes()` again.
    case scenesChanged
    /// Credentials expired/rejected; the UI should re-run the account flow.
    case needsReauthentication(accountID: String?)
    /// Connection-level state of the provider (SSE stream, TCP session, push registration).
    case connectionChanged(connected: Bool, detail: String?)
    /// Non-fatal error worth surfacing in Diagnostics. Never include secrets.
    case error(String)
}

/// One brand integration. Providers are actors; all state is isolated (CLAUDE.md conventions).
///
/// Rules (PLAN.md §4.1):
/// - normalise colour with `LightCommand.normalized(for:)`/`ColorMath` so each light receives
///   one attribute it supports; send brightness and colour in one wire command where possible;
/// - enforce vendor rate limits internally (`RateLimiter`);
/// - key everything by stable id, never by IP.
public protocol LightProvider: Actor {
    static var brand: Brand { get }
    /// Credentials/keys reference (values in `SecretStore`).
    var account: ProviderAccount? { get }
    /// Finds devices. The stream finishes when `options.timeout` elapses or the task is cancelled.
    func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice>
    func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice
    func loadLights() async throws -> [Light]
    func send(_ command: LightCommand, to light: LightID) async throws
    /// Default: sequential fan-out to `send`. Override for native groups (Hue grouped_light).
    func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws
    /// State changes, reachability, errors. Single consumer: `ProviderRegistry` owns it once registered.
    var events: AsyncStream<ProviderEvent> { get }
    /// Vendor scenes, if any. Default: none.
    func scenes() async throws -> [Scene]
    /// Recall a vendor scene. Default: throws `.unsupported`.
    func recall(_ scene: Scene.ID) async throws
}

extension LightProvider {
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        var failures: [LightID: String] = [:]
        for id in lights {
            do {
                try await send(command, to: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[id] = String(describing: error)
            }
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    public func scenes() async throws -> [Scene] { [] }

    public func recall(_ scene: Scene.ID) async throws {
        throw LightCoreError.unsupported("\(Self.brand.displayName) has no vendor scenes")
    }

    /// Convenience: the brand of this provider instance.
    public nonisolated var brand: Brand { Self.brand }
}
