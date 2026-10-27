import Foundation

/// Transition effect parameter of the setter methods.
public enum YeelightEffect: String, Sendable, Hashable, CaseIterable {
    /// Change immediately; the duration is ignored by the device.
    case sudden
    /// Fade over the given duration (minimum 30 ms).
    case smooth
}

/// Effect + duration pair appended to setter params.
public struct YeelightTiming: Sendable, Hashable {
    public var effect: YeelightEffect
    /// Milliseconds; clamped to at least 30 for `.smooth`.
    public var duration: Int

    public init(effect: YeelightEffect, duration: Int) {
        self.effect = effect
        self.duration = effect == .smooth ? max(duration, YeelightProtocol.minimumSmoothDuration) : max(duration, 0)
    }

    /// Sudden change. The device ignores the duration; 30 ms is sent because some firmware rejects
    /// durations below the smooth minimum even for sudden changes [verify].
    public static let sudden = YeelightTiming(effect: .sudden, duration: 30)
    /// Default used when a command carries no transition (HA's yeelight default is ~350 ms smooth).
    public static let `default` = YeelightTiming(effect: .smooth, duration: 300)

    /// Timing for a transition in milliseconds; 0 means sudden, nil means `fallback`.
    public static func forTransition(milliseconds: Int?, fallback: YeelightTiming = .default) -> YeelightTiming {
        guard let ms = milliseconds else { return fallback }
        return ms <= 0 ? .sudden : YeelightTiming(effect: .smooth, duration: ms)
    }

    var params: [YeelightValue] { [.string(effect.rawValue), .int(duration)] }
}

/// `set_power` mode parameter (spec: 0 normal/last, 1 CT, 2 RGB, 3 HSV, 4 colour flow, 5 night light).
public enum YeelightPowerMode: Int, Sendable, Hashable {
    case normal = 0
    case colorTemperature = 1
    case rgb = 2
    case hsv = 3
    case colorFlow = 4
    case nightLight = 5
}

/// `color_mode` property values.
public enum YeelightColorMode: Int, Sendable, Hashable {
    case rgb = 1
    case colorTemperature = 2
    case hsv = 3
}

/// Action after a colour flow ends (`start_cf` second param).
public enum YeelightFlowAction: Int, Sendable, Hashable {
    /// Return to the state before the flow.
    case recover = 0
    /// Stay at the last flow state.
    case stay = 1
    /// Turn off.
    case turnOff = 2
}

/// One step of a colour flow (`start_cf` expression tuple `duration,mode,value,brightness`).
public struct YeelightFlowStep: Sendable, Hashable {
    public enum Mode: Int, Sendable, Hashable {
        case color = 1
        case colorTemperature = 2
        case sleep = 7
    }

    /// Milliseconds (minimum 50 per spec).
    public var duration: Int
    public var mode: Mode
    /// RGB integer, Kelvin, or ignored for sleep.
    public var value: Int
    /// 1...100, or -1 to keep the current brightness.
    public var brightness: Int

    public init(duration: Int, mode: Mode, value: Int, brightness: Int) {
        self.duration = max(duration, 50)
        self.mode = mode
        self.value = value
        self.brightness = brightness
    }

    var expression: String { "\(duration),\(mode.rawValue),\(value),\(brightness)" }
}

/// Builders for the methods of the Yeelight Inter-Operation Spec. Values are clamped to the ranges
/// the spec documents (brightness 1...100, CT 1700...6500 K, hue 0...359, saturation 0...100,
/// RGB 0...0xFFFFFF).
public enum YeelightCommands {
    /// Properties requested by `get_prop` for state refreshes, in this order.
    public static let stateProperties = [
        "power", "bright", "ct", "rgb", "hue", "sat", "color_mode", "flowing", "name",
    ]

    public static func getProp(_ names: [String] = stateProperties) -> YeelightCall {
        YeelightCall(method: "get_prop", params: names.map { .string($0) })
    }

    public static func setPower(_ on: Bool, timing: YeelightTiming = .default, mode: YeelightPowerMode? = nil) -> YeelightCall {
        var params: [YeelightValue] = [.string(on ? "on" : "off")] + timing.params
        if on, let mode, mode != .normal { params.append(.int(mode.rawValue)) }
        return YeelightCall(method: "set_power", params: params)
    }

