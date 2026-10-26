// The only file that touches the HomeKit framework. HomeKit has no AppKit (native macOS) API, and
// does not exist on Linux, so this compiles to nothing there; the iOS simulator CI build
// (IOS_ONLY) compiles it. HomeKit itself does not work in the Simulator: logic is tested via fakes.
#if canImport(HomeKit) && !os(macOS)
@preconcurrency import HomeKit
import Foundation
import LightCore

/// `HomeKitSession` backed by `HMHomeManager`. Main-actor bound: HomeKit objects are used and its
/// delegate callbacks are delivered on the main queue.
@MainActor
public final class HMHomeKitSession: NSObject, HomeKitSession {
    public nonisolated let events: AsyncStream<HomeKitSessionEvent>
    private nonisolated let continuation: AsyncStream<HomeKitSessionEvent>.Continuation
    private var manager: HMHomeManager?
    private nonisolated let log = Log(package: "homekitprovider", category: "session")

    public private(set) var isReady = false

    /// Does not touch HomeKit; the home manager (and the permission prompt) is created by `start()`.
    public nonisolated override init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: HomeKitSessionEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        self.events = stream
        self.continuation = continuation
        super.init()
    }

    deinit {
        continuation.finish()
    }

    public var authorizationState: HomeKitAuthorizationState {
        guard let manager else { return .notDetermined }
        return Self.map(manager.authorizationStatus)
    }

    public func start() {
        guard manager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
        continuation.yield(.authorizationChanged(Self.map(manager.authorizationStatus)))
    }

    public func lightbulbs() -> [HomeKitLightbulb] {
        guard let manager else { return [] }
        var result: [HomeKitLightbulb] = []
        for home in manager.homes {
            home.delegate = self
            let wholeHome = home.roomForEntireHome()
            for accessory in home.accessories {
                let services = accessory.services.filter { $0.serviceType == HMServiceTypeLightbulb }
                if services.isEmpty { continue }
                accessory.delegate = self
                for service in services {
                    result.append(Self.snapshot(home: home, wholeHome: wholeHome, accessory: accessory, service: service))
                }
            }
        }
        return result
    }

    public func write(_ writes: [HomeKitWrite], accessoryID: UUID, serviceID: UUID) async throws {
        guard let found = find(accessoryID: accessoryID, serviceID: serviceID) else {
            throw LightCoreError.unreachable("accessory is no longer in Apple Home")
        }
        let accessory = found.accessory
        let service = found.service
        guard accessory.isReachable else {
            throw LightCoreError.unreachable("\(accessory.name) is not responding in Apple Home")
        }
        for write in writes {
            guard let characteristic = Self.characteristic(write.kind, in: service) else {
                throw LightCoreError.unsupported("\(accessory.name) has no \(write.kind.rawValue) characteristic")
            }
            let value = Self.homeKitValue(for: write)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                characteristic.writeValue(value) { @Sendable error in
                    if let error {
                        cont.resume(throwing: HMHomeKitSession.mapError(error))
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    public func enableNotifications(accessoryID: UUID, serviceID: UUID) async throws {
        guard let service = find(accessoryID: accessoryID, serviceID: serviceID)?.service else { return }
        for characteristic in service.characteristics {
            guard Self.kind(of: characteristic) != nil,
                  characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
                  !characteristic.isNotificationEnabled else { continue }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                characteristic.enableNotification(true) { @Sendable error in
                    if let error {
                        cont.resume(throwing: HMHomeKitSession.mapError(error))
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func find(accessoryID: UUID, serviceID: UUID) -> (accessory: HMAccessory, service: HMService)? {
        guard let manager else { return nil }
        for home in manager.homes {
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else { continue }
            guard let service = accessory.services.first(where: { $0.uniqueIdentifier == serviceID }) else { return nil }
            return (accessory, service)
        }
        return nil
    }

    private func home(of accessory: HMAccessory) -> HMHome? {
        manager?.homes.first { home in home.accessories.contains { $0.uniqueIdentifier == accessory.uniqueIdentifier } }
    }

    private func publishUpdate(accessory: HMAccessory, service: HMService, changed: HomeKitCharacteristicKind?) {
        guard service.serviceType == HMServiceTypeLightbulb, let home = home(of: accessory) else { return }
        let snapshot = Self.snapshot(home: home, wholeHome: home.roomForEntireHome(), accessory: accessory, service: service)
        continuation.yield(.lightbulbUpdated(snapshot, changed: changed))
    }

    private static func snapshot(home: HMHome, wholeHome: HMRoom, accessory: HMAccessory, service: HMService) -> HomeKitLightbulb {
        var characteristics: [HomeKitCharacteristicKind: HomeKitCharacteristicSnapshot] = [:]
        for characteristic in service.characteristics {
            guard let kind = kind(of: characteristic) else { continue }
            let metadata = characteristic.metadata
            characteristics[kind] = HomeKitCharacteristicSnapshot(
                value: number(characteristic.value),
                minimum: metadata?.minimumValue?.doubleValue,
                maximum: metadata?.maximumValue?.doubleValue,
                step: metadata?.stepValue?.doubleValue,
                isWritable: characteristic.properties.contains(HMCharacteristicPropertyWritable),
                supportsNotification: characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
            )
        }
        var roomName: String?
        if let room = accessory.room, room.uniqueIdentifier != wholeHome.uniqueIdentifier {
            roomName = room.name
        }
        return HomeKitLightbulb(
            accessoryID: accessory.uniqueIdentifier,
            serviceID: service.uniqueIdentifier,
            accessoryName: accessory.name,
            serviceName: service.name,
            manufacturer: accessory.manufacturer,
            model: accessory.model,
            firmwareVersion: accessory.firmwareVersion,
            roomName: roomName,
            homeID: home.uniqueIdentifier,
            homeName: home.name,
            isReachable: accessory.isReachable,
            characteristics: characteristics
        )
    }

    private static func kind(of characteristic: HMCharacteristic) -> HomeKitCharacteristicKind? {
        kind(ofType: characteristic.characteristicType)
    }

    private static func kind(ofType type: String) -> HomeKitCharacteristicKind? {
        if type == HMCharacteristicTypePowerState { return .powerState }
        if type == HMCharacteristicTypeBrightness { return .brightness }
        if type == HMCharacteristicTypeHue { return .hue }
        if type == HMCharacteristicTypeSaturation { return .saturation }
        if type == HMCharacteristicTypeColorTemperature { return .colorTemperature }
        return nil
    }

    private static func characteristic(_ kind: HomeKitCharacteristicKind, in service: HMService) -> HMCharacteristic? {
        service.characteristics.first { Self.kind(of: $0) == kind }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let b = value as? Bool { return b ? 1 : 0 }
        if let i = value as? Int { return Double(i) }
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        return nil
    }

    /// HomeKit value for a write: bool for power, int for brightness / colour temperature,
    /// float for hue / saturation (HAP formats).
    private static func homeKitValue(for write: HomeKitWrite) -> NSNumber {
        switch write.kind {
        case .powerState: NSNumber(value: write.value != 0)
        case .brightness, .colorTemperature: NSNumber(value: Int(write.value.rounded()))
        case .hue, .saturation: NSNumber(value: Float(write.value))
        }
    }

    private static func map(_ status: HMHomeManagerAuthorizationStatus) -> HomeKitAuthorizationState {
        if !status.contains(.determined) { return .notDetermined }
        if status.contains(.authorized) { return .authorized }
        if status.contains(.restricted) { return .restricted }
        return .denied
    }

    /// Maps HomeKit errors to `LightCoreError`. HMError 80 ("Missing entitlement for API",
    /// "Handler does not support background access") is what extensions get since iOS 18.4.
    nonisolated static func mapError(_ error: any Error) -> any Error {
        let ns = error as NSError
        if ns.domain == "HMErrorDomain" && ns.code == 80 {
            return LightCoreError.unsupported(
                "HomeKit is only available while SmartLights is in the foreground (HMError 80)"
            )
        }
        return LightCoreError.transport("HomeKit \(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}

// MARK: - Delegates (delivered on the main queue)

extension HMHomeKitSession: @preconcurrency HMHomeManagerDelegate {
    public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        isReady = true
        for home in manager.homes { home.delegate = self }
        continuation.yield(.homesChanged)
    }

    public func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        home.delegate = self
        continuation.yield(.homesChanged)
    }

    public func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        continuation.yield(.homesChanged)
    }

    public func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        log.info("HomeKit authorization status changed: \(status.rawValue)")
        continuation.yield(.authorizationChanged(Self.map(status)))
    }
}

extension HMHomeKitSession: @preconcurrency HMHomeDelegate {
    public func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        continuation.yield(.homesChanged)
    }

    public func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        continuation.yield(.homesChanged)
    }

    public func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        continuation.yield(.homesChanged)
    }

    public func home(_ home: HMHome, didUpdateNameFor room: HMRoom) {
        continuation.yield(.homesChanged)
    }

    public func homeDidUpdateName(_ home: HMHome) {
        continuation.yield(.homesChanged)
    }
}

extension HMHomeKitSession: @preconcurrency HMAccessoryDelegate {
    public func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        publishUpdate(accessory: accessory, service: service, changed: Self.kind(of: characteristic))
    }

    public func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        continuation.yield(.reachabilityChanged(accessoryID: accessory.uniqueIdentifier, reachable: accessory.isReachable))
    }

    public func accessoryDidUpdateName(_ accessory: HMAccessory) {
        for service in accessory.services where service.serviceType == HMServiceTypeLightbulb {
            publishUpdate(accessory: accessory, service: service, changed: nil)
        }
    }

    public func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        publishUpdate(accessory: accessory, service: service, changed: nil)
    }

    public func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        continuation.yield(.homesChanged)
    }
}

extension HomeKitProvider {
    /// A provider backed by the real HomeKit framework. Create once, on the main actor, and register
    /// it with `ProviderRegistry`; the permission prompt appears on first use (`start`/`loadLights`).
    @MainActor
    public static func live(readyTimeout: Duration = .seconds(8)) -> HomeKitProvider {
        HomeKitProvider(session: HMHomeKitSession(), readyTimeout: readyTimeout)
    }
}
#endif
