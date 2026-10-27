import Foundation
import YeelightCodec
@testable import YeelightProvider

/// Protocol-level fake of a Yeelight device: answers JSON-RPC lines like a real bulb and pushes
/// `props` notifications to every attached connection. Shared by the in-memory connector and the
/// TCP server so both transports exercise the same behaviour.
final class FakeYeelightBulb: @unchecked Sendable {
    struct State: Equatable {
        var power = false
        var bright = 50
        var ct = 4000
        var rgb = 0xFF0000
        var hue = 0
        var sat = 100
        var colorMode = 2
        var flowing = 0
        var name = ""
    }

    let id: String
    let model: String
    let support: Set<String>
    private let lock = NSLock()
    private var _state: State
    private var _received: [YeelightRequest] = []
    private var _ignoreNext = 0
    private var listeners: [UUID: @Sendable (Data) -> Void] = [:]

    init(id: String = "0x000000000015243f", model: String = "color", support: Set<String>? = nil, state: State = State()) {
        self.id = id
        self.model = model
        self.support = support ?? [
            "get_prop", "set_default", "set_power", "toggle", "set_bright", "start_cf", "stop_cf", "set_scene",
            "cron_add", "cron_get", "cron_del", "set_ct_abx", "set_rgb", "set_hsv", "set_name",
        ]
        self._state = state
    }

    var state: State { lock.locked { _state } }
    var received: [YeelightRequest] { lock.locked { _received } }
    var receivedMethods: [String] { received.map(\.method) }

    /// Silently drop the next `n` requests (models "first command after reconnect is ignored").
    func ignoreNext(_ n: Int) { lock.locked { _ignoreNext = n } }

    func clearLog() { lock.locked { _received.removeAll() } }

    func advertisement(host: String, port: UInt16 = YeelightProtocol.controlPort) -> YeelightAdvertisement {
        let s = state
        return YeelightAdvertisement(
            id: id, host: host, port: port, model: model, firmwareVersion: "18", support: support,
            properties: ["power": .string(s.power ? "on" : "off"), "bright": .string(String(s.bright))],
            name: s.name.isEmpty ? nil : s.name
        )
    }

    // MARK: Connections

    func attach(_ listener: @escaping @Sendable (Data) -> Void) -> UUID {
        let token = UUID()
        lock.locked { listeners[token] = listener }
        return token
    }

    func detach(_ token: UUID) {
        _ = lock.locked { listeners.removeValue(forKey: token) }
    }

    /// Simulates a change made from the Yeelight app: updates state and notifies every connection.
    func externalChange(_ change: (inout State) -> Void) {
        let (changed, targets) = lock.locked { () -> ([String: YeelightValue], [@Sendable (Data) -> Void]) in
            let before = _state
            change(&_state)
            return (Self.diff(before, _state), Array(listeners.values))
        }
        guard !changed.isEmpty else { return }
        let line = Self.notificationLine(changed)
        for t in targets { t(line) }
    }

