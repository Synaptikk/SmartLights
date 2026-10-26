import Foundation

/// `Scene` is kept as an alias for the PLAN.md contract. In SwiftUI files prefer `LightScene`
/// (SwiftUI also declares `Scene`; qualify as `SwiftUI.Scene` in the `App` body).
public typealias Scene = LightScene

/// A scene: either a vendor scene exposed by a provider, or an app-level snapshot across brands.
public struct LightScene: Identifiable, Codable, Sendable, Hashable {
    public typealias ID = String

    public enum Kind: String, Codable, Sendable, Hashable {
        /// Stored on the vendor side (Hue scene, Nanoleaf effect); recalled via `LightProvider.recall`.
        case vendor
        /// Stored by the app; recalled by sending `commands` per light.
        case app
    }

    /// Vendor scenes: `"<brand>:<vendor scene id>"` is recommended; app scenes: a UUID string.
    public var id: ID
    public var name: String
    public var kind: Kind
    /// Owning brand for vendor scenes; nil for app scenes.
    public var brand: Brand?
    public var roomHint: String?
    /// Lights affected (informational for vendor scenes).
    public var lightIDs: [LightID]
    /// Per-light commands for app scenes (empty for vendor scenes).
    public var commands: [LightID: LightCommand]

    public init(
        id: ID,
        name: String,
        kind: Kind,
        brand: Brand? = nil,
        roomHint: String? = nil,
        lightIDs: [LightID] = [],
        commands: [LightID: LightCommand] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.brand = brand
        self.roomHint = roomHint
        self.lightIDs = lightIDs
        self.commands = commands
    }

    /// App scene snapshotting the current state of `lights`.
    public static func snapshot(of lights: [Light], name: String, id: ID = UUID().uuidString) -> LightScene {
        var commands: [LightID: LightCommand] = [:]
        for light in lights { commands[light.id] = light.state.asCommand }
        return LightScene(id: id, name: name, kind: .app, lightIDs: lights.map(\.id), commands: commands)
    }
}

/// How a device was found.
public enum DiscoveryMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case bonjour
    case broadcast
    case sweep
    case cloud
    case manual
    case cached
    case homeKit
}

/// Parameters for `LightProvider.discover(options:)`.
public struct DiscoveryOptions: Sendable, Hashable {
    /// Overall time budget; the stream should finish when it elapses.
    public var timeout: Duration
    /// Methods the caller allows. Providers skip methods they do not implement.
    public var methods: Set<DiscoveryMethod>
    /// Whether UDP broadcast/multicast may be attempted (multicast entitlement present and working).
    public var broadcastAvailable: Bool
    /// Hosts typed by the user (IP or hostname) to probe directly.
    public var manualHosts: [String]
    /// Previously known IPs (hints only; devices are keyed by stable id).
    public var cachedHosts: [String]

    public init(
        timeout: Duration = .seconds(10),
        methods: Set<DiscoveryMethod> = Set(DiscoveryMethod.allCases),
        broadcastAvailable: Bool = false,
        manualHosts: [String] = [],
        cachedHosts: [String] = []
    ) {
        self.timeout = timeout
        self.methods = methods
        self.broadcastAvailable = broadcastAvailable
        self.manualHosts = manualHosts
        self.cachedHosts = cachedHosts
    }

    public static let `default` = DiscoveryOptions()
}

/// A device seen during discovery, not yet paired.
public struct DiscoveredDevice: Identifiable, Codable, Sendable, Hashable {
    /// Stable vendor id if known at discovery time (Hue bridge id, WiZ MAC, AiDot devId),
    /// otherwise a provisional id such as `"ip:192.168.1.20"`.
    public var id: String
    public var brand: Brand
    public var name: String
    public var model: String?
    /// IP/hostname hint.
    public var host: String?
    public var port: Int?
    public var macAddress: String?
    public var method: DiscoveryMethod
    /// Non-secret vendor extras (firmware, moduleName, bridge api version, ...).
    public var metadata: [String: String]
    public var discoveredAt: Date

    public init(
        id: String,
        brand: Brand,
        name: String,
        model: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        macAddress: String? = nil,
        method: DiscoveryMethod,
        metadata: [String: String] = [:],
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.brand = brand
        self.name = name
        self.model = model
        self.host = host
        self.port = port
        self.macAddress = macAddress
        self.method = method
        self.metadata = metadata
        self.discoveredAt = discoveredAt
    }
}

/// A device (bulb, bridge, hub or cloud-account device) the user has added.
/// Persisted by `DeviceStore`; secrets for it live in `SecretStore`, never here.
public struct PairedDevice: Identifiable, Codable, Sendable, Hashable {
    /// Stable vendor id (Hue bridge id, WiZ MAC, AiDot devId).
    public var id: String
    public var brand: Brand
    public var name: String
    public var model: String?
    /// Last known IP/hostname (hint only).
    public var hostHint: String?
    public var port: Int?
    /// Owning `ProviderAccount.id` for cloud-backed brands.
    public var accountID: String?
    /// Lights exposed by this device (a bridge exposes many, a bulb one).
    public var lightIDs: [LightID]
    /// Non-secret provider extras.
    public var metadata: [String: String]
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(
        id: String,
        brand: Brand,
        name: String,
        model: String? = nil,
        hostHint: String? = nil,
        port: Int? = nil,
        accountID: String? = nil,
        lightIDs: [LightID] = [],
        metadata: [String: String] = [:],
        pairedAt: Date = Date(),
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.brand = brand
        self.name = name
        self.model = model
        self.hostHint = hostHint
        self.port = port
        self.accountID = accountID
        self.lightIDs = lightIDs
        self.metadata = metadata
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }

    /// Unique key across brands: `"<brand>:<id>"`.
    public var storeKey: String { "\(brand.rawValue):\(id)" }
}

/// A cloud/vendor account or credential set (AiDot login, Govee API key, LIFX token, Hue app key...).
/// Only *references* to secrets are stored here (`secretKeys`); values live in `SecretStore`.
public struct ProviderAccount: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var brand: Brand
    /// Shown in Settings, e.g. the masked username. Never a token.
    public var displayName: String
    /// Cloud region / country code if relevant.
    public var region: String?
    /// Keys under which this account's secrets are stored.
    public var secretKeys: [SecretKey]
    public var metadata: [String: String]
    public var createdAt: Date

    public init(
        id: String,
        brand: Brand,
        displayName: String,
        region: String? = nil,
        secretKeys: [SecretKey] = [],
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.brand = brand
        self.displayName = displayName
        self.region = region
        self.secretKeys = secretKeys
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
