import Foundation
import LightCore

/// What a connected device is: its table row, the dialect for its firmware and the channel
/// layout for its current mode byte. Derived from a state response.
public struct MagicHomeProfile: Sendable, Hashable {
    public var model: MagicHomeModel
    /// nil when the dialect is not implemented (addressable strips, 25-byte bulbs...).
    public var `protocol`: MagicHomeProtocol?
    public var layout: MagicHomeChannelLayout
    public var version: UInt8

    public init(model: MagicHomeModel, protocol proto: MagicHomeProtocol?, layout: MagicHomeChannelLayout, version: UInt8) {
        self.model = model
        self.protocol = proto
        self.layout = layout
        self.version = version
    }

    public init(state: MagicHomeRawState) {
        let model = MagicHomeModel.lookup(state.modelNumber)
        self.init(model: model, protocol: model.protocol(forVersion: state.version),
                  layout: model.layout(forMode: state.mode), version: state.version)
    }

    public var isSupported: Bool { `protocol` != nil }
    /// `"Bulb RGBCW (0x35)"`.
    public var modelDescription: String { String(format: "%@ (0x%02X)", model.name, model.number) }

    /// Write mode `all` regardless of which channels change.
    var writesAll: Bool { layout.writesColorAndWhiteTogether || model.alwaysWritesWhiteAndColors }
}

/// Channel levels in logical order (red, green, blue, warm white, cold white), i.e. after the
/// model's channel map and, for the CCT dialect, after converting temperature/brightness
/// percentages back to 0...255 levels.
public struct MagicHomeChannels: Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var warm: UInt8
    public var cool: UInt8

    public init(red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, warm: UInt8 = 0, cool: UInt8 = 0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.warm = warm
        self.cool = cool
    }

    public init(_ raw: MagicHomeRawState, profile: MagicHomeProfile) {
        if profile.protocol?.whitesAreTemperatureAndBrightness == true {
            let w = MagicHomeWhite.levels(scaledTemperature: raw.warmWhite, brightness: raw.coolWhite)
            self.init(red: raw.red, green: raw.green, blue: raw.blue, warm: w.warm, cool: w.cool)
            return
        }
        switch profile.model.channelMap {
        case .none:
            self.init(red: raw.red, green: raw.green, blue: raw.blue, warm: raw.warmWhite, cool: raw.coolWhite)
        case .whiteInRed:
            self.init(red: raw.warmWhite, green: raw.green, blue: raw.blue, warm: raw.red, cool: raw.coolWhite)
        case .cctInRedGreen:
            self.init(red: raw.warmWhite, green: raw.coolWhite, blue: raw.blue, warm: raw.red, cool: raw.green)
        }
    }

    /// Writes these channels back into `raw` as the device would report them.
    public func applied(to raw: MagicHomeRawState, profile: MagicHomeProfile) -> MagicHomeRawState {
        var out = raw
        if profile.protocol?.whitesAreTemperatureAndBrightness == true {
            let scaled = MagicHomeWhite.scaledTemperature(warm: warm, cool: cool)
            out.warmWhite = scaled.temperature
            out.coolWhite = scaled.brightness
            return out
        }
        switch profile.model.channelMap {
        case .none:
            (out.red, out.green, out.blue, out.warmWhite, out.coolWhite) = (red, green, blue, warm, cool)
        case .whiteInRed:
            (out.red, out.green, out.blue, out.warmWhite, out.coolWhite) = (warm, green, blue, red, cool)
        case .cctInRedGreen:
            (out.red, out.green, out.blue, out.warmWhite, out.coolWhite) = (warm, cool, blue, red, green)
        }
        return out
    }

    public var colorActive: Bool { red > 0 || green > 0 || blue > 0 }
    public var whiteActive: Bool { warm > 0 || cool > 0 }
}

/// Built-in effects ("preset patterns", flux_led names). Ids are sent back in `LightCommand.effect`.
public enum MagicHomeEffect {
    public struct Preset: Sendable, Hashable {
        public var id: String
        public var name: String
        public var pattern: UInt8
        public var isFast: Bool
        /// Only on dimmable-effect firmware.
        public var dimmableOnly: Bool
    }

