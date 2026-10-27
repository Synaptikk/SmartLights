import Foundation

/// An Elgato light on `FakeHTTPServer`: `/elgato/accessory-info`, `/elgato/lights` (GET/PUT),
/// `/elgato/lights/settings`, `/elgato/identify`. `lightStrip: true` adds hue/saturation.
final class FakeElgatoLight: @unchecked Sendable {
    struct State: Equatable {
        var on = 1
        var brightness = 21
        var temperature: Int? = 297
        var hue: Double?
        var saturation: Double?
    }

    let serial: String
    let lightStrip: Bool
    private let lock = NSLock()
    private var _state: State
    private var _dropNext = 0
    private var _offline = false
    private var _identifies = 0
    private var server: FakeHTTPServer!

    init(serial: String = "CN11A1A00001", displayName: String = "Desk Light", lightStrip: Bool = false, state: State = State()) throws {
        self.serial = serial
        self.lightStrip = lightStrip
        self._state = state
        let product = lightStrip ? "Elgato Light Strip" : "Elgato Key Light"
        let info: [String: Any] = [
            "productName": product,
            "hardwareBoardType": lightStrip ? 70 : 53,
            "firmwareBuildNumber": 218,
            "firmwareVersion": "1.0.3",
            "serialNumber": serial,
            "displayName": displayName,
            "features": ["lights"],
            "macAddress": "3C:6A:9D:14:D0:F5",
        ]
        var settings: [String: Any] = [
            "powerOnBehavior": 1, "powerOnBrightness": 20, "powerOnTemperature": 213,
            "switchOnDurationMs": 100, "switchOffDurationMs": 300, "colorChangeDurationMs": 100,
        ]
        if lightStrip {
            settings["powerOnHue"] = 40.0
            settings["powerOnSaturation"] = 15.0
        }
        let infoBody = FakeHTTPServer.Response.json(object: info)
        let settingsBody = FakeHTTPServer.Response.json(object: settings)
        server = try FakeHTTPServer { [unowned self] request in
            self.respond(request, info: infoBody, settings: settingsBody)
        }
    }

    var port: UInt16 { server.port }
    var hostSpec: String { server.hostSpec }
    var requests: [FakeHTTPServer.Request] { server.requests }
    func requests(_ method: String, _ path: String) -> [FakeHTTPServer.Request] { server.requests(method, path) }
    func stop() { server.stop() }

    var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    /// Drops the next `n` connections without answering (connection reset quirk).
    func dropNext(_ n: Int) { lock.withLock { _dropNext = n } }
    /// Drops every connection while true.
    func setOffline(_ offline: Bool) { lock.withLock { _offline = offline } }
    var identifyCount: Int { lock.withLock { _identifies } }

    private func respond(_ request: FakeHTTPServer.Request, info: FakeHTTPServer.Response, settings: FakeHTTPServer.Response) -> FakeHTTPServer.Response? {
        let drop = lock.withLock { () -> Bool in
            if _offline { return true }
            if _dropNext > 0 { _dropNext -= 1; return true }
            return false
        }
        if drop { return nil }
        switch (request.method, request.path) {
        case ("GET", "/elgato/accessory-info"):
            return info
        case ("GET", "/elgato/lights/settings"):
            return settings
        case ("GET", "/elgato/lights"):
            return .json(object: document())
        case ("PUT", "/elgato/lights"):
            guard let body = request.bodyJSON, let lights = body["lights"] as? [[String: Any]], let l = lights.first else {
                return FakeHTTPServer.Response(status: 400, body: Data())
            }
            lock.withLock {
                if let v = l["on"] as? Int { _state.on = v }
                if let v = l["brightness"] as? Int { _state.brightness = v }
                if let v = l["temperature"] as? Int {
                    _state.temperature = v
                    _state.hue = nil
                    _state.saturation = nil
                }
                if lightStrip, let h = l["hue"] as? Double {
                    _state.hue = h
                    _state.saturation = (l["saturation"] as? Double) ?? _state.saturation
                    _state.temperature = nil
                }
            }
            return .json(object: document())
        case ("POST", "/elgato/identify"):
            lock.withLock { _identifies += 1 }
            return FakeHTTPServer.Response(status: 200, body: Data())
        default:
            return .notFound
        }
    }

    private func document() -> [String: Any] {
        let s = state
        var light: [String: Any] = ["on": s.on, "brightness": s.brightness]
        if let t = s.temperature { light["temperature"] = t }
        if let h = s.hue { light["hue"] = h }
        if let sat = s.saturation { light["saturation"] = sat }
        return ["numberOfLights": 1, "lights": [light]]
    }
}
