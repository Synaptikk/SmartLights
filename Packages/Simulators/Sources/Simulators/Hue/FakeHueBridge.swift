// Fake Philips Hue bridge: HTTPS (self-signed, CN = bridge id) + optional plain HTTP,
// v1 pairing (`POST /api`), unauthenticated `GET /api/config`, a CLIP v2 subset under
// /clip/v2/resource, and the SSE eventstream at /eventstream/clip/v2.
// See research/research_hue.md §1.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

public final class FakeHueBridge: Simulator {
    public struct Configuration: Sendable {
        public var host: String = "127.0.0.1"
        /// HTTPS port (real bridge: 443). 0 = ephemeral.
        public var httpsPort: Int = 0
        /// Optional plain-HTTP port (real bridge: 80). nil = no HTTP listener.
        public var httpPort: Int? = nil
        /// 16 hex chars; certificate CN and `bridgeid`.
        public var bridgeId: String = "001788FFFE000001"
        public var name: String = "Hue Bridge"
        public var modelId: String = "BSB002"
        public var swversion: String = "1967054020"
        public var apiversion: String = "1.67.0"
        public var linkButtonPressed: Bool = false
        /// Pre-authorised application keys (username -> clientkey).
        public var appKeys: [String: String] = [:]
        /// More than this many concurrent requests -> HTTP 429 (aiohue: "the bridge denies more than 3").
        public var maxConcurrentRequests: Int? = 3
        /// Artificial latency per response, in milliseconds.
        public var responseDelayMs: Int = 0

        public init() {}
        public init(
            host: String = "127.0.0.1", httpsPort: Int = 0, httpPort: Int? = nil,
            bridgeId: String = "001788FFFE000001", linkButtonPressed: Bool = false, appKeys: [String: String] = [:]
        ) {
            self.host = host
            self.httpsPort = httpsPort
            self.httpPort = httpPort
            self.bridgeId = bridgeId
            self.linkButtonPressed = linkButtonPressed
            self.appKeys = appKeys
        }
    }

    struct State {
        var config: Configuration
        var resources: [String: [JSONObject]]
        var appKeys: [String: String]
        var linkButtonPressed: Bool
        var linkButtonExpires: Date?
        var streams: [Int: EventStreamConnection] = [:]
        var eventCounter = 0
        var channels: [any Channel] = []
        var httpsPort: Int?
        var httpPort: Int?
        var lastDuration: [String: Int] = [:]
        var putLog: [(String, String, JSONObject)] = []
    }

    public let name: String
    public let group: any EventLoopGroup
    public let certificate: SelfSignedCertificate
    private let state: NIOLockedValueBox<State>
    private let limits: NIOLockedValueBox<HTTPLimits>

    public init(
        _ config: Configuration = Configuration(), name: String = "hue",
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) throws {
        self.name = name
        self.group = group
        self.certificate = try SelfSignedCertificate(commonName: config.bridgeId.uppercased())
        var st = State(
            config: config, resources: Self.seedResources(bridgeId: config.bridgeId), appKeys: config.appKeys,
            linkButtonPressed: config.linkButtonPressed)
        Self.recomputeGroups(&st)
        self.state = NIOLockedValueBox(st)
        self.limits = NIOLockedValueBox(
            HTTPLimits(
                maxConcurrentRequests: config.maxConcurrentRequests,
                responseDelay: .milliseconds(Int64(config.responseDelayMs))))
    }

    // MARK: Simulator

    public func start() async throws {
        let cfg = state.withLockedValue { $0.config }
        guard state.withLockedValue({ $0.channels.isEmpty }) else { throw SimulatorError.alreadyStarted }
        let server = MiniHTTPServer(
            group: group, limits: limits,
            tooManyResponse: {
                .json(.tooManyRequests, ["errors": [["description": "Too many requests"]], "data": []])
            },
            handler: { [self] req in self.handle(req) })
        let tls = try certificate.makeServerContext()
        let https = try await server.bind(host: cfg.host, port: cfg.httpsPort, tls: tls)
        var chans: [any Channel] = [https]
        var httpPort: Int?
        if let p = cfg.httpPort {
            let http = try await server.bind(host: cfg.host, port: p, tls: nil)
            chans.append(http)
            httpPort = http.localAddress?.port
        }
        let finalChans = chans
        let finalHttp = httpPort
        state.withLockedValue {
            $0.channels = finalChans
            $0.httpsPort = https.localAddress?.port
            $0.httpPort = finalHttp
        }
    }

