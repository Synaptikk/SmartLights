import Foundation

/// Capability `type` strings of the Govee Developer API (https://developer.govee.com/reference).
public enum GoveeCapabilityType {
    public static let onOff = "devices.capabilities.on_off"
    public static let toggle = "devices.capabilities.toggle"
    public static let range = "devices.capabilities.range"
    public static let colorSetting = "devices.capabilities.color_setting"
    public static let segmentColorSetting = "devices.capabilities.segment_color_setting"
    public static let dynamicScene = "devices.capabilities.dynamic_scene"
    public static let musicSetting = "devices.capabilities.music_setting"
    public static let mode = "devices.capabilities.mode"
    public static let workMode = "devices.capabilities.work_mode"
    public static let online = "devices.capabilities.online"
    public static let event = "devices.capabilities.event"
}

/// Capability `instance` strings used by SmartLights.
public enum GoveeCapabilityInstance {
    public static let powerSwitch = "powerSwitch"
    public static let brightness = "brightness"
    public static let colorRgb = "colorRgb"
    public static let colorTemperatureK = "colorTemperatureK"
    public static let online = "online"
    public static let lightScene = "lightScene"
    public static let diyScene = "diyScene"
    public static let snapshot = "snapshot"
}

/// Device `type` strings.
public enum GoveeDeviceType {
    public static let light = "devices.types.light"
    public static let socket = "devices.types.socket"
}

/// `parameters.range` of an INTEGER capability.
public struct GoveeValueRange: Codable, Sendable, Hashable {
    public var min: Int
    public var max: Int
    public var precision: Int?

    public init(min: Int, max: Int, precision: Int? = 1) {
        self.min = min
        self.max = max
        self.precision = precision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = c.lenientInt(.min) ?? 0
        max = c.lenientInt(.max) ?? 0
        precision = c.lenientInt(.precision)
    }

    public var closedRange: ClosedRange<Int> { Swift.min(min, max)...Swift.max(min, max) }
}

/// One `parameters.options[]` entry of an ENUM capability.
public struct GoveeOption: Codable, Sendable, Hashable {
    public var name: String
    public var value: GoveeJSONValue

    public init(name: String, value: GoveeJSONValue) {
        self.name = name
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenientString(.name) ?? ""
        value = (try? c.decodeIfPresent(GoveeJSONValue.self, forKey: .value)) ?? .null
    }
}

/// `capabilities[].parameters`. STRUCT `fields` are kept raw (segment colour, music mode).
public struct GoveeCapabilityParameters: Codable, Sendable, Hashable {
    public var dataType: String?
    public var unit: String?
    public var range: GoveeValueRange?
    public var options: [GoveeOption]?
    public var fields: GoveeJSONValue?

    public init(dataType: String? = nil, unit: String? = nil, range: GoveeValueRange? = nil,
                options: [GoveeOption]? = nil, fields: GoveeJSONValue? = nil) {
        self.dataType = dataType
        self.unit = unit
        self.range = range
        self.options = options
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataType = c.lenientString(.dataType)
        unit = c.lenientString(.unit)
        range = try? c.decodeIfPresent(GoveeValueRange.self, forKey: .range)
        options = try? c.decodeIfPresent([GoveeOption].self, forKey: .options)
        fields = try? c.decodeIfPresent(GoveeJSONValue.self, forKey: .fields)
    }
}

/// One capability of a device in `GET /router/api/v1/user/devices`.
public struct GoveeCloudCapability: Codable, Sendable, Hashable {
    public var type: String
    public var instance: String
    public var parameters: GoveeCapabilityParameters?

    public init(type: String, instance: String, parameters: GoveeCapabilityParameters? = nil) {
        self.type = type
        self.instance = instance
        self.parameters = parameters
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenientString(.type) ?? ""
        instance = c.lenientString(.instance) ?? ""
        parameters = try? c.decodeIfPresent(GoveeCapabilityParameters.self, forKey: .parameters)
    }
}

/// One device of `GET /router/api/v1/user/devices`.
public struct GoveeCloudDevice: Codable, Sendable, Hashable {
    public var sku: String
    public var device: String
    public var deviceName: String?
    public var type: String?
    public var capabilities: [GoveeCloudCapability]

    public init(sku: String, device: String, deviceName: String? = nil, type: String? = GoveeDeviceType.light,
                capabilities: [GoveeCloudCapability]) {
        self.sku = sku
        self.device = device
        self.deviceName = deviceName
        self.type = type
        self.capabilities = capabilities
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sku = c.lenientString(.sku) ?? ""
        device = c.lenientString(.device) ?? ""
        deviceName = c.lenientString(.deviceName)
        type = c.lenientString(.type)
        // Skip capabilities that fail to decode instead of dropping the whole device.
        let raw = (try? c.decodeIfPresent([GoveeJSONValue].self, forKey: .capabilities)) ?? []
        let decoder = JSONDecoder()
        capabilities = raw.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(GoveeCloudCapability.self, from: data)
        }
    }

    /// Normalised stable id (same as the LAN `device`).
    public var deviceID: String { GoveeDeviceID.normalize(device) }

    public func capability(_ type: String, _ instance: String) -> GoveeCloudCapability? {
        capabilities.first { $0.type == type && $0.instance == instance }
    }

    public func capabilities(ofType type: String) -> [GoveeCloudCapability] {
        capabilities.filter { $0.type == type }
    }

    /// Lights and anything dimmable/colourable; humidifiers, heaters, sensors are skipped.
    public var isLight: Bool {
        if type == GoveeDeviceType.light { return true }
        if let type, !type.isEmpty, type != GoveeDeviceType.light {
            return false
        }
        return capability(GoveeCapabilityType.range, GoveeCapabilityInstance.brightness) != nil
            || !capabilities(ofType: GoveeCapabilityType.colorSetting).isEmpty
    }
}

