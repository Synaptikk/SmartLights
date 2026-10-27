import Foundation
import LightCore

/// A Bonjour `_nanoleafapi._tcp` service as seen by the platform browser (platform-neutral, so the
/// TXT mapping is testable on Linux).
public struct NanoleafServiceRecord: Sendable, Hashable {
    /// Service instance name, e.g. `"Shapes 4A2B"`.
    public var name: String
    /// Resolved IPv4 address or host name.
    public var host: String?
    public var port: Int?
    /// TXT record: `id` (device id, MAC-like `"59:7E:43:1A:2B:3C"`), `md` (model), `srcvers` (firmware).
    public var txt: [String: String]

    public init(name: String, host: String?, port: Int?, txt: [String: String]) {
        self.name = name
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// What to send for one `LightCommand`: an optional state write followed by an optional effect select.
public struct NanoleafCommandPlan: Sendable, Hashable {
    public var stateUpdate: NanoleafStateUpdate?
    public var effect: String?

    public init(stateUpdate: NanoleafStateUpdate? = nil, effect: String? = nil) {
        self.stateUpdate = stateUpdate
        self.effect = effect
    }

    public var isEmpty: Bool { (stateUpdate?.isEmpty ?? true) && effect == nil }
}

/// Mapping between Open API payloads and LightCore types.
public enum NanoleafMapper {
    /// Colour temperature range used when the controller reports none or a nonsensical one
    /// (early Light Panels firmware returned `ct: {min: 0, max: 100}`).
    public static let defaultKelvinRange = 1200...6500
    public static let defaultBrightnessRange = 0...100

    // MARK: - Identity

    /// Stable id per controller: `serialNo` from the info, else the Bonjour `id` TXT value
    /// (never an IP address). Whitespace is stripped; returns nil when neither is usable.
    public static func stableID(serialNo: String?, bonjourID: String?) -> String? {
        for candidate in [serialNo, bonjourID] {
            guard let candidate else { continue }
            let cleaned = String(candidate.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            if !cleaned.isEmpty, !cleaned.contains("/") { return cleaned }
        }
        return nil
    }

    public static func lightID(stableID: String) -> LightID? {
        LightID(brand: .nanoleaf, stableId: stableID)
    }

    /// Whether `host` is acceptable: IPv4 literal or host name. IPv6 literals are rejected because
    /// firmware >= 8.5.2 advertises IPv6 addresses that do not answer API requests (openHAB note).
    public static func isUsableHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && !h.contains(":") && !h.contains("%") && !h.contains("/") && !h.contains(" ")
    }

    /// Parses a user-typed `"host"` or `"host:port"` (IPv4/host name only).
    public static func parseManualHost(_ input: String) -> (host: String, port: Int)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasSuffix("/") { text.removeLast() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return isUsableHost(text) ? (text, NanoleafAPI.port) : nil
        case 2:
            let host = String(parts[0])
            guard isUsableHost(host), let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
            return (host, port)
        default:
            return nil // IPv6 literal
        }
    }

    // MARK: - Capabilities and state

    /// Effects as LightCore descriptors (special `*Solid*`/`*Static*`/`*Dynamic*` names and
    /// duplicates removed, order kept).
    public static func effectDescriptors(_ names: [String]) -> [EffectDescriptor] {
        var seen = Set<String>()
        var out: [EffectDescriptor] = []
        for name in names where !isSpecialEffect(name) && !name.isEmpty && seen.insert(name).inserted {
            out.append(EffectDescriptor(id: name, name: name, isFast: isFastEffect(name)))
        }
        return out
    }

    /// `*Solid*`, `*Static*`, `*Dynamic*`, ...: pseudo effects, not user-selectable.
    public static func isSpecialEffect(_ name: String) -> Bool {
        name.hasPrefix("*") && name.hasSuffix("*")
    }

    /// Heuristic for the photosensitivity warning: Nanoleaf does not mark effect speed, so names that
    /// suggest strobing or rapid flashing are flagged. **[verify]** against real effect lists.
    public static func isFastEffect(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["strobe", "flash", "fireworks", "party", "rave", "disco", "lightning", "glitch"].contains {
            lower.contains($0)
        }
    }

    public static func kelvinRange(_ state: NanoleafState?) -> ClosedRange<Int> {
        guard let range = state?.ct?.range, range.lowerBound >= 1000, range.upperBound <= 10000 else {
            return defaultKelvinRange
        }
        return range
    }

    public static func brightnessRange(_ state: NanoleafState?) -> ClosedRange<Int> {
        state?.brightness?.range ?? defaultBrightnessRange
    }

    /// Every Open API controller is full colour (hs) + tunable white (ct), with brightness fades
    /// (transition) and stored effects.
    public static func capabilities(for info: NanoleafInfo?) -> LightCapabilities {
        let kelvin = kelvinRange(info?.state)
        let effects = effectDescriptors(info?.effects?.effectsList ?? [])
        return LightCapabilities(
            supportedColorModes: [.hs, .colorTemp],
            minKelvin: kelvin.lowerBound,
            maxKelvin: kelvin.upperBound,
            supportsTransition: true,
            supportsEffects: true,
            effects: effects
        )
    }

    public static func brightness(fromDevice value: Int, in range: ClosedRange<Int>) -> Double {
        guard range.upperBound > range.lowerBound else { return value > 0 ? 1 : 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return Double(clamped - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    public static func deviceBrightness(_ brightness: Double, in range: ClosedRange<Int>) -> Int {
        let b = brightness.isFinite ? min(max(brightness, 0), 1) : 0
        return range.lowerBound + Int((b * Double(range.upperBound - range.lowerBound)).rounded())
    }

    /// LightState from the controller state. `colorMode == "effect"` reports the selected effect name
    /// (unless it is a pseudo effect) and the hs values as a hint.
    public static func lightState(
        from info: NanoleafInfo?, reachable: Bool = true, updatedAt: Date = Date()
    ) -> LightState {
        let state = info?.state
        var out = LightState(isOn: state?.on?.value ?? false, reachable: reachable, updatedAt: updatedAt)
        if let b = state?.brightness {
            out.brightness = brightness(fromDevice: b.value, in: brightnessRange(state))
        }
        let hs: HS? = state?.hue.map { hue in
            HS(h: Double(hue.value), s: Double(state?.sat?.value ?? 0) / 100).clamped
        }
        let kelvin = state?.ct.flatMap { ct in
            ct.value >= 1000 ? min(max(ct.value, kelvinRange(state).lowerBound), kelvinRange(state).upperBound) : nil
        }
        switch state?.mode {
        case .ct:
            out.colorMode = kelvin == nil ? nil : .colorTemp
            out.kelvin = kelvin
        case .hs:
            out.colorMode = hs == nil ? nil : .hs
            out.hs = hs
        case .effect:
            out.colorMode = hs == nil ? nil : .hs
            out.hs = hs
            if let select = info?.effects?.select, !isSpecialEffect(select), !select.isEmpty {
                out.effect = select
            }
        case nil:
            if let hs {
                out.colorMode = .hs
                out.hs = hs
            } else if let kelvin {
                out.colorMode = .colorTemp
                out.kelvin = kelvin
            }
        }
        return out
    }

    /// The `Light` for one controller.
    public static func light(
        info: NanoleafInfo?,
        stableID: String,
        fallbackName: String? = nil,
        host: String?,
        port: Int,
        reachable: Bool = true,
        updatedAt: Date = Date()
    ) -> Light? {
        guard let id = lightID(stableID: stableID) else { return nil }
        let name = [info?.name, fallbackName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Nanoleaf"
        return Light(
            id: id,
            name: name,
            capabilities: capabilities(for: info),
            state: lightState(from: info, reachable: reachable, updatedAt: updatedAt),
            providerRef: host.map { "\($0):\(port)" } ?? "",
            manufacturer: info?.manufacturer ?? "Nanoleaf",
            model: info?.model
        )
    }

    // MARK: - Commands

    /// Whole seconds for the Open API `duration` field (rounded; nil when no transition).
    public static func transitionSeconds(_ transition: Duration?) -> Int? {
        guard let transition else { return nil }
        let c = transition.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded())
    }

    /// Translates a command into Open API writes. Call `command.normalized(for:)` first (the provider
    /// does); this only formats.
    ///
    /// - `on: false` sends only `on` (the Open API has no fade for power).
    /// - brightness 0 without `on` turns the panels off (matches `LightState.applying`).
    /// - brightness with a transition is sent as `brightness {value, duration}` without `on`, which
    ///   turns the panels on and fades (HA nanoleaf behaviour); without a transition `on: true` is
    ///   included explicitly.
    /// - hs → `hue` 0-359 + `sat` 0-100; Kelvin → `ct` clamped to the controller's range.
    /// - an effect is selected after the state write.
    public static func plan(for command: LightCommand, capabilities: LightCapabilities,
                            brightnessRange: ClosedRange<Int> = defaultBrightnessRange) -> NanoleafCommandPlan {
        var update = NanoleafStateUpdate()
        if command.on == false {
            update.on = false
            return NanoleafCommandPlan(stateUpdate: update)
        }
        let seconds = transitionSeconds(command.transition)
        let fades = (seconds ?? 0) > 0
        if let b = command.brightness {
            if b <= 0, command.on == nil {
                update.on = false
                return NanoleafCommandPlan(stateUpdate: update)
            }
            update.brightness = deviceBrightness(b, in: brightnessRange)
            if fades { update.duration = seconds } else { update.on = true }
        } else if command.on == true {
            update.on = true
        }
        switch command.color {
        case .hs(let hs)?:
            let c = hs.clamped
            update.hue = Int(c.h.rounded()) % 360
            update.sat = Int((c.s * 100).rounded())
        case .kelvin(let k)?:
            update.ct = capabilities.clampKelvin(k)
        default:
            break // normalisation leaves only hs/kelvin for Nanoleaf
        }
        return NanoleafCommandPlan(stateUpdate: update.isEmpty ? nil : update, effect: command.effect)
    }

    // MARK: - Scenes (effects)

    /// `"nanoleaf:<stableID>/<effect name>"`.
    public static func sceneID(stableID: String, effect: String) -> String {
        "\(Brand.nanoleaf.rawValue):\(stableID)/\(effect)"
    }

    public static func parseSceneID(_ id: String) -> (stableID: String, effect: String)? {
        let prefix = "\(Brand.nanoleaf.rawValue):"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let stable = String(rest[..<slash])
        let effect = String(rest[rest.index(after: slash)...])
        guard !stable.isEmpty, !effect.isEmpty else { return nil }
        return (stable, effect)
    }

    /// Every stored effect of a controller as a vendor scene.
    public static func scenes(info: NanoleafInfo?, stableID: String, roomHint: String? = nil) -> [LightScene] {
        guard let id = lightID(stableID: stableID) else { return [] }
        return effectDescriptors(info?.effects?.effectsList ?? []).map { effect in
            LightScene(
                id: sceneID(stableID: stableID, effect: effect.id),
                name: effect.name,
                kind: .vendor,
                brand: .nanoleaf,
                roomHint: roomHint,
                lightIDs: [id]
            )
        }
    }

    // MARK: - Discovery

    /// Bonjour service → DiscoveredDevice. Id is the TXT `id` (stable), else a provisional
    /// `"ip:<host>"`. Returns nil for services without a usable IPv4/host name.
    public static func discoveredDevice(from record: NanoleafServiceRecord, at date: Date = Date()) -> DiscoveredDevice? {
        guard let host = record.host, isUsableHost(host) else { return nil }
        var metadata: [String: String] = [:]
        let bonjourID = record.txt["id"].flatMap { stableID(serialNo: nil, bonjourID: $0) }
        if let bonjourID { metadata["id"] = bonjourID }
        if let model = record.txt["md"] { metadata["model"] = model }
        if let fw = record.txt["srcvers"] { metadata["firmware"] = fw }
        metadata["service"] = record.name
        return DiscoveredDevice(
            id: bonjourID ?? "ip:\(host)",
            brand: .nanoleaf,
            name: record.name,
            model: record.txt["md"],
            host: host,
            port: record.port ?? NanoleafAPI.port,
            macAddress: bonjourID.flatMap(macAddress(fromDeviceID:)),
            method: .bonjour,
            metadata: metadata,
            discoveredAt: date
        )
    }

    /// The TXT `id` is MAC-formatted on most controllers; returns it lowercased if it looks like one.
    public static func macAddress(fromDeviceID id: String) -> String? {
        let parts = id.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return id.lowercased()
    }
}