    public func stop() async throws {
        let (chans, streams) = state.withLockedValue { s -> ([any Channel], [EventStreamConnection]) in
            defer {
                s.channels = []
                s.streams = [:]
                s.httpsPort = nil
                s.httpPort = nil
            }
            return (s.channels, Array(s.streams.values))
        }
        for st in streams { st.close() }
        await closeAll(chans)
    }

    public var boundPorts: [String: Int] {
        state.withLockedValue { s in
            var d: [String: Int] = [:]
            if let p = s.httpsPort { d["https"] = p }
            if let p = s.httpPort { d["http"] = p }
            return d
        }
    }

    public var httpsPort: Int? { state.withLockedValue { $0.httpsPort } }
    public var httpPort: Int? { state.withLockedValue { $0.httpPort } }
    public var bridgeId: String { state.withLockedValue { $0.config.bridgeId } }

    // MARK: Test controls

    public var linkButtonPressed: Bool {
        state.withLockedValue { Self.isLinkButtonActive(&$0) }
    }

    /// Press the link button. `duration` nil = stays pressed until `releaseLinkButton()`.
    public func pressLinkButton(duration: TimeInterval? = nil) {
        state.withLockedValue {
            $0.linkButtonPressed = true
            $0.linkButtonExpires = duration.map { Date().addingTimeInterval($0) }
        }
    }

    public func releaseLinkButton() {
        state.withLockedValue {
            $0.linkButtonPressed = false
            $0.linkButtonExpires = nil
        }
    }

    /// Registered application keys (username -> clientkey).
    public var appKeys: [String: String] { state.withLockedValue { $0.appKeys } }

    public func addAppKey(_ username: String, clientKey: String = "") {
        state.withLockedValue { $0.appKeys[username] = clientKey }
    }

    public func setLimits(maxConcurrentRequests: Int?, responseDelayMs: Int) {
        limits.withLockedValue {
            $0.maxConcurrentRequests = maxConcurrentRequests
            $0.responseDelay = .milliseconds(Int64(responseDelayMs))
        }
    }

    public func resources(type: String) -> [JSONObject] { state.withLockedValue { $0.resources[type] ?? [] } }

    public func resource(type: String, id: String) -> JSONObject? {
        resources(type: type).first { $0["id"]?.stringValue == id }
    }

    /// Last `dynamics.duration` (ms) applied to a light (via light, grouped_light or scene recall).
    public func lastTransitionDuration(lightId: String) -> Int? { state.withLockedValue { $0.lastDuration[lightId] } }

    /// Number of open eventstream connections.
    public var eventStreamCount: Int { state.withLockedValue { $0.streams.count } }

    /// Apply a CLIP v2 PUT body as if another app (or a physical switch) changed the resource.
    /// Emits SSE events. Throws on validation errors.
    public func externalUpdate(type: String, id: String, body: JSONObject) throws {
        let result = state.withLockedValue { s in Self.applyPut(type: type, id: id, body: body, state: &s) }
        switch result {
        case .success(let events): broadcast(events)
        case .failure(let e): throw e
        }
    }

    // MARK: HTTP routing

    func handle(_ req: HTTPRequest) -> HTTPReply {
        let path = req.path.hasSuffix("/") && req.path.count > 1 ? String(req.path.dropLast()) : req.path
        let comps = path.split(separator: "/").map(String.init)

        // Admin endpoints (simulator only).
        if comps.first == "_sim" {
            return .response(handleAdmin(req, comps: Array(comps.dropFirst())))
        }

        // v1: pairing + config.
        if comps.first == "api" {
            return .response(handleV1(req, comps: Array(comps.dropFirst())))
        }

        if comps == ["eventstream", "clip", "v2"] {
            guard req.method == .GET else { return .response(Self.v2Error(.methodNotAllowed, "method not allowed")) }
            guard isAuthorized(req) else { return .response(Self.v2Error(.forbidden, "unauthorized user")) }
            return .eventStream(
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                onOpen: { [self] conn in
                    state.withLockedValue { $0.streams[conn.id] = conn }
                    conn.send(": hi\n\n")
                },
                onClose: { [self] conn in
                    _ = state.withLockedValue { $0.streams.removeValue(forKey: conn.id) }
                })
        }

        if comps.count >= 3, comps[0] == "clip", comps[1] == "v2", comps[2] == "resource" {
            guard isAuthorized(req) else { return .response(Self.v2Error(.forbidden, "unauthorized user")) }
            return .response(handleV2(req, comps: Array(comps.dropFirst(3))))
        }
        return .response(.text(.notFound, "Not Found"))
    }

