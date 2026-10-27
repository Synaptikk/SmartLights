import DirigeraCodec
import DirigeraProvider
import Foundation
import NetKit

/// An in-process DIRIGERA hub over loopback HTTP + WebSocket (the TLS layer is the transport's
/// job; the provider is tested over plain http/ws). Behaviour follows Leggin/dirigera:
/// PKCE authorize -> code; token only after the action button is pressed and only for the
/// matching `code_verifier`; bearer token on everything else (401 otherwise); `PATCH
/// /v1/devices/{id}` with `[{"attributes": {...}}]` honouring `canReceive` and value ranges;
/// every change is pushed to connected WebSockets as `deviceStateChanged`.
final class FakeDirigeraHub: @unchecked Sendable {
    static let hubID = "d7a1c2b3-0000-4000-8000-000000000001_1"
    static let sofa = "5f2b6a10-1111-4c3d-9e8f-0a1b2c3d4e5f_1"
    static let bed = "23taswdg-sdf-4eeb-99c2-23asdf2gw"
    static let plug = "aa11bb22-4444-4eee-8fff-000000000005_1"
    static let scene = "c3a7e1d2-6666-4aaa-8bbb-000000000007"

    struct State {
        var devices: [[String: Any]]
        var buttonPressed = false
        var codes: [String: String] = [:] // code -> challenge
        var tokens: Set<String> = []
        /// Reject PATCHes carrying more than one attribute with 400 (tests the split fallback).
        var rejectCombinedPatches = false
        var patches: [String] = []
        var triggered: [String] = []
        var sockets: [WebSocketServerConnection] = []
        var log: [LoopbackRequest] = []
    }

    private let lock = NSLock()
    private var state: State
    private var server: LoopbackHTTPServer!

    var port: Int { Int(server.port) }
    var host: String { "127.0.0.1:\(server.port)" }

    init() throws {
        state = State(devices: Self.seedDevices())
        server = try LoopbackHTTPServer { [weak self] request in
            guard let self else { return .response(.text("gone", status: 500)) }
            return self.handle(request)
        }
    }

    deinit { stop() }

