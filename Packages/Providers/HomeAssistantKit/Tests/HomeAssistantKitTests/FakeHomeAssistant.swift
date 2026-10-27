import Foundation
import HomeAssistantCodec
import LightCore

@testable import HomeAssistantKit

/// In-process Home Assistant WebSocket server speaking the real protocol (auth phase, ids,
/// `result`/`event`/`pong`, coalesced-free frames). Implements `get_states`, `get_config`,
/// `subscribe_events`/`unsubscribe_events`, the three registry lists, `ping` and `call_service`
/// for `light.turn_on`/`light.turn_off`/`scene.turn_on`, applying light changes to its state and
/// broadcasting `state_changed` like HA does.
actor FakeHomeAssistant {
    var token = "good-token"
    var version = "2026.10.1"
    var locationName = "Home"
    /// Hosts that accept connections (others fail like an unreachable LAN address).
    var reachableHosts: Set<String> = ["ha.test"]
    var respondToPings = true
    var registryAvailable = true
    var states: [String: HAJSONValue] = [:]
    var entityRegistry: [HAJSONValue] = []
    var deviceRegistry: [HAJSONValue] = []
    var areaRegistry: [HAJSONValue] = []

    /// Every command received after authentication, in order.
    private(set) var commands: [HAJSONValue] = []
    private(set) var connectCount = 0
    private(set) var authAttempts: [String] = []
    private var connections: [ObjectIdentifier: Session] = [:]

    private struct Session {
        let connection: FakeHAConnection
        var authenticated = false
        var subscriptions: [Int: String?] = [:]
    }

    init() {
        let lights: [(String, String, [String: HAJSONValue])] = [
            ("light.ceiling", "on", [
                "supported_color_modes": ["color_temp", "hs"], "min_color_temp_kelvin": 2000, "max_color_temp_kelvin": 6535,
                "color_mode": "color_temp", "brightness": 128, "color_temp_kelvin": 2700, "friendly_name": "Ceiling",
                "supported_features": 32,
            ]),
            ("light.kitchen", "off", [
                "supported_color_modes": ["color_temp", "hs"], "min_color_temp_kelvin": 2000, "max_color_temp_kelvin": 6535,
                "color_mode": nil, "brightness": nil, "friendly_name": "Kitchen", "supported_features": 32,
            ]),
            ("light.porch", "on", ["supported_color_modes": ["onoff"], "color_mode": "onoff", "friendly_name": "Porch", "supported_features": 0]),
            ("light.strip", "on", [
                "supported_color_modes": ["rgb"], "color_mode": "rgb", "brightness": 255, "rgb_color": [255, 0, 0],
                "effect_list": ["off", "rainbow"], "effect": "off", "friendly_name": "Strip", "supported_features": 4,
            ]),
        ]
        for (id, state, attributes) in lights {
            states[id] = Self.stateJSON(id, state, attributes)
        }
        states["scene.movie"] = Self.stateJSON("scene.movie", "unknown", ["entity_id": ["light.ceiling", "light.kitchen"], "friendly_name": "Movie"])
        states["sensor.temp"] = Self.stateJSON("sensor.temp", "21.5", ["friendly_name": "Temp"])
        entityRegistry = [
            ["entity_id": "light.ceiling", "id": "reg-ceiling", "unique_id": "c1", "platform": "hue", "area_id": nil, "device_id": "dev-1", "disabled_by": nil, "hidden_by": nil],
            ["entity_id": "light.kitchen", "id": "reg-kitchen", "unique_id": "k1", "platform": "zha", "area_id": "kitchen", "device_id": nil, "disabled_by": nil, "hidden_by": nil],
            ["entity_id": "light.strip", "id": "reg-strip", "unique_id": "s1", "platform": "wled", "area_id": nil, "device_id": nil, "disabled_by": nil, "hidden_by": nil],
            ["entity_id": "scene.movie", "id": "reg-movie", "unique_id": "m1", "platform": "homeassistant", "area_id": "living_room", "device_id": nil, "disabled_by": nil, "hidden_by": nil],
        ]
        deviceRegistry = [["id": "dev-1", "area_id": "living_room", "name": "Ceiling", "manufacturer": "Signify Netherlands B.V.", "model": "Hue white and color ambiance"]]
        areaRegistry = [["area_id": "living_room", "name": "Living Room"], ["area_id": "kitchen", "name": "Kitchen"]]
    }

    static func stateJSON(_ entityID: String, _ state: String, _ attributes: [String: HAJSONValue]) -> HAJSONValue {
        [
            "entity_id": .string(entityID), "state": .string(state), "attributes": .object(attributes),
            "last_changed": "2026-10-26T18:00:00.000001+00:00", "last_updated": "2026-10-26T18:00:00.000001+00:00",
            "context": ["id": "01JBX00000000000000000CTX1", "parent_id": nil, "user_id": nil],
        ]
    }

    // MARK: Test controls

    func setToken(_ value: String) { token = value }
    func setReachableHosts(_ value: Set<String>) { reachableHosts = value }
    func setRespondToPings(_ value: Bool) { respondToPings = value }
    func setRegistryAvailable(_ value: Bool) { registryAvailable = value }

    /// Replaces (or with nil removes) an entity state and broadcasts `state_changed`.
    func setState(_ entityID: String, _ state: String?, _ attributes: [String: HAJSONValue] = [:]) {
        let old = states[entityID]
        let new = state.map { Self.stateJSON(entityID, $0, attributes) }
        states[entityID] = new
        broadcastStateChanged(entityID, old: old, new: new)
    }

    /// Changes a state without telling anyone (e.g. while the client is disconnected).
    func setStateSilently(_ entityID: String, _ state: String, _ attributes: [String: HAJSONValue]) {
        states[entityID] = Self.stateJSON(entityID, state, attributes)
    }

    func addRegistryEntity(_ entry: HAJSONValue) { entityRegistry.append(entry) }

    func renameArea(_ areaID: String, to name: String) {
        areaRegistry = areaRegistry.map { $0["area_id"]?.stringValue == areaID ? ["area_id": .string(areaID), "name": .string(name)] : $0 }
    }

    /// Fires a registry update event (no state change).
    func fireEvent(_ type: String, data: HAJSONValue = [:]) {
        broadcast(type, data: data)
    }

    /// Closes every open connection from the server side.
    func dropAllConnections() {
        for session in connections.values { session.connection.serverClose() }
        connections.removeAll()
    }

    var openConnections: Int { connections.count }

    func commands(ofType type: String) -> [HAJSONValue] { commands.filter { $0["type"]?.stringValue == type } }

    func serviceCalls() -> [HAJSONValue] { commands(ofType: "call_service") }

    // MARK: Connection lifecycle

    func accept(_ url: URL) throws -> FakeHAConnection {
        guard let host = url.host, reachableHosts.contains(host) else { throw URLError(.cannotConnectToHost) }
        guard url.path == "/api/websocket" else { throw URLError(.badServerResponse) }
        connectCount += 1
        let connection = FakeHAConnection(server: self)
        connections[ObjectIdentifier(connection)] = Session(connection: connection)
        connection.deliver(#"{"type":"auth_required","ha_version":"\#(version)"}"#)
        return connection
    }

    func clientClosed(_ connection: FakeHAConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    func receive(_ text: String, from connection: FakeHAConnection) {
        let key = ObjectIdentifier(connection)
        guard var session = connections[key], let message = try? HAJSONValue.parse(text) else { return }
        guard session.authenticated else {
            let supplied = message["access_token"]?.stringValue ?? ""
            authAttempts.append(supplied)
            if message["type"]?.stringValue == "auth", supplied == token {
                session.authenticated = true
                connections[key] = session
                connection.deliver(#"{"type":"auth_ok","ha_version":"\#(version)"}"#)
            } else {
                connection.deliver(#"{"type":"auth_invalid","message":"Invalid access token or password"}"#)
                connection.serverClose()
                connections.removeValue(forKey: key)
            }
            return
        }
        commands.append(message)
        guard let id = message["id"]?.intValue, let type = message["type"]?.stringValue else { return }
        switch type {
        case "ping":
            if respondToPings { send(["id": .int(id), "type": "pong"], to: connection) }
        case "subscribe_events":
            session.subscriptions[id] = message["event_type"]?.stringValue
            connections[key] = session
            result(id, .null, to: connection)
        case "unsubscribe_events":
            if let sub = message["subscription"]?.intValue { session.subscriptions[sub] = nil }
            connections[key] = session
            result(id, .null, to: connection)
        case "get_states":
            result(id, .array(states.keys.sorted().compactMap { states[$0] }), to: connection)
        case "get_config":
            result(id, ["location_name": .string(locationName), "version": .string(version), "internal_url": nil, "external_url": nil], to: connection)
        case "config/entity_registry/list", "config/device_registry/list", "config/area_registry/list":
            guard registryAvailable else {
                error(id, code: "unauthorized", message: "Unauthorized", to: connection)
                return
            }
            let list = type.contains("entity") ? entityRegistry : type.contains("device") ? deviceRegistry : areaRegistry
            result(id, .array(list), to: connection)
        case "call_service":
            callService(id, message, connection: connection)
        default:
            error(id, code: "unknown_command", message: "Unknown command.", to: connection)
        }
    }

    // MARK: Services

    private func callService(_ id: Int, _ message: HAJSONValue, connection: FakeHAConnection) {
        let domain = message["domain"]?.stringValue ?? ""
        let service = message["service"]?.stringValue ?? ""
        let data = message["service_data"]?.objectValue ?? [:]
        let target = message["target"]?["entity_id"]
        let entityIDs = target?.arrayValue?.compactMap(\.stringValue) ?? target?.stringValue.map { [$0] } ?? []
        switch (domain, service) {
        case ("light", "turn_on"), ("light", "turn_off"):
            for entityID in entityIDs {
                guard let old = states[entityID] else { continue }
                let new = Self.apply(service: service, data: data, to: old)
                states[entityID] = new
                broadcastStateChanged(entityID, old: old, new: new)
            }
        case ("scene", "turn_on"):
            break
        default:
            error(id, code: "not_found", message: "Service \(domain).\(service) not found.", to: connection)
            return
        }
        result(id, ["context": ["id": "01JBX00000000000000000CTX2", "parent_id": nil, "user_id": "u1"], "response": nil], to: connection)
    }

    /// Simplified `light.turn_on`/`turn_off` semantics (enough for the provider's round trips).
    static func apply(service: String, data: [String: HAJSONValue], to old: HAJSONValue) -> HAJSONValue {
        var attributes = old["attributes"]?.objectValue ?? [:]
        let entityID = old["entity_id"]?.stringValue ?? ""
        if service == "turn_off" {
            for key in ["color_mode", "brightness", "color_temp_kelvin", "hs_color", "rgb_color", "xy_color"] where attributes[key] != nil {
                attributes[key] = .null
            }
            return stateJSON(entityID, "off", attributes)
        }
        let modes = attributes["supported_color_modes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let pct = data["brightness_pct"]?.doubleValue { attributes["brightness"] = .int(Int((pct * 255 / 100).rounded())) }
        if attributes["brightness"] == nil || attributes["brightness"] == .null, modes != ["onoff"] { attributes["brightness"] = 255 }
        if let k = data["color_temp_kelvin"] {
            attributes["color_mode"] = "color_temp"
            attributes["color_temp_kelvin"] = k
            attributes["hs_color"] = .null
        }
        if let hs = data["hs_color"] {
            attributes["color_mode"] = "hs"
            attributes["hs_color"] = hs
            attributes["color_temp_kelvin"] = .null
        }
        if let rgb = data["rgb_color"] {
            attributes["color_mode"] = "rgb"
            attributes["rgb_color"] = rgb
        }
        if let effect = data["effect"] { attributes["effect"] = effect }
        if attributes["color_mode"] == nil || attributes["color_mode"] == .null {
            attributes["color_mode"] = modes.contains("color_temp") ? "color_temp" : .string(modes.first ?? "onoff")
            if modes.contains("color_temp") { attributes["color_temp_kelvin"] = 3000 }
        }
        return stateJSON(entityID, "on", attributes)
    }

    // MARK: Output

    private func broadcastStateChanged(_ entityID: String, old: HAJSONValue?, new: HAJSONValue?) {
        broadcast("state_changed", data: ["entity_id": .string(entityID), "old_state": old ?? .null, "new_state": new ?? .null])
    }

    private func broadcast(_ eventType: String, data: HAJSONValue) {
        for session in connections.values where session.authenticated {
            for (subscription, filter) in session.subscriptions where filter == nil || filter == eventType {
                send([
                    "id": .int(subscription), "type": "event",
                    "event": [
                        "event_type": .string(eventType), "data": data, "origin": "LOCAL",
                        "time_fired": "2026-10-26T18:00:01.000001+00:00",
                        "context": ["id": "01JBX00000000000000000CTX3", "parent_id": nil, "user_id": nil],
                    ],
                ], to: session.connection)
            }
        }
    }

    private func result(_ id: Int, _ value: HAJSONValue, to connection: FakeHAConnection) {
        send(["id": .int(id), "type": "result", "success": true, "result": value], to: connection)
    }

    private func error(_ id: Int, code: String, message: String, to connection: FakeHAConnection) {
        send(["id": .int(id), "type": "result", "success": false, "error": ["code": .string(code), "message": .string(message)]], to: connection)
    }

    private func send(_ value: HAJSONValue, to connection: FakeHAConnection) {
        if let text = try? value.jsonString() { connection.deliver(text) }
    }
}

/// Client end of an in-memory WebSocket to `FakeHomeAssistant`.
final class FakeHAConnection: HAWebSocketConnection, @unchecked Sendable {
    private let server: FakeHomeAssistant
    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiters: [CheckedContinuation<String, any Error>] = []
    private var closed = false

    init(server: FakeHomeAssistant) { self.server = server }

    /// Server -> client frame.
    func deliver(_ text: String) {
        lock.lock()
        if closed { lock.unlock(); return }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            buffer.append(text)
            lock.unlock()
        }
    }

    /// Server-initiated close: pending frames are still delivered, then `receive` throws.
    func serverClose() { finish() }

    func send(_ text: String) async throws {
        if isClosed { throw URLError(.networkConnectionLost) }
        await server.receive(text, from: self)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let text = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {
        finish()
        Task { await server.clientClosed(self) }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func finish() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(throwing: URLError(.networkConnectionLost)) }
    }
}

/// `HAWebSocketTransport` backed by `FakeHomeAssistant`, plus scripted Bonjour results.
struct FakeHATransport: HAWebSocketTransport {
    let server: FakeHomeAssistant
    var bonjour: [HADiscoveredInstance] = []

    func connect(to url: URL) async throws -> any HAWebSocketConnection {
        try await server.accept(url)
    }

    func browse(timeout: Duration) -> AsyncStream<HADiscoveredInstance> {
        let found = bonjour
        return AsyncStream { continuation in
            for instance in found { continuation.yield(instance) }
            continuation.finish()
        }
    }
}
