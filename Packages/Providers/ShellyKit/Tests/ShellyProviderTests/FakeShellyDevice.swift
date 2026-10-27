import Crypto
import Foundation
import LightCore
import ShellyCodec
import Synchronization
@testable import ShellyProvider

/// In-process Shelly device behind an in-memory HTTP transport.
///
/// Gen2+: `GET /shelly`, `POST /rpc` (Shelly.GetDeviceInfo/GetConfig/GetStatus, Light/CCT/RGB/RGBW.Set)
/// with RFC 7616 SHA-256 digest when a password is set (verified here with swift-crypto directly,
/// independent of the codec), and `/rpc` WebSocket notifications.
/// Gen1: `GET /shelly`, `/settings`, `/status`, `/light|color|white/N?...` with HTTP Basic auth.
final class FakeShellyDevice: Sendable {
    struct State {
        var info: ShellyJSON
        var config: [String: ShellyJSON]
        var status: [String: ShellyJSON]
        var gen1Settings: ShellyJSON = .object([:])
        var gen1Lights: [ShellyJSON] = []
        var password: String?
        var nonce = "60dc59c6"
        var requests: [String] = []
        var authFailures = 0
        var offline = false
        var sockets: [FakeShellySocket] = []
    }

    let ip: String
    let mac: String
    let generation: Int
    let deviceID: String
    private let state: Mutex<State>

    /// Gen2+ device with the given components (`"rgbw:0": ["output": true, ...]`).
    init(gen2 ip: String, mac: String, app: String = "PlusRGBWPM", model: String = "SNDC-0D4P10WW", gen: Int = 2,
         password: String? = nil, components: [String: ShellyJSON], config: [String: ShellyJSON] = [:], name: String? = nil) {
        self.ip = ip
        self.mac = mac
        generation = gen
        deviceID = "shelly\(app.lowercased())-\(mac)"
        let info: ShellyJSON = [
            "name": name.map { .string($0) } ?? .null, "id": .string(deviceID), "mac": .string(mac.uppercased()),
            "model": .string(model), "gen": .number(Double(gen)), "ver": "1.4.4", "app": .string(app),
            "auth_en": .bool(password != nil), "auth_domain": password != nil ? .string(deviceID) : .null,
        ]
        var cfg = config
        for key in components.keys where cfg[key] == nil { cfg[key] = ["id": .number(Double(Int(key.split(separator: ":")[1])!))] }
        cfg["sys"] = ["device": ["name": name.map { .string($0) } ?? .null, "mac": .string(mac.uppercased())]]
        var status = components
        status["sys"] = ["uptime": 100]
        state = Mutex(State(info: info, config: cfg, status: status, password: password))
    }

    /// Gen1 device (`type` like SHBDUO-1) with `/settings` and `lights[]` status entries.
    init(gen1 ip: String, mac: String, type: String, password: String? = nil, settings: ShellyJSON, lights: [ShellyJSON]) {
        self.ip = ip
        self.mac = mac
        generation = 1
        deviceID = "\(type.lowercased())-\(mac)"
        let info: ShellyJSON = ["type": .string(type), "mac": .string(mac.uppercased()), "auth": .bool(password != nil), "fw": "20230913-114008/v1.14.0"]
        var s = State(info: info, config: [:], status: [:], password: password)
        s.gen1Settings = settings
        s.gen1Lights = lights
        state = Mutex(s)
    }

    var requests: [String] { state.withLock { $0.requests } }
    var authFailures: Int { state.withLock { $0.authFailures } }
    var socketCount: Int { state.withLock { $0.sockets.count } }
    func status(_ key: String) -> ShellyJSON? { state.withLock { $0.status[key] } }
    func gen1Light(_ i: Int) -> ShellyJSON? { state.withLock { $0.gen1Lights.indices.contains(i) ? $0.gen1Lights[i] : nil } }
    func setOffline(_ v: Bool) { state.withLock { $0.offline = v } }
    var isOffline: Bool { state.withLock { $0.offline } }
    /// New nonce: the next digest computed from the old one is rejected (`stale=true`).
    func rotateNonce(_ n: String) { state.withLock { $0.nonce = n } }

    /// Change made from the Shelly app: updates status and notifies open WebSockets.
    func externalChange(_ key: String, _ patch: ShellyJSON) {
        let sockets: [FakeShellySocket] = state.withLock { s in
            s.status[key] = (s.status[key] ?? .object([:])).merging(patch)
            return s.sockets
        }
        let frame: ShellyJSON = ["src": .string(deviceID), "dst": "*", "method": "NotifyStatus",
                                 "params": .object(["ts": 1.7e9, key: patch])]
        for s in sockets { s.deliver(frame.jsonString) }
    }

