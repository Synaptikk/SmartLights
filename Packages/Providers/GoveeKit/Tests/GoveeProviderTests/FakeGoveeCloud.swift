import Foundation
import GoveeCodec
import LightCore

/// Fake Govee Developer API on a loopback HTTP server: `GET /router/api/v1/user/devices`,
/// `POST /router/api/v1/device/control`, `POST /router/api/v1/device/state`, `Govee-API-Key` auth,
/// `API-RateLimit-*` headers, scripted failures.
final class FakeGoveeCloud: @unchecked Sendable {
    struct DeviceState: Sendable, Equatable {
        var power = 0
        var brightness = 100
        var rgb = 0xFFFFFF
        var kelvin = 0
        var online = true
    }

    struct Logged: Sendable {
        var method: String
        var path: String
        var apiKey: String?
        var body: GoveeJSONValue?
    }

    let apiKey: String
    let devices: Locked<[GoveeCloudDevice]>
    let states: Locked<[String: DeviceState]>
    /// Next responses forced to this status (e.g. 429), consumed one per request.
    let forcedStatuses = Locked<[Int]>([])
    let dailyRemaining = Locked(10_000)
    private let log = Locked<[Logged]>([])
    private var server: TestHTTPServer!

    init(apiKey: String = "test-api-key", devices: [GoveeCloudDevice]) throws {
        self.apiKey = apiKey
        self.devices = Locked(devices)
        self.states = Locked(Dictionary(devices.map { ($0.deviceID, DeviceState()) }, uniquingKeysWith: { a, _ in a }))
        server = try TestHTTPServer { [unowned self] request in self.handle(request) }
    }

    var baseURL: URL { server.baseURL }
    var requests: [Logged] { log.current }
    var controlRequests: [GoveeJSONValue] { requests.filter { $0.path == GoveeCloudAPI.controlPath }.compactMap(\.body) }
    func clearLog() { log.withLock { $0.removeAll() } }
    func stop() { server.stop() }

    func state(_ device: String) -> DeviceState? { states.current[GoveeDeviceID.normalize(device)] }

    private func json(_ status: Int, _ value: GoveeJSONValue) -> TestHTTPServer.Response {
        let remaining = dailyRemaining.withLock { r -> Int in
            r = max(0, r - 1)
            return r
        }
        let body = (try? JSONEncoder().encode(value)) ?? Data()
        return TestHTTPServer.Response(status: status, headers: [
            "API-RateLimit-Limit": "10000",
            "API-RateLimit-Remaining": "\(remaining)",
        ], body: body)
    }

