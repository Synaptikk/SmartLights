import Foundation
import LightCore

/// Pure mapping between WLED wire values and the SmartLights domain model (`LightCore`).
public enum WLEDMapping {
    /// Master brightness range on the wire. `0` is never sent: "off" uses `on: false`.
    public static let brightnessRange = 1...255
    /// Longest one-shot transition WLED accepts (`tt`, 100 ms units; 65535 = 109 min).
    public static let maxTransitionUnits = 65535

    // MARK: Identity

    /// mDNS host name normalised for use as the stable id: lower case, no `.local` suffix,
    /// no whitespace ("WLED-Kitchen.local." -> "wled-kitchen"). Nil if nothing is left.
    public static func stableID(mdns: String) -> String? {
        var s = mdns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasSuffix(".local") { s.removeLast(".local".count) }
        s = String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        return s.isEmpty ? nil : s
    }

    /// `"wled:<mdns name>"`.
    public static func lightID(mdns: String) -> LightID? {
        stableID(mdns: mdns).flatMap { LightID(brand: .wled, stableId: $0) }
    }

    /// WLED's default mDNS name: `wled-` + the last 6 hex digits of the MAC ("a4cf12fdaea8" ->
    /// "wled-fdaea8"). Used when neither Bonjour nor `/json/cfg` tells us the configured name.
    public static func defaultMDNSName(mac: String) -> String? {
        guard let m = normalizedMAC(mac) else { return nil }
        return "wled-" + m.suffix(6)
    }

    /// MAC as 12 lower-case hex digits ("A4:CF:12:FD:AE:A8" -> "a4cf12fdaea8"); nil if malformed.
    public static func normalizedMAC(_ mac: String) -> String? {
        let hex = mac.lowercased().filter { $0.isHexDigit }
        return hex.count == 12 ? hex : nil
    }

    /// "a4cf12fdaea8" -> "a4:cf:12:fd:ae:a8".
    public static func formattedMAC(_ mac: String) -> String? {
        guard let m = normalizedMAC(mac) else { return nil }
        var out = ""
        for (i, c) in m.enumerated() {
            if i > 0 && i % 2 == 0 { out.append(":") }
            out.append(c)
        }
        return out
    }

    // MARK: Effects

