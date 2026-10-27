import Foundation
import LightCore
import TPLinkCodec
@testable import TPLinkProvider

/// Light state shared by both fakes.
struct FakeLightState: Sendable, Equatable {
    var on = true
    var brightness = 50
    var hue = 0
    var saturation = 0
    var colorTemp = 2700
}

// MARK: - Legacy Kasa bulb (XOR JSON over TCP)

/// A Kasa KL130-style bulb (or KL430 strip) on a loopback TCP port, speaking the XOR protocol.
/// Also answers the UDP 9999 discovery datagram through `FakeDatagramNetwork`.
final class FakeKasaBulb: @unchecked Sendable {
    let model: String
    let mac: String
    let isStrip: Bool
    private let lock = NSLock()
    private var _state = FakeLightState()
    private var _alias: String
    private var _requests: [TPLinkJSON] = []
    private var server: LoopbackServer!

    init(model: String = "KL130(US)", mac: String = "1C:3B:F3:11:22:33", alias: String = "Desk lamp", strip: Bool = false) throws {
        self.model = model
        self.mac = mac
        self.isStrip = strip
        _alias = alias
        server = try LoopbackServer { fd in self.serve(fd) }
    }

    var port: UInt16 { server.port }
    var stableID: String { TPLinkIdentity.normalizedMAC(mac)! }

    var state: FakeLightState {
        get { lock.sync { _state } }
        set { lock.sync { _state = newValue } }
    }

    var alias: String {
        get { lock.sync { _alias } }
        set { lock.sync { _alias = newValue } }
    }

    /// Requests received, in order.
    var requests: [TPLinkJSON] { lock.sync { _requests } }

    func stop() { server.stop() }

    private func serve(_ fd: Int32) {
        defer { PosixSocket.close(fd) }
        while true {
            guard let header = try? PosixSocket.receive(fd, exactly: 4),
                  let length = TPLinkXOR.announcedLength(Data(header)),
                  let payload = try? PosixSocket.receive(fd, exactly: length),
                  let request = try? TPLinkJSON.parse(TPLinkXOR.decrypt(Data(payload)))
            else { return }
            lock.sync { _requests.append(request) }
            try? PosixSocket.sendAll(fd, TPLinkXOR.frame(handle(request)))
        }
    }

    func handle(_ request: TPLinkJSON) -> TPLinkJSON {
        if request["system"]?["get_sysinfo"] != nil {
            return ["system": ["get_sysinfo": sysinfo]]
        }
        let service = isStrip ? TPLinkIOT.stripService : TPLinkIOT.bulbService
        let command = isStrip ? TPLinkIOT.stripSetCommand : TPLinkIOT.bulbSetCommand
        if let args = request[service]?[command] {
            lock.sync {
                if let v = args["on_off"]?.boolValue { _state.on = v }
                if let v = args["brightness"]?.intValue { _state.brightness = v }
                if let v = args["hue"]?.intValue { _state.hue = v }
                if let v = args["saturation"]?.intValue { _state.saturation = v }
                if let v = args["color_temp"]?.intValue { _state.colorTemp = v }
            }
            var result = lightState
            if case .object(var m) = result {
                m["err_code"] = 0
                result = .object(m)
            }
            return .object([service: .object([command: result])])
        }
        let target = request.objectValue?.keys.first ?? "unknown"
        return .object([target: ["err_code": -1, "err_msg": "module not support"]])
    }

    var lightState: TPLinkJSON {
        let s = state
        let values: TPLinkJSON = [
            "mode": "normal", "hue": .int(Int64(s.hue)), "saturation": .int(Int64(s.saturation)),
            "color_temp": .int(Int64(s.colorTemp)), "brightness": .int(Int64(s.brightness)),
        ]
        if s.on {
            guard case .object(var m) = values else { return values }
            m["on_off"] = 1
            return .object(m)
        }
        return ["on_off": 0, "dft_on_state": values]
    }

    var sysinfo: TPLinkJSON {
        var m: [String: TPLinkJSON] = [
            "sw_ver": "1.8.11 Build 191113 Rel.105336", "hw_ver": "1.0", "model": .string(model), "alias": .string(alias),
            "mic_type": "IOT.SMARTBULB", "dev_state": "normal", "mic_mac": .string(mac.replacingOccurrences(of: ":", with: "")),
            "deviceId": "801200AABBCCDDEEFF00112233445566778899AA", "is_color": 1, "is_dimmable": 1, "is_variable_color_temp": 1,
            "light_state": lightState, "err_code": 0,
        ]
        if isStrip { m["length"] = 16 }
        return .object(m)
    }

