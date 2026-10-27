import Foundation
import LightCore

/// Pure mapping between CLIP v2 models and the LightCore domain model.
public enum HueMapping {
    /// Default CLIP mirek range when a light omits `mirek_schema` (6535 K ... 2000 K).
    public static let defaultMirekRange: ClosedRange<Int> = 153...500

    // MARK: Colour temperature

    /// mirek -> Kelvin (floored, same convention as LightCore `ColorMath`). 153 -> 6535, 500 -> 2000.
    public static func kelvin(fromMirek mirek: Int) -> Int { ColorMath.miredToKelvin(mirek) }

    /// Kelvin -> mirek, clamped into the light's schema (default 153...500).
    public static func mirek(fromKelvin kelvin: Int, schema: HueMirekSchema? = nil) -> Int {
        let range = mirekRange(schema)
        let raw = ColorMath.kelvinToMired(max(kelvin, 1))
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    public static func mirekRange(_ schema: HueMirekSchema?) -> ClosedRange<Int> {
        let lo = schema?.mirekMinimum ?? defaultMirekRange.lowerBound
        let hi = schema?.mirekMaximum ?? defaultMirekRange.upperBound
        return lo <= hi ? lo...hi : hi...lo
    }

    /// Kelvin range of a mirek schema: min Kelvin comes from the *maximum* mirek.
    public static func kelvinRange(_ schema: HueMirekSchema?) -> ClosedRange<Int> {
        let m = mirekRange(schema)
        return kelvin(fromMirek: m.upperBound)...kelvin(fromMirek: m.lowerBound)
    }

    // MARK: Gamut

    /// Gamut from `color.gamut_type` (A/B/C), else from the explicit `color.gamut` triangle.
    public static func gamut(for color: HueColor?) -> Gamut? {
        guard let color else { return nil }
        switch color.gamutType?.uppercased() {
        case "A": return .hueA
        case "B": return .hueB
        case "C": return .hueC
        default: break
        }
        guard let r = color.gamut?.red, let g = color.gamut?.green, let b = color.gamut?.blue else { return nil }
        let gamut = Gamut(red: XY(x: r.x, y: r.y), green: XY(x: g.x, y: g.y), blue: XY(x: b.x, y: b.y))
        return gamut.isValid ? gamut : nil
    }

    // MARK: Capabilities and state

    public static func capabilities(for light: HueLight) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        if light.color != nil { modes.insert(.xy) }
        if light.colorTemperature != nil { modes.insert(.colorTemp) }
        if modes.isEmpty { modes.insert(light.dimming != nil ? .brightness : .onOff) }
        var minKelvin: Int?
        var maxKelvin: Int?
        if let ct = light.colorTemperature {
            let range = kelvinRange(ct.mirekSchema)
            minKelvin = range.lowerBound
            maxKelvin = range.upperBound
        }
        let effects = (light.effects?.effectValues ?? []).map { EffectDescriptor(id: $0, name: effectName($0)) }
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: minKelvin,
            maxKelvin: maxKelvin,
            supportsTransition: true,
            supportsEffects: !effects.isEmpty,
            effects: effects,
            gamut: gamut(for: light.color)
        )
    }

    /// "no_effect" -> "None", "candle" -> "Candle", "dynamic_palette" -> "Dynamic Palette".
    public static func effectName(_ id: String) -> String {
        if id == "no_effect" { return "None" }
        return id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static func state(for light: HueLight, reachable: Bool, at date: Date = Date()) -> LightState {
        var state = LightState(isOn: light.on?.on ?? false, reachable: reachable, updatedAt: date)
        if let b = light.dimming?.brightness { state.brightness = min(max(b / 100, 0), 1) }
        if let xy = light.color?.xy { state.xy = XY(x: xy.x, y: xy.y) }
        if let ct = light.colorTemperature, ct.mirekValid != false, let m = ct.mirek, m > 0 {
            state.colorMode = .colorTemp
            state.kelvin = kelvin(fromMirek: m)
        } else if state.xy != nil {
            state.colorMode = .xy
        } else {
            state.colorMode = light.dimming != nil ? .brightness : .onOff
        }
        if let effect = light.effects?.status, effect != "no_effect", !effect.isEmpty { state.effect = effect }
        return state
    }

    /// Capabilities a `grouped_light` can honour for a set of member lights (union of modes,
    /// widest Kelvin range, no gamut clamp: the bridge clamps per lamp; no effects).
    public static func groupCapabilities(_ members: [LightCapabilities]) -> LightCapabilities {
        var modes = Set(members.flatMap(\.supportedColorModes))
        if modes.count > 1 { modes.remove(.onOff) }
        if modes.contains(.xy) || modes.contains(.colorTemp) { modes.remove(.brightness) }
        if modes.isEmpty { modes = [.onOff] }
        let mins = members.compactMap(\.minKelvin)
        let maxs = members.compactMap(\.maxKelvin)
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: mins.min(),
            maxKelvin: maxs.max(),
            supportsTransition: true
        )
    }

    // MARK: Commands

    /// Builds one CLIP v2 PUT body for `command` (normalised for `capabilities`):
    /// - xy for colour lights (clamped to the gamut), mirek for colour temperature;
    /// - brightness > 0 without an explicit `on` also turns the light on, brightness 0 turns it off;
    /// - `transition` -> `dynamics.duration` (ms).
    public static func lightUpdate(
        for command: LightCommand, capabilities: LightCapabilities, mirekSchema: HueMirekSchema? = nil
    ) -> HueLightUpdate {
        let cmd = command.normalized(for: capabilities)
        var update = HueLightUpdate()
        var on = cmd.on
        if let b = cmd.brightness {
            if b <= 0 {
                if on == nil { on = false }
                if on == true { update.dimming = .init(brightness: 0) }
            } else {
                update.dimming = .init(brightness: min(max(round2(b * 100), 0), 100))
                if on == nil { on = true }
            }
        }
        update.on = on.map(HueLightUpdate.On.init(on:))
        if let color = cmd.color {
            switch color {
            case .xy(let xy):
                update.color = .init(xy: HueXY(x: round4(xy.x), y: round4(xy.y)))
            case .kelvin(let k):
                update.colorTemperature = .init(mirek: mirek(fromKelvin: k, schema: mirekSchema))
            case .hs, .rgb, .rgbw, .rgbww:
                // Not produced by `normalized` for Hue capabilities; convert defensively.
                let xy = xyFromAttribute(color, gamut: capabilities.gamut)
                update.color = .init(xy: HueXY(x: round4(xy.x), y: round4(xy.y)))
            }
        }
        if let effect = cmd.effect { update.effects = .init(effect: effect) }
        if let ms = cmd.transitionMilliseconds { update.dynamics = .init(duration: ms) }
        return update
    }

    /// Body for a `grouped_light` PUT (effects are not supported on groups and are dropped).
    public static func groupUpdate(for command: LightCommand, members: [LightCapabilities]) -> HueLightUpdate {
        var cmd = command
        cmd.effect = nil
        var update = lightUpdate(for: cmd, capabilities: groupCapabilities(members), mirekSchema: nil)
        update.effects = nil
        return update
    }

    private static func xyFromAttribute(_ attr: ColorAttribute, gamut: Gamut?) -> XY {
        switch attr {
        case .xy(let xy): gamut?.clamp(xy) ?? xy
        case .hs(let hs): ColorMath.hsToXY(hs, gamut: gamut)
        case .rgb(let rgb): ColorMath.rgbToXY(rgb, gamut: gamut)
        case .rgbw(let v): ColorMath.rgbToXY(ColorMath.rgbwToRGB(v), gamut: gamut)
        case .rgbww(let v): ColorMath.rgbToXY(ColorMath.rgbwwToRGB(v, minKelvin: 2000, maxKelvin: 6535), gamut: gamut)
        case .kelvin(let k): ColorMath.kelvinToXY(k)
        }
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
}

