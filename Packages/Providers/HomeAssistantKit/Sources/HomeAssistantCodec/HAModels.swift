import Foundation

/// One entity state from `get_states` or a `state_changed` event.
///
/// ```json
/// {"entity_id":"light.bed_light","state":"on","attributes":{"brightness":180,...},
///  "last_changed":"2016-11-26T01:37:24.265390+00:00","last_updated":"...","context":{...}}
/// ```
public struct HAEntityState: Sendable, Hashable {
    public var entityID: String
    /// `"on"`, `"off"`, `"unavailable"`, `"unknown"`, or a domain-specific value.
    public var state: String
    public var attributes: [String: HAJSONValue]
    public var lastChanged: Date?
    public var lastUpdated: Date?

    public init(
        entityID: String, state: String, attributes: [String: HAJSONValue] = [:],
        lastChanged: Date? = nil, lastUpdated: Date? = nil
    ) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
        self.lastUpdated = lastUpdated
    }

    /// Lenient: anything without `entity_id` + `state` is rejected (nil), unknown keys ignored.
    public init?(json: HAJSONValue) {
        guard let entityID = json["entity_id"]?.stringValue, let state = json["state"]?.stringValue else { return nil }
        self.init(
            entityID: entityID, state: state,
            attributes: json["attributes"]?.objectValue ?? [:],
            lastChanged: json["last_changed"]?.stringValue.flatMap(HADate.parse),
            lastUpdated: json["last_updated"]?.stringValue.flatMap(HADate.parse))
    }

    /// `"light"` for `"light.kitchen"`.
    public var domain: String { HAEntityID.domain(of: entityID) }

    public var friendlyName: String? { attributes["friendly_name"]?.stringValue }

    /// HA marks entities whose integration lost the device as `unavailable`.
    public var isAvailable: Bool { state != HAEntityState.unavailable }

    public static let unavailable = "unavailable"
    public static let unknown = "unknown"

    /// The JSON form (used by tests and the fake server).
    public var json: HAJSONValue {
        var o: [String: HAJSONValue] = [
            "entity_id": .string(entityID), "state": .string(state), "attributes": .object(attributes),
        ]
        if let lastChanged { o["last_changed"] = .string(HADate.format(lastChanged)) }
        if let lastUpdated { o["last_updated"] = .string(HADate.format(lastUpdated)) }
        return .object(o)
    }

    /// Parses a `get_states` result.
    public static func list(from result: HAJSONValue) -> [HAEntityState] {
        (result.arrayValue ?? []).compactMap(HAEntityState.init(json:))
    }
}

