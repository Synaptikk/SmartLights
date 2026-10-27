import Foundation
import LightCore

/// What kind of light a Yeelight model is.
public enum YeelightLightKind: String, Sendable, Hashable, Codable {
    /// RGB + colour temperature (bulbs, strips, bedside lamps).
    case color
    /// Tunable white only (ceiling lights, desk lamps, ct bulbs).
    case colorTemperature
    /// Dimmable fixed white (mono bulbs).
    case mono
}

/// Per-model facts. Kelvin ranges follow python-yeelight's `_MODEL_SPECS` (BSD-2-Clause, see NOTICES.md);
/// the light kind follows its `bulb_type` detection (support list first, model as fallback).
public struct YeelightModelSpec: Sendable, Hashable {
    public var minKelvin: Int
    public var maxKelvin: Int
    /// Kind forced by the model regardless of the support list (python-yeelight `bulb_type`).
    public var forcedKind: YeelightLightKind?

    public init(minKelvin: Int, maxKelvin: Int, forcedKind: YeelightLightKind? = nil) {
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
        self.forcedKind = forcedKind
    }

    /// python-yeelight `_MODEL_SPECS` (2021+ GitLab master) plus the model names used by the
    /// Inter-Operation Spec and older firmware (`stripe`, `ceiling`, `bslamp`, `desklamp`).
    public static let table: [String: YeelightModelSpec] = {
        var t: [String: YeelightModelSpec] = [:]
        func add(_ names: [String], _ lo: Int, _ hi: Int, _ kind: YeelightLightKind? = nil) {
            for n in names { t[n] = YeelightModelSpec(minKelvin: lo, maxKelvin: hi, forcedKind: kind) }
        }
        add(["bslamp1", "bslamp2", "bslamp3", "bslamp"], 1700, 6500)
        add(["ceil26", "ceila", "ceilc", "ceiling10", "ceiling13", "ceiling15", "ceiling18", "ceiling19",
             "ceiling1", "ceiling20", "ceiling24", "ceiling2", "ceiling3", "ceiling4", "ceiling6", "ceiling"], 2700, 6500)
        add(["ceild"], 3000, 6500)
        add(["ceiling17"], 3000, 5700)
        add(["ceiling5"], 2700, 5700)
        add(["color", "color1", "color2", "color4", "color5", "strip1", "stripe"], 1700, 6500)
        add(["colorc", "strip2", "strip4", "strip6"], 2700, 6500)
        add(["ct_bulb", "ct2", "lamp15"], 2700, 6500)
        add(["lamp1", "desklamp"], 2700, 5000)
        add(["lamp3"], 4000, 4000, .mono)
        add(["lamp4"], 2600, 5000)
        add(["mono", "mono1", "mono5", "mono6", "monob"], 2700, 2700)
        return t
    }()

    public static func spec(for model: String?) -> YeelightModelSpec? {
        guard let model else { return nil }
        return table[model.lowercased()]
    }

    /// Kind guessed from the model name alone (used when the support list is unknown).
    public static func kind(forModel model: String?) -> YeelightLightKind? {
        guard let m = model?.lowercased(), !m.isEmpty else { return nil }
        if let forced = spec(for: m)?.forcedKind { return forced }
        if m.hasPrefix("mono") { return .mono }
        if m.hasPrefix("color") || m.hasPrefix("strip") || m.hasPrefix("bslamp") { return .color }
        if spec(for: m) != nil { return .colorTemperature }
        return nil
    }
}

/// Capability decoding for Yeelight devices.
public enum YeelightCapabilities {
    /// Light kind from model and `support` list. Order (python-yeelight `bulb_type`): a kind forced
    /// by the model table, then `set_rgb` -> colour, `set_ct_abx` -> tunable white, else mono;
    /// without a support list the model name decides; unknown devices are assumed colour.
    public static func kind(model: String?, support: Set<String>) -> YeelightLightKind {
        if let forced = YeelightModelSpec.spec(for: model)?.forcedKind { return forced }
        if !support.isEmpty {
            if support.contains("set_rgb") || support.contains("set_hsv") { return .color }
            if support.contains("set_ct_abx") { return .colorTemperature }
            return .mono
        }
        return YeelightModelSpec.kind(forModel: model) ?? .color
    }

    /// Like `kind(model:support:)`, but when neither the support list nor the model is known, uses
    /// python-yeelight's property heuristic on a `get_prop` result (unsupported properties come back
    /// empty and are absent here): no `rgb` but `ct` -> tunable white; none of `ct`/`rgb`/`hue`/`sat`
    /// -> mono; otherwise colour.
    public static func kind(model: String?, support: Set<String>, properties: [String: YeelightValue]) -> YeelightLightKind {
        if YeelightModelSpec.spec(for: model)?.forcedKind != nil || !support.isEmpty || YeelightModelSpec.kind(forModel: model) != nil {
            return kind(model: model, support: support)
        }
        guard !properties.isEmpty else { return .color }
        let has = { (key: String) in properties[key] != nil }
        if !has("rgb") && has("ct") { return .colorTemperature }
        if !has("ct") && !has("rgb") && !has("hue") && !has("sat") { return .mono }
        return .color
    }

    /// Kelvin range: model table, else the python-yeelight fallback for the kind
    /// (colour 1700-6500 K, tunable white 2700-6500 K).
    public static func kelvinRange(model: String?, kind: YeelightLightKind) -> ClosedRange<Int>? {
        if kind == .mono { return nil }
        if let spec = YeelightModelSpec.spec(for: model), spec.minKelvin < spec.maxKelvin {
            return spec.minKelvin...spec.maxKelvin
        }
        return kind == .color ? 1700...6500 : 2700...6500
    }

    /// `LightCapabilities` for a device (HA yeelight: colour bulbs expose CT + HS + RGB).
    public static func capabilities(model: String?, support: Set<String>) -> LightCapabilities {
        capabilities(model: model, kind: kind(model: model, support: support))
    }

    /// `LightCapabilities` for an already decided kind.
    public static func capabilities(model: String?, kind: YeelightLightKind) -> LightCapabilities {
        let range = kelvinRange(model: model, kind: kind)
        let modes: Set<ColorMode>
        switch kind {
        case .color: modes = [.colorTemp, .hs, .rgb]
        case .colorTemperature: modes = [.colorTemp]
        case .mono: modes = [.brightness]
        }
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: range?.lowerBound,
            maxKelvin: range?.upperBound,
            supportsTransition: true,
            supportsEffects: false
        )
    }

    /// Whether the device accepts `method`. An empty support list (unknown) accepts everything.
    public static func supports(_ method: String, in support: Set<String>) -> Bool {
        support.isEmpty || support.contains(method)
    }
}
