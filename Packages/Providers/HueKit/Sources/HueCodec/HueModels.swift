import Foundation

// Hand-written, lenient Codable models for the CLIP v2 resources SmartLights uses.
// Shapes follow GET responses of /clip/v2/resource/<type> (openhue-api spec, aiohue models).
// Unknown fields are ignored; everything except `id` (and `rid`/`rtype` in references) is optional.

/// Reference to another resource: `{"rid": "<uuid>", "rtype": "device"}`.
public struct HueResourceIdentifier: Codable, Sendable, Hashable {
    public var rid: String
    public var rtype: String

    public init(rid: String, rtype: String) {
        self.rid = rid
        self.rtype = rtype
    }
}

/// CLIP v2 resource type names used by SmartLights.
public enum HueResourceType {
    public static let light = "light"
    public static let groupedLight = "grouped_light"
    public static let room = "room"
    public static let zone = "zone"
    public static let bridgeHome = "bridge_home"
    public static let scene = "scene"
    public static let device = "device"
    public static let bridge = "bridge"
    public static let zigbeeConnectivity = "zigbee_connectivity"
    public static let entertainmentConfiguration = "entertainment_configuration"
    public static let geofenceClient = "geofence_client"
}

public struct HueMetadata: Codable, Sendable, Hashable {
    public var name: String?
    public var archetype: String?
    /// Lights only: "functional" | "decorative" | "mixed" | "unknown".
    public var function: String?

    public init(name: String? = nil, archetype: String? = nil, function: String? = nil) {
        self.name = name
        self.archetype = archetype
        self.function = function
    }
}

public struct HueOn: Codable, Sendable, Hashable {
    public var on: Bool?

    public init(on: Bool?) { self.on = on }
}

public struct HueDimming: Codable, Sendable, Hashable {
    /// 0...100 (percent).
    public var brightness: Double?
    /// Lowest brightness percentage the lamp supports.
    public var minDimLevel: Double?

    enum CodingKeys: String, CodingKey {
        case brightness
        case minDimLevel = "min_dim_level"
    }

    public init(brightness: Double? = nil, minDimLevel: Double? = nil) {
        self.brightness = brightness
        self.minDimLevel = minDimLevel
    }
}

public struct HueXY: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HueGamut: Codable, Sendable, Hashable {
    public var red: HueXY?
    public var green: HueXY?
    public var blue: HueXY?

    public init(red: HueXY?, green: HueXY?, blue: HueXY?) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct HueColor: Codable, Sendable, Hashable {
    public var xy: HueXY?
    public var gamut: HueGamut?
    /// "A" | "B" | "C" | "other".
    public var gamutType: String?

    enum CodingKeys: String, CodingKey {
        case xy, gamut
        case gamutType = "gamut_type"
    }

    public init(xy: HueXY? = nil, gamut: HueGamut? = nil, gamutType: String? = nil) {
        self.xy = xy
        self.gamut = gamut
        self.gamutType = gamutType
    }
}

public struct HueMirekSchema: Codable, Sendable, Hashable {
    public var mirekMinimum: Int?
    public var mirekMaximum: Int?

    enum CodingKeys: String, CodingKey {
        case mirekMinimum = "mirek_minimum"
        case mirekMaximum = "mirek_maximum"
    }

    public init(mirekMinimum: Int?, mirekMaximum: Int?) {
        self.mirekMinimum = mirekMinimum
        self.mirekMaximum = mirekMaximum
    }
}

public struct HueColorTemperature: Codable, Sendable, Hashable {
    /// `null` while the light is in xy mode.
    public var mirek: Int?
    /// False when the current colour is not on the Planckian locus (xy mode).
    public var mirekValid: Bool?
    public var mirekSchema: HueMirekSchema?

    enum CodingKeys: String, CodingKey {
        case mirek
        case mirekValid = "mirek_valid"
        case mirekSchema = "mirek_schema"
    }

    public init(mirek: Int? = nil, mirekValid: Bool? = nil, mirekSchema: HueMirekSchema? = nil) {
        self.mirek = mirek
        self.mirekValid = mirekValid
        self.mirekSchema = mirekSchema
    }
}

public struct HueDynamics: Codable, Sendable, Hashable {
    /// "none" | "dynamic_palette".
    public var status: String?
    public var statusValues: [String]?
    public var speed: Double?
    public var speedValid: Bool?

