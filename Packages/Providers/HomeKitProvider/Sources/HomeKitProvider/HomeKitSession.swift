import Foundation
import LightCore

// Thin, testable layer over HomeKit. Nothing in this file imports HomeKit: the real adapter
// (`HMHomeKitSession`, iOS only) converts HMHomeManager/HMHome/HMAccessory/HMService/
// HMCharacteristic into the value snapshots below, and tests use a fake session.

/// HomeKit permission state (maps `HMHomeManager.authorizationStatus`).
public enum HomeKitAuthorizationState: String, Sendable, Hashable, Codable {
    /// The user has not answered the permission prompt yet (or HMHomeManager not created).
    case notDetermined
    case authorized
    /// The user declined access (Settings > Privacy & Security > HomeKit).
    case denied
    /// Access is blocked by parental controls / device management.
    case restricted
    /// HomeKit does not exist on this platform (macOS AppKit, Linux).
    case unavailable

    public var isAuthorized: Bool { self == .authorized }
}

/// The lightbulb characteristics SmartLights reads and writes (HAP / Matter-over-HomeKit surface).
public enum HomeKitCharacteristicKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// `HMCharacteristicTypePowerState` (bool).
    case powerState
    /// `HMCharacteristicTypeBrightness` (int percent, usually 0...100).
    case brightness
    /// `HMCharacteristicTypeHue` (float degrees, 0...360).
    case hue
    /// `HMCharacteristicTypeSaturation` (float percent, 0...100).
    case saturation
    /// `HMCharacteristicTypeColorTemperature` (uint32 mireds, HAP default 140...500).
    case colorTemperature
}

/// Value snapshot of one `HMCharacteristic`.
public struct HomeKitCharacteristicSnapshot: Sendable, Hashable, Codable {
    /// Last known value as a number (bool as 0/1); nil if HomeKit has no cached value.
    public var value: Double?
    /// `HMCharacteristicMetadata.minimumValue`.
    public var minimum: Double?
    /// `HMCharacteristicMetadata.maximumValue`.
    public var maximum: Double?
    /// `HMCharacteristicMetadata.stepValue`.
    public var step: Double?
    public var isWritable: Bool
    public var supportsNotification: Bool

    public init(
        value: Double?,
        minimum: Double? = nil,
        maximum: Double? = nil,
        step: Double? = nil,
        isWritable: Bool = true,
        supportsNotification: Bool = true
    ) {
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.isWritable = isWritable
        self.supportsNotification = supportsNotification
    }
}

/// Value snapshot of one `HMService` of type `HMServiceTypeLightbulb` plus its accessory context.
public struct HomeKitLightbulb: Sendable, Hashable, Codable {
    /// `HMAccessory.uniqueIdentifier`.
    public var accessoryID: UUID
    /// `HMService.uniqueIdentifier`.
    public var serviceID: UUID
    public var accessoryName: String
    /// `HMService.name` (often equal to the accessory name).
    public var serviceName: String
    /// `HMAccessory.manufacturer` ("Signify Netherlands B.V.", "Nanoleaf", ...).
    public var manufacturer: String?
    /// `HMAccessory.model`.
    public var model: String?
    public var firmwareVersion: String?
    /// `HMAccessory.room?.name`; nil when the accessory sits in the "entire home" default room.
    public var roomName: String?
    public var homeID: UUID?
    public var homeName: String?
    /// `HMAccessory.isReachable`.
    public var isReachable: Bool
    /// Only the characteristics SmartLights knows about; absent kinds are unsupported.
    public var characteristics: [HomeKitCharacteristicKind: HomeKitCharacteristicSnapshot]

    public init(
        accessoryID: UUID,
        serviceID: UUID,
        accessoryName: String,
        serviceName: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        roomName: String? = nil,
        homeID: UUID? = nil,
        homeName: String? = nil,
        isReachable: Bool = true,
        characteristics: [HomeKitCharacteristicKind: HomeKitCharacteristicSnapshot]
    ) {
        self.accessoryID = accessoryID
        self.serviceID = serviceID
        self.accessoryName = accessoryName
        self.serviceName = serviceName ?? accessoryName
        self.manufacturer = manufacturer
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.roomName = roomName
        self.homeID = homeID
        self.homeName = homeName
        self.isReachable = isReachable
        self.characteristics = characteristics
    }