    /// Handles one request line: returns the reply line for the sender and broadcasts the
    /// resulting `props` notification (if any) to every attached connection.
    func handle(line: Data, replyTo sender: @Sendable (Data) -> Void) {
        guard let object = try? JSONDecoder().decode([String: YeelightValue].self, from: line),
              let id = object["id"]?.intValue, let method = object["method"]?.stringValue
        else {
            sender(Data("{\"id\":0,\"error\":{\"code\":-1,\"message\":\"invalid command\"}}\r\n".utf8))
            return
        }
        let params = object["params"]?.arrayValue ?? []
        let (reply, notification, targets): (Data?, Data?, [@Sendable (Data) -> Void]) = lock.locked {
            _received.append(YeelightRequest(id: id, method: method, params: params))
            if _ignoreNext > 0 {
                _ignoreNext -= 1
                return (nil, nil, [])
            }
            let before = _state
            let result = apply(method: method, params: params)
            let changed = Self.diff(before, _state)
            let reply: Data
            switch result {
            case .success(let values): reply = Data((#"{"id":\#(id),"result":"# + YeelightValue.array(values).jsonText + "}\r\n").utf8)
            case .failure(let message): reply = Data((#"{"id":\#(id),"error":{"code":-1,"message":"\#(message)"}}"# + "\r\n").utf8)
            }
            return (reply, changed.isEmpty ? nil : Self.notificationLine(changed), Array(listeners.values))
        }
        if let reply { sender(reply) }
        if let notification { for t in targets { t(notification) } }
    }

    private enum Outcome {
        case success([YeelightValue])
        case failure(String)
    }

    /// Must be called with the lock held.
    private func apply(method: String, params: [YeelightValue]) -> Outcome {
        guard support.contains(method) else { return .failure("method not supported") }
        let ok = Outcome.success(["ok"])
        func int(_ i: Int) -> Int? { params.indices.contains(i) ? params[i].intValue : nil }
        func str(_ i: Int) -> String? { params.indices.contains(i) ? params[i].stringValue : nil }
        func validTiming(_ i: Int) -> Bool {
            guard let effect = str(i), effect == "smooth" || effect == "sudden", let d = int(i + 1) else { return false }
            return effect == "sudden" || d >= 30
        }
        switch method {
        case "get_prop":
            return .success(params.map { name in
                switch name.stringValue ?? "" {
                case "power": .string(_state.power ? "on" : "off")
                case "bright": .string(String(_state.bright))
                case "ct": .string(String(_state.ct))
                case "rgb": .string(String(_state.rgb))
                case "hue": .string(String(_state.hue))
                case "sat": .string(String(_state.sat))
                case "color_mode": .string(String(_state.colorMode))
                case "flowing": .string(String(_state.flowing))
                case "name": .string(_state.name)
                default: .string("")
                }
            })
        case "set_power":
            guard let p = str(0), p == "on" || p == "off", validTiming(1) else { return .failure("invalid params") }
            _state.power = p == "on"
            return ok
        case "toggle":
            _state.power.toggle()
            return ok
        case "set_bright":
            guard _state.power else { return .failure("general error") }
            guard let b = int(0), (1...100).contains(b), validTiming(1) else { return .failure("invalid params") }
            _state.bright = b
            return ok
        case "set_ct_abx":
            guard _state.power else { return .failure("general error") }
            guard let k = int(0), (1700...6500).contains(k), validTiming(1) else { return .failure("invalid params") }
            _state.ct = k
            _state.colorMode = 2
            return ok
        case "set_rgb":
            guard _state.power else { return .failure("general error") }
            guard let v = int(0), (0...0xFFFFFF).contains(v), validTiming(1) else { return .failure("invalid params") }
            _state.rgb = v
            _state.colorMode = 1
            return ok
        case "set_hsv":
            guard _state.power else { return .failure("general error") }
            guard let h = int(0), let s = int(1), (0...359).contains(h), (0...100).contains(s), validTiming(2) else {
                return .failure("invalid params")
            }
            _state.hue = h
            _state.sat = s
            _state.colorMode = 3
            return ok
        case "set_scene":
            switch str(0) {
            case "color":
                guard let v = int(1), let b = int(2) else { return .failure("invalid params") }
                _state.rgb = v; _state.bright = b; _state.colorMode = 1
            case "hsv":
                guard let h = int(1), let s = int(2), let b = int(3) else { return .failure("invalid params") }
                _state.hue = h; _state.sat = s; _state.bright = b; _state.colorMode = 3
            case "ct":
                guard let k = int(1), let b = int(2) else { return .failure("invalid params") }
                _state.ct = k; _state.bright = b; _state.colorMode = 2
            case "auto_delay_off":
                guard let b = int(1) else { return .failure("invalid params") }
                _state.bright = b
            default:
                return .failure("invalid params")
            }
            _state.power = true
            return ok
        case "set_name":
            guard let n = str(0) else { return .failure("invalid params") }
            _state.name = n
            return ok
        case "start_cf":
            _state.flowing = 1
            return ok
        case "stop_cf":
            _state.flowing = 0
            return ok
        default:
            return ok
        }
    }

    static func diff(_ a: State, _ b: State) -> [String: YeelightValue] {
        var out: [String: YeelightValue] = [:]
        if a.power != b.power { out["power"] = .string(b.power ? "on" : "off") }
        if a.bright != b.bright { out["bright"] = .int(b.bright) }   // numbers, like some firmware sends
        if a.ct != b.ct { out["ct"] = .int(b.ct) }
        if a.rgb != b.rgb { out["rgb"] = .int(b.rgb) }
        if a.hue != b.hue { out["hue"] = .int(b.hue) }
        if a.sat != b.sat { out["sat"] = .int(b.sat) }
        if a.colorMode != b.colorMode { out["color_mode"] = .int(b.colorMode) }
        if a.flowing != b.flowing { out["flowing"] = .int(b.flowing) }
        if a.name != b.name { out["name"] = .string(b.name) }
        return out
    }

    static func notificationLine(_ params: [String: YeelightValue]) -> Data {
        Data(("{\"method\":\"props\",\"params\":" + YeelightValue.object(params).jsonText + "}\r\n").utf8)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
