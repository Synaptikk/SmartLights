import Foundation
import LightCore

/// What the device can do, derived from `/gestalt`, `/fw/version` and `/led/effects`.
public struct TwinklyDeviceInfo: Sendable, Hashable, Codable {
    public var gestalt: TwinklyGestalt
    public var firmware: String?
    /// Number of predefined effects (`/led/effects`); 0 if unknown.
    public var effectCount: Int

    public init(gestalt: TwinklyGestalt, firmware: String?, effectCount: Int) {
        self.gestalt = gestalt
        self.firmware = firmware
        self.effectCount = effectCount
    }

    var version: TwinklyFirmwareVersion? { firmware.flatMap(TwinklyFirmwareVersion.init) }

    /// `/led/color` (static colour mode) exists. Unknown firmware is treated as recent.
    public var supportsColor: Bool { version.map { $0 >= .colorEndpoint } ?? true }
    /// `/led/out/brightness` exists.
    public var supportsBrightness: Bool { version.map { $0 >= .brightnessEndpoint } ?? true }

    public var displayName: String {
        if let name = gestalt.deviceName, !name.isEmpty { return name }
        return gestalt.productName ?? "Twinkly"
    }
}

/// Effects exposed as `EffectDescriptor`s.
///
/// - `movie`: whatever the user last uploaded in the Twinkly app (the default "on" look).
/// - `effect:<n>`: the n-th predefined effect (`effect_id`).
///
/// Twinkly effects are animations whose speed we cannot read, so all are flagged `isFast` and
/// the UI shows the photosensitivity warning before starting one.
public enum TwinklyEffects {
    public static let movie = "movie"
    public static let playlist = "playlist"

    public static func effectID(_ n: Int) -> String { "effect:\(n)" }

    /// Parses `effect:<n>`.
    public static func effectNumber(_ id: String) -> Int? {
        guard id.hasPrefix("effect:") else { return nil }
        return Int(id.dropFirst("effect:".count)).flatMap { $0 >= 0 ? $0 : nil }
    }

    public static func descriptors(effectCount: Int) -> [EffectDescriptor] {
        var out = [EffectDescriptor(id: movie, name: "Saved effect (Twinkly app)", isFast: true)]
        for n in 0..<max(0, effectCount) {
            out.append(EffectDescriptor(id: effectID(n), name: "Effect \(n + 1)", isFast: true))
        }
        return out
    }
}

/// Last known device-side state (what the planner needs besides `LightState`).
public struct TwinklyLiveState: Sendable, Hashable, Codable {
    public var mode: TwinklyMode
    /// Mode to restore on a bare "turn on" (the last non-off mode we saw or set).
    public var lastOnMode: TwinklyMode?
    public var effectID: Int?

    public init(mode: TwinklyMode, lastOnMode: TwinklyMode? = nil, effectID: Int? = nil) {
        self.mode = mode
        self.lastOnMode = lastOnMode ?? (mode == .off ? nil : mode)
        self.effectID = effectID
    }

    /// Records a mode change, remembering the last "on" mode.
    public mutating func apply(mode newMode: TwinklyMode, effectID newEffect: Int? = nil) {
        mode = newMode
        if newMode != .off { lastOnMode = newMode }
        if newMode == .effect, let newEffect { effectID = newEffect }
    }
}

/// Pure mapping between xled payloads and the LightCore model.
public enum TwinklyMapping {
    public static func capabilities(_ info: TwinklyDeviceInfo) -> LightCapabilities {
        let modes: Set<ColorMode>
        if info.supportsColor {
            modes = [.hs]
        } else if info.supportsBrightness {
            modes = [.brightness]
        } else {
            modes = [.onOff]
        }
        return LightCapabilities(
            supportedColorModes: modes,
            supportsTransition: false,
            supportsEffects: true,
            effects: TwinklyEffects.descriptors(effectCount: info.effectCount))
    }

