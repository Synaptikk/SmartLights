import Foundation
import LightCore

/// What a TP-Link light model can do, by model prefix. Used before the first state read and as a
/// fallback; the device's own flags (`is_color`, `color_temp_range`, ...) win once known.
///
/// Sources: python-kasa `SUPPORTED.md` and `iot/iotbulb.py` `TPLINK_KELVIN`, the device fixtures in
/// python-kasa's test suite (checked 2026-10-27), TP-Link product pages.
public struct TPLinkModelInfo: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Dimmable white.
        case dimmable
        /// Tunable white.
        case tunable
        /// Colour + tunable white.
        case color
        /// Colour only (no white temperature control).
        case colorOnly
    }

    /// Model prefix, e.g. `KL130`, `L530`.
    public var prefix: String
    public var name: String
    public var kind: Kind
    public var kelvin: ClosedRange<Int>?
    public var isStrip: Bool
    /// Kasa legacy (IOT) or Tapo (SMART) family of the model line.
    public var family: TPLinkConnection.Family

    public init(_ prefix: String, _ name: String, _ kind: Kind, kelvin: ClosedRange<Int>? = nil, strip: Bool = false, family: TPLinkConnection.Family) {
        self.prefix = prefix
        self.name = name
        self.kind = kind
        self.kelvin = kelvin
        self.isStrip = strip
        self.family = family
    }

    public var colorModes: Set<ColorMode> {
        switch kind {
        case .dimmable: [.brightness]
        case .tunable: [.colorTemp]
        case .color: [.hs, .colorTemp]
        case .colorOnly: [.hs]
        }
    }
}

public enum TPLinkModelTable {
    /// Longest prefix first is not needed: prefixes are matched exactly against the model without
    /// its region/length suffix (see `normalizedModel`), then by `hasPrefix` in table order.
    public static let models: [TPLinkModelInfo] = [
        // Kasa bulbs (legacy XOR on TCP 9999; newer firmware may use KLAP)
        TPLinkModelInfo("KL110", "Kasa KL110 dimmable bulb", .dimmable, family: .iot),
        TPLinkModelInfo("KL120", "Kasa KL120 tunable white bulb", .tunable, kelvin: 2700...6500, family: .iot),
        TPLinkModelInfo("KL125", "Kasa KL125 colour bulb", .color, kelvin: 2500...6500, family: .iot),
        TPLinkModelInfo("KL130", "Kasa KL130 colour bulb", .color, kelvin: 2500...9000, family: .iot),
        TPLinkModelInfo("KL135", "Kasa KL135 colour bulb", .color, kelvin: 2500...9000, family: .iot),
        TPLinkModelInfo("LB100", "Kasa LB100 dimmable bulb", .dimmable, family: .iot),
        TPLinkModelInfo("LB110", "Kasa LB110 dimmable bulb", .dimmable, family: .iot),
        TPLinkModelInfo("LB120", "Kasa LB120 tunable white bulb", .tunable, kelvin: 2700...6500, family: .iot),
        TPLinkModelInfo("LB130", "Kasa LB130 colour bulb", .color, kelvin: 2500...9000, family: .iot),
        TPLinkModelInfo("LB230", "Kasa LB230 colour bulb", .color, kelvin: 2500...9000, family: .iot),
        TPLinkModelInfo("KB130", "Kasa KB130 colour bulb", .color, kelvin: 2500...9000, family: .iot),
        // Kasa light strips
        TPLinkModelInfo("KL400", "Kasa KL400 light strip", .color, kelvin: 2500...9000, strip: true, family: .iot),
        TPLinkModelInfo("KL420", "Kasa KL420 light strip", .color, kelvin: 2500...9000, strip: true, family: .iot),
        TPLinkModelInfo("KL430", "Kasa KL430 light strip", .color, kelvin: 2500...9000, strip: true, family: .iot),
        // Tapo bulbs (SMART over KLAP, credentials required)
        TPLinkModelInfo("L510", "Tapo L510 dimmable bulb", .dimmable, family: .smart),
        TPLinkModelInfo("L530", "Tapo L530 colour bulb", .color, kelvin: 2500...6500, family: .smart),
        TPLinkModelInfo("L535", "Tapo L535 colour bulb", .color, kelvin: 2500...6500, family: .smart),
        TPLinkModelInfo("L630", "Tapo L630 colour spot", .color, kelvin: 2200...6500, family: .smart),
        TPLinkModelInfo("L430", "Tapo L430 colour bulb", .color, kelvin: 2500...6500, family: .smart),
        // Tapo light strips (L900 has no white temperature; L920 reports a fixed 9000 K range)
        TPLinkModelInfo("L900", "Tapo L900 light strip", .colorOnly, strip: true, family: .smart),
        TPLinkModelInfo("L920", "Tapo L920 light strip", .colorOnly, strip: true, family: .smart),
        TPLinkModelInfo("L930", "Tapo L930 light strip", .color, kelvin: 2500...6500, strip: true, family: .smart),
    ]

    /// `KL120(US)` -> `KL120`, `L900-5` -> `L900`, `kl400l5(us)` -> `KL400L5`.
    public static func normalizedModel(_ model: String) -> String {
        var m = model.uppercased()
        if let paren = m.firstIndex(of: "(") { m = String(m[..<paren]) }
        if let dash = m.firstIndex(of: "-") { m = String(m[..<dash]) }
        return m.trimmingCharacters(in: .whitespaces)
    }

    /// The table entry for a model string (`KL130(US)`, `L530E(EU)`, `L900-5`), or nil.
    public static func lookup(_ model: String) -> TPLinkModelInfo? {
        let m = normalizedModel(model)
        if let exact = models.first(where: { $0.prefix == m }) { return exact }
        return models.first { m.hasPrefix($0.prefix) }
    }

    /// Kasa KL120(US) only goes to 5000 K (python-kasa `TPLINK_KELVIN`).
    public static func kelvinRange(model: String) -> ClosedRange<Int>? {
        if model.uppercased().hasPrefix("KL120(US)") { return 2700...5000 }
        return lookup(model)?.kelvin
    }
}