    func isAuthorized(_ req: HTTPRequest) -> Bool {
        guard let key = req.headers.first(name: "hue-application-key"), !key.isEmpty else { return false }
        return state.withLockedValue { $0.appKeys[key] != nil }
    }

    static func isLinkButtonActive(_ s: inout State) -> Bool {
        if s.linkButtonPressed, let exp = s.linkButtonExpires, exp < Date() {
            s.linkButtonPressed = false
            s.linkButtonExpires = nil
        }
        return s.linkButtonPressed
    }

    func handleAdmin(_ req: HTTPRequest, comps: [String]) -> HTTPResponse {
        switch (req.method, comps) {
        case (.POST, ["linkbutton"]), (.PUT, ["linkbutton"]):
            let body = req.json
            let pressed = body?["pressed"]?.boolValue ?? true
            if pressed {
                pressLinkButton(duration: body?["duration"]?.doubleValue)
            } else {
                releaseLinkButton()
            }
            return .json(.ok, ["linkbutton": .bool(pressed)])
        case (.GET, ["linkbutton"]):
            return .json(.ok, ["linkbutton": .bool(linkButtonPressed)])
        default:
            return .text(.notFound, "Not Found")
        }
    }

    func handleV1(_ req: HTTPRequest, comps: [String]) -> HTTPResponse {
        let cfg = state.withLockedValue { $0.config }
        if req.method == .GET, comps == ["config"] || (comps.count == 2 && comps[1] == "config") {
            return .json(.ok, .object(v1Config(cfg)))
        }
        if req.method == .POST, comps.isEmpty {
            guard let body = req.json, case .object = body else {
                return .json(.ok, [["error": ["type": 2, "address": "/", "description": "body contains invalid json"]]])
            }
            guard body["devicetype"]?.stringValue?.isEmpty == false else {
                return .json(
                    .ok,
                    [["error": ["type": 5, "address": "/", "description": "invalid/missing parameters in body"]]])
            }
            let wantsClientKey = body["generateclientkey"]?.boolValue == true
            let result = state.withLockedValue { s -> JSON in
                guard Self.isLinkButtonActive(&s) else {
                    return [["error": ["type": 101, "address": "", "description": "link button not pressed"]]]
                }
                let username = Self.randomUsername()
                let clientKey = SimCrypto.hexEncode(SimCrypto.randomBytes(16), uppercase: true)
                s.appKeys[username] = clientKey
                var success: JSONObject = ["username": .string(username)]
                if wantsClientKey { success["clientkey"] = .string(clientKey) }
                return [["success": .object(success)]]
            }
            return .json(.ok, result)
        }
        return .json(.ok, [["error": ["type": 1, "address": "/", "description": "unauthorized user"]]])
    }

    func v1Config(_ cfg: Configuration) -> JSONObject {
        let id = cfg.bridgeId.uppercased()
        let macHex = Array(id.lowercased())
        let mac = [0, 2, 4, 10, 12, 14].map { i in String(macHex[i..<i + 2]) }.joined(separator: ":")
        return [
            "name": .string(cfg.name), "datastoreversion": "172", "swversion": .string(cfg.swversion),
            "apiversion": .string(cfg.apiversion), "mac": .string(mac), "bridgeid": .string(id),
            "factorynew": false, "replacesbridgeid": nil, "modelid": .string(cfg.modelId), "starterkitid": "",
        ]
    }

