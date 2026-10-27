import Foundation
import LightCore

/// One controllable light output of a Shelly device.
///
/// Gen2+: a component from `Shelly.GetConfig`/`Shelly.GetStatus` keys `light:N`, `cct:N`,
/// `rgb:N`, `rgbw:N`, `rgbcct:N`, controlled with `<Component>.Set`.
/// Gen1: a REST channel `/light/N`, `/color/N` or `/white/N`, chosen by device type and mode.
public struct ShellyChannel: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        // Gen2+ components (raw value = key prefix).
        case rgbw, rgbcct, rgb, cct, light
        /// Gen1 dimmers and Vintage: `/light/N` brightness.
        case gen1Dimmer
        /// Gen1 Duo: `/light/0` brightness + temp.
        case gen1CCT
        /// Gen1 Bulb RGBW / Duo RGBW: `/light/0` colour mode (rgbw + gain) or white mode (temp + brightness).
        case gen1Bulb
        /// Gen1 RGBW2 colour mode: `/color/0` rgbw + gain.
        case gen1Color
        /// Gen1 RGBW2 white mode: `/white/N` brightness (4 channels).
        case gen1White

        public var isRPC: Bool {
            switch self {
            case .rgbw, .rgbcct, .rgb, .cct, .light: true
            default: false
            }
        }

        /// RPC method prefix (`Light`, `CCT`, `RGB`, `RGBW`, `RGBCCT`).
        public var rpcPrefix: String? {
            switch self {
            case .light: "Light"
            case .cct: "CCT"
            case .rgb: "RGB"
            case .rgbw: "RGBW"
            case .rgbcct: "RGBCCT"
            default: nil
            }
        }

        /// Gen1 path segment.
        public var gen1Path: String? {
            switch self {
            case .gen1Dimmer, .gen1CCT, .gen1Bulb: "light"
            case .gen1Color: "color"
            case .gen1White: "white"
            default: nil
            }
        }
    }

    public var kind: Kind
    public var index: Int
    public var name: String?
    public var minKelvin: Int?
    public var maxKelvin: Int?

    public init(kind: Kind, index: Int, name: String? = nil, minKelvin: Int? = nil, maxKelvin: Int? = nil) {
        self.kind = kind
        self.index = index
        self.name = name
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
    }

    /// `"light:0"` (Gen2 status key) or `"light/0"` (Gen1 path).
    public var key: String { kind.isRPC ? "\(kind.rawValue):\(index)" : "\(kind.gen1Path ?? "light")/\(index)" }

    /// Stable id suffix inside the device: primary channel = bare MAC, others `-<kind><index>`.
    public func stableID(mac: String, primary: Bool) -> String {
        primary ? mac : "\(mac)-\(kind.isRPC ? kind.rawValue : (kind.gen1Path ?? "light"))\(index)"
    }

    /// Default Kelvin ranges (HA shelly: white 2700-6500, colour bulbs in white mode 3000-6500).
    static let whiteKelvin = 2700...6500
    static let colorBulbKelvin = 3000...6500
}

/// Status of one channel (both generations).
public struct ShellyChannelStatus: Sendable, Hashable, Codable {
    public var isOn: Bool
    /// 0...100 (white brightness / Gen2 brightness).
    public var brightness: Int?
    public var rgb: RGB?
    /// 0...255 white channel (RGBW).
    public var white: Int?
    public var kelvin: Int?
    /// 0...100, Gen1 colour-mode brightness.
    public var gain: Int?
    /// Gen1 `color`/`white`, Gen2 RGBCCT `rgb`/`cct`.
    public var mode: String?

    public init(isOn: Bool, brightness: Int? = nil, rgb: RGB? = nil, white: Int? = nil, kelvin: Int? = nil,
                gain: Int? = nil, mode: String? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.rgb = rgb
        self.white = white
        self.kelvin = kelvin
        self.gain = gain
        self.mode = mode
    }

    /// Gen2 component status: `{"id":0,"output":true,"brightness":50,"rgb":[255,0,0],"white":0,"ct":4000}`.
    public static func parseRPC(_ json: ShellyJSON) -> ShellyChannelStatus? {
        guard let on = json["output"]?.bool ?? json["on"]?.bool else { return nil }
        return ShellyChannelStatus(isOn: on, brightness: json["brightness"]?.int, rgb: rgb(json["rgb"]),
                                   white: json["white"]?.int, kelvin: json["ct"]?.int, mode: json["mode"]?.string)
    }

