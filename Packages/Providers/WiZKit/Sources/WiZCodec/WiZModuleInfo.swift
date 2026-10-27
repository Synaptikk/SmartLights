import Foundation
import LightCore

/// Decoded `getSystemConfig.moduleName` (`ESPxx_<ID>_<rev>`, e.g. `ESP01_SHRGB_03`), following
/// pywizlight `bulblibrary.py` (research_wiz.md §7).
public struct WiZModuleInfo: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `RGB` in the id: full colour + tunable white.
        case rgb
        /// `TW`: tunable white.
        case tunableWhite
        /// Anything else (`DW`, `DIMTRIAC`, ...): dimmable white.
        case dimmable
        /// `SOCKET`: smart plug (on/off).
        case socket
        /// `FANDIM`: ceiling fan module with a dimmable light.
        case fanDimmable
        /// `DDTW`: ceiling fan module with a tunable-white light.
        case fanTunableWhite
    }

    public var moduleName: String
    /// Chip family, e.g. `ESP01`, `ESP25`.
    public var chip: String?
    /// The id segment, e.g. `SHRGB`, `DHRGB`, `SHTW1C`.
    public var identifier: String
    /// Revision suffix, e.g. `03`, `01BT`.
    public var revision: String?
    public var kind: Kind

    public init?(moduleName: String) {
        let name = moduleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        self.moduleName = name
        let parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 {
            chip = parts[0]
            identifier = parts[1].uppercased()
            revision = parts.count >= 3 ? parts[2...].joined(separator: "_") : nil
        } else {
            chip = name.uppercased().hasPrefix("ESP") ? name : nil
            identifier = name.uppercased()
            revision = nil
        }
        kind = Self.kind(for: identifier)
    }

    /// pywizlight order: RGB, then the fan ids, then TW, SOCKET, otherwise dimmable white.
    static func kind(for id: String) -> Kind {
        if id.contains("RGB") { return .rgb }
        if id.contains("DDTW") { return .fanTunableWhite }
        if id.contains("FANDIM") { return .fanDimmable }
        if id.contains("TW") { return .tunableWhite }
        if id.contains("SOCKET") { return .socket }
        return .dimmable
    }

    /// `DH` prefix: dual-head lamp (zones addressed with `devices`).
    public var isDualHead: Bool { identifier.hasPrefix("DH") }
    /// `SH` prefix: single head / strip.
    public var isSingleHead: Bool { identifier.hasPrefix("SH") }
    public var hasFan: Bool { kind == .fanDimmable || kind == .fanTunableWhite }

    /// Best guess when `moduleName` is missing (fw 1.8.0): from the fields `getPilot` returns.
    public static func fallbackKind(pilot: WiZPilot?) -> Kind {
        guard let pilot else { return .rgb }
        if pilot.hasRGB { return .rgb }
        if pilot.temp != nil { return .tunableWhite }
        if pilot.dimming != nil { return .dimmable }
        return .socket
    }
}

/// Builds `LightCapabilities` for a WiZ device.
public enum WiZCapabilities {
    /// Defaults when neither `getModelConfig` nor `getUserConfig` reports a range
    /// (pywizlight defaults: colour bulbs 2200-6500 K, tunable white 2700-6500 K).
    public static let defaultRGBKelvin = 2200...6500
    public static let defaultTunableWhiteKelvin = 2700...6500

    public static func colorModes(for kind: WiZModuleInfo.Kind) -> Set<ColorMode> {
        switch kind {
        case .rgb: [.rgb, .colorTemp]
        case .tunableWhite, .fanTunableWhite: [.colorTemp]
        case .dimmable, .fanDimmable: [.brightness]
        case .socket: [.onOff]
        }
    }

    /// Kelvin range: `cctRange` (min/max of all four values, as pywizlight), else `extRange`
    /// from model or user config, else `whiteRange`, else the per-kind default.
    public static func kelvinRange(kind: WiZModuleInfo.Kind, modelConfig: WiZModelConfig?, userConfig: WiZUserConfig?) -> ClosedRange<Int> {
        let candidates: [[Int]?] = [modelConfig?.cctRange, modelConfig?.extRange, userConfig?.extRange, userConfig?.whiteRange]
        for case let values? in candidates {
            let valid = values.filter { (1000...10000).contains($0) }
            if let lo = valid.min(), let hi = valid.max(), lo < hi { return lo...hi }
        }
        return kind == .rgb ? defaultRGBKelvin : defaultTunableWhiteKelvin
    }

