import Foundation

// Home Assistant WebSocket API (`/api/websocket`), https://developers.home-assistant.io/docs/api/websocket
//
//   server: {"type":"auth_required","ha_version":"2026.10.1"}
//   client: {"type":"auth","access_token":"..."}
//   server: {"type":"auth_ok","ha_version":"2026.10.1"} | {"type":"auth_invalid","message":"..."}
//   client: {"id":1,"type":"subscribe_events","event_type":"state_changed"}
//   server: {"id":1,"type":"result","success":true,"result":null}
//   server: {"id":1,"type":"event","event":{"event_type":"state_changed","data":{...}}}
//
// After authentication every client message carries an incrementing integer `id`; the server
// echoes it on the `result` (and, for subscriptions, on every `event`).

/// Authentication-phase messages sent by the client (no `id`).
public enum HAAuthMessage {
    /// `{"type":"auth","access_token":"..."}`. The token is a long-lived access token
    /// (profile > Security) or an OAuth access token. Never log the encoded message.
    public static func auth(accessToken: String) -> HAJSONValue {
        ["type": "auth", "access_token": .string(accessToken)]
    }
}

/// A target for `call_service` (`{"entity_id": [...]}`; areas/devices are not used here).
public struct HAServiceTarget: Sendable, Hashable {
    public var entityIDs: [String]

    public init(entityIDs: [String]) {
        self.entityIDs = entityIDs
    }

    public var json: HAJSONValue {
        entityIDs.count == 1 ? ["entity_id": .string(entityIDs[0])] : ["entity_id": .array(entityIDs.map { .string($0) })]
    }
}

/// A command-phase message. `message(id:)` adds the correlation id.
public enum HACommand: Sendable, Hashable {
    /// `{"type":"supported_features","features":{"coalesce_messages":1}}`; must be the first
    /// command (id 1) if sent at all.
    case supportedFeatures(coalesceMessages: Bool)
    /// `{"type":"subscribe_events","event_type":"state_changed"}`; nil = all events.
    case subscribeEvents(eventType: String?)
    case unsubscribeEvents(subscription: Int)
    case getStates
    case getConfig
    case getServices
    /// `{"type":"call_service","domain":"light","service":"turn_on","service_data":{...},"target":{...}}`.
    case callService(HAServiceCall)
    /// `config/entity_registry/list`: entity -> area/device/registry id/name.
    case entityRegistryList
    /// `config/area_registry/list`: area id -> name (room hints).
    case areaRegistryList
    /// `config/device_registry/list`: device -> area (entities without their own area inherit it).
    case deviceRegistryList
    case ping

    public var type: String {
        switch self {
        case .supportedFeatures: "supported_features"
        case .subscribeEvents: "subscribe_events"
        case .unsubscribeEvents: "unsubscribe_events"
        case .getStates: "get_states"
        case .getConfig: "get_config"
        case .getServices: "get_services"
        case .callService: "call_service"
        case .entityRegistryList: "config/entity_registry/list"
        case .areaRegistryList: "config/area_registry/list"
        case .deviceRegistryList: "config/device_registry/list"
        case .ping: "ping"
        }
    }

    public func message(id: Int) -> HAJSONValue {
        var o: [String: HAJSONValue] = ["id": .int(id), "type": .string(type)]
        switch self {
        case .supportedFeatures(let coalesce):
            o["features"] = ["coalesce_messages": .int(coalesce ? 1 : 0)]
        case .subscribeEvents(let eventType):
            if let eventType { o["event_type"] = .string(eventType) }
        case .unsubscribeEvents(let subscription):
            o["subscription"] = .int(subscription)
        case .callService(let call):
            o["domain"] = .string(call.domain)
            o["service"] = .string(call.service)
            if !call.serviceData.isEmpty { o["service_data"] = .object(call.serviceData) }
            if let target = call.target { o["target"] = target.json }
        case .getStates, .getConfig, .getServices, .entityRegistryList, .areaRegistryList, .deviceRegistryList, .ping:
            break
        }
        return .object(o)
    }
}

/// A `call_service` request (domain + service + data + target).
public struct HAServiceCall: Sendable, Hashable {
    public var domain: String
    public var service: String
    public var serviceData: [String: HAJSONValue]
    public var target: HAServiceTarget?

    public init(domain: String, service: String, serviceData: [String: HAJSONValue] = [:], target: HAServiceTarget? = nil) {
        self.domain = domain
        self.service = service
        self.serviceData = serviceData
        self.target = target
    }

