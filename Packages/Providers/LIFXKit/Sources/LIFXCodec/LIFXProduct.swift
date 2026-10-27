import Foundation

/// Product features from the LIFX product registry (`products.json`).
public struct LIFXFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let color = LIFXFeatures(rawValue: 1 << 0)
    public static let infrared = LIFXFeatures(rawValue: 1 << 1)
    public static let multizone = LIFXFeatures(rawValue: 1 << 2)
    public static let extendedMultizone = LIFXFeatures(rawValue: 1 << 3)
    public static let chain = LIFXFeatures(rawValue: 1 << 4)
    public static let matrix = LIFXFeatures(rawValue: 1 << 5)
    public static let hev = LIFXFeatures(rawValue: 1 << 6)
    public static let relays = LIFXFeatures(rawValue: 1 << 7)
    public static let buttons = LIFXFeatures(rawValue: 1 << 8)

    /// Names for diagnostics/metadata.
    public var names: [String] {
        let all: [(LIFXFeatures, String)] = [
            (.color, "color"), (.infrared, "infrared"), (.multizone, "multizone"),
            (.extendedMultizone, "extended_multizone"), (.chain, "chain"), (.matrix, "matrix"),
            (.hev, "hev"), (.relays, "relays"), (.buttons, "buttons"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

/// Host firmware version (`StateHostFirmware` major.minor).
public struct LIFXFirmwareVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `"3.70"` / `"4.110"` (mDNS `fw` TXT record).
    public init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    public static func < (lhs: LIFXFirmwareVersion, rhs: LIFXFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// A firmware-dependent feature change from `products.json` `upgrades`.
public struct LIFXProductUpgrade: Hashable, Sendable {
    public var minimum: LIFXFirmwareVersion
    public var adds: LIFXFeatures
    public var kelvinRange: ClosedRange<Int>?

    public init(major: Int, minor: Int, adds: LIFXFeatures = [], kelvin: ClosedRange<Int>? = nil) {
        self.minimum = LIFXFirmwareVersion(major: major, minor: minor)
        self.adds = adds
        self.kelvinRange = kelvin
    }
}

/// One entry of the LIFX product registry (trimmed: features + temperature range).
public struct LIFXProduct: Hashable, Sendable {
    public var vendor: UInt32
    public var product: UInt32
    public var name: String
    public var features: LIFXFeatures
    /// Supported colour temperature; nil for products without a light (Switch).
    public var kelvinRange: ClosedRange<Int>?
    public var upgrades: [LIFXProductUpgrade]
    /// False for the fallback returned by `lookup` for ids missing from the registry.
    public var isKnown: Bool

    public init(
        vendor: UInt32,
        product: UInt32,
        name: String,
        features: LIFXFeatures,
        kelvinRange: ClosedRange<Int>?,
        upgrades: [LIFXProductUpgrade] = [],
        isKnown: Bool = true
    ) {
        self.vendor = vendor
        self.product = product
        self.name = name
        self.features = features
        self.kelvinRange = kelvinRange
        self.upgrades = upgrades
        self.isKnown = isKnown
    }

    /// Features and Kelvin range after applying firmware upgrades (`nil` firmware = base table).
    public func resolved(firmware: LIFXFirmwareVersion?) -> LIFXProduct {
        guard let firmware else { return self }
        var out = self
        for upgrade in upgrades where firmware >= upgrade.minimum {
            out.features.formUnion(upgrade.adds)
            if let k = upgrade.kelvinRange { out.kelvinRange = k }
        }
        return out
    }

    public var isLight: Bool { kelvinRange != nil || features.contains(.color) }

    private static let index: [UInt64: LIFXProduct] = {
        var d: [UInt64: LIFXProduct] = [:]
        for p in table { d[key(p.vendor, p.product)] = p }
        return d
    }()

    private static func key(_ vendor: UInt32, _ product: UInt32) -> UInt64 { UInt64(vendor) << 32 | UInt64(product) }

    /// All registry entries (generated from LIFX/products).
    public static var all: [LIFXProduct] { table }

    /// Registry entry for `vendor`/`product`, or nil if unknown.
    public static func find(vendor: UInt32, product: UInt32) -> LIFXProduct? {
        index[key(vendor, product)]
    }

    /// Registry entry, or a conservative fallback for unknown ids (newer products than this
    /// table): a full-colour bulb with 1500...9000 K, which is what every current LIFX light
    /// supports. Regenerate the table with `Scripts/gen_products.py` to pick up new products.
    public static func lookup(vendor: UInt32, product: UInt32) -> LIFXProduct {
        find(vendor: vendor, product: product)
            ?? LIFXProduct(vendor: vendor, product: product, name: "LIFX \(product)", features: [.color],
                           kelvinRange: 1500...9000, isKnown: false)
    }
}