    public func has(_ kind: HomeKitCharacteristicKind) -> Bool { characteristics[kind] != nil }
    public func value(_ kind: HomeKitCharacteristicKind) -> Double? { characteristics[kind]?.value }

    /// Name shown in the UI: the service name when set, else the accessory name.
    public var displayName: String {
        let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? accessoryName : serviceName
    }
}

/// One characteristic write. `value` is numeric; the adapter converts it to the HomeKit format
/// of the characteristic (bool for power, int for brightness/colour temperature, float for hue/saturation).
public struct HomeKitWrite: Sendable, Hashable, Codable, CustomStringConvertible {
    public var kind: HomeKitCharacteristicKind
    public var value: Double

    public init(_ kind: HomeKitCharacteristicKind, _ value: Double) {
        self.kind = kind
        self.value = value
    }

    public static func power(_ on: Bool) -> HomeKitWrite { HomeKitWrite(.powerState, on ? 1 : 0) }
    /// Percent `0...100`.
    public static func brightness(_ percent: Int) -> HomeKitWrite { HomeKitWrite(.brightness, Double(percent)) }
    /// Degrees `0...360`.
    public static func hue(_ degrees: Double) -> HomeKitWrite { HomeKitWrite(.hue, degrees) }
    /// Percent `0...100`.
    public static func saturation(_ percent: Double) -> HomeKitWrite { HomeKitWrite(.saturation, percent) }
    /// Mireds.
    public static func colorTemperature(mireds: Int) -> HomeKitWrite { HomeKitWrite(.colorTemperature, Double(mireds)) }

    public var description: String { "\(kind.rawValue)=\(value)" }
}

/// Changes reported by a `HomeKitSession`.
public enum HomeKitSessionEvent: Sendable, Hashable {
    /// `homeManager(_:didUpdate:)` (authorization) or the initial status after `start()`.
    case authorizationChanged(HomeKitAuthorizationState)
    /// Homes, accessories, services or rooms changed (`homeManagerDidUpdateHomes`, accessory
    /// added/removed, room assignment). The consumer re-reads `lightbulbs()` and diffs.
    case homesChanged
    /// A characteristic value or name of a lightbulb service changed outside this app
    /// (`HMAccessoryDelegate.accessory(_:service:didUpdateValueFor:)`). `changed` is the
    /// characteristic that triggered the update, if known.
    case lightbulbUpdated(HomeKitLightbulb, changed: HomeKitCharacteristicKind?)
    /// `HMAccessoryDelegate.accessoryDidUpdateReachability(_:)`.
    case reachabilityChanged(accessoryID: UUID, reachable: Bool)
}

/// Abstraction of `HMHomeManager` and friends. HomeKit objects are main-thread objects and their
/// delegate callbacks arrive on the main queue, so the session is `@MainActor`; the provider actor
/// talks to it with `await`. Implementations: `HMHomeKitSession` (iOS) and test fakes.
@MainActor
public protocol HomeKitSession: AnyObject, Sendable {
    /// Session events. Single consumer (the provider).
    nonisolated var events: AsyncStream<HomeKitSessionEvent> { get }
    var authorizationState: HomeKitAuthorizationState { get }
    /// True once HomeKit delivered the home list at least once (`homeManagerDidUpdateHomes`).
    var isReady: Bool { get }
    /// Creates the home manager (shows the HomeKit permission prompt on first use). Idempotent.
    func start()
    /// Every lightbulb service in every home, with cached characteristic values. Also makes the
    /// session the delegate of the returned accessories.
    func lightbulbs() -> [HomeKitLightbulb]
    /// Writes characteristics of one service, in order. Throws `LightCoreError`.
    func write(_ writes: [HomeKitWrite], accessoryID: UUID, serviceID: UUID) async throws
    /// `enableNotification(true)` on the known characteristics of one service that support it.
    func enableNotifications(accessoryID: UUID, serviceID: UUID) async throws
}