    /// The same call aimed at other entities.
    public func targeting(_ entityIDs: [String]) -> HAServiceCall {
        var copy = self
        copy.target = HAServiceTarget(entityIDs: entityIDs)
        return copy
    }
}

/// `{"code":"not_found","message":"Service not found."}` from a failed `result`.
public struct HAErrorInfo: Sendable, Hashable, Codable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    // Codes from homeassistant/components/websocket_api/const.py.
    public static let unknownCommand = "unknown_command"
    public static let notFound = "not_found"
    public static let invalidFormat = "invalid_format"
    public static let homeAssistantError = "home_assistant_error"
    public static let serviceValidationError = "service_validation_error"
    public static let unauthorized = "unauthorized"
    public static let timeout = "timeout"
    public static let unknownError = "unknown_error"
}

/// An event on the HA bus as delivered to a `subscribe_events` subscription.
public struct HAEvent: Sendable, Hashable {
    public var eventType: String
    public var data: HAJSONValue
    public var timeFired: String?
    public var origin: String?

    public init(eventType: String, data: HAJSONValue, timeFired: String? = nil, origin: String? = nil) {
        self.eventType = eventType
        self.data = data
        self.timeFired = timeFired
        self.origin = origin
    }

    init?(_ value: HAJSONValue) {
        guard let type = value["event_type"]?.stringValue else { return nil }
        self.init(
            eventType: type, data: value["data"] ?? .null,
            timeFired: value["time_fired"]?.stringValue, origin: value["origin"]?.stringValue)
    }

    /// The payload of a `state_changed` event, or nil for other event types.
    public var stateChanged: HAStateChange? {
        guard eventType == "state_changed", let entityID = data["entity_id"]?.stringValue else { return nil }
        return HAStateChange(
            entityID: entityID,
            oldState: data["old_state"].flatMap(HAEntityState.init(json:)),
            newState: data["new_state"].flatMap(HAEntityState.init(json:)))
    }
}

/// `state_changed`: `new_state` is nil when the entity was removed, `old_state` nil when added.
public struct HAStateChange: Sendable, Hashable {
    public var entityID: String
    public var oldState: HAEntityState?
    public var newState: HAEntityState?

    public init(entityID: String, oldState: HAEntityState?, newState: HAEntityState?) {
        self.entityID = entityID
        self.oldState = oldState
        self.newState = newState
    }
}

/// Any message the server sends.
public enum HAIncomingMessage: Sendable, Hashable {
    case authRequired(haVersion: String?)
    case authOK(haVersion: String?)
    case authInvalid(message: String?)
    /// Reply to a command. `result` is `.null` for commands without a payload.
    case result(id: Int, success: Bool, result: HAJSONValue, error: HAErrorInfo?)
    /// Event for the subscription created by command `id`.
    case event(id: Int, HAEvent)
    case pong(id: Int)
    /// Anything else (future message types); kept for diagnostics.
    case unknown(type: String?, HAJSONValue)

    /// Parses one WebSocket text frame. With `coalesce_messages` HA may send a JSON array of
    /// messages in one frame; this always returns a list.
    public static func parse(_ text: String) throws -> [HAIncomingMessage] {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> [HAIncomingMessage] {
        let value = try HAJSONValue.parse(data)
        if let list = value.arrayValue { return list.map(HAIncomingMessage.init) }
        return [HAIncomingMessage(value)]
    }

    public init(_ value: HAJSONValue) {
        let type = value["type"]?.stringValue
        let id = value["id"]?.intValue
        switch type {
        case "auth_required":
            self = .authRequired(haVersion: value["ha_version"]?.stringValue)
        case "auth_ok":
            self = .authOK(haVersion: value["ha_version"]?.stringValue)
        case "auth_invalid":
            self = .authInvalid(message: value["message"]?.stringValue)
        case "result" where id != nil:
            let error = value["error"].flatMap { e -> HAErrorInfo? in
                guard e.objectValue != nil else { return nil }
                return HAErrorInfo(code: e["code"]?.stringValue ?? HAErrorInfo.unknownError, message: e["message"]?.stringValue ?? "")
            }
            self = .result(id: id!, success: value["success"]?.boolValue ?? false, result: value["result"] ?? .null, error: error)
        case "event" where id != nil:
            if let event = value["event"].flatMap(HAEvent.init) {
                self = .event(id: id!, event)
            } else {
                self = .unknown(type: type, value)
            }
        case "pong" where id != nil:
            self = .pong(id: id!)
        default:
            self = .unknown(type: type, value)
        }
    }
}