    public static func toggle() -> YeelightCall { YeelightCall(method: "toggle") }

    public static func setBright(_ brightness: Int, timing: YeelightTiming = .default) -> YeelightCall {
        YeelightCall(method: "set_bright", params: [.int(clampBright(brightness))] + timing.params)
    }

    public static func setCTAbx(_ kelvin: Int, timing: YeelightTiming = .default) -> YeelightCall {
        YeelightCall(method: "set_ct_abx", params: [.int(clampKelvin(kelvin))] + timing.params)
    }

    public static func setRGB(_ rgb: Int, timing: YeelightTiming = .default) -> YeelightCall {
        YeelightCall(method: "set_rgb", params: [.int(clampRGB(rgb))] + timing.params)
    }

    public static func setHSV(hue: Int, saturation: Int, timing: YeelightTiming = .default) -> YeelightCall {
        YeelightCall(method: "set_hsv", params: [.int(clampHue(hue)), .int(clampPercent(saturation))] + timing.params)
    }

    /// `set_scene` variants. A scene sets colour and brightness in one call and turns the light on
    /// (accepted in both on and off state); it takes no effect/duration.
    public enum Scene: Sendable, Hashable {
        case color(rgb: Int, brightness: Int)
        case hsv(hue: Int, saturation: Int, brightness: Int)
        case colorTemperature(kelvin: Int, brightness: Int)
        case colorFlow(count: Int, action: YeelightFlowAction, steps: [YeelightFlowStep])
        /// Turn on at `brightness`, then off after `minutes`.
        case autoDelayOff(brightness: Int, minutes: Int)
    }

    public static func setScene(_ scene: Scene) -> YeelightCall {
        let params: [YeelightValue]
        switch scene {
        case .color(let rgb, let b):
            params = ["color", .int(clampRGB(rgb)), .int(clampBright(b))]
        case .hsv(let h, let s, let b):
            params = ["hsv", .int(clampHue(h)), .int(clampPercent(s)), .int(clampBright(b))]
        case .colorTemperature(let k, let b):
            params = ["ct", .int(clampKelvin(k)), .int(clampBright(b))]
        case .colorFlow(let count, let action, let steps):
            params = ["cf", .int(max(0, count)), .int(action.rawValue), .string(steps.map(\.expression).joined(separator: ","))]
        case .autoDelayOff(let b, let minutes):
            params = ["auto_delay_off", .int(clampBright(b)), .int(max(1, minutes))]
        }
        return YeelightCall(method: "set_scene", params: params)
    }

    /// `set_name`. The spec suggests Base64 for non-ASCII names; the raw UTF-8 string is sent here
    /// and the caller decides. Names are truncated to 64 UTF-8 bytes.
    public static func setName(_ name: String) -> YeelightCall {
        var bytes = Array(name.utf8.prefix(64))
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty { bytes.removeLast() }
        return YeelightCall(method: "set_name", params: [.string(String(decoding: bytes, as: UTF8.self))])
    }

    /// `start_cf`: `count` 0 = infinite.
    public static func startColorFlow(count: Int, action: YeelightFlowAction, steps: [YeelightFlowStep]) -> YeelightCall {
        YeelightCall(method: "start_cf", params: [
            .int(max(0, count)), .int(action.rawValue), .string(steps.map(\.expression).joined(separator: ",")),
        ])
    }

    public static func stopColorFlow() -> YeelightCall { YeelightCall(method: "stop_cf") }

    // MARK: Clamping

    public static func clampBright(_ v: Int) -> Int { min(max(v, 1), 100) }
    public static func clampKelvin(_ v: Int) -> Int { min(max(v, 1700), 6500) }
    public static func clampRGB(_ v: Int) -> Int { min(max(v, 0), 0xFFFFFF) }
    public static func clampHue(_ v: Int) -> Int { ((v % 360) + 360) % 360 }
    public static func clampPercent(_ v: Int) -> Int { min(max(v, 0), 100) }
}