    /// Gen1 light status: `{"ison":true,"mode":"color","red":255,"green":0,"blue":0,"white":0,"gain":80,"temp":4000,"brightness":50}`.
    public static func parseGen1(_ json: ShellyJSON) -> ShellyChannelStatus? {
        guard let on = json["ison"]?.bool else { return nil }
        var rgb: RGB?
        if let r = json["red"]?.int, let g = json["green"]?.int, let b = json["blue"]?.int {
            rgb = RGB(r: UInt8(clamping: r), g: UInt8(clamping: g), b: UInt8(clamping: b))
        }
        return ShellyChannelStatus(isOn: on, brightness: json["brightness"]?.int, rgb: rgb, white: json["white"]?.int,
                                   kelvin: json["temp"]?.int, gain: json["gain"]?.int, mode: json["mode"]?.string)
    }

    /// Applies a partial Gen2 notification patch.
    public func merging(rpcPatch json: ShellyJSON) -> ShellyChannelStatus {
        var s = self
        if let v = json["output"]?.bool ?? json["on"]?.bool { s.isOn = v }
        if let v = json["brightness"]?.int { s.brightness = v }
        if let v = Self.rgb(json["rgb"]) { s.rgb = v }
        if let v = json["white"]?.int { s.white = v }
        if let v = json["ct"]?.int { s.kelvin = v }
        if let v = json["mode"]?.string { s.mode = v }
        return s
    }

    private static func rgb(_ json: ShellyJSON?) -> RGB? {
        guard let a = json?.array, a.count >= 3, let r = a[0].int, let g = a[1].int, let b = a[2].int else { return nil }
        return RGB(r: UInt8(clamping: r), g: UInt8(clamping: g), b: UInt8(clamping: b))
    }
}

/// A request that executes one command.
public enum ShellyAction: Sendable, Hashable {
    /// Gen2+: `POST /rpc` (or WebSocket) `method` with `params`.
    case rpc(method: String, params: ShellyJSON)
    /// Gen1: `GET` path + query.
    case gen1(ShellyGen1Request)
}

/// Component discovery and state/command mapping.
public enum ShellyMapping {
    /// Shortest transition HA sends to Gen2+ (`RPC_MIN_TRANSITION_TIME_SEC`).
    public static let minRPCTransition = 0.5
    /// Gen1 maximum transition (`BLOCK_MAX_TRANSITION_TIME_MS`).
    public static let maxGen1TransitionMs = 5000

    public static func lightID(mac: String, channel: ShellyChannel, primary: Bool) -> LightID {
        LightID(brand: .shelly, stableId: channel.stableID(mac: mac, primary: primary))!
    }

    // MARK: Channels

