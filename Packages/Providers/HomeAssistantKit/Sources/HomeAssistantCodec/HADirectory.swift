import Foundation
import LightCore

/// Light/scene identities for one Home Assistant instance.
///
/// - Light id: `homeassistant:<instanceID>/<key>`, where `key` is the entity registry entry id
///   (stable across `entity_id` renames) or, for entities without a registry entry (YAML lights
///   without `unique_id`), the `entity_id`.
/// - Scene id: `homeassistant:<instanceID>/<scene entity_id>`.
/// - `providerRef`: `<instanceID>/<entity_id>`.
///
/// `instanceID` is the HA installation uuid from Bonjour (`_home-assistant._tcp` TXT `uuid`) when
/// discovered that way, otherwise a uuid generated at pairing time; never a host or IP.
public enum HAIdentifiers {
    public static func lightID(instanceID: String, key: String) -> LightID? {
        LightID(brand: .homeAssistant, stableId: "\(instanceID)/\(key)")
    }

    public static func sceneID(instanceID: String, entityID: String) -> LightScene.ID {
        "\(Brand.homeAssistant.rawValue):\(instanceID)/\(entityID)"
    }

    /// Splits a light id / scene id / providerRef into `(instanceID, key)`.
    public static func split(_ stableId: String) -> (instanceID: String, key: String)? {
        let raw = stableId.hasPrefix("\(Brand.homeAssistant.rawValue):")
            ? String(stableId.dropFirst(Brand.homeAssistant.rawValue.count + 1)) : stableId
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let instance = String(raw[..<slash])
        let key = String(raw[raw.index(after: slash)...])
        guard !instance.isEmpty, !key.isEmpty else { return nil }
        return (instance, key)
    }
}

/// Registry snapshot (entities, devices, areas) used for names, room hints and stable keys.
public struct HARegistry: Sendable, Hashable {
    public var entities: [String: HAEntityRegistryEntry]
    public var devices: [String: HADeviceRegistryEntry]
    public var areas: [String: HAAreaRegistryEntry]

    public init(
        entities: [HAEntityRegistryEntry] = [], devices: [HADeviceRegistryEntry] = [], areas: [HAAreaRegistryEntry] = []
    ) {
        self.entities = Dictionary(entities.map { ($0.entityID, $0) }, uniquingKeysWith: { _, last in last })
        self.devices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.areas = Dictionary(areas.map { ($0.areaID, $0) }, uniquingKeysWith: { _, last in last })
    }

    public static let empty = HARegistry()

    /// Stable key for an entity: its registry entry id if registered, else the entity_id.
    public func key(for entityID: String) -> String {
        if let id = entities[entityID]?.id, LightID(brand: .homeAssistant, stableId: "x/\(id)") != nil { return id }
        return entityID
    }

    /// Area name for the entity: the entity's own area, else its device's area.
    public func areaName(for entityID: String) -> String? {
        guard let entry = entities[entityID] else { return nil }
        let areaID = entry.areaID ?? entry.deviceID.flatMap { devices[$0]?.areaID }
        return areaID.flatMap { areas[$0]?.name }
    }

    /// Hidden or disabled entities are skipped (HA's own UI hides them too).
    public func isHidden(_ entityID: String) -> Bool {
        guard let entry = entities[entityID] else { return false }
        return entry.isDisabled || entry.hiddenBy != nil
    }
}

extension HALightMapping {
    /// `Light` for a `light.*` state; nil for other domains or hidden/disabled entities.
    public static func light(for state: HAEntityState, instanceID: String, registry: HARegistry, now: Date = Date()) -> Light? {
        guard state.domain == "light", !registry.isHidden(state.entityID),
            let id = HAIdentifiers.lightID(instanceID: instanceID, key: registry.key(for: state.entityID))
        else { return nil }
        let entry = registry.entities[state.entityID]
        let device = entry?.deviceID.flatMap { registry.devices[$0] }
        // `friendly_name` already reflects the user's registry name override and HA's
        // device-name composition, so it is preferred over the raw registry fields.
        let name = state.friendlyName ?? entry?.name ?? entry?.originalName ?? state.entityID
        return Light(
            id: id,
            name: name,
            roomHint: registry.areaName(for: state.entityID),
            capabilities: capabilities(for: state),
            state: lightState(for: state, now: now),
            providerRef: "\(instanceID)/\(state.entityID)",
            manufacturer: device?.manufacturer,
            model: device?.model ?? entry?.platform)
    }

    /// Vendor scene for a `scene.*` state.
    public static func scene(for state: HAEntityState, instanceID: String, registry: HARegistry) -> LightScene? {
        guard state.domain == "scene", !registry.isHidden(state.entityID) else { return nil }
        let entityIDs = state.attributes["entity_id"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let lights = entityIDs.filter { HAEntityID.domain(of: $0) == "light" }.compactMap {
            HAIdentifiers.lightID(instanceID: instanceID, key: registry.key(for: $0))
        }
        return LightScene(
            id: HAIdentifiers.sceneID(instanceID: instanceID, entityID: state.entityID),
            name: state.friendlyName ?? state.entityID,
            kind: .vendor,
            brand: .homeAssistant,
            roomHint: registry.areaName(for: state.entityID),
            lightIDs: lights)
    }

    /// `scene.turn_on` for a scene entity.
    public static func sceneCall(entityID: String, transition: Duration? = nil) -> HAServiceCall {
        var data: [String: HAJSONValue] = [:]
        if let transition { data["transition"] = .double(transition.seconds) }
        return HAServiceCall(domain: "scene", service: "turn_on", serviceData: data, target: HAServiceTarget(entityIDs: [entityID]))
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
