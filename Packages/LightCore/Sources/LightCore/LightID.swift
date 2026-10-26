import Foundation

/// Stable identity of a light: `"<brand>:<stableId>"`, e.g. `"wiz:a8bb5006033d"`, `"hue:<uuid>"`.
///
/// The stable id is the vendor's durable identifier (Hue resource uuid, WiZ MAC, AiDot devId),
/// never an IP address (PLAN.md D10). It may itself contain `:`; only the first `:` separates
/// the brand prefix. Encodes as a single JSON string and can be used as a dictionary key in JSON.
public struct LightID: Hashable, Sendable, Comparable {
    public let brand: Brand
    public let stableId: String

    /// Creates an id. Returns nil if `stableId` is empty or contains whitespace/newlines.
    public init?(brand: Brand, stableId: String) {
        guard Self.isValidStableId(stableId) else { return nil }
        self.brand = brand
        self.stableId = stableId
    }

    /// Parses `"<brand>:<stableId>"`. The brand prefix is matched case-insensitively.
    public init?(_ string: String) {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let prefix = string[..<colon].lowercased()
        let rest = String(string[string.index(after: colon)...])
        guard let brand = Brand(rawValue: prefix) else { return nil }
        self.init(brand: brand, stableId: rest)
    }

    /// Parses or throws `LightCoreError.invalidLightID`.
    public static func parse(_ string: String) throws -> LightID {
        guard let id = LightID(string) else { throw LightCoreError.invalidLightID(string) }
        return id
    }

    /// `"<brand>:<stableId>"`.
    public var rawValue: String { "\(brand.rawValue):\(stableId)" }

    public static func < (lhs: LightID, rhs: LightID) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func isValidStableId(_ s: String) -> Bool {
        !s.isEmpty && !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

extension LightID: LosslessStringConvertible, CustomStringConvertible {
    public var description: String { rawValue }
}

extension LightID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = LightID(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid LightID '\(string)'")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension LightID: CodingKeyRepresentable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { Key(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(codingKey.stringValue)
    }
}