    public static let presets: [Preset] = [
        Preset(id: "rgb_cross_fade", name: "RGB cross fade", pattern: 0x24, isFast: false, dimmableOnly: true),
        Preset(id: "colorloop", name: "Colour loop", pattern: 0x25, isFast: false, dimmableOnly: false),
        Preset(id: "red_fade", name: "Red fade", pattern: 0x26, isFast: false, dimmableOnly: false),
        Preset(id: "green_fade", name: "Green fade", pattern: 0x27, isFast: false, dimmableOnly: false),
        Preset(id: "blue_fade", name: "Blue fade", pattern: 0x28, isFast: false, dimmableOnly: false),
        Preset(id: "yellow_fade", name: "Yellow fade", pattern: 0x29, isFast: false, dimmableOnly: false),
        Preset(id: "cyan_fade", name: "Cyan fade", pattern: 0x2A, isFast: false, dimmableOnly: false),
        Preset(id: "purple_fade", name: "Purple fade", pattern: 0x2B, isFast: false, dimmableOnly: false),
        Preset(id: "white_fade", name: "White fade", pattern: 0x2C, isFast: false, dimmableOnly: false),
        Preset(id: "rg_cross_fade", name: "Red/green cross fade", pattern: 0x2D, isFast: false, dimmableOnly: false),
        Preset(id: "rb_cross_fade", name: "Red/blue cross fade", pattern: 0x2E, isFast: false, dimmableOnly: false),
        Preset(id: "gb_cross_fade", name: "Green/blue cross fade", pattern: 0x2F, isFast: false, dimmableOnly: false),
        Preset(id: "colorstrobe", name: "Colour strobe", pattern: 0x30, isFast: true, dimmableOnly: false),
        Preset(id: "red_strobe", name: "Red strobe", pattern: 0x31, isFast: true, dimmableOnly: false),
        Preset(id: "green_strobe", name: "Green strobe", pattern: 0x32, isFast: true, dimmableOnly: false),
        Preset(id: "blue_strobe", name: "Blue strobe", pattern: 0x33, isFast: true, dimmableOnly: false),
        Preset(id: "yellow_strobe", name: "Yellow strobe", pattern: 0x34, isFast: true, dimmableOnly: false),
        Preset(id: "cyan_strobe", name: "Cyan strobe", pattern: 0x35, isFast: true, dimmableOnly: false),
        Preset(id: "purple_strobe", name: "Purple strobe", pattern: 0x36, isFast: true, dimmableOnly: false),
        Preset(id: "white_strobe", name: "White strobe", pattern: 0x37, isFast: true, dimmableOnly: false),
        Preset(id: "colorjump", name: "Colour jump", pattern: 0x38, isFast: true, dimmableOnly: false),
        Preset(id: "cycle_rgb", name: "Cycle RGB", pattern: 0x39, isFast: false, dimmableOnly: true),
        Preset(id: "cycle_seven_colors", name: "Cycle seven colours", pattern: 0x3A, isFast: false, dimmableOnly: true),
    ]

    /// Static colour / white patterns (no effect running).
    public static let staticPatterns: Set<UInt8> = [0x41, 0x61]

    public static func presets(for proto: MagicHomeProtocol) -> [Preset] {
        presets.filter { proto.dimmableEffects || !$0.dimmableOnly }
    }

    public static func preset(id: String) -> Preset? { presets.first { $0.id == id } }
    public static func preset(pattern: UInt8) -> Preset? { presets.first { $0.pattern == pattern } }

    /// Speed 0...100 -> delay byte 1...31 (1 = fastest).
    public static func delay(forSpeed speed: Int) -> UInt8 {
        let s = min(max(speed, 0), 100)
        return UInt8((100 - s) * 30 / 100 + 1)
    }

    /// Delay byte 1...31 -> speed 0...100.
    public static func speed(forDelay delay: UInt8) -> Int {
        let d = min(max(Int(delay) - 1, 0), 30)
        return 100 - d * 100 / 30
    }
}

/// The messages for one command and the state the device will report afterwards.
public struct MagicHomePlan: Sendable, Hashable {
    public var messages: [Data]
    public var predicted: MagicHomeRawState

    public var isEmpty: Bool { messages.isEmpty }
}

/// `MagicHomeRawState` <-> `LightState` / `LightCommand`.
public enum MagicHomeMapping {
    /// Default speed for effects started from the app (flux_led default 50).
    public static let defaultEffectSpeed = 50

    public static func lightID(mac: String) -> LightID {
        LightID(brand: .magicHome, stableId: mac)!
    }

    public static func mac(of id: LightID) -> String? {
        id.brand == .magicHome ? MagicHomeDiscovery.normalizeMAC(id.stableId) : nil
    }