    /// UDP 9999 answer to the legacy discovery datagram.
    func discoveryAnswer(_ probe: TPLinkProbe) -> TPLinkDatagram? {
        guard probe.port == TPLinkDiscovery.legacyPort,
              let q = try? TPLinkJSON.parse(TPLinkXOR.decrypt(probe.payload)), q["system"]?["get_sysinfo"] != nil
        else { return nil }
        let answer: TPLinkJSON = ["system": ["get_sysinfo": sysinfo]]
        return TPLinkDatagram(data: TPLinkXOR.encrypt(answer.data), host: "127.0.0.1", port: TPLinkDiscovery.legacyPort)
    }
}

// MARK: - Tapo bulb (SMART over KLAP v2 over HTTP)

/// A Tapo L530-style bulb on a loopback HTTP port: KLAP v2 handshake with fixed account
/// credentials, AES session per `TP_SESSIONID`, SMART `get_device_info` / `set_device_info`.
final class FakeTapoBulb: @unchecked Sendable {
    let model: String
    let mac: String
    let username: String
    let password: String
    let version: TPLinkKLAP.Version
    private let lock = NSLock()
    private var _state = FakeLightState(on: false, brightness: 80, hue: 0, saturation: 100, colorTemp: 2700)
    private var _nickname = "Living room"
    private var pending: [String: (local: Data, remote: Data)] = [:]
    private var sessions: [String: TPLinkKLAPSession] = [:]
    private var _handshake1Count = 0
    private var _handshake2Count = 0
    private var _methods: [String] = []
    private var _setParams: [TPLinkJSON] = []
    private var _failNext: [Int] = []
    private var server: LoopbackServer!

    init(model: String = "L530", mac: String = "5C-E9-31-12-34-56", username: String = "Jane.Doe@Example.com",
         password: String = "S3cret!", version: TPLinkKLAP.Version = .v2) throws {
        self.model = model
        self.mac = mac
        self.username = username
        self.password = password
        self.version = version
        server = try LoopbackServer { fd in self.serve(fd) }
    }

    var port: UInt16 { server.port }
    var stableID: String { TPLinkIdentity.normalizedMAC(mac)! }
    var state: FakeLightState {
        get { lock.sync { _state } }
        set { lock.sync { _state = newValue } }
    }

    var handshake1Count: Int { lock.sync { _handshake1Count } }
    var handshake2Count: Int { lock.sync { _handshake2Count } }
    var methods: [String] { lock.sync { _methods } }
    var setParams: [TPLinkJSON] { lock.sync { _setParams } }

    func stop() { server.stop() }

    /// Forgets every session: the next request gets HTTP 403 (as after a device reboot).
    func dropSessions() { lock.sync { sessions.removeAll() } }

    /// The next SMART request answers with `error_code` (e.g. 9999 session timeout).
    func failNext(errorCode: Int) { lock.sync { _failNext.append(errorCode) } }

    private var authHash: Data { TPLinkKLAP.authHash(username: username, password: password, version: version) }

