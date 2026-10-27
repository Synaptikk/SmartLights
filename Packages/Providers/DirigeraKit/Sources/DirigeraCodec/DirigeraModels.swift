import Foundation

/// Room a device is assigned to in the IKEA Home smart app.
public struct DirigeraRoom: Codable, Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `capabilities.canReceive` lists the attributes a device accepts in a PATCH.
public struct DirigeraCapabilities: Codable, Sendable, Hashable {
    public var canSend: [String]
    public var canReceive: [String]

    public init(canSend: [String] = [], canReceive: [String] = []) {
        self.canSend = canSend
        self.canReceive = canReceive
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canSend = (try? c.decodeIfPresent([String].self, forKey: .canSend)) ?? []
        canReceive = (try? c.decodeIfPresent([String].self, forKey: .canReceive)) ?? []
    }
}

/// The light-related subset of a device's `attributes` (Leggin/dirigera `LightAttributes`).
/// Unknown attributes are ignored; numbers are accepted as integers or doubles.
public struct DirigeraLightAttributes: Codable, Sendable, Hashable {
    public var customName: String?
    public var model: String?
    public var manufacturer: String?
    public var firmwareVersion: String?
    public var serialNumber: String?
    public var productCode: String?
    public var isOn: Bool?
    /// 1...100.
    public var lightLevel: Int?
    /// Kelvin.
    public var colorTemperature: Int?
    /// Bounds as reported. Usually Kelvin with min > max (warmest last); some bulbs (KAJPLATS)
    /// report mireds. Use `DirigeraMapping.kelvinRange`.
    public var colorTemperatureMin: Int?
    public var colorTemperatureMax: Int?
    /// Degrees 0...360.
    public var colorHue: Double?
    /// 0...1.
    public var colorSaturation: Double?
    /// `color` or `temperature`.
    public var colorMode: String?

    public init(customName: String? = nil, model: String? = nil, manufacturer: String? = nil, firmwareVersion: String? = nil,
                serialNumber: String? = nil, productCode: String? = nil, isOn: Bool? = nil, lightLevel: Int? = nil,
                colorTemperature: Int? = nil, colorTemperatureMin: Int? = nil, colorTemperatureMax: Int? = nil,
                colorHue: Double? = nil, colorSaturation: Double? = nil, colorMode: String? = nil) {
        self.customName = customName
        self.model = model
        self.manufacturer = manufacturer
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.productCode = productCode
        self.isOn = isOn
        self.lightLevel = lightLevel
        self.colorTemperature = colorTemperature
        self.colorTemperatureMin = colorTemperatureMin
        self.colorTemperatureMax = colorTemperatureMax
        self.colorHue = colorHue
        self.colorSaturation = colorSaturation
        self.colorMode = colorMode
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case customName, model, manufacturer, firmwareVersion, serialNumber, productCode, isOn, lightLevel
        case colorTemperature, colorTemperatureMin, colorTemperatureMax, colorHue, colorSaturation, colorMode
    }

    public init(from decoder: any Decoder) throws {
        let raw = try [String: DirigeraJSON](from: decoder)
        self.init()
        merge(raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(customName, forKey: .customName)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try c.encodeIfPresent(firmwareVersion, forKey: .firmwareVersion)
        try c.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try c.encodeIfPresent(productCode, forKey: .productCode)
        try c.encodeIfPresent(isOn, forKey: .isOn)
        try c.encodeIfPresent(lightLevel, forKey: .lightLevel)
        try c.encodeIfPresent(colorTemperature, forKey: .colorTemperature)
        try c.encodeIfPresent(colorTemperatureMin, forKey: .colorTemperatureMin)
        try c.encodeIfPresent(colorTemperatureMax, forKey: .colorTemperatureMax)
        try c.encodeIfPresent(colorHue, forKey: .colorHue)
        try c.encodeIfPresent(colorSaturation, forKey: .colorSaturation)
        try c.encodeIfPresent(colorMode, forKey: .colorMode)
    }

    /// Applies a (partial) attribute object, e.g. from a `deviceStateChanged` event or a PATCH.
    public mutating func merge(_ attributes: [String: DirigeraJSON]) {
        for (key, value) in attributes {
            switch CodingKeys(rawValue: key) {
            case .customName: customName = value.stringValue ?? customName
            case .model: model = value.stringValue ?? model
            case .manufacturer: manufacturer = value.stringValue ?? manufacturer
            case .firmwareVersion: firmwareVersion = value.stringValue ?? firmwareVersion
            case .serialNumber: serialNumber = value.stringValue ?? serialNumber
            case .productCode: productCode = value.stringValue ?? productCode
            case .isOn: isOn = value.boolValue ?? isOn
            case .lightLevel: lightLevel = value.intValue ?? lightLevel
            case .colorTemperature: colorTemperature = value.intValue ?? colorTemperature
            case .colorTemperatureMin: colorTemperatureMin = value.intValue ?? colorTemperatureMin
            case .colorTemperatureMax: colorTemperatureMax = value.intValue ?? colorTemperatureMax
            case .colorHue: colorHue = value.doubleValue ?? colorHue
            case .colorSaturation: colorSaturation = value.doubleValue ?? colorSaturation
            case .colorMode: colorMode = value.stringValue ?? colorMode
            case nil: break
            }
        }
    }
}

/// One entry of `GET /v1/devices` (lenient: only the fields SmartLights uses).
public struct DirigeraDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `light`, `outlet`, `gateway`, `sensor`, `controller`, ...
    public var type: String
    public var deviceType: String?
    public var relationId: String?
    public var isReachable: Bool
    public var isHidden: Bool?
    public var attributes: DirigeraLightAttributes
    public var capabilities: DirigeraCapabilities
    public var room: DirigeraRoom?