    /// `/json/effects` names -> effects; the array index is the id. Reserved slots ("RSVD", "-",
    /// empty) are skipped, metadata after `@` is stripped. Strobe-like effects are marked fast so
    /// the UI shows the photosensitivity warning first.
    public static func effects(fromNames names: [String]) -> [EffectDescriptor] {
        names.enumerated().compactMap { index, raw in
            let name = String(raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "RSVD", name != "-" else { return nil }
            return EffectDescriptor(id: String(index), name: name, isFast: isFast(name))
        }
    }

    public static func decodeEffects(_ data: Data) throws -> [EffectDescriptor] {
        effects(fromNames: try JSONDecoder().decode([String].self, from: data))
    }

    private static let fastKeywords = ["strobe", "blink", "lightning", "flash", "police", "glitter"]

    static func isFast(_ name: String) -> Bool {
        let lower = name.lowercased()
        return fastKeywords.contains { lower.contains($0) }
    }

    // MARK: Capabilities

    /// Whether colour slots carry a white channel (`leds.lc & 2`, or `leds.rgbw` on old firmware).
    public static func hasWhiteChannel(_ info: WLEDInfo?) -> Bool {
        if let lc = info?.leds?.lc { return lc & 0x02 != 0 }
        return info?.leds?.rgbw ?? false
    }

    /// RGB strips -> `[.rgb]`; RGBW -> `[.rgbw]`; white-only (lc == 2) -> `[.brightness]`.
    /// Transitions supported; effects from `/json/effects`. CCT (lc & 4) is not mapped yet.
    public static func capabilities(info: WLEDInfo?, effects: [EffectDescriptor]) -> LightCapabilities {
        let lc = info?.leds?.lc
        let modes: Set<ColorMode>
        if let lc, lc & 0x01 == 0, lc & 0x02 != 0 {
            modes = [.brightness]
        } else {
            modes = hasWhiteChannel(info) ? [.rgbw] : [.rgb]
        }
        return LightCapabilities(supportedColorModes: modes, supportsTransition: true, supportsEffects: !effects.isEmpty, effects: effects)
    }

    // MARK: State

    /// Domain state from `/json/state` (master on/brightness, segment 0 colour slot 0 and effect).
    public static func state(from wled: WLEDState, capabilities: LightCapabilities, at date: Date = Date()) -> LightState {
        var s = LightState(isOn: wled.on ?? false, reachable: true, updatedAt: date)
        if let bri = wled.bri, bri > 0 {
            s.brightness = ColorMath.brightness(fromDeviceValue: bri, in: brightnessRange)
        } else if wled.bri == 0 {
            s.brightness = 0
        }
        let seg = wled.primarySegment
        if let fx = seg?.fx, fx != 0 { s.effect = String(fx) }
        let modes = capabilities.supportedColorModes
        guard let slot = seg?.col?.first, slot.count >= 3 else {
            s.colorMode = modes.contains(.brightness) ? .brightness : nil
            return s
        }
        let c = slot.map { UInt8(clamping: $0) }
        let rgb = RGB(r: c[0], g: c[1], b: c[2])
        if modes.contains(.rgbw) {
            let rgbw = RGBW(r: c[0], g: c[1], b: c[2], w: c.count > 3 ? c[3] : 0)
            s.colorMode = .rgbw
            s.rgbw = rgbw
            s.rgb = ColorMath.rgbwToRGB(rgbw)
        } else if modes.contains(.rgb) {
            s.colorMode = .rgb
            s.rgb = rgb
        } else {
            s.colorMode = .brightness
            return s
        }
        if let rgb = s.rgb, rgb != .black { s.hs = ColorMath.rgbToHS(rgb) }
        return s
    }

    // MARK: Commands

    /// The `POST /json/state` body for `command`, or nil if nothing would change.
    ///
    /// - Normalised for the light first (`LightCommand.normalized(for:)`): HS/xy/Kelvin become RGB
    ///   (or RGBW) for segment 0's primary colour slot.
    /// - Brightness (master `bri`), colour and effect go in one POST.
    /// - `brightness == 0` without `on` switches off and keeps `bri`; `brightness > 0` without `on`
    ///   on an off light switches it on.
    /// - A colour without an effect selects Solid (`fx: 0`) so the colour is actually shown;
    ///   an effect id selects `fx` (and switches an off light on).
    /// - `transition` -> `tt` (one-shot, 100 ms units, rounded).
    /// - `v: true` asks WLED to answer with the new state.
    public static func plan(_ command: LightCommand, current: WLEDState?, capabilities: LightCapabilities) -> WLEDStateUpdate? {
        let cmd = command.normalized(for: capabilities)
        let isOn = current?.on ?? false
        var out = WLEDStateUpdate()

        var power = cmd.on
        var brightness = cmd.brightness
        if let b = brightness, b <= 0 {
            brightness = nil
            if power == nil { power = false }
        }
        if brightness != nil, power == nil, !isOn { power = true }

        var segment = WLEDStateUpdate.Segment(id: current?.primarySegment?.id ?? 0)
        switch cmd.color {
        case .rgb(let c): segment.col = [[Int(c.r), Int(c.g), Int(c.b)]]
        case .rgbw(let c): segment.col = [[Int(c.r), Int(c.g), Int(c.b), Int(c.w)]]
        default: break
        }
        if let effect = cmd.effect, let fx = Int(effect), fx >= 0 {
            segment.fx = fx
        } else if segment.col != nil {
            segment.fx = 0
        }
        // An effect on an off light switches it on (as LIFX waveforms do); a bare colour does not.
        if cmd.effect != nil, segment.fx != nil, power == nil, !isOn { power = true }

        out.on = power
        if let b = brightness { out.bri = ColorMath.deviceValue(forBrightness: b, in: brightnessRange) }
        if segment.col != nil || segment.fx != nil { out.seg = [segment] }
        if out.isEmpty { return nil }
        if let ms = cmd.transitionMilliseconds {
            out.tt = min(Int((Double(ms) / 100).rounded()), maxTransitionUnits)
        }
        out.v = true
        return out
    }
}