    private func serve(_ fd: Int32) {
        defer { PosixSocket.close(fd) }
        guard let request = FakeHTTPRequest.read(from: fd), request.method == "POST" else { return }
        switch request.path {
        case TPLinkKLAP.handshake1Path:
            guard request.body.count == 16 else { return FakeHTTPRequest.respond(fd, status: 400) }
            let remote = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let cookie = (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
            let hash = TPLinkKLAP.handshake1Hash(localSeed: request.body, remoteSeed: remote, authHash: authHash, version: version)
            lock.sync {
                _handshake1Count += 1
                pending[cookie] = (request.body, remote)
            }
            FakeHTTPRequest.respond(fd, status: 200, body: remote + hash,
                                    headers: ["Set-Cookie": "\(TPLinkKLAP.sessionCookieName)=\(cookie);TIMEOUT=86400"])
        case TPLinkKLAP.handshake2Path:
            guard let cookie = request.cookies[TPLinkKLAP.sessionCookieName],
                  let seeds = lock.sync({ pending.removeValue(forKey: cookie) }) else {
                return FakeHTTPRequest.respond(fd, status: 403)
            }
            let expected = TPLinkKLAP.handshake2Hash(localSeed: seeds.local, remoteSeed: seeds.remote, authHash: authHash, version: version)
            guard request.body == expected else { return FakeHTTPRequest.respond(fd, status: 403) }
            lock.sync {
                _handshake2Count += 1
                sessions[cookie] = TPLinkKLAPSession(localSeed: seeds.local, remoteSeed: seeds.remote, authHash: authHash)
            }
            FakeHTTPRequest.respond(fd, status: 200)
        case TPLinkKLAP.requestPath:
            guard let cookie = request.cookies[TPLinkKLAP.sessionCookieName],
                  let session = lock.sync({ sessions[cookie] }),
                  let seqText = request.query["seq"], let seq = Int32(seqText) else {
                return FakeHTTPRequest.respond(fd, status: 403)
            }
            guard let plain = try? session.open(request.body, sequence: seq), let json = try? TPLinkJSON.parse(plain) else {
                return FakeHTTPRequest.respond(fd, status: 400)
            }
            let answer = handle(json)
            guard let sealed = try? session.seal(answer.data, sequence: seq) else { return FakeHTTPRequest.respond(fd, status: 500) }
            FakeHTTPRequest.respond(fd, status: 200, body: sealed)
        default:
            FakeHTTPRequest.respond(fd, status: 404)
        }
    }

    func handle(_ request: TPLinkJSON) -> TPLinkJSON {
        let method = request["method"]?.stringValue ?? ""
        let failure: Int? = lock.sync {
            _methods.append(method)
            return _failNext.isEmpty ? nil : _failNext.removeFirst()
        }
        if let failure { return ["error_code": .int(Int64(failure))] }
        switch method {
        case "get_device_info":
            return ["error_code": 0, "result": deviceInfo]
        case "set_device_info":
            let params = request["params"] ?? .emptyObject
            lock.sync {
                _setParams.append(params)
                if let v = params["device_on"]?.boolValue { _state.on = v }
                if let v = params["brightness"]?.intValue { _state.brightness = v }
                if let v = params["hue"]?.intValue { _state.hue = v }
                if let v = params["saturation"]?.intValue { _state.saturation = v }
                if let v = params["color_temp"]?.intValue { _state.colorTemp = v }
            }
            return ["error_code": 0]
        default:
            return ["error_code": -1002]
        }
    }

    var deviceInfo: TPLinkJSON {
        let s = state
        let nickname = lock.sync { _nickname }
        return [
            "device_id": "80223A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F", "fw_ver": "1.1.6 Build 240130 Rel.173828", "hw_ver": "3.0",
            "type": "SMART.TAPOBULB", "model": .string(model), "mac": .string(mac),
            "nickname": .string(Data(nickname.utf8).base64EncodedString()), "device_on": .bool(s.on),
            "brightness": .int(Int64(s.brightness)), "hue": .int(Int64(s.hue)), "saturation": .int(Int64(s.saturation)),
            "color_temp": .int(Int64(s.colorTemp)), "color_temp_range": [2500, 6500], "dynamic_light_effect_enable": false,
            "overheated": false,
        ]
    }

    /// UDP 20002 answer (16-byte header + JSON) naming this fake's HTTP port.
    func discoveryAnswer(_ probe: TPLinkProbe, encryptType: String = "KLAP") -> TPLinkDatagram? {
        guard probe.port == TPLinkDiscovery.port, probe.payload.first == 0x02 else { return nil }
        let result: TPLinkJSON = [
            "device_id": "8022A1B2C3D4E5F60718293A4B5C6D7E", "device_type": "SMART.TAPOBULB", "device_model": "L530E(EU)",
            "ip": "127.0.0.1", "mac": .string(mac), "factory_default": false,
            "mgt_encrypt_schm": ["is_support_https": false, "encrypt_type": .string(encryptType), "http_port": .int(Int64(port)), "lv": 2],
        ]
        let answer: TPLinkJSON = ["error_code": 0, "result": result]
        return TPLinkDatagram(data: Data(count: 16) + answer.data, host: "127.0.0.1", port: TPLinkDiscovery.port)
    }
}

// MARK: - UDP discovery stand-in

/// In-memory `TPLinkDatagramTransport`: each host has a responder that answers probes.
final class FakeDatagramNetwork: TPLinkDatagramTransport, @unchecked Sendable {
    typealias Responder = @Sendable (TPLinkProbe) -> TPLinkDatagram?
    private let lock = NSLock()
    private var responders: [String: [Responder]] = [:]
    private var _broadcasts = 0
    private var _probedHosts: [String] = []

    func add(host: String, _ responder: @escaping Responder) {
        lock.sync { responders[host, default: []].append(responder) }
    }

    var broadcasts: Int { lock.sync { _broadcasts } }
    var probedHosts: [String] { lock.sync { _probedHosts } }

    private func answers(_ probes: [TPLinkProbe], host: String) -> [TPLinkDatagram] {
        let rs = lock.sync { responders[host] ?? [] }
        return probes.flatMap { probe in rs.compactMap { $0(probe) } }
    }

    func broadcast(_ probes: [TPLinkProbe], to addresses: [String], rounds: Int, listen: Duration) -> AsyncStream<TPLinkDatagram> {
        let hosts: [String] = lock.sync {
            _broadcasts += 1
            return Array(responders.keys)
        }
        let all = hosts.flatMap { answers(probes, host: $0) }
        return AsyncStream { continuation in
            for d in all { continuation.yield(d) }
            continuation.finish()
        }
    }

    func probe(_ probes: [TPLinkProbe], host: String, timeout: Duration) async -> [TPLinkDatagram] {
        lock.sync { _probedHosts.append(host) }
        return answers(probes, host: host)
    }
}