    public init(id: String, type: String, deviceType: String? = nil, relationId: String? = nil, isReachable: Bool = true,
                isHidden: Bool? = nil, attributes: DirigeraLightAttributes = DirigeraLightAttributes(),
                capabilities: DirigeraCapabilities = DirigeraCapabilities(), room: DirigeraRoom? = nil) {
        self.id = id
        self.type = type
        self.deviceType = deviceType
        self.relationId = relationId
        self.isReachable = isReachable
        self.isHidden = isHidden
        self.attributes = attributes
        self.capabilities = capabilities
        self.room = room
    }

    enum CodingKeys: String, CodingKey {
        case id, type, deviceType, relationId, isReachable, isHidden, attributes, capabilities, room
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "unknown"
        deviceType = try? c.decodeIfPresent(String.self, forKey: .deviceType)
        relationId = try? c.decodeIfPresent(String.self, forKey: .relationId)
        isReachable = (try? c.decodeIfPresent(Bool.self, forKey: .isReachable)) ?? true
        isHidden = try? c.decodeIfPresent(Bool.self, forKey: .isHidden)
        attributes = (try? c.decodeIfPresent(DirigeraLightAttributes.self, forKey: .attributes)) ?? DirigeraLightAttributes()
        capabilities = (try? c.decodeIfPresent(DirigeraCapabilities.self, forKey: .capabilities)) ?? DirigeraCapabilities()
        room = try? c.decodeIfPresent(DirigeraRoom.self, forKey: .room)
    }

    /// Leggin/dirigera `get_lights()` filters on `type == "light"`.
    public var isLight: Bool { type == "light" }

    public var canReceive: Set<String> { Set(capabilities.canReceive) }

    /// Applies a partial update (event `data` or a PATCH we sent).
    public mutating func apply(_ update: DirigeraDeviceUpdate) {
        if let attributes = update.attributes { self.attributes.merge(attributes) }
        if let reachable = update.isReachable { isReachable = reachable }
        if let room = update.room { self.room = room }
    }
}

/// Partial device data carried by events.
public struct DirigeraDeviceUpdate: Sendable, Hashable {
    public var id: String
    public var type: String?
    public var attributes: [String: DirigeraJSON]?
    public var isReachable: Bool?
    public var room: DirigeraRoom?

    public init(id: String, type: String? = nil, attributes: [String: DirigeraJSON]? = nil, isReachable: Bool? = nil,
                room: DirigeraRoom? = nil) {
        self.id = id
        self.type = type
        self.attributes = attributes
        self.isReachable = isReachable
        self.room = room
    }

    public init?(_ data: DirigeraJSON) {
        guard let id = data["id"]?.stringValue else { return nil }
        self.id = id
        type = data["type"]?.stringValue
        attributes = data["attributes"]?.objectValue
        isReachable = data["isReachable"]?.boolValue
        if let room = data["room"], let roomID = room["id"]?.stringValue, let name = room["name"]?.stringValue {
            self.room = DirigeraRoom(id: roomID, name: name)
        }
    }
}

/// `GET /v1/hub/status`.
public struct DirigeraHubStatus: Codable, Sendable, Hashable {
    public struct Attributes: Codable, Sendable, Hashable {
        public var customName: String?
        public var model: String?
        public var firmwareVersion: String?
        public var serialNumber: String?

        public init(customName: String? = nil, model: String? = nil, firmwareVersion: String? = nil, serialNumber: String? = nil) {
            self.customName = customName
            self.model = model
            self.firmwareVersion = firmwareVersion
            self.serialNumber = serialNumber
        }
    }

    public var id: String
    public var attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }
}

/// One entry of `GET /v1/scenes` (only what is needed to list and trigger it).
public struct DirigeraScene: Codable, Sendable, Hashable, Identifiable {
    public struct Info: Codable, Sendable, Hashable {
        public var name: String
        public var icon: String?

        public init(name: String, icon: String? = nil) {
            self.name = name
            self.icon = icon
        }
    }

    public var id: String
    public var info: Info
    /// `userScene`, `customScene`, `wakeUpScene`, ...
    public var type: String?

    public init(id: String, info: Info, type: String? = nil) {
        self.id = id
        self.info = info
        self.type = type
    }
}

/// A WebSocket message: `{"id", "time", "specversion", "source", "type", "data"}`.
/// Types used: `deviceStateChanged`, `deviceAdded`, `deviceRemoved`, `sceneCreated`,
/// `sceneUpdated`, `sceneDeleted` (others are ignored).
public struct DirigeraEvent: Codable, Sendable, Hashable {
    public var id: String?
    public var type: String
    public var data: DirigeraJSON?

    public init(id: String? = nil, type: String, data: DirigeraJSON? = nil) {
        self.id = id
        self.type = type
        self.data = data
    }

    public static func parse(_ text: String) -> DirigeraEvent? {
        try? JSONDecoder().decode(DirigeraEvent.self, from: Data(text.utf8))
    }

    public var deviceUpdate: DirigeraDeviceUpdate? { data.flatMap(DirigeraDeviceUpdate.init) }

    public var isDeviceEvent: Bool { type.hasPrefix("device") }
    public var isSceneEvent: Bool { type.hasPrefix("scene") }
}