    enum CodingKeys: String, CodingKey {
        case status, speed
        case statusValues = "status_values"
        case speedValid = "speed_valid"
    }
}

public struct HueEffects: Codable, Sendable, Hashable {
    /// Effects the light accepts in `effects.effect` (includes "no_effect").
    public var effectValues: [String]?
    /// Current effect ("no_effect" when none).
    public var status: String?
    public var statusValues: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case effectValues = "effect_values"
        case statusValues = "status_values"
    }

    public init(effectValues: [String]? = nil, status: String? = nil, statusValues: [String]? = nil) {
        self.effectValues = effectValues
        self.status = status
        self.statusValues = statusValues
    }
}

// MARK: - Resources

/// `light` resource.
public struct HueLight: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var idV1: String?
    public var type: String?
    /// The `device` this light service belongs to.
    public var owner: HueResourceIdentifier?
    public var metadata: HueMetadata?
    public var on: HueOn?
    public var dimming: HueDimming?
    public var colorTemperature: HueColorTemperature?
    public var color: HueColor?
    public var dynamics: HueDynamics?
    public var effects: HueEffects?
    /// "normal" | "streaming" (Entertainment).
    public var mode: String?

    enum CodingKeys: String, CodingKey {
        case id, type, owner, metadata, on, dimming, color, dynamics, effects, mode
        case idV1 = "id_v1"
        case colorTemperature = "color_temperature"
    }

    public init(
        id: String, owner: HueResourceIdentifier? = nil, metadata: HueMetadata? = nil, on: HueOn? = nil,
        dimming: HueDimming? = nil, colorTemperature: HueColorTemperature? = nil, color: HueColor? = nil,
        effects: HueEffects? = nil
    ) {
        self.id = id
        self.type = HueResourceType.light
        self.owner = owner
        self.metadata = metadata
        self.on = on
        self.dimming = dimming
        self.colorTemperature = colorTemperature
        self.color = color
        self.effects = effects
    }
}

/// `grouped_light` resource (service of a room, zone or bridge_home).
public struct HueGroupedLight: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var idV1: String?
    public var type: String?
    /// The room / zone / bridge_home this group controls.
    public var owner: HueResourceIdentifier?
    public var on: HueOn?
    public var dimming: HueDimming?

    enum CodingKeys: String, CodingKey {
        case id, type, owner, on, dimming
        case idV1 = "id_v1"
    }
}

/// `room` or `zone` resource (identical shape). Rooms list devices as children, zones list
/// light services.
public struct HueGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var idV1: String?
    /// "room" or "zone".
    public var type: String?
    public var metadata: HueMetadata?
    public var children: [HueResourceIdentifier]?
    /// Contains the `grouped_light` of this room/zone.
    public var services: [HueResourceIdentifier]?

    enum CodingKeys: String, CodingKey {
        case id, type, metadata, children, services
        case idV1 = "id_v1"
    }

    /// The `grouped_light` service id, if any.
    public var groupedLightID: String? {
        services?.first { $0.rtype == HueResourceType.groupedLight }?.rid
    }
}

/// One action of a scene: the target light and the state to apply.
public struct HueSceneAction: Codable, Sendable, Hashable {
    public struct Action: Codable, Sendable, Hashable {
        public var on: HueOn?
        public var dimming: HueDimming?
        public var color: HueColor?
        public var colorTemperature: HueColorTemperature?

        enum CodingKeys: String, CodingKey {
            case on, dimming, color
            case colorTemperature = "color_temperature"
        }
    }

    public var target: HueResourceIdentifier?
    public var action: Action?
}

public struct HueSceneStatus: Codable, Sendable, Hashable {
    /// "inactive" | "static" | "dynamic_palette".
    public var active: String?
    public var lastRecall: String?

    enum CodingKeys: String, CodingKey {
        case active
        case lastRecall = "last_recall"
    }
}

