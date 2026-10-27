import Foundation

/// A WLED controller on `FakeHTTPServer`: `/json/info`, `/json/state` (GET/POST), `/json/effects`,
/// `/json/cfg`. Applies `on`, `bri`, `tt` and `seg[0]` `col`/`fx`; `"v": true` echoes the state.
final class FakeWLEDController: @unchecked Sendable {
    struct State: Equatable {
        var on = true
        var bri = 128
        var col: [Int] = [255, 160, 0]
        var fx = 0
    }

    let mac: String
    let rgbw: Bool
    private let lock = NSLock()
    private var _state: State
    private var _mdns: String?
    private var _name: String
    private var _dropNext = 0
    private var _offline = false
    private var _lastTT: Int?
    private var server: FakeHTTPServer!

    static let effectNames = ["Solid", "Blink", "Breathe", "Wipe", "RSVD", "Rainbow", "Strobe"]

    /// `mdns: nil` makes `/json/cfg` answer 404 (forces the `wled-<mac>` fallback).
    init(mac: String = "a4cf12fdaea8", mdns: String? = "wled-kitchen", name: String = "Kitchen Strip", rgbw: Bool = false, state: State = State()) throws {
        self.mac = mac
        self.rgbw = rgbw
        self._mdns = mdns
        self._name = name
        self._state = state
        server = try FakeHTTPServer { [unowned self] request in self.respond(request) }
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

    var mdns: String? {
        get { lock.withLock { _mdns } }
        set { lock.withLock { _mdns = newValue } }
    }

    var lastTransition: Int? { lock.withLock { _lastTT } }
    func dropNext(_ n: Int) { lock.withLock { _dropNext = n } }
    func setOffline(_ offline: Bool) { lock.withLock { _offline = offline } }

    private func respond(_ request: FakeHTTPServer.Request) -> FakeHTTPServer.Response? {
        let drop = lock.withLock { () -> Bool in
            if _offline { return true }
            if _dropNext > 0 { _dropNext -= 1; return true }
            return false
        }
        if drop { return nil }
        switch (request.method, request.path) {
        case ("GET", "/json/info"):
            return .json(object: info())
        case ("GET", "/json/state"):
            return .json(object: stateDocument())
        case ("GET", "/json/effects"):
            return .json(object: Self.effectNames)
        case ("GET", "/json/cfg"):
            guard let mdns else { return .notFound }
            return .json(object: ["id": ["mdns": mdns, "name": lock.withLock { _name }]])
        case ("POST", "/json/state"):
            guard let body = request.bodyJSON else { return FakeHTTPServer.Response(status: 400, body: Data(#"{"error":9}"#.utf8)) }
            lock.withLock {
                if let v = body["on"] as? Bool { _state.on = v }
                if let v = body["bri"] as? Int { _state.bri = v }
                _lastTT = body["tt"] as? Int
                if let seg = (body["seg"] as? [[String: Any]])?.first {
                    if let col = (seg["col"] as? [[Int]])?.first { _state.col = col }
                    if let fx = seg["fx"] as? Int { _state.fx = fx }
                }
            }
            if body["v"] as? Bool == true { return .json(object: stateDocument()) }
            return .json(#"{"success":true}"#)
        default:
            return .notFound
        }
    }

    private func info() -> [String: Any] {
        [
            "ver": "0.14.4", "vid": 2405180, "name": lock.withLock { _name }, "mac": mac, "arch": "esp32",
            "brand": "WLED", "product": "FOSS", "fxcount": Self.effectNames.count,
            "leds": ["count": 60, "lc": rgbw ? 3 : 1, "rgbw": rgbw, "maxseg": 32],
        ]
    }

    private func stateDocument() -> [String: Any] {
        let s = state
        return [
            "on": s.on, "bri": s.bri, "transition": 7, "ps": -1, "mainseg": 0,
            "seg": [["id": 0, "start": 0, "stop": 60, "len": 60, "on": true, "bri": 255,
                     "col": [s.col, rgbw ? [0, 0, 0, 0] : [0, 0, 0], rgbw ? [0, 0, 0, 0] : [0, 0, 0]], "fx": s.fx, "sx": 128, "ix": 128, "pal": 0]],
        ]
    }
}
