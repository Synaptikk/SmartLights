import Crypto
import Foundation
import LightCore
import MerossCodec
import Synchronization

@testable import MerossProvider

/// One fake Meross light on the fake LAN: verifies signatures, applies SETs, answers like firmware does
/// (`/appliance/<uuid>/publish` in `from`, signed reply header, ERROR 5001 on a bad sign).
struct FakeMerossDeviceState: Sendable {
    var uuid: String
    var type = "msl120d"
    var mac = "48:e1:e9:00:00:01"
    var capacity = 7
    var hasToggleX = true
    var encrypted = false
    var isOn = false
    var rgb = 16711680
    var temperature = 50
    var luminance = 60
    var mode = 2
    /// Requests received (namespace, method), in order.
    var log: [(String, String)] = []
}

final class FakeMerossLAN: MerossLocalTransport, Sendable {
    private struct State {
        var devicesByHost: [String: FakeMerossDeviceState] = [:]
        var requestCount = 0
    }

    let key: String
    private let state = Mutex(State())

    init(key: String) {
        self.key = key
    }

    func add(_ device: FakeMerossDeviceState, at host: String) {
        state.withLock { $0.devicesByHost[host] = device }
    }

    /// Moves a device to another IP (DHCP lease change).
    func move(uuid: String, to host: String) {
        state.withLock { s in
            guard let (old, dev) = s.devicesByHost.first(where: { $0.value.uuid == uuid }) else { return }
            s.devicesByHost[old] = nil
            s.devicesByHost[host] = dev
        }
    }

    func device(_ uuid: String) -> FakeMerossDeviceState? {
        state.withLock { $0.devicesByHost.values.first { $0.uuid == uuid } }
    }

    func update(_ uuid: String, _ body: (inout FakeMerossDeviceState) -> Void) {
        state.withLock { s in
            guard let host = s.devicesByHost.first(where: { $0.value.uuid == uuid })?.key else { return }
            body(&s.devicesByHost[host]!)
        }
    }

    var requestCount: Int { state.withLock { $0.requestCount } }

    func post(host: String, port: UInt16, body: Data, contentType: String, timeout: Duration) async throws -> (status: Int, body: Data) {
        let dev: FakeMerossDeviceState? = state.withLock { s in
            s.requestCount += 1
            return s.devicesByHost[host]
        }
        guard let dev else { throw LightCoreError.unreachable("no route to \(host)") }
        var plain = body
        let cipherKey = MerossCrypto.encryptionKey(uuid: dev.uuid, key: key, mac: dev.mac)
        let isEncrypted = contentType == "application/octet-stream"
        if isEncrypted {
            guard dev.encrypted else { return (400, Data()) }
            plain = try MerossCrypto.decryptBody(body, key: cipherKey)
        }
        let json = try MerossJSON.decode(plain)
        let header = json["header"]!
        let namespace = header["namespace"]!.stringValue!
        let method = header["method"]!.stringValue!
        // Encrypted firmware answers only the ability in clear (meross_lan config_flow).
        if dev.encrypted, !isEncrypted, namespace != MerossNamespace.systemAbility { return (500, Data()) }
        let validSign = MerossRequest.signature(messageId: header["messageId"]!.stringValue!, key: key,
                                                timestamp: header["timestamp"]!.intValue!) == header["sign"]!.stringValue!
        let reply: MerossJSON
        if !validSign {
            reply = makeReply(for: dev, namespace: namespace, method: "ERROR", payload: ["error": ["code": 5001, "detail": "sign error"]])
        } else {
            let payload = json["payload"] ?? [:]
            let result: (String, MerossJSON) = state.withLock { s in
                guard let h = s.devicesByHost.first(where: { $0.value.uuid == dev.uuid })?.key else { return ("ERROR", [:]) }
                s.devicesByHost[h]!.log.append((namespace, method))
                return Self.handle(namespace: namespace, method: method, payload: payload, device: &s.devicesByHost[h]!)
            }
            reply = makeReply(for: dev, namespace: namespace, method: result.0, payload: result.1)
        }
        var out = reply.encoded()
        if isEncrypted { out = try MerossCrypto.encryptBody(out, key: cipherKey) }
        return (200, out)
    }

    private func makeReply(for dev: FakeMerossDeviceState, namespace: String, method: String, payload: MerossJSON) -> MerossJSON {
        let messageId = MerossRequest.newMessageId()
        let ts = Int(Date().timeIntervalSince1970)
        return [
            "header": [
                "messageId": .string(messageId), "namespace": .string(namespace), "method": .string(method),
                "payloadVersion": 1, "from": .string("/appliance/\(dev.uuid)/publish"), "timestamp": .int(ts),
                "timestampMs": 0, "sign": .string(MerossRequest.signature(messageId: messageId, key: key, timestamp: ts)),
            ],
            "payload": payload,
        ]
    }