/// `scene` resource.
public struct HueScene: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var idV1: String?
    public var type: String?
    public var metadata: HueMetadata?
    /// Room or zone the scene belongs to.
    public var group: HueResourceIdentifier?
    public var actions: [HueSceneAction]?
    public var speed: Double?
    public var autoDynamic: Bool?
    public var status: HueSceneStatus?

    enum CodingKeys: String, CodingKey {
        case id, type, metadata, group, actions, speed, status
        case idV1 = "id_v1"
        case autoDynamic = "auto_dynamic"
    }
}

public struct HueProductData: Codable, Sendable, Hashable {
    public var modelID: String?
    public var manufacturerName: String?
    public var productName: String?
    public var productArchetype: String?
    public var certified: Bool?
    public var softwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case certified
        case modelID = "model_id"
        case manufacturerName = "manufacturer_name"
        case productName = "product_name"
        case productArchetype = "product_archetype"
        case softwareVersion = "software_version"
    }
}

/// `device` resource (a physical product; its `services` include `light`, `zigbee_connectivity`, ...).
public struct HueDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var idV1: String?
    public var type: String?
    public var metadata: HueMetadata?
    public var productData: HueProductData?
    public var services: [HueResourceIdentifier]?

    enum CodingKeys: String, CodingKey {
        case id, type, metadata, services
        case idV1 = "id_v1"
        case productData = "product_data"
    }

    public func serviceIDs(ofType rtype: String) -> [String] {
        (services ?? []).filter { $0.rtype == rtype }.map(\.rid)
    }
}

/// `bridge` resource.
public struct HueBridgeResource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var owner: HueResourceIdentifier?
    /// Lower-case bridge id (16 hex chars).
    public var bridgeID: String?
    public var timeZone: TimeZoneInfo?

    public struct TimeZoneInfo: Codable, Sendable, Hashable {
        public var timeZone: String?
        enum CodingKeys: String, CodingKey { case timeZone = "time_zone" }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, owner
        case bridgeID = "bridge_id"
        case timeZone = "time_zone"
    }
}

/// `zigbee_connectivity` resource: reachability of a device.
public struct HueZigbeeConnectivity: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var owner: HueResourceIdentifier?
    /// "connected" | "disconnected" | "connectivity_issue" | "unidirectional_incoming".
    public var status: String?
    public var macAddress: String?

    enum CodingKeys: String, CodingKey {
        case id, type, owner, status
        case macAddress = "mac_address"
    }

    /// Unknown status counts as connected (lenient).
    public var isConnected: Bool { status == nil || status == "connected" }
}

/// `entertainment_configuration` resource (minimal: used to list areas for phase-3 streaming).
public struct HueEntertainmentConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var metadata: HueMetadata?
    /// "screen" | "monitor" | "music" | "3dspace" | "other".
    public var configurationType: String?
    /// "active" | "inactive".
    public var status: String?
    public var lightServices: [HueResourceIdentifier]?

    enum CodingKeys: String, CodingKey {
        case id, type, metadata, status
        case configurationType = "configuration_type"
        case lightServices = "light_services"
    }
}

/// `geofence_client` resource (used only for the event-stream keep-alive workaround).
public struct HueGeofenceClient: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var name: String?
}

// MARK: - Envelope

/// One entry of the CLIP v2 `errors` array.
public struct HueAPIErrorEntry: Codable, Sendable, Hashable {
    public var description: String?

    public init(description: String?) { self.description = description }
}

/// Every CLIP v2 response: `{"errors": [...], "data": [...]}`.
public struct ResourceEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public var errors: [HueAPIErrorEntry]?
    public var data: T?

    public init(errors: [HueAPIErrorEntry]? = nil, data: T? = nil) {
        self.errors = errors
        self.data = data
    }

    /// Error descriptions, joined (empty string if none).
    public var errorDescription: String {
        (errors ?? []).compactMap(\.description).joined(separator: "; ")
    }
}

/// Decodes an array element by element, dropping elements that fail to decode (lenient lists).
public struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    public var elements: [Element]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                out.append(value)
            } else if (try? container.decode(JSONValue.self)) == nil {
                break
            }
        }
        elements = out
    }
}