    func externalGen1Change(_ index: Int, _ patch: ShellyJSON) {
        state.withLock { s in s.gen1Lights[index] = s.gen1Lights[index].merging(patch) }
    }

    // MARK: HTTP

    func handle(_ r: ShellyHTTPRequest) -> ShellyHTTPResponse {
        state.withLock { s in
            s.requests.append("\(r.method) \(r.uri)")
            if r.uri == "/shelly" { return json(s.info) }
            if generation >= 2 {
                guard r.method == "POST", r.uri == "/rpc", let body = r.body, let frame = try? ShellyJSON.parse(body) else {
                    return ShellyHTTPResponse(status: 404)
                }
                if let password = s.password {
                    switch Self.verifyDigest(r.headers["Authorization"], realm: deviceID, nonce: s.nonce, password: password) {
                    case .ok: break
                    case .missing:
                        return challenge(s.nonce, stale: false)
                    case .staleNonce:
                        return challenge(s.nonce, stale: true)
                    case .wrong:
                        s.authFailures += 1
                        return challenge(s.nonce, stale: false)
                    }
                }
                return json(rpc(frame, &s))
            }
            if let password = s.password {
                let expected = "Basic " + Data("admin:\(password)".utf8).base64EncodedString()
                guard r.headers["Authorization"] == expected else {
                    if r.headers["Authorization"] != nil { s.authFailures += 1 }
                    return ShellyHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"\(deviceID)\""])
                }
            }
            return gen1(ShellyGen1Request.parse(uri: r.uri), &s)
        }
    }

    private func json(_ j: ShellyJSON) -> ShellyHTTPResponse {
        ShellyHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: j.encoded())
    }

    private func challenge(_ nonce: String, stale: Bool) -> ShellyHTTPResponse {
        let header = "Digest qop=\"auth\", realm=\"\(deviceID)\", nonce=\"\(nonce)\", algorithm=SHA-256" + (stale ? ", stale=true" : "")
        return ShellyHTTPResponse(status: 401, headers: ["WWW-Authenticate": header])
    }

    func rpc(_ frame: ShellyJSON, _ s: inout State) -> ShellyJSON {
        let id = frame["id"] ?? .null
        let method = frame["method"]?.string ?? ""
        let params = frame["params"] ?? .object([:])
        func result(_ r: ShellyJSON) -> ShellyJSON { ["id": id, "src": .string(deviceID), "dst": frame["src"] ?? .null, "result": r] }
        switch method {
        case "Shelly.GetDeviceInfo": return result(s.info)
        case "Shelly.GetConfig": return result(.object(s.config))
        case "Shelly.GetStatus": return result(.object(s.status))
        default:
            guard method.hasSuffix(".Set"), let index = params["id"]?.int else {
                return ["id": id, "error": ["code": -114, "message": .string("Method \(method) failed: not found")]]
            }
            let kind = method.dropLast(4).lowercased()
            let key = "\(kind):\(index)"
            guard var c = s.status[key] else {
                return ["id": id, "error": ["code": -105, "message": .string("Argument 'id', value \(index) not found!")]]
            }
            if let on = params["on"] { c = c.merging(["output": on]) }
            for field in ["brightness", "rgb", "white", "ct", "mode"] { if let v = params[field] { c = c.merging(.object([field: v])) } }
            s.status[key] = c
            return result(.null)
        }
    }

    func gen1(_ r: ShellyGen1Request, _ s: inout State) -> ShellyHTTPResponse {
        switch r.path {
        case "/settings": return json(s.gen1Settings)
        case "/status": return json(["lights": .array(s.gen1Lights), "wifi_sta": ["connected": true]])
        default:
            let parts = r.path.split(separator: "/")
            guard parts.count == 2, ["light", "color", "white"].contains(parts[0]), let i = Int(parts[1]), s.gen1Lights.indices.contains(i) else {
                return ShellyHTTPResponse(status: 404)
            }
            var l = s.gen1Lights[i]
            for (k, v) in r.query {
                switch k {
                case "turn": l = l.merging(["ison": .bool(v == "on")])
                case "mode": l = l.merging(["mode": .string(v)])
                default: if let n = Double(v) { l = l.merging(.object([k: .number(n)])) }
                }
            }
            s.gen1Lights[i] = l
            return json(l)
        }
    }

    // MARK: Digest verification (independent implementation)

    enum DigestResult { case ok, missing, staleNonce, wrong }

    static func verifyDigest(_ header: String?, realm: String, nonce: String, password: String) -> DigestResult {
        guard let header, header.hasPrefix("Digest ") else { return .missing }
        var p: [String: String] = [:]
        for part in header.dropFirst(7).components(separatedBy: ", ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            p[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard p["nonce"] == nonce else { return .staleNonce }
        func h(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        guard p["username"] == "admin", p["realm"] == realm, p["algorithm"] == "SHA-256", p["qop"] == "auth",
              let nc = p["nc"], nc.count == 8, let cnonce = p["cnonce"], let uri = p["uri"] else { return .wrong }
        let expected = h("\(h("admin:\(realm):\(password)")):\(nonce):\(nc):\(cnonce):auth:\(h("POST:\(uri)"))")
        return p["response"] == expected ? .ok : .wrong
    }

    // MARK: WebSocket

    func openSocket() throws -> FakeShellySocket {
        let socket = FakeShellySocket(device: self)
        try state.withLock { s in
            guard !s.offline else { throw LightCoreError.unreachable("\(ip) refused") }
            s.sockets.append(socket)
        }
        return socket
    }

    func socketClosed(_ socket: FakeShellySocket) {
        state.withLock { s in s.sockets.removeAll { $0 === socket } }
    }

    /// Handles a client frame on a WebSocket (auth via the frame's `auth` object, aioshelly formula).
    func handleSocketFrame(_ text: String, socket: FakeShellySocket) {
        let reply: ShellyJSON? = state.withLock { s in
            guard let frame = try? ShellyJSON.parse(text) else { return nil }
            if let password = s.password {
                let auth = frame["auth"]
                func h(_ x: String) -> String { SHA256.hash(data: Data(x.utf8)).map { String(format: "%02x", $0) }.joined() }
                var ok = false
                if let auth, let cnonce = auth["cnonce"]?.string, let nc = auth["nc"]?.int, auth["nonce"]?.string == s.nonce {
                    let expected = h("\(h("admin:\(deviceID):\(password)")):\(s.nonce):\(nc):\(cnonce):auth:\(h("dummy_method:dummy_uri"))")
                    ok = auth["response"]?.string == expected
                }
                if !ok {
                    let message: ShellyJSON = ["auth_type": "digest", "nonce": .string(s.nonce), "nc": 1, "realm": .string(deviceID), "algorithm": "SHA-256"]
                    return ["id": frame["id"] ?? .null, "src": .string(deviceID), "error": ["code": 401, "message": .string(message.jsonString)]]
                }
            }
            return rpc(frame, &s)
        }
        if let reply { socket.deliver(reply.jsonString) }
    }
}

final class FakeShellySocket: ShellyWebSocket, Sendable {
    let messages: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let device: FakeShellyDevice
    let sent = Mutex<[String]>([])

    init(device: FakeShellyDevice) {
        self.device = device
        (messages, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    }

    func send(_ text: String) async throws {
        sent.withLock { $0.append(text) }
        device.handleSocketFrame(text, socket: self)
    }

    func deliver(_ text: String) { continuation.yield(text) }

    func close() {
        continuation.finish()
        device.socketClosed(self)
    }
}

/// A LAN of fake devices as a `ShellyNetworkEnvironment`.
final class FakeShellyNetwork: ShellyHTTPTransport, Sendable {
    private let devices: Mutex<[String: FakeShellyDevice]>
    let bonjour: [ShellyBonjourHit]?
    let sweep: [String]
    let webSockets: Bool

    init(_ devices: [FakeShellyDevice], bonjour: [ShellyBonjourHit]? = nil, sweep: [String] = [], webSockets: Bool = false) {
        self.devices = Mutex(Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) }))
        self.bonjour = bonjour
        self.sweep = sweep
        self.webSockets = webSockets
    }

    func perform(_ request: ShellyHTTPRequest, timeout: Duration) async throws -> ShellyHTTPResponse {
        guard let d = devices.withLock({ $0[request.host] }), !d.isOffline else {
            throw LightCoreError.unreachable("\(request.host): timed out")
        }
        return d.handle(request)
    }

    var environment: ShellyNetworkEnvironment {
        let net = self
        var browse: (@Sendable () -> AsyncStream<ShellyBonjourHit>)?
        if let list = bonjour {
            browse = { AsyncStream { c in for h in list { c.yield(h) }; c.finish() } }
        }
        var open: (@Sendable (String, Int) async throws -> any ShellyWebSocket)?
        if webSockets {
            open = { host, _ in
                guard let d = net.devices.withLock({ $0[host] }) else { throw LightCoreError.unreachable(host) }
                return try d.openSocket()
            }
        }
        return ShellyNetworkEnvironment(http: self, browseBonjour: browse, sweepHosts: { net.sweep }, openWebSocket: open)
    }
}