    public static func make(
        kind: WiZModuleInfo.Kind,
        modelConfig: WiZModelConfig? = nil,
        userConfig: WiZUserConfig? = nil
    ) -> LightCapabilities {
        let modes = colorModes(for: kind)
        let kelvin: ClosedRange<Int>? = modes.contains(.colorTemp)
            ? kelvinRange(kind: kind, modelConfig: modelConfig, userConfig: userConfig) : nil
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: kelvin?.lowerBound,
            maxKelvin: kelvin?.upperBound,
            supportsTransition: false,
            supportsEffects: !WiZScenes.effects(for: kind).isEmpty,
            effects: WiZScenes.effects(for: kind)
        )
    }

    /// Convenience from the raw replies; `module` nil falls back to `pilot` inspection.
    public static func make(
        module: WiZModuleInfo?,
        modelConfig: WiZModelConfig?,
        userConfig: WiZUserConfig?,
        pilot: WiZPilot? = nil
    ) -> LightCapabilities {
        make(kind: module?.kind ?? WiZModuleInfo.fallbackKind(pilot: pilot), modelConfig: modelConfig, userConfig: userConfig)
    }
}

/// WiZ dynamic/static scenes (pywizlight `scenes.py`, research_wiz.md §1.5).
public enum WiZScenes {
    public struct Scene: Sendable, Hashable {
        public var id: Int
        public var name: String
        /// Fast colour changes: the UI shows a photosensitivity warning first.
        public var isFast: Bool
    }

    public static let all: [Scene] = {
        let names: [(Int, String)] = [
            (1, "Ocean"), (2, "Romance"), (3, "Sunset"), (4, "Party"), (5, "Fireplace"), (6, "Cozy"),
            (7, "Forest"), (8, "Pastel colors"), (9, "Wake-up"), (10, "Bedtime"), (11, "Warm white"),
            (12, "Daylight"), (13, "Cool white"), (14, "Night light"), (15, "Focus"), (16, "Relax"),
            (17, "True colors"), (18, "TV time"), (19, "Plantgrowth"), (20, "Spring"), (21, "Summer"),
            (22, "Fall"), (23, "Deep dive"), (24, "Jungle"), (25, "Mojito"), (26, "Club"), (27, "Christmas"),
            (28, "Halloween"), (29, "Candlelight"), (30, "Golden white"), (31, "Pulse"), (32, "Steampunk"),
            (33, "Diwali"), (34, "White"), (35, "Alarm"), (36, "Snowy sky"), (40, "Dim-to-warm"),
        ]
        var scenes = names.map { Scene(id: $0.0, name: $0.1, isFast: fastIDs.contains($0.0)) }
        scenes += (1...10).map { Scene(id: 255 + $0, name: "Custom Mode \($0)", isFast: false) }
        scenes.append(Scene(id: 1000, name: "Rhythm", isFast: false))
        return scenes
    }()

    /// Strobing / rapidly changing scenes.
    public static let fastIDs: Set<Int> = [4, 26, 28, 35]
    /// The 17 scenes tunable-white bulbs support.
    public static let tunableWhiteIDs: Set<Int> = [6, 9, 10, 11, 12, 13, 14, 15, 16, 18, 29, 30, 31, 32, 33, 35, 40]
    /// The 8 scenes dimmable-white bulbs support.
    public static let dimmableIDs: Set<Int> = [9, 10, 14, 29, 31, 32, 34, 35]

    public static func scene(id: Int) -> Scene? { all.first { $0.id == id } }
    public static func name(for id: Int) -> String? { scene(id: id)?.name }

    public static func scenes(for kind: WiZModuleInfo.Kind) -> [Scene] {
        switch kind {
        case .rgb: all
        case .tunableWhite, .fanTunableWhite: all.filter { tunableWhiteIDs.contains($0.id) }
        case .dimmable, .fanDimmable: all.filter { dimmableIDs.contains($0.id) }
        case .socket: []
        }
    }

    /// Scenes as `EffectDescriptor`s; the effect id is the scene id as a string (`"4"`).
    public static func effects(for kind: WiZModuleInfo.Kind) -> [EffectDescriptor] {
        scenes(for: kind).map { EffectDescriptor(id: String($0.id), name: $0.name, isFast: $0.isFast) }
    }
}