/// Entity id helpers (`<domain>.<object_id>`).
public enum HAEntityID {
    public static func domain(of entityID: String) -> String {
        entityID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// `light.kitchen` style ids: lowercase domain, a dot, a non-empty object id, no whitespace.
    public static func isValid(_ entityID: String) -> Bool {
        let parts = entityID.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return !entityID.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

/// HA timestamps: ISO 8601 with microseconds and offset (`2016-11-26T01:37:24.265390+00:00`).
public enum HADate {
    public static func parse(_ string: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        // Microsecond precision is not accepted by every Foundation version: retry truncated to ms.
        if let dot = string.firstIndex(of: "."),
            let zone = string[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        {
            let digits = string[string.index(after: dot)..<zone]
            let trimmed = String(string[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                + String(string[zone...])
            return try? fractional.parse(trimmed)
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// One entry of `config/entity_registry/list`. Only the fields used for naming and rooms are
/// modelled; everything is optional except `entity_id` so older/newer cores decode.
public struct HAEntityRegistryEntry: Sendable, Hashable, Codable {
    public var entityID: String
    /// Registry entry id (a stable uuid hex; survives entity_id renames).
    public var id: String?
    public var uniqueID: String?
    public var platform: String?
    public var name: String?
    public var originalName: String?
    public var areaID: String?
    public var deviceID: String?
    public var disabledBy: String?
    public var hiddenBy: String?
    public var entityCategory: String?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case id
        case uniqueID = "unique_id"
        case platform
        case name
        case originalName = "original_name"
        case areaID = "area_id"
        case deviceID = "device_id"
        case disabledBy = "disabled_by"
        case hiddenBy = "hidden_by"
        case entityCategory = "entity_category"
    }

    public init(
        entityID: String, id: String? = nil, uniqueID: String? = nil, platform: String? = nil, name: String? = nil,
        originalName: String? = nil, areaID: String? = nil, deviceID: String? = nil, disabledBy: String? = nil,
        hiddenBy: String? = nil, entityCategory: String? = nil
    ) {
        self.entityID = entityID
        self.id = id
        self.uniqueID = uniqueID
        self.platform = platform
        self.name = name
        self.originalName = originalName
        self.areaID = areaID
        self.deviceID = deviceID
        self.disabledBy = disabledBy
        self.hiddenBy = hiddenBy
        self.entityCategory = entityCategory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        id = Self.string(c, .id)
        uniqueID = Self.string(c, .uniqueID)
        platform = Self.string(c, .platform)
        name = Self.string(c, .name)
        originalName = Self.string(c, .originalName)
        areaID = Self.string(c, .areaID)
        deviceID = Self.string(c, .deviceID)
        disabledBy = Self.string(c, .disabledBy)
        hiddenBy = Self.string(c, .hiddenBy)
        entityCategory = Self.string(c, .entityCategory)
    }

    /// Tolerates wrong types (`unique_id` may be numeric for some integrations).
    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard let value = try? c.decodeIfPresent(HAJSONValue.self, forKey: key) else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        default: return nil
        }
    }

    public var isDisabled: Bool { disabledBy != nil }

    public static func list(from result: HAJSONValue) -> [HAEntityRegistryEntry] {
        (result.arrayValue ?? []).compactMap { try? $0.decode(HAEntityRegistryEntry.self) }
    }
}

/// One entry of `config/area_registry/list` (`{"area_id":"living_room","name":"Living Room",...}`).
public struct HAAreaRegistryEntry: Sendable, Hashable, Codable {
    public var areaID: String
    public var name: String
    public var floorID: String?

    enum CodingKeys: String, CodingKey {
        case areaID = "area_id"
        case name
        case floorID = "floor_id"
    }

    public init(areaID: String, name: String, floorID: String? = nil) {
        self.areaID = areaID
        self.name = name
        self.floorID = floorID
    }

    public static func list(from result: HAJSONValue) -> [HAAreaRegistryEntry] {
        (result.arrayValue ?? []).compactMap { try? $0.decode(HAAreaRegistryEntry.self) }
    }
}

/// One entry of `config/device_registry/list`; entities without an `area_id` inherit their
/// device's area.
public struct HADeviceRegistryEntry: Sendable, Hashable, Codable {
    public var id: String
    public var areaID: String?
    public var name: String?
    public var nameByUser: String?
    public var manufacturer: String?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case id
        case areaID = "area_id"
        case name
        case nameByUser = "name_by_user"
        case manufacturer
        case model
    }

    public init(
        id: String, areaID: String? = nil, name: String? = nil, nameByUser: String? = nil,
        manufacturer: String? = nil, model: String? = nil
    ) {
        self.id = id
        self.areaID = areaID
        self.name = name
        self.nameByUser = nameByUser
        self.manufacturer = manufacturer
        self.model = model
    }

    public static func list(from result: HAJSONValue) -> [HADeviceRegistryEntry] {
        (result.arrayValue ?? []).compactMap { try? $0.decode(HADeviceRegistryEntry.self) }
    }
}

/// The parts of `get_config` the provider shows (instance name and version).
public struct HAConfig: Sendable, Hashable {
    public var locationName: String?
    public var version: String?
    public var internalURL: String?
    public var externalURL: String?

    public init(locationName: String? = nil, version: String? = nil, internalURL: String? = nil, externalURL: String? = nil) {
        self.locationName = locationName
        self.version = version
        self.internalURL = internalURL
        self.externalURL = externalURL
    }

    public init(json: HAJSONValue) {
        self.init(
            locationName: json["location_name"]?.stringValue, version: json["version"]?.stringValue,
            internalURL: json["internal_url"]?.stringValue, externalURL: json["external_url"]?.stringValue)
    }
}