    private func handle(_ request: TestHTTPServer.Request) -> TestHTTPServer.Response {
        let body = request.body.isEmpty ? nil : try? JSONDecoder().decode(GoveeJSONValue.self, from: request.body)
        log.withLock { $0.append(Logged(method: request.method, path: request.path, apiKey: request.header("Govee-API-Key"), body: body)) }
        if let forced = forcedStatuses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            return json(forced, .object(["code": .int(forced), "message": .string("forced")]))
        }
        guard request.header("Govee-API-Key") == apiKey else {
            return json(401, .object(["code": .int(401), "message": .string("Invalid API Key")]))
        }
        switch (request.method, request.path) {
        case ("GET", GoveeCloudAPI.devicesPath):
            let data = (try? JSONEncoder().encode(devices.current)).flatMap { try? JSONDecoder().decode(GoveeJSONValue.self, from: $0) } ?? .array([])
            return json(200, .object(["code": .int(200), "message": .string("success"), "data": data]))
        case ("POST", GoveeCloudAPI.controlPath):
            guard let payload = body?["payload"], let device = payload["device"]?.stringValue,
                  let capability = payload["capability"], let instance = capability["instance"]?.stringValue,
                  let value = capability["value"] else {
                return json(400, .object(["code": .int(400), "message": .string("bad request")]))
            }
            let id = GoveeDeviceID.normalize(device)
            guard states.current[id] != nil else { return json(404, .object(["code": .int(404), "message": .string("device not found")])) }
            states.withLock { all in
                var s = all[id]!
                switch instance {
                case "powerSwitch": s.power = value.intValue ?? 0
                case "brightness": s.brightness = value.intValue ?? s.brightness
                case "colorRgb": s.rgb = value.intValue ?? s.rgb; s.kelvin = 0
                case "colorTemperatureK": s.kelvin = value.intValue ?? s.kelvin
                default: break
                }
                all[id] = s
            }
            return json(200, .object([
                "requestId": body?["requestId"] ?? .string(""),
                "msg": .string("success"),
                "code": .int(200),
                "capability": .object([
                    "type": capability["type"] ?? .null,
                    "instance": .string(instance),
                    "state": .object(["status": .string("success")]),
                    "value": value,
                ]),
            ]))
        case ("POST", GoveeCloudAPI.statePath):
            guard let device = body?["payload"]?["device"]?.stringValue, let s = states.current[GoveeDeviceID.normalize(device)] else {
                return json(404, .object(["code": .int(404), "message": .string("device not found")]))
            }
            func cap(_ type: String, _ instance: String, _ value: GoveeJSONValue) -> GoveeJSONValue {
                .object(["type": .string(type), "instance": .string(instance), "state": .object(["value": value])])
            }
            return json(200, .object([
                "requestId": body?["requestId"] ?? .string(""),
                "msg": .string("success"),
                "code": .int(200),
                "payload": .object([
                    "sku": body?["payload"]?["sku"] ?? .null,
                    "device": .string(device),
                    "capabilities": .array([
                        cap(GoveeCapabilityType.online, "online", .bool(s.online)),
                        cap(GoveeCapabilityType.onOff, "powerSwitch", .int(s.power)),
                        cap(GoveeCapabilityType.range, "brightness", .int(s.brightness)),
                        cap(GoveeCapabilityType.colorSetting, "colorRgb", .int(s.rgb)),
                        cap(GoveeCapabilityType.colorSetting, "colorTemperatureK", .int(s.kelvin)),
                    ]),
                ]),
            ]))
        default:
            return json(404, .object(["code": .int(404), "message": .string("not found")]))
        }
    }

    // MARK: Sample devices (shapes from the Govee developer docs examples)

    static func light(_ device: String, sku: String, name: String?, scenes: [String: Int] = [:]) -> GoveeCloudDevice {
        var caps = [
            GoveeCloudCapability(type: GoveeCapabilityType.onOff, instance: "powerSwitch", parameters: GoveeCapabilityParameters(
                dataType: "ENUM", options: [GoveeOption(name: "on", value: .int(1)), GoveeOption(name: "off", value: .int(0))])),
            GoveeCloudCapability(type: GoveeCapabilityType.range, instance: "brightness", parameters: GoveeCapabilityParameters(
                dataType: "INTEGER", unit: "unit.percent", range: GoveeValueRange(min: 1, max: 100))),
            GoveeCloudCapability(type: GoveeCapabilityType.colorSetting, instance: "colorRgb", parameters: GoveeCapabilityParameters(
                dataType: "INTEGER", range: GoveeValueRange(min: 0, max: 16_777_215))),
            GoveeCloudCapability(type: GoveeCapabilityType.colorSetting, instance: "colorTemperatureK", parameters: GoveeCapabilityParameters(
                dataType: "INTEGER", range: GoveeValueRange(min: 2000, max: 9000))),
        ]
        if !scenes.isEmpty {
            caps.append(GoveeCloudCapability(type: GoveeCapabilityType.dynamicScene, instance: "snapshot", parameters: GoveeCapabilityParameters(
                dataType: "ENUM", options: scenes.sorted { $0.key < $1.key }.map { GoveeOption(name: $0.key, value: .int($0.value)) })))
        }
        return GoveeCloudDevice(sku: sku, device: device, deviceName: name, type: GoveeDeviceType.light, capabilities: caps)
    }

    static let humidifier = GoveeCloudDevice(sku: "H7143", device: "52:8B:D4:AD:FC:45:5D:FE", deviceName: "Humidifier",
                                             type: "devices.types.humidifier", capabilities: [
                                                 GoveeCloudCapability(type: GoveeCapabilityType.onOff, instance: "powerSwitch"),
                                             ])
}