    // MARK: Capabilities

    public static func capabilities(for profile: MagicHomeProfile) -> LightCapabilities {
        guard let proto = profile.protocol else { return .onOff }
        let effects: [EffectDescriptor] = profile.layout.hasColor
            ? MagicHomeEffect.presets(for: proto).map { EffectDescriptor(id: $0.id, name: $0.name, isFast: $0.isFast) }
            : []
        let modes: Set<ColorMode>
        switch profile.layout {
        case .switch: modes = [.onOff]
        case .dim: modes = [.brightness]
        case .cct: modes = [.colorTemp]
        case .rgb: modes = [.rgb]
        case .rgbw: modes = [.rgbw]
        case .rgbww: modes = [.rgbww, .colorTemp]
        case .rgbOrWhite: modes = [.rgb, .white]
        case .rgbOrCCT: modes = [.rgb, .colorTemp]
        }
        let kelvin = modes.contains(.colorTemp) || modes.contains(.rgbww)
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: kelvin ? MagicHomeWhite.minKelvin : nil,
            maxKelvin: kelvin ? MagicHomeWhite.maxKelvin : nil,
            supportsTransition: false,
            effects: effects
        )
    }

    // MARK: State

    public static func state(_ raw: MagicHomeRawState, profile: MagicHomeProfile, at date: Date = Date()) -> LightState {
        var s = LightState(isOn: raw.isOn, reachable: true, updatedAt: date)
        let ch = MagicHomeChannels(raw, profile: profile)
        if profile.layout.hasColor, let preset = MagicHomeEffect.preset(pattern: raw.presetPattern) {
            s.effect = preset.id
        }
        switch profile.layout {
        case .switch:
            s.colorMode = .onOff
        case .dim:
            s.colorMode = .brightness
            s.brightness = ColorMath.brightness(from255: Int(ch.warm))
        case .cct:
            setWhite(&s, ch)
        case .rgb:
            setRGB(&s, ch)
        case .rgbw:
            let peak = max(ch.red, ch.green, ch.blue, ch.warm)
            s.colorMode = .rgbw
            s.brightness = ColorMath.brightness(from255: Int(peak))
            let n = normalize([ch.red, ch.green, ch.blue, ch.warm], peak: peak)
            s.rgbw = RGBW(r: n[0], g: n[1], b: n[2], w: n[3])
            s.rgb = ColorMath.rgbwToRGB(s.rgbw!)
        case .rgbww:
            if ch.colorActive {
                let peak = max(ch.red, ch.green, ch.blue, ch.warm, ch.cool)
                s.colorMode = .rgbww
                s.brightness = ColorMath.brightness(from255: Int(peak))
                let n = normalize([ch.red, ch.green, ch.blue, ch.cool, ch.warm], peak: peak)
                s.rgbww = RGBWW(r: n[0], g: n[1], b: n[2], cw: n[3], ww: n[4])
            } else {
                setWhite(&s, ch)
            }
        case .rgbOrWhite:
            if ch.whiteActive && !ch.colorActive {
                s.colorMode = .white
                s.brightness = ColorMath.brightness(from255: Int(ch.warm))
            } else {
                setRGB(&s, ch)
            }
        case .rgbOrCCT:
            if ch.whiteActive && !ch.colorActive { setWhite(&s, ch) } else { setRGB(&s, ch) }
        }
        return s
    }

    private static func setRGB(_ s: inout LightState, _ ch: MagicHomeChannels) {
        let peak = max(ch.red, ch.green, ch.blue)
        s.colorMode = .rgb
        s.brightness = ColorMath.brightness(from255: Int(peak))
        let n = normalize([ch.red, ch.green, ch.blue], peak: peak)
        s.rgb = RGB(r: n[0], g: n[1], b: n[2])
        s.hs = ColorMath.rgbToHS(s.rgb!)
    }

    private static func setWhite(_ s: inout LightState, _ ch: MagicHomeChannels) {
        let t = MagicHomeWhite.kelvin(warm: ch.warm, cool: ch.cool)
        s.colorMode = .colorTemp
        s.kelvin = t.kelvin
        s.brightness = ColorMath.brightness(from255: t.brightness)
    }

    /// Scales channels so the peak becomes 255 (colour at full value; brightness is separate).
    private static func normalize(_ values: [UInt8], peak: UInt8) -> [UInt8] {
        guard peak > 0 else { return values.map { _ in 255 } }
        return values.map { UInt8(clamping: Int((Double($0) * 255 / Double(peak)).rounded())) }
    }

    // MARK: Commands

    /// Messages for `command` given the last known state.
    ///
    /// - Brightness scales the channel levels (the protocol has no separate dimmer): RGB/RGBW/RGBWW
    ///   channels are multiplied so their peak equals the brightness; whites use the 2700-6500 K mix.
    /// - Colour and brightness go out in **one** levels message (`0x31`, or `0x41` when
    ///   `persist == false`).
    /// - Levels or an effect turn the light on (a power-on message is sent first on firmware whose
    ///   levels do not do that themselves). `brightness 0` without `on` = power off.
    /// - RGB/W bulbs: a Kelvin request selects the white channel ("white" mode).
    public static func plan(
        _ command: LightCommand,
        current raw: MagicHomeRawState,
        profile: MagicHomeProfile,
        persist: Bool = true,
        counter: UInt8 = 0
    ) -> MagicHomePlan {
        guard let proto = profile.protocol else { return MagicHomePlan(messages: [], predicted: raw) }
        let caps = capabilities(for: profile)
        var whiteRequested = false
        var cmd = command
        if profile.layout == .rgbOrWhite, case .kelvin = command.color {
            whiteRequested = true
            cmd.color = nil
        }
        cmd = cmd.normalized(for: caps)
        let currentState = state(raw, profile: profile)
        var predicted = raw
        var messages: [Data] = []

        let offByBrightness = cmd.on == nil && cmd.brightness == 0
        let levelChange = !offByBrightness && (cmd.color != nil || whiteRequested || (cmd.brightness ?? 0) > 0)
        let effectChange = cmd.effect != nil && profile.layout.hasColor
        let wantOn: Bool = {
            if let on = cmd.on { return on }
            if offByBrightness { return false }
            if levelChange || effectChange { return true }
            return raw.isOn
        }()

        if !wantOn {
            if raw.isOn || cmd.on == false || offByBrightness {
                messages.append(MagicHomeMessage.power(false, protocol: proto, counter: counter))
            }
            predicted.power = MagicHomeRawState.offByte
            return MagicHomePlan(messages: messages, predicted: predicted)
        }

        let needsPowerOn = !raw.isOn && (cmd.on == true || !proto.autoOn || !(levelChange || effectChange))
        if needsPowerOn {
            messages.append(MagicHomeMessage.power(true, protocol: proto, counter: counter))
        }
        predicted.power = MagicHomeRawState.onByte

        let currentBrightness = currentState.brightness ?? 1
        var brightness = cmd.brightness ?? (currentBrightness > 0 ? currentBrightness : 1)
        if brightness <= 0 { brightness = 1.0 / 255 }

        if effectChange, let id = cmd.effect, let preset = MagicHomeEffect.preset(id: id) {
            let speed = MagicHomeEffect.speed(forDelay: raw.speed)
            messages.append(MagicHomeMessage.presetPattern(preset.pattern, speed: raw.presetPattern == preset.pattern ? speed : defaultEffectSpeed,
                                                           brightness: Int((brightness * 100).rounded()), protocol: proto))
            predicted.presetPattern = preset.pattern
            return MagicHomePlan(messages: messages, predicted: predicted)
        }

        guard levelChange, let target = target(for: cmd, whiteRequested: whiteRequested, current: currentState, layout: profile.layout) else {
            return MagicHomePlan(messages: messages, predicted: predicted)
        }
        let logical = channels(for: target, brightness: brightness, layout: profile.layout)
        let wire = wireLevels(logical, profile: profile)
        let writeMode: MagicHomeWriteMode = profile.writesAll ? .all
            : !wire.hasWhite ? .colors
            : !wire.hasColor ? .whites
            : .all
        messages.append(MagicHomeMessage.levels(wire, writeMode: writeMode, protocol: proto, persist: persist, counter: counter))

        // Predicted report: channels not written keep their value unless the write mode clears them.
        var next = MagicHomeChannels(raw, profile: profile)
        let colorsWritten = writeMode != .whites
        let whitesWritten = writeMode != .colors
        let splitLayout = profile.layout == .rgbOrWhite || profile.layout == .rgbOrCCT
        if colorsWritten || splitLayout {
            next.red = logical.red ?? 0
            next.green = logical.green ?? 0
            next.blue = logical.blue ?? 0
        }
        if whitesWritten || splitLayout {
            next.warm = logical.warm ?? 0
            next.cool = logical.cool ?? 0
        }
        predicted = next.applied(to: predicted, profile: profile)
        predicted.presetPattern = 0x61
        return MagicHomePlan(messages: messages, predicted: predicted)
    }

    enum Target {
        case white
        case kelvin(Int)
        case rgb(RGB)
        case rgbw(RGBW)
        case rgbww(RGBWW)
    }

    /// What to render: the command's colour, else (brightness-only change) the current colour.
    static func target(for cmd: LightCommand, whiteRequested: Bool, current: LightState, layout: MagicHomeChannelLayout) -> Target? {
        if whiteRequested { return .white }
        switch cmd.color {
        case .kelvin(let k): return .kelvin(k)
        case .rgb(let v): return .rgb(v)
        case .rgbw(let v): return .rgbw(v)
        case .rgbww(let v): return .rgbww(v)
        case .hs(let v): return .rgb(ColorMath.hsToRGB(v))
        case .xy(let v): return .rgb(ColorMath.xyToRGB(v))
        case nil: break
        }
        switch layout {
        case .switch: return nil
        case .dim: return .white
        case .cct: return .kelvin(current.kelvin ?? MagicHomeWhite.minKelvin)
        case .rgb: return .rgb(current.rgb ?? .white)
        case .rgbw: return .rgbw(current.rgbw ?? RGBW(r: 0, g: 0, b: 0, w: 255))
        case .rgbww:
            if current.colorMode == .rgbww, let v = current.rgbww { return .rgbww(v) }
            return .kelvin(current.kelvin ?? MagicHomeWhite.minKelvin)
        case .rgbOrWhite:
            return current.colorMode == .white ? .white : .rgb(current.rgb ?? .white)
        case .rgbOrCCT:
            return current.colorMode == .colorTemp ? .kelvin(current.kelvin ?? MagicHomeWhite.minKelvin) : .rgb(current.rgb ?? .white)
        }
    }

    struct LogicalLevels {
        var red: UInt8?, green: UInt8?, blue: UInt8?, warm: UInt8?, cool: UInt8?
    }

    static func channels(for target: Target, brightness: Double, layout: MagicHomeChannelLayout) -> LogicalLevels {
        let b255 = max(1, ColorMath.brightness255(brightness))
        func scale(_ v: UInt8) -> UInt8 { UInt8(clamping: Int((Double(v) * brightness).rounded())) }
        switch target {
        case .white:
            return LogicalLevels(warm: UInt8(b255))
        case .kelvin(let k):
            let w = MagicHomeWhite.levels(kelvin: k, brightness: b255)
            switch layout {
            case .rgbww: return LogicalLevels(red: 0, green: 0, blue: 0, warm: w.warm, cool: w.cool)
            default: return LogicalLevels(warm: w.warm, cool: w.cool)
            }
        case .rgb(let c):
            let s = ColorMath.scaled(c, by: brightness)
            switch layout {
            case .rgbw: return LogicalLevels(red: s.r, green: s.g, blue: s.b, warm: 0)
            case .rgbww: return LogicalLevels(red: s.r, green: s.g, blue: s.b, warm: 0, cool: 0)
            default: return LogicalLevels(red: s.r, green: s.g, blue: s.b)
            }
        case .rgbw(let c):
            return LogicalLevels(red: scale(c.r), green: scale(c.g), blue: scale(c.b), warm: scale(c.w))
        case .rgbww(let c):
            return LogicalLevels(red: scale(c.r), green: scale(c.g), blue: scale(c.b), warm: scale(c.ww), cool: scale(c.cw))
        }
    }

    /// Logical channels -> wire positions (channel map).
    static func wireLevels(_ l: LogicalLevels, profile: MagicHomeProfile) -> MagicHomeLevels {
        switch profile.model.channelMap {
        case .none:
            return MagicHomeLevels(red: l.red, green: l.green, blue: l.blue, warmWhite: l.warm, coolWhite: l.cool)
        case .whiteInRed:
            return MagicHomeLevels(red: l.warm, green: l.green, blue: l.blue, warmWhite: l.red, coolWhite: l.cool)
        case .cctInRedGreen:
            return MagicHomeLevels(red: l.warm, green: l.cool, blue: l.blue, warmWhite: l.red, coolWhite: l.green)
        }
    }
}