/// `GET /router/api/v1/user/devices` body.
public struct GoveeCloudDeviceList: Codable, Sendable, Hashable {
    public var code: Int
    public var message: String?
    public var data: [GoveeCloudDevice]

    public init(code: Int = 200, message: String? = "success", data: [GoveeCloudDevice]) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.lenientInt(.code) ?? 200
        message = c.lenientString(.message)
        data = (try? c.decodeIfPresent([GoveeCloudDevice].self, forKey: .data)) ?? []
    }
}

/// The capability part of a control request: `{type, instance, value}`.
public struct GoveeCapabilityCommand: Codable, Sendable, Hashable {
    public var type: String
    public var instance: String
    public var value: GoveeJSONValue

    public init(type: String, instance: String, value: GoveeJSONValue) {
        self.type = type
        self.instance = instance
        self.value = value
    }

    public static func power(_ on: Bool) -> GoveeCapabilityCommand {
        GoveeCapabilityCommand(type: GoveeCapabilityType.onOff, instance: GoveeCapabilityInstance.powerSwitch, value: .int(on ? 1 : 0))
    }

    public static func brightness(_ percent: Int) -> GoveeCapabilityCommand {
        GoveeCapabilityCommand(type: GoveeCapabilityType.range, instance: GoveeCapabilityInstance.brightness, value: .int(percent))
    }

    public static func colorRGB(_ packed: Int) -> GoveeCapabilityCommand {
        GoveeCapabilityCommand(type: GoveeCapabilityType.colorSetting, instance: GoveeCapabilityInstance.colorRgb, value: .int(packed))
    }

    public static func colorTemperature(_ kelvin: Int) -> GoveeCapabilityCommand {
        GoveeCapabilityCommand(type: GoveeCapabilityType.colorSetting, instance: GoveeCapabilityInstance.colorTemperatureK, value: .int(kelvin))
    }
}

/// `POST /router/api/v1/device/control` body.
public struct GoveeControlRequest: Codable, Sendable, Hashable {
    public struct Payload: Codable, Sendable, Hashable {
        public var sku: String
        public var device: String
        public var capability: GoveeCapabilityCommand
    }

    public var requestId: String
    public var payload: Payload

    public init(requestId: String, sku: String, device: String, capability: GoveeCapabilityCommand) {
        self.requestId = requestId
        self.payload = Payload(sku: sku, device: device, capability: capability)
    }
}

/// `POST /router/api/v1/device/control` response:
/// `{"requestId":..,"msg":"success","code":200,"capability":{type,instance,state:{status},value}}`.
public struct GoveeControlResponse: Codable, Sendable, Hashable {
    public struct Capability: Codable, Sendable, Hashable {
        public var type: String?
        public var instance: String?
        public var state: GoveeJSONValue?
        public var value: GoveeJSONValue?
    }

    public var requestId: String?
    public var msg: String?
    public var code: Int
    public var capability: Capability?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = c.lenientString(.requestId)
        msg = c.lenientString(.msg)
        code = c.lenientInt(.code) ?? 200
        capability = try? c.decodeIfPresent(Capability.self, forKey: .capability)
    }

    /// `capability.state.status` ("success" when the command was accepted).
    public var status: String? { capability?.state?["status"]?.stringValue }
}

/// `POST /router/api/v1/device/state` body.
public struct GoveeStateRequest: Codable, Sendable, Hashable {
    public struct Payload: Codable, Sendable, Hashable {
        public var sku: String
        public var device: String
    }

    public var requestId: String
    public var payload: Payload

    public init(requestId: String, sku: String, device: String) {
        self.requestId = requestId
        self.payload = Payload(sku: sku, device: device)
    }
}

/// One `payload.capabilities[]` entry of a state response: `{type, instance, state:{value}}`.
public struct GoveeCapabilityState: Codable, Sendable, Hashable {
    public var type: String
    public var instance: String
    /// `state.value`; `.null`/empty when the instance cannot be queried.
    public var value: GoveeJSONValue

    public init(type: String, instance: String, value: GoveeJSONValue) {
        self.type = type
        self.instance = instance
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case type, instance, state }
    private enum StateKeys: String, CodingKey { case value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenientString(.type) ?? ""
        instance = c.lenientString(.instance) ?? ""
        if let state = try? c.nestedContainer(keyedBy: StateKeys.self, forKey: .state) {
            value = (try? state.decodeIfPresent(GoveeJSONValue.self, forKey: .value)) ?? .null
        } else {
            value = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(instance, forKey: .instance)
        var state = c.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        try state.encode(value, forKey: .value)
    }
}

/// `POST /router/api/v1/device/state` response.
public struct GoveeStateResponse: Codable, Sendable, Hashable {
    public struct Payload: Codable, Sendable, Hashable {
        public var sku: String?
        public var device: String?
        public var capabilities: [GoveeCapabilityState]
    }

    public var requestId: String?
    public var msg: String?
    public var code: Int
    public var payload: Payload?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = c.lenientString(.requestId)
        msg = c.lenientString(.msg)
        code = c.lenientInt(.code) ?? 200
        payload = try? c.decodeIfPresent(Payload.self, forKey: .payload)
    }
}
