import Crypto
import Foundation
import LightCore
import Synchronization
import SwitchBotCodec

@testable import SwitchBotProvider

/// Fake `api.switch-bot.com`: verifies `Authorization`/`sign`/`t`/`nonce`, keeps light state,
/// answers like the v1.1 docs, and enforces its own daily quota.
final class FakeSwitchBotCloud: SwitchBotHTTPTransport, Sendable {
    struct Light: Sendable {
        var device: SwitchBotDevice
        var power = "off"
        var brightness = 50
        var color = "255:255:255"
        var colorTemperature = 4000
        var offline = false
    }

    struct State: Sendable {
        var token = "tok-0123456789abcdef"
        var secret = "sec-abcdef"
        var lights: [String: Light] = [:]
        var order: [String] = []
        var quota = 10_000
        var calls = 0
        var commands: [(String, String)] = []
        var badSignatures = 0
    }

    private let state: Mutex<State>

    init(lights: [Light]) {
        var s = State()
        for l in lights {
            s.lights[l.device.deviceId] = l
            s.order.append(l.device.deviceId)
        }
        state = Mutex(s)
    }

    static func standard() -> FakeSwitchBotCloud {
        FakeSwitchBotCloud(lights: [
            Light(device: SwitchBotDevice(deviceId: "6055F92B4F5A", deviceName: "Bedroom bulb", deviceType: "Color Bulb",
                                          enableCloudService: true, hubDeviceId: "000000000000")),
            Light(device: SwitchBotDevice(deviceId: "C1D2E3F4A5B6", deviceName: "TV strip", deviceType: "Strip Light",
                                          enableCloudService: true, hubDeviceId: "000000000000"), power: "on", color: "0:0:255"),
            Light(device: SwitchBotDevice(deviceId: "F0E1D2C3B4A5", deviceName: "Ceiling", deviceType: "Ceiling Light",
                                          enableCloudService: true, hubDeviceId: "FA7310762361"), colorTemperature: 6500),
            Light(device: SwitchBotDevice(deviceId: "FA7310762361", deviceName: "Hub 2", deviceType: "Hub 2", hubDeviceId: "000000000000")),
        ])
    }

    var token: String { state.withLock { $0.token } }
    var secret: String { state.withLock { $0.secret } }
    var calls: Int { state.withLock { $0.calls } }
    var commands: [(String, String)] { state.withLock { $0.commands } }
    func light(_ id: String) -> Light? { state.withLock { $0.lights[id] } }
    func update(_ id: String, _ body: (inout Light) -> Void) { state.withLock { body(&$0.lights[id]!) } }
    func setQuota(_ q: Int) { state.withLock { $0.quota = q } }
    func rotateToken() { state.withLock { $0.token = "tok-new" } }

    func perform(_ request: SwitchBotRequest, baseURL: URL, timeout: Duration) async throws -> (status: Int, body: Data) {
        state.withLock { s in
            s.calls += 1
            guard let auth = request.headers["Authorization"], let t = request.headers["t"], let nonce = request.headers["nonce"],
                  let sign = request.headers["sign"], auth == s.token, t.count == 13, Int64(t) != nil,
                  sign == SwitchBotAPI.sign(token: s.token, secret: s.secret, t: Int64(t)!, nonce: nonce) else {
                s.badSignatures += 1
                return (401, Data(#"{"message":"Unauthorized"}"#.utf8))
            }
            guard s.calls <= s.quota else { return (401, Data(#"{"message":"Unauthorized"}"#.utf8)) }
            let parts = request.path.split(separator: "/").map(String.init)
            switch (request.method, parts.count) {
            case ("GET", 2) where parts == ["v1.1", "devices"]:
                let list = s.order.compactMap { s.lights[$0]?.device }
                let body: [String: Any] = ["statusCode": 100, "message": "success", "body": [
                    "deviceList": list.map { d -> [String: Any] in
                        var o: [String: Any] = ["deviceId": d.deviceId, "deviceName": d.deviceName, "deviceType": d.deviceType]
                        if let c = d.enableCloudService { o["enableCloudService"] = c }
                        if let h = d.hubDeviceId { o["hubDeviceId"] = h }
                        return o
                    },
                    "infraredRemoteList": [],
                ]]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            case ("GET", 4) where parts[3] == "status":
                guard let l = s.lights[parts[2]] else { return Self.reply(152, "device not found") }
                if l.offline { return Self.reply(161, "device offline") }
                var body: [String: Any] = ["deviceId": l.device.deviceId, "deviceType": l.device.deviceType, "power": l.power,
                                           "brightness": l.brightness, "version": "V1.0"]
                if l.device.lightKind?.hasColor == true { body["color"] = l.color }
                if l.device.lightKind?.hasColorTemperature == true { body["colorTemperature"] = l.colorTemperature }
                return (200, try! JSONSerialization.data(withJSONObject: ["statusCode": 100, "message": "success", "body": body]))
            case ("POST", 4) where parts[3] == "commands":
                guard var l = s.lights[parts[2]], let kind = l.device.lightKind else { return Self.reply(152, "device not found") }
                if l.offline { return Self.reply(161, "device offline") }
                guard let data = request.body, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let command = json["command"] as? String, json["commandType"] as? String == "command" else {
                    return Self.reply(190, "invalid command format")
                }
                let parameter = json["parameter"]
                s.commands.append((parts[2], command))
                switch command {
                case "turnOn": l.power = "on"
                case "turnOff": l.power = "off"
                case "setBrightness":
                    guard let v = parameter as? Int, (1...100).contains(v) else { return Self.reply(190, "bad brightness") }
                    l.brightness = v
                case "setColor":
                    guard kind.hasColor, let v = parameter as? String, v.split(separator: ":").count == 3 else { return Self.reply(160, "command is not supported") }
                    l.color = v
                case "setColorTemperature":
                    guard kind.hasColorTemperature, let v = parameter as? Int, SwitchBotLightKind.kelvinRange.contains(v) else {
                        return Self.reply(160, "command is not supported")
                    }
                    l.colorTemperature = v
                default:
                    return Self.reply(160, "command is not supported")
                }
                s.lights[parts[2]] = l
                return Self.reply(100, "success")
            default:
                return (404, Data())
            }
        }
    }

    private static func reply(_ code: Int, _ message: String) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: ["statusCode": code, "message": message, "body": [String: Any]()]))
    }
}