/// Light / scene identifiers: `hue:<BRIDGEID>/<resource uuid>`.
public enum HueIdentifiers {
    public static func lightID(bridgeID: String, resourceID: String) -> LightID? {
        LightID(brand: .hue, stableId: "\(bridgeID)/\(resourceID)")
    }

    public static func sceneID(bridgeID: String, resourceID: String) -> String {
        "hue:\(bridgeID)/\(resourceID)"
    }

    /// Splits a `LightID` stable id (`BRIDGEID/uuid`).
    public static func split(_ id: LightID) -> (bridgeID: String, resourceID: String)? {
        guard id.brand == .hue else { return nil }
        return split(stableID: id.stableId)
    }

    /// Splits `BRIDGEID/uuid` or `hue:BRIDGEID/uuid`.
    public static func split(stableID raw: String) -> (bridgeID: String, resourceID: String)? {
        var s = Substring(raw)
        if s.lowercased().hasPrefix("hue:") { s = s.dropFirst(4) }
        guard let slash = s.firstIndex(of: "/") else { return nil }
        let bridge = s[..<slash].uppercased()
        let resource = String(s[s.index(after: slash)...])
        guard !bridge.isEmpty, !resource.isEmpty else { return nil }
        return (bridge, resource)
    }
}

/// Builds base URLs for a bridge host (IPv4, IPv6, hostname, optional port).
public enum HueEndpoint {
    /// Splits user input like `192.168.1.2`, `192.168.1.2:8443`, `[fe80::1]:443`, `fe80::1`.
    public static func parseHost(_ input: String) -> (host: String, port: Int?) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, nil)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let idx = s.firstIndex(of: ":"), let port = Int(s[s.index(after: idx)...]) {
            return (String(s[..<idx]), port)
        }
        return (s, nil)
    }

    /// `host[:port]` for a URL (brackets IPv6, escapes a zone id).
    public static func authority(host: String, port: Int?) -> String {
        var h = host
        if h.contains(":") {
            h = h.replacingOccurrences(of: "%25", with: "%").replacingOccurrences(of: "%", with: "%25")
            h = "[\(h)]"
        }
        if let port { return "\(h):\(port)" }
        return h
    }

    public static func url(scheme: String, host: String, port: Int?, path: String) -> URL? {
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "\(scheme)://\(authority(host: host, port: port))\(p)")
    }
}