    /// Builds `LightState` from the mode plus whatever was read (`color` only in colour mode).
    public static func state(
        mode: TwinklyMode,
        color: TwinklyColorResponse?,
        brightness: TwinklyBrightnessResponse?,
        effectID: Int?,
        reachable: Bool = true,
        at date: Date = Date()
    ) -> LightState {
        var state = LightState(isOn: mode != .off, reachable: reachable, updatedAt: date)
        state.brightness = brightness?.brightness
        switch mode {
        case .color:
            if let color, let hue = color.hue, let sat = color.saturation {
                let hs = HS(h: Double(hue), s: Double(min(max(sat, 0), 255)) / 255).clamped
                state.colorMode = .hs
                state.hs = hs
                state.rgb = ColorMath.hsToRGB(hs)
            } else if let color, let r = color.red, let g = color.green, let b = color.blue {
                let rgb = RGB(clamping: Double(r), Double(g), Double(b))
                state.colorMode = .hs
                state.hs = ColorMath.rgbToHS(rgb)
                state.rgb = rgb
            }
        case .effect:
            state.effect = effectID.map(TwinklyEffects.effectID)
        case .movie:
            state.effect = TwinklyEffects.movie
        case .playlist:
            state.effect = TwinklyEffects.playlist
        case .off, .demo, .rt, .other:
            break
        }
        return state
    }

    /// Requests to execute in order, plus the device mode afterwards.
    public struct Plan: Sendable, Hashable {
        public var requests: [TwinklyRequest]
        public var resultingMode: TwinklyMode
        public var resultingEffectID: Int?

        public init(requests: [TwinklyRequest], resultingMode: TwinklyMode, resultingEffectID: Int? = nil) {
            self.requests = requests
            self.resultingMode = resultingMode
            self.resultingEffectID = resultingEffectID
        }
    }

    /// Plans the xled calls for a command.
    ///
    /// - Off (`on == false`, or `brightness == 0` without `on`): `mode off` only.
    /// - Colour: `POST /led/color` (HSV, value 255; dimming goes through `/led/out/brightness`)
    ///   then `mode color`.
    /// - Effect: `movie` -> `mode movie`; `effect:<n>` -> `/led/effects/current` + `mode effect`.
    /// - Brightness: `/led/out/brightness` (1...100) before the mode switch, so the lights come on
    ///   at the requested level.
    /// - Bare "on" while off: restore the last "on" mode (default `movie`, like the Twinkly app).
    /// - A mode request is skipped when the device is already in that mode.
    public static func plan(_ command: LightCommand, current: TwinklyLiveState, capabilities: LightCapabilities) -> Plan {
        let cmd = command.normalized(for: capabilities)
        let turningOff = cmd.on == false || (cmd.on == nil && cmd.brightness == 0)
        if turningOff {
            guard current.mode != .off else { return Plan(requests: [], resultingMode: .off) }
            return Plan(requests: [TwinklyAPI.setMode(.off)], resultingMode: .off)
        }

        var requests: [TwinklyRequest] = []
        var target: TwinklyMode?
        var targetEffect: Int?

        if let color = cmd.color, case .hs(let hs) = color {
            let c = hs.clamped
            let hue = Int(c.h.rounded()) % 360
            let sat = Int((c.s * 255).rounded())
            requests.append(TwinklyAPI.setColor(.hsv(hue: hue, saturation: sat, value: 255)))
            target = .color
        } else if let effect = cmd.effect {
            if effect == TwinklyEffects.movie {
                target = .movie
            } else if effect == TwinklyEffects.playlist {
                target = .playlist
            } else if let n = TwinklyEffects.effectNumber(effect) {
                requests.append(TwinklyAPI.setCurrentEffect(n))
                target = .effect
                targetEffect = n
            }
        }

        if let b = cmd.brightness, b > 0 {
            requests.append(TwinklyAPI.setBrightness(percent: max(1, Int((b * 100).rounded()))))
        }

        let wantsOn = cmd.on == true || (cmd.brightness ?? 0) > 0 || target != nil
        if target == nil, wantsOn, current.mode == .off {
            target = current.lastOnMode ?? .movie
            if target == .effect { targetEffect = current.effectID }
        }

        if let target {
            // Effect mode is re-posted every time: `effect_id` travels with it.
            if target != current.mode || target == .effect {
                requests.append(TwinklyAPI.setMode(target, effectID: target == .effect ? targetEffect : nil))
            }
            return Plan(requests: requests, resultingMode: target,
                        resultingEffectID: target == .effect ? (targetEffect ?? current.effectID) : current.effectID)
        }
        return Plan(requests: requests, resultingMode: current.mode, resultingEffectID: current.effectID)
    }
}