    func stop() {
        let sockets = lock.withLock { state.sockets }
        for socket in sockets { socket.close() }
        server?.stop()
    }

    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    func mutate(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    func pressButton() { mutate { $0.buttonPressed = true } }
    var patches: [String] { read(\.patches) }
    var openSockets: Int { read { $0.sockets.filter(\.isOpen).count } }

    /// Drops every WebSocket (the provider should reconnect).
    func dropSockets() {
        let sockets = lock.withLock { () -> [WebSocketServerConnection] in
            defer { state.sockets = [] }
            return state.sockets
        }
        for socket in sockets { socket.close() }
    }

    /// Revokes all tokens (hub reset / client removed in the IKEA app).
    func revokeTokens() { mutate { $0.tokens = [] } }

    /// A change made elsewhere (IKEA app, remote): updates the device and pushes an event.
    func externalChange(_ deviceID: String, _ attributes: [String: Any], isReachable: Bool? = nil) {
        lock.withLock { apply(deviceID, attributes, isReachable: isReachable, &state) }
    }

    func push(_ event: [String: Any]) {
        let text = Self.jsonText(event)
        let sockets = lock.withLock { state.sockets }
        for socket in sockets { socket.send(text) }
    }

    private func apply(_ deviceID: String, _ attributes: [String: Any], isReachable: Bool?, _ s: inout State) {
        guard let index = s.devices.firstIndex(where: { $0["id"] as? String == deviceID }) else { return }
        var device = s.devices[index]
        var attrs = device["attributes"] as? [String: Any] ?? [:]
        for (k, v) in attributes { attrs[k] = v }
        if attributes["colorHue"] != nil || attributes["colorSaturation"] != nil { attrs["colorMode"] = "color" }
        if attributes["colorTemperature"] != nil { attrs["colorMode"] = "temperature" }
        device["attributes"] = attrs
        if let isReachable { device["isReachable"] = isReachable }
        s.devices[index] = device
        var data: [String: Any] = ["id": deviceID, "type": device["type"] ?? "light", "attributes": attributes]
        if let isReachable { data["isReachable"] = isReachable }
        let text = Self.jsonText(["id": UUID().uuidString, "type": "deviceStateChanged", "specversion": "1.1.0",
                                  "source": "urn:com:ikea:homesmart:iotc:ipc", "data": data])
        for socket in s.sockets { socket.send(text) }
    }

    private func handle(_ r: LoopbackRequest) -> LoopbackReply {
        lock.withLock {
            state.log.append(r)
            return route(r, &state)
        }
    }

    private func route(_ r: LoopbackRequest, _ s: inout State) -> LoopbackReply {
        switch (r.method, r.path) {
        case ("GET", "/v1/oauth/authorize"):
            guard r.query["audience"] == "homesmart.local", r.query["response_type"] == "code",
                  r.query["code_challenge_method"] == "S256", let challenge = r.query["code_challenge"] else {
                return .response(.json(#"{"error":"invalid_request"}"#, status: 400))
            }
            let code = UUID().uuidString
            s.codes[code] = challenge
            return .response(.json(object: ["code": code]))
        case ("POST", "/v1/oauth/token"):
            var form: [String: String] = [:]
            for pair in r.bodyText.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { form[kv[0]] = kv[1] }
            }
            guard form["grant_type"] == "authorization_code", let code = form["code"], let challenge = s.codes[code],
                  let verifier = form["code_verifier"], DirigeraPKCE.challenge(for: verifier) == challenge,
                  form["name"]?.isEmpty == false else {
                return .response(.json(#"{"error":"invalid_grant"}"#, status: 400))
            }
            guard s.buttonPressed else { return .response(.json(#"{"error":"button not pressed"}"#, status: 403)) }
            s.codes[code] = nil
            let token = "token-\(UUID().uuidString)"
            s.tokens.insert(token)
            return .response(.json(object: ["access_token": token]))
        default:
            break
        }

        guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer "), s.tokens.contains(String(auth.dropFirst(7))) else {
            return .response(.text("Unauthorized", status: 401))
        }
        if r.method == "GET", r.path == "/v1", r.headers["upgrade"]?.lowercased() == "websocket" {
            return .webSocket { [weak self] connection in self?.mutate { $0.sockets.append(connection) } }
        }
        switch (r.method, r.path) {
        case ("GET", "/v1/hub/status"):
            return .response(.json(object: ["id": Self.hubID, "type": "gateway", "deviceType": "gateway", "isReachable": true,
                                             "attributes": ["customName": "Home", "model": "DIRIGERA Hub for smart products",
                                                            "firmwareVersion": "2.866.3", "serialNumber": "0123456789ABCDEF"]]))
        case ("GET", "/v1/devices"):
            return .response(.json(object: s.devices))
        case ("GET", "/v1/scenes"):
            return .response(.json(object: [["id": Self.scene, "type": "userScene", "info": ["name": "Movie night", "icon": "scenes_clapper"],
                                              "triggers": [], "actions": []]]))
        case ("POST", let path) where path.hasPrefix("/v1/scenes/") && path.hasSuffix("/trigger"):
            let id = path.dropFirst("/v1/scenes/".count).dropLast("/trigger".count)
            guard id == Self.scene else { return .response(.text("Not Found", status: 404)) }
            s.triggered.append(String(id))
            return .response(LoopbackResponse(status: 202, headers: [:], body: Data()))
        case ("PATCH", let path) where path.hasPrefix("/v1/devices/"):
            let id = String(path.dropFirst("/v1/devices/".count))
            guard let device = s.devices.first(where: { $0["id"] as? String == id }) else { return .response(.text("Not Found", status: 404)) }
            guard let body = r.json as? [[String: Any]], body.count == 1, let attrs = body[0]["attributes"] as? [String: Any], !attrs.isEmpty else {
                return .response(.json(#"{"error":"Bad request"}"#, status: 400))
            }
            if s.rejectCombinedPatches, attrs.count > 1, Set(attrs.keys) != ["colorHue", "colorSaturation"] { return .response(.json(#"{"error":"Bad request"}"#, status: 400)) }
            let receive = Set(((device["capabilities"] as? [String: Any])?["canReceive"] as? [String]) ?? [])
            for (key, value) in attrs {
                guard receive.contains(key) else { return .response(.json(#"{"error":"not receivable"}"#, status: 400)) }
                switch key {
                case "lightLevel": guard let v = value as? Int, (1...100).contains(v) else { return .response(.json("{}", status: 400)) }
                case "colorHue": guard let v = value as? Double ?? (value as? Int).map(Double.init), (0...360).contains(v) else { return .response(.json("{}", status: 400)) }
                case "colorSaturation": guard let v = value as? Double ?? (value as? Int).map(Double.init), (0...1).contains(v) else { return .response(.json("{}", status: 400)) }
                default: break
                }
            }
            s.patches.append(r.bodyText)
            apply(id, attrs, isReachable: nil, &s)
            return .response(LoopbackResponse(status: 202, headers: [:], body: Data()))
        default:
            return .response(.text("Not Found", status: 404))
        }
    }

    static func jsonText(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func seedDevices() -> [[String: Any]] {
        [
            ["id": hubID, "type": "gateway", "deviceType": "gateway", "isReachable": true,
             "attributes": ["customName": "Home", "model": "DIRIGERA Hub for smart products", "manufacturer": "IKEA of Sweden"],
             "capabilities": ["canSend": [String](), "canReceive": ["customName"]]],
            ["id": sofa, "type": "light", "deviceType": "light", "isReachable": true,
             "attributes": ["customName": "Sofa", "model": "TRADFRI bulb E27 CWS globe 806lm", "manufacturer": "IKEA of Sweden",
                            "isOn": true, "lightLevel": 80, "colorTemperature": 2700, "colorTemperatureMin": 4000,
                            "colorTemperatureMax": 2202, "colorHue": 120.5, "colorSaturation": 0.75, "colorMode": "color"],
             "capabilities": ["canSend": [String](), "canReceive": ["customName", "isOn", "lightLevel", "colorTemperature", "colorHue", "colorSaturation"]],
             "room": ["id": "room-living", "name": "Living room", "color": "ikea_green_no_65", "icon": "rooms_sofa"]],
            ["id": bed, "type": "light", "deviceType": "light", "isReachable": true,
             "attributes": ["customName": "Bed", "model": "TRADFRIbulbE27WSglobeopal1055lm", "manufacturer": "IKEA of Sweden",
                            "isOn": false, "lightLevel": 43, "colorTemperature": 2222, "colorTemperatureMin": 4000,
                            "colorTemperatureMax": 2202, "colorMode": "temperature"],
             "capabilities": ["canSend": [String](), "canReceive": ["customName", "isOn", "lightLevel", "colorTemperature"]],
             "room": ["id": "room-bed", "name": "Bedroom", "color": "ikea_yellow_no_24", "icon": "rooms_bed"]],
            ["id": plug, "type": "outlet", "deviceType": "outlet", "isReachable": true,
             "attributes": ["customName": "Plug", "model": "TRETAKT Smart plug", "isOn": true],
             "capabilities": ["canSend": [String](), "canReceive": ["customName", "isOn"]]],
        ]
    }
}

/// `DirigeraTransport` over the loopback client (plain http/ws; Linux and macOS). Pairing
/// responses carry a configurable fake certificate fingerprint so TOFU pinning can be tested.
final class LoopbackDirigeraTransport: DirigeraTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _fingerprint: Data? = Data(repeating: 0xAB, count: 32)
    private var _requests: [DirigeraHTTPRequest] = []

    var fingerprint: Data? {
        get { lock.withLock { _fingerprint } }
        set { lock.withLock { _fingerprint = newValue } }
    }

    var requests: [DirigeraHTTPRequest] { lock.withLock { _requests } }

    func send(_ request: DirigeraHTTPRequest) async throws -> DirigeraHTTPResponse {
        lock.withLock { _requests.append(request) }
        let timeout = request.timeout.timeInterval
        do {
            let response = try await onThread {
                try LoopbackHTTPClient.send(method: request.method, url: request.url, headers: request.headers,
                                            body: request.body, timeout: timeout)
            }
            let fp = request.trust == .pairing ? fingerprint : nil
            return DirigeraHTTPResponse(status: response.status, body: response.body, peerCertificateSHA256: fp)
        } catch let error as LoopbackError {
            throw error.message == "timed out" ? DirigeraTransportError.timedOut : DirigeraTransportError.connectionFailed(error.message)
        }
    }

    func eventStream(_ request: DirigeraEventStreamRequest) -> AsyncThrowingStream<DirigeraStreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DirigeraStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                let (status, messages) = try await LoopbackHTTPClient.webSocket(
                    url: request.url, headers: ["Authorization": "Bearer \(request.token)"], timeout: 2)
                guard status == 101 else {
                    continuation.finish(throwing: status == 401 || status == 403
                        ? DirigeraTransportError.unauthorized : DirigeraTransportError.connectionFailed("HTTP \(status)"))
                    return
                }
                continuation.yield(.connected)
                for await message in messages { continuation.yield(.message(message)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: DirigeraTransportError.connectionFailed(String(describing: error)))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