    static func randomUsername() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        var g = SystemRandomNumberGenerator()
        return String((0..<40).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    static func v2Error(_ status: HTTPResponseStatus, _ description: String) -> HTTPResponse {
        .json(status, ["errors": [["description": .string(description)]], "data": []])
    }

    static let supportedTypes: Set<String> = ["light", "grouped_light", "room", "zone", "scene", "device", "bridge"]

    func handleV2(_ req: HTTPRequest, comps: [String]) -> HTTPResponse {
        switch (req.method, comps.count) {
        case (.GET, 0):
            let all = state.withLockedValue { s in
                ["device", "bridge", "light", "room", "zone", "grouped_light", "scene"].flatMap {
                    (s.resources[$0] ?? []).map(JSON.object)
                }
            }
            return .json(.ok, ["errors": [], "data": .array(all)])
        case (.GET, 1):
            guard Self.isValidType(comps[0]) else { return Self.v2Error(.notFound, "Not Found") }
            let list = resources(type: comps[0]).map(JSON.object)
            return .json(.ok, ["errors": [], "data": .array(list)])
        case (.GET, 2):
            guard let r = resource(type: comps[0], id: comps[1]) else {
                return Self.v2Error(.notFound, "Not Found")
            }
            return .json(.ok, ["errors": [], "data": [.object(r)]])
        case (.PUT, 2):
            guard let body = req.json?.objectValue else {
                return Self.v2Error(.badRequest, "Invalid JSON body")
            }
            let result = state.withLockedValue { s in
                Self.applyPut(type: comps[0], id: comps[1], body: body, state: &s)
            }
            switch result {
            case .success(let events):
                broadcast(events)
                return .json(.ok, ["data": [["rid": .string(comps[1]), "rtype": .string(comps[0])]], "errors": []])
            case .failure(let e):
                return Self.v2Error(e.status, e.description)
            }
        case (.PUT, _), (.GET, _):
            return Self.v2Error(.notFound, "Not Found")
        default:
            return Self.v2Error(.methodNotAllowed, "method not supported by fake bridge")
        }
    }

    static func isValidType(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { $0.isLowercase || $0 == "_" }
    }

    // MARK: State changes

    public struct HueError: Error, CustomStringConvertible, Sendable {
        public var status: HTTPResponseStatus
        public var description: String
    }

    static func index(_ s: State, _ type: String, _ id: String) -> Int? {
        s.resources[type]?.firstIndex { $0["id"]?.stringValue == id }
    }

    /// Returns the SSE event data entries (partial resources) caused by the PUT.
    static func applyPut(type: String, id: String, body: JSONObject, state s: inout State) -> Result<[JSON], HueError> {
        guard supportedTypes.contains(type), let idx = index(s, type, id) else {
            return .failure(HueError(status: .notFound, description: "Not Found"))
        }
        let groupsBefore = s.resources["grouped_light"] ?? []
        var changes: [JSON] = []
        do {
            switch type {
            case "light":
                if let c = try applyLight(lightId: id, body: body, state: &s) { changes.append(.object(c)) }
            case "grouped_light":
                for lid in memberLights(ofGroup: id, s) {
                    if let c = try applyLight(lightId: lid, body: body, state: &s, lenient: true) {
                        changes.append(.object(c))
                    }
                }
            case "scene":
                changes += try applyScene(index: idx, body: body, state: &s)
            default:
                break
            }
            if let name = body["metadata"]?["name"]?.stringValue {
                var r = s.resources[type]![idx]
                var md = r["metadata"]?.objectValue ?? JSONObject()
                if md["name"]?.stringValue != name {
                    md["name"] = .string(name)
                    r["metadata"] = .object(md)
                    s.resources[type]![idx] = r
                    changes.append(
                        ["id": .string(id), "id_v1": r["id_v1"] ?? "", "metadata": ["name": .string(name)], "type": .string(type)])
                }
            }
        } catch let e as HueError {
            return .failure(e)
        } catch {
            return .failure(HueError(status: .internalServerError, description: "\(error)"))
        }
        recomputeGroups(&s)
        for g in s.resources["grouped_light"] ?? [] {
            guard let before = groupsBefore.first(where: { $0["id"] == g["id"] }) else { continue }
            if before["on"] != g["on"] || before["dimming"] != g["dimming"] {
                changes.append(
                    [
                        "id": g["id"] ?? nil, "id_v1": g["id_v1"] ?? nil, "owner": g["owner"] ?? nil,
                        "on": g["on"] ?? nil, "dimming": g["dimming"] ?? nil, "type": "grouped_light",
                    ])
            }
        }
        s.putLog.append((type, id, body))
        return .success(changes)
    }

    /// Applies on/dimming/color/color_temperature/dynamics to a light; returns the changed partial or nil.
    /// `lenient`: ignore capabilities the light lacks (grouped_light / scene fan-out).
    static func applyLight(lightId: String, body: JSONObject, state s: inout State, lenient: Bool = false) throws
        -> JSONObject?
    {
        guard let idx = index(s, "light", lightId) else { throw HueError(status: .notFound, description: "Not Found") }
        var light = s.resources["light"]![idx]
        let before = light
        var partial: JSONObject = ["id": .string(lightId), "id_v1": light["id_v1"] ?? "", "owner": light["owner"] ?? nil]

        if let on = body["on"]?["on"] {
            guard let b = on.boolValue, case .bool = on else {
                throw HueError(status: .badRequest, description: "on.on: expected boolean")
            }
            light["on"] = ["on": .bool(b)]
            if before["on"] != light["on"] { partial["on"] = ["on": .bool(b)] }
        }
        if let dim = body["dimming"]?["brightness"] {
            guard let v = dim.doubleValue, v >= 0, v <= 100 else {
                throw HueError(status: .badRequest, description: "dimming.brightness: value must be between 0 and 100")
            }
            if var d = light["dimming"]?.objectValue {
                let minDim = d["min_dim_level"]?.doubleValue ?? 0
                d["brightness"] = .double(max(v, minDim))
                light["dimming"] = .object(d)
                if before["dimming"] != light["dimming"] { partial["dimming"] = ["brightness": d["brightness"]!] }
            } else if !lenient {
                throw HueError(status: .badRequest, description: "device (light) has no dimming capability")
            }
        }
        if let xy = body["color"]?["xy"] {
            guard let x = xy["x"]?.doubleValue, let y = xy["y"]?.doubleValue, (0...1).contains(x), (0...1).contains(y)
            else { throw HueError(status: .badRequest, description: "color.xy: x and y must be between 0 and 1") }
            if var c = light["color"]?.objectValue {
                c["xy"] = ["x": .double(x), "y": .double(y)]
                light["color"] = .object(c)
                if var ct = light["color_temperature"]?.objectValue {
                    ct["mirek"] = .null
                    ct["mirek_valid"] = false
                    light["color_temperature"] = .object(ct)
                    partial["color_temperature"] = ["mirek": nil, "mirek_valid": false]
                }
                if before["color"] != light["color"] { partial["color"] = ["xy": c["xy"]!] }
            } else if !lenient {
                throw HueError(status: .badRequest, description: "device (light) has no color capability")
            }
        }
        if let mirekJ = body["color_temperature"]?["mirek"] {
            guard let mirek = mirekJ.intValue else {
                throw HueError(status: .badRequest, description: "color_temperature.mirek: expected integer")
            }
            if var ct = light["color_temperature"]?.objectValue {
                let lo = ct["mirek_schema"]?["mirek_minimum"]?.intValue ?? 153
                let hi = ct["mirek_schema"]?["mirek_maximum"]?.intValue ?? 500
                guard (lo...hi).contains(mirek) || (lenient && (153...500).contains(mirek)) else {
                    throw HueError(
                        status: .badRequest, description: "color_temperature.mirek: value must be between \(lo) and \(hi)")
                }
                let clamped = max(lo, min(hi, mirek))
                ct["mirek"] = .int(clamped)
                ct["mirek_valid"] = true
                light["color_temperature"] = .object(ct)
                if before["color_temperature"] != light["color_temperature"] {
                    partial["color_temperature"] = ["mirek": .int(clamped), "mirek_valid": true]
                }
            } else if !lenient {
                throw HueError(status: .badRequest, description: "device (light) has no color temperature capability")
            }
        }
        if let dur = body["dynamics"]?["duration"] {
            guard let ms = dur.intValue, ms >= 0 else {
                throw HueError(status: .badRequest, description: "dynamics.duration: expected non-negative integer")
            }
            s.lastDuration[lightId] = ms
        }
        s.resources["light"]![idx] = light
        partial["type"] = "light"
        return light == before ? nil : partial
    }

    static func applyScene(index idx: Int, body: JSONObject, state s: inout State) throws -> [JSON] {
        guard let recall = body["recall"]?.objectValue else { return [] }
        let action = recall["action"]?.stringValue ?? "active"
        guard ["active", "static", "dynamic_palette"].contains(action) else {
            throw HueError(status: .badRequest, description: "recall.action: invalid value")
        }
        var scene = s.resources["scene"]![idx]
        var changes: [JSON] = []
        for a in scene["actions"]?.arrayValue ?? [] {
            guard let lid = a["target"]?["rid"]?.stringValue, var act = a["action"]?.objectValue else { continue }
            if let dim = recall["dimming"]?["brightness"] { act["dimming"] = ["brightness": dim] }
            if let d = recall["duration"] { act["dynamics"] = ["duration": d] }
            if let c = try applyLight(lightId: lid, body: act, state: &s, lenient: true) { changes.append(.object(c)) }
        }
        let status: String = action == "dynamic_palette" ? "dynamic_palette" : "static"
        let groupRid = scene["group"]?["rid"]
        for (i, other) in (s.resources["scene"] ?? []).enumerated() where i != idx && other["group"]?["rid"] == groupRid {
            if other["status"]?["active"]?.stringValue != "inactive" {
                var o = other
                o["status"] = ["active": "inactive"]
                s.resources["scene"]![i] = o
                changes.append(["id": o["id"] ?? nil, "id_v1": o["id_v1"] ?? nil, "status": ["active": "inactive"], "type": "scene"])
            }
        }
        let iso = ISO8601DateFormatter().string(from: Date())
        scene["status"] = ["active": .string(status), "last_recall": .string(iso)]
        s.resources["scene"]![idx] = scene
        changes.append(["id": scene["id"] ?? nil, "id_v1": scene["id_v1"] ?? nil, "status": scene["status"] ?? nil, "type": "scene"])
        return changes
    }

    /// Light ids belonging to a grouped_light (via its owning room's devices or zone's lights).
    static func memberLights(ofGroup groupId: String, _ s: State) -> [String] {
        guard let g = s.resources["grouped_light"]?.first(where: { $0["id"]?.stringValue == groupId }),
            let ownerId = g["owner"]?["rid"]?.stringValue, let ownerType = g["owner"]?["rtype"]?.stringValue,
            let owner = s.resources[ownerType]?.first(where: { $0["id"]?.stringValue == ownerId })
        else { return [] }
        var lights: [String] = []
        for child in owner["children"]?.arrayValue ?? [] {
            guard let rid = child["rid"]?.stringValue else { continue }
            switch child["rtype"]?.stringValue {
            case "light": lights.append(rid)
            case "device":
                let dev = s.resources["device"]?.first { $0["id"]?.stringValue == rid }
                for svc in dev?["services"]?.arrayValue ?? [] where svc["rtype"]?.stringValue == "light" {
                    if let l = svc["rid"]?.stringValue { lights.append(l) }
                }
            default: break
            }
        }
        return lights
    }

    static func recomputeGroups(_ s: inout State) {
        guard var groups = s.resources["grouped_light"] else { return }
        for i in groups.indices {
            let members = memberLights(ofGroup: groups[i]["id"]?.stringValue ?? "", s)
            let lights = members.compactMap { id in s.resources["light"]?.first { $0["id"]?.stringValue == id } }
            let onLights = lights.filter { $0["on"]?["on"]?.boolValue == true }
            let pool = onLights.isEmpty ? lights : onLights
            let bri = pool.compactMap { $0["dimming"]?["brightness"]?.doubleValue }
            let avg = bri.isEmpty ? 0 : (bri.reduce(0, +) / Double(bri.count) * 100).rounded() / 100
            groups[i]["on"] = ["on": .bool(!onLights.isEmpty)]
            groups[i]["dimming"] = ["brightness": .double(avg)]
        }
        s.resources["grouped_light"] = groups
    }

    // MARK: SSE

    func broadcast(_ changes: [JSON]) {
        guard !changes.isEmpty else { return }
        let (text, streams) = state.withLockedValue { s -> (String, [EventStreamConnection]) in
            s.eventCounter += 1
            let ts = Int(Date().timeIntervalSince1970)
            let event: JSON = [
                "creationtime": .string(ISO8601DateFormatter().string(from: Date())),
                "data": .array(changes),
                "id": .string(SimCrypto.uuid()),
                "type": "update",
            ]
            let text = "id: \(ts):\(s.eventCounter)\ndata: \(JSON.array([event]).compact)\n\n"
            return (text, Array(s.streams.values))
        }
        for st in streams { st.send(text) }
    }
}