    private static func handle(namespace: String, method: String, payload: MerossJSON,
                               device d: inout FakeMerossDeviceState) -> (String, MerossJSON) {
        switch (namespace, method) {
        case (MerossNamespace.systemAbility, "GET"):
            var ability: [String: MerossJSON] = [
                "Appliance.System.All": [:],
                "Appliance.Control.Light": ["capacity": .int(d.capacity)],
            ]
            if d.hasToggleX { ability["Appliance.Control.ToggleX"] = [:] }
            if d.encrypted { ability["Appliance.Encrypt.ECDHE"] = [:] }
            return ("GETACK", ["ability": .object(ability)])
        case (MerossNamespace.systemAll, "GET"):
            var digest: [String: MerossJSON] = ["light": lightJSON(d)]
            if d.hasToggleX { digest["togglex"] = [["channel": 0, "onoff": .int(d.isOn ? 1 : 0), "lmTime": 0]] }
            return ("GETACK", ["all": [
                "system": [
                    "hardware": ["type": .string(d.type), "uuid": .string(d.uuid), "macAddress": .string(d.mac), "version": "2.0.0"],
                    "firmware": ["version": "2.1.2", "innerIp": "10.0.0.1"],
                    "online": ["status": 1],
                ],
                "digest": .object(digest),
            ]])
        case (MerossNamespace.controlToggleX, "SET"):
            if let on = payload["togglex"]?["onoff"]?.intValue { d.isOn = on != 0 }
            return ("SETACK", [:])
        case (MerossNamespace.controlLight, "SET"):
            let l = payload["light"] ?? [:]
            if let v = l["rgb"]?.intValue { d.rgb = v }
            if let v = l["temperature"]?.intValue { d.temperature = v }
            if let v = l["luminance"]?.intValue { d.luminance = v }
            if let v = l["capacity"]?.intValue { d.mode = v }
            if let v = l["onoff"]?.intValue { d.isOn = v != 0 } else if !d.hasToggleX { d.isOn = true }
            return ("SETACK", [:])
        case (MerossNamespace.controlLight, "GET"):
            return ("GETACK", ["light": lightJSON(d)])
        default:
            return ("ERROR", ["error": ["code": 5000, "detail": "unsupported"]])
        }
    }

    private static func lightJSON(_ d: FakeMerossDeviceState) -> MerossJSON {
        ["channel": 0, "capacity": .int(d.mode), "rgb": .int(d.rgb), "temperature": .int(d.temperature),
         "luminance": .int(d.luminance), "transform": 0]
    }
}

/// Fake Meross cloud: checks the request signature and the md5 password, issues one token per sign-in.
final class FakeMerossCloud: MerossCloudTransport, Sendable {
    struct Configuration: Sendable {
        var email = "user@example.com"
        var password = "s3cret-pw"
        var key = "0123456789abcdef0123456789abcdef"
        var userId = "1234567"
        /// Redirect sign-ins arriving at another base URL to this domain (apiStatus 1030).
        var homeDomain: String?
        var mfaCode: String?
        var devices: [MerossCloudDevice] = []
    }

    private struct State {
        var config: Configuration
        var tokens: Set<String> = []
        var signInCount = 0
        var devListCount = 0
        var paths: [String] = []
        var lastSignInParams: MerossJSON?
    }

    private let state: Mutex<State>

    init(_ config: Configuration) {
        state = Mutex(State(config: config))
    }

    var signInCount: Int { state.withLock { $0.signInCount } }
    var devListCount: Int { state.withLock { $0.devListCount } }
    var paths: [String] { state.withLock { $0.paths } }
    var lastSignInParams: MerossJSON? { state.withLock { $0.lastSignInParams } }

    func revokeTokens() { state.withLock { $0.tokens = [] } }

    func perform(_ request: MerossCloudRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data) {
        let body = try MerossJSON.decode(request.body)
        guard let params = body["params"]?.stringValue, let ts = body["timestamp"]?.intValue, let nonce = body["nonce"]?.stringValue,
              body["sign"]?.stringValue == MerossCrypto.md5Hex(MerossCloudAPI.secret + String(ts) + nonce + params),
              let paramData = Data(base64Encoded: params), let p = try? MerossJSON.decode(paramData) else {
            return (200, Self.status(1022))
        }
        return state.withLock { s in
            s.paths.append(baseURL.absoluteString + request.path)
            switch request.path {
            case MerossCloudAPI.signInPath:
                s.signInCount += 1
                s.lastSignInParams = p
                if let home = s.config.homeDomain, baseURL.absoluteString != home {
                    return (200, MerossJSON.object(["apiStatus": 1030, "data": ["domain": .string(home), "mqttDomain": "m"]]).encoded())
                }
                guard p["email"]?.stringValue == s.config.email,
                      p["password"]?.stringValue == MerossCrypto.md5Hex(s.config.password) else { return (200, Self.status(1004)) }
                if let mfa = s.config.mfaCode {
                    guard let code = p["mfaCode"]?.stringValue else { return (200, Self.status(1033)) }
                    guard code == mfa else { return (200, Self.status(1032)) }
                }
                let token = "tok-\(s.signInCount)"
                s.tokens.insert(token)
                return (200, MerossJSON.object(["apiStatus": 0, "data": [
                    "userid": .string(s.config.userId), "email": .string(s.config.email), "key": .string(s.config.key),
                    "token": .string(token), "domain": .string(s.config.homeDomain ?? baseURL.absoluteString), "mqttDomain": "m",
                ]]).encoded())
            case MerossCloudAPI.deviceListPath, MerossCloudAPI.logoutPath:
                guard let auth = request.headers["Authorization"], auth.hasPrefix("Basic "),
                      s.tokens.contains(String(auth.dropFirst(6))) else { return (200, Self.status(1200)) }
                if request.path == MerossCloudAPI.logoutPath {
                    s.tokens.remove(String(auth.dropFirst(6)))
                    return (200, MerossJSON.object(["apiStatus": 0, "data": [:]]).encoded())
                }
                s.devListCount += 1
                let list: [MerossJSON] = s.config.devices.map { d in
                    ["uuid": .string(d.uuid), "devName": .string(d.name), "deviceType": .string(d.deviceType),
                     "onlineStatus": 1, "fmwareVersion": .string(d.firmwareVersion ?? "1.0.0"), "channels": [[:]]]
                }
                return (200, MerossJSON.object(["apiStatus": 0, "data": .array(list)]).encoded())
            default:
                return (404, Data())
            }
        }
    }

    private static func status(_ code: Int) -> Data {
        MerossJSON.object(["apiStatus": .int(code), "info": "error", "data": [:]]).encoded()
    }
}