    /// Gen2+: light components from `Shelly.GetConfig` (names, `ct_range`) and/or `Shelly.GetStatus`.
    public static func rpcChannels(config: ShellyJSON?, status: ShellyJSON?) -> [ShellyChannel] {
        var keys = Set<String>()
        for source in [config, status] { if let o = source?.object { keys.formUnion(o.keys) } }
        var out: [ShellyChannel] = []
        for key in keys {
            let parts = key.split(separator: ":")
            guard parts.count == 2, let kind = ShellyChannel.Kind(rawValue: String(parts[0])), kind.isRPC,
                  let index = Int(parts[1]) else { continue }
            let cfg = config?[key]
            var channel = ShellyChannel(kind: kind, index: index, name: cfg?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 })
            if kind == .cct || kind == .rgbcct {
                let range = cfg?["ct_range"]?.array?.compactMap(\.int)
                channel.minKelvin = range?.count == 2 ? range![0] : ShellyChannel.whiteKelvin.lowerBound
                channel.maxKelvin = range?.count == 2 ? range![1] : ShellyChannel.whiteKelvin.upperBound
            }
            out.append(channel)
        }
        return sorted(out)
    }

    /// Gen1: channels from the device type and `/settings` (`mode`, `lights[]` names).
    public static func gen1Channels(type: String, settings: ShellyJSON?) -> [ShellyChannel] {
        let lights = settings?["lights"]?.array ?? []
        func name(_ i: Int) -> String? { lights.indices.contains(i) ? lights[i]["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil }
        let mode = settings?["mode"]?.string
        switch type {
        case "SHBDUO-1":
            let r = ShellyChannel.whiteKelvin
            return [ShellyChannel(kind: .gen1CCT, index: 0, name: name(0), minKelvin: r.lowerBound, maxKelvin: r.upperBound)]
        case "SHBLB-1", "SHCB-1":
            let r = ShellyChannel.colorBulbKelvin
            return [ShellyChannel(kind: .gen1Bulb, index: 0, name: name(0), minKelvin: r.lowerBound, maxKelvin: r.upperBound)]
        case "SHRGBW2":
            if mode == "white" {
                return (0..<max(1, lights.count)).map { ShellyChannel(kind: .gen1White, index: $0, name: name($0)) }
            }
            return [ShellyChannel(kind: .gen1Color, index: 0, name: name(0))]
        default:
            // Vintage, dimmers and unknown light devices: brightness on /light/N.
            return (0..<max(1, lights.count)).map { ShellyChannel(kind: .gen1Dimmer, index: $0, name: name($0)) }
        }
    }

    /// Colour-capable components first, then by index (the first one is the "primary" light).
    static func sorted(_ channels: [ShellyChannel]) -> [ShellyChannel] {
        let order = ShellyChannel.Kind.allCases
        return channels.sorted {
            let a = order.firstIndex(of: $0.kind)!, b = order.firstIndex(of: $1.kind)!
            return a != b ? a < b : $0.index < $1.index
        }
    }

    /// Status per channel key from Gen2 `Shelly.GetStatus` or Gen1 `/status`.
    public static func statuses(for channels: [ShellyChannel], rpcStatus: ShellyJSON) -> [String: ShellyChannelStatus] {
        var out: [String: ShellyChannelStatus] = [:]
        for c in channels { if let s = rpcStatus[c.key].flatMap(ShellyChannelStatus.parseRPC) { out[c.key] = s } }
        return out
    }

    public static func statuses(for channels: [ShellyChannel], gen1Status: ShellyJSON) -> [String: ShellyChannelStatus] {
        var out: [String: ShellyChannelStatus] = [:]
        let lists: [String: [ShellyJSON]] = [
            "light": gen1Status["lights"]?.array ?? [],
            "color": gen1Status["lights"]?.array ?? [],
            "white": gen1Status["lights"]?.array ?? [],
        ]
        for c in channels {
            guard let list = lists[c.kind.gen1Path ?? ""], list.indices.contains(c.index),
                  let s = ShellyChannelStatus.parseGen1(list[c.index]) else { continue }
            out[c.key] = s
        }
        return out
    }

    // MARK: Capabilities and state

    public static func capabilities(for c: ShellyChannel) -> LightCapabilities {
        let modes: Set<ColorMode>
        switch c.kind {
        case .light, .gen1Dimmer, .gen1White: modes = [.brightness]
        case .cct, .gen1CCT: modes = [.colorTemp]
        case .rgb: modes = [.rgb]
        case .rgbw, .gen1Color: modes = [.rgbw]
        case .rgbcct: modes = [.rgb, .colorTemp]
        case .gen1Bulb: modes = [.rgbw, .colorTemp]
        }
        return LightCapabilities(supportedColorModes: modes, minKelvin: c.minKelvin, maxKelvin: c.maxKelvin, supportsTransition: true)
    }

    public static func state(_ s: ShellyChannelStatus, channel c: ShellyChannel, at date: Date = Date()) -> LightState {
        var out = LightState(isOn: s.isOn, reachable: true, updatedAt: date)
        func percent(_ v: Int?) -> Double? { v.map { Double(min(max($0, 0), 100)) / 100 } }
        switch c.kind {
        case .light, .gen1Dimmer, .gen1White:
            out.colorMode = .brightness
            out.brightness = percent(s.brightness)
        case .cct, .gen1CCT:
            out.colorMode = .colorTemp
            out.brightness = percent(s.brightness)
            out.kelvin = s.kelvin
        case .rgb:
            setColor(&out, rgb: s.rgb, white: nil, brightness: percent(s.brightness))
        case .rgbw:
            setColor(&out, rgb: s.rgb, white: s.white ?? 0, brightness: percent(s.brightness))
        case .rgbcct:
            if s.mode == "cct" {
                out.colorMode = .colorTemp
                out.kelvin = s.kelvin
                out.brightness = percent(s.brightness)
            } else {
                setColor(&out, rgb: s.rgb, white: nil, brightness: percent(s.brightness))
            }
        case .gen1Color:
            setColor(&out, rgb: s.rgb, white: s.white ?? 0, brightness: percent(s.gain))
        case .gen1Bulb:
            if s.mode == "white" {
                out.colorMode = .colorTemp
                out.kelvin = s.kelvin
                out.brightness = percent(s.brightness)
            } else {
                setColor(&out, rgb: s.rgb, white: s.white ?? 0, brightness: percent(s.gain))
            }
        }
        return out
    }

    private static func setColor(_ s: inout LightState, rgb: RGB?, white: Int?, brightness: Double?) {
        let c = rgb ?? .white
        s.brightness = brightness
        s.rgb = c
        s.hs = ColorMath.rgbToHS(c)
        if let white {
            s.colorMode = .rgbw
            s.rgbw = RGBW(r: c.r, g: c.g, b: c.b, w: UInt8(clamping: white))
        } else {
            s.colorMode = .rgb
        }
    }

    // MARK: Commands

    /// Builds the request for `command` and the status expected afterwards.
    ///
    /// - Brightness and colour go out in **one** request (`<Component>.Set` / one Gen1 GET).
    /// - `brightness 0` without `on` = off; any other change implies on unless `on == false`.
    /// - Brightness maps to 1...100 (Gen1 colour modes: `gain`); RGB is sent at full value.
    /// - Transitions: Gen2 `transition_duration` (seconds, >= 0.5), Gen1 `transition` (ms, <= 5000).
    public static func plan(
        _ command: LightCommand, channel c: ShellyChannel, current: ShellyChannelStatus?
    ) -> (action: ShellyAction, predicted: ShellyChannelStatus)? {
        let caps = capabilities(for: c)
        let cmd = command.normalized(for: caps)
        if cmd.isEmpty { return nil }
        var next = current ?? ShellyChannelStatus(isOn: false)

        let offByBrightness = cmd.on == nil && cmd.brightness == 0
        let changesLight = cmd.color != nil || (cmd.brightness ?? 0) > 0
        let on: Bool = cmd.on ?? (offByBrightness ? false : (changesLight ? true : next.isOn))
        next.isOn = on
        let level = cmd.brightness.flatMap { $0 > 0 ? ColorMath.deviceValue(forBrightness: $0, in: 1...100) : nil }
        let transitionMs = cmd.transitionMilliseconds

        var kelvin: Int?
        var rgb: RGB?
        var white: Int?
        switch cmd.color {
        case .kelvin(let k): kelvin = k
        case .rgb(let v): rgb = v
        case .rgbw(let v): rgb = RGB(r: v.r, g: v.g, b: v.b); white = Int(v.w)
        default: break
        }

        if c.kind.isRPC {
            var p: [String: ShellyJSON] = ["id": .number(Double(c.index)), "on": .bool(on)]
            if on {
                if let level { p["brightness"] = .number(Double(level)); next.brightness = level }
                if let kelvin { p["ct"] = .number(Double(kelvin)); next.kelvin = kelvin }
                if let rgb { p["rgb"] = [.number(Double(rgb.r)), .number(Double(rgb.g)), .number(Double(rgb.b))]; next.rgb = rgb }
                if let white, c.kind == .rgbw { p["white"] = .number(Double(white)); next.white = white }
                if c.kind == .rgbcct {
                    if kelvin != nil { p["mode"] = "cct"; next.mode = "cct" } else if rgb != nil { p["mode"] = "rgb"; next.mode = "rgb" }
                }
            }
            if let ms = transitionMs, ms > 0 { p["transition_duration"] = .number(max(Double(ms) / 1000, minRPCTransition)) }
            return (.rpc(method: "\(c.kind.rpcPrefix!).Set", params: .object(p)), next)
        }

        var q: [(String, String)] = [("turn", on ? "on" : "off")]
        if on {
            let colorMode: Bool
            switch c.kind {
            case .gen1Color: colorMode = true
            case .gen1Bulb: colorMode = rgb != nil || (kelvin == nil && next.mode != "white")
            default: colorMode = false
            }
            if c.kind == .gen1Bulb {
                let mode = colorMode ? "color" : "white"
                if mode != next.mode { q.append(("mode", mode)); next.mode = mode }
            }
            if let level {
                q.append((colorMode ? "gain" : "brightness", String(level)))
                if colorMode { next.gain = level } else { next.brightness = level }
            }
            if let kelvin { q.append(("temp", String(kelvin))); next.kelvin = kelvin }
            if let rgb {
                q += [("red", String(rgb.r)), ("green", String(rgb.g)), ("blue", String(rgb.b))]
                next.rgb = rgb
                q.append(("white", String(white ?? 0)))
                next.white = white ?? 0
            }
        }
        if let ms = transitionMs, ms > 0 { q.append(("transition", String(min(ms, maxGen1TransitionMs)))) }
        return (.gen1(ShellyGen1Request(path: "/\(c.kind.gen1Path!)/\(c.index)", query: q)), next)
    }
}
