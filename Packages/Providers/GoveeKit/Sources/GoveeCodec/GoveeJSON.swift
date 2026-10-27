import Foundation

/// An arbitrary JSON value. Govee capability values are integers, structs or scene objects
/// depending on the capability, so they are carried untyped.
public enum GoveeJSONValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([GoveeJSONValue])
    case object([String: GoveeJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self), !Self.looksNumeric(container) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([GoveeJSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: GoveeJSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    /// Foundation on Linux decodes `0`/`1` as `Bool`; only accept a Bool when it is not also an Int.
    private static func looksNumeric(_ container: any SingleValueDecodingContainer) -> Bool {
        (try? container.decode(Int.self)) != nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// Integer view (Int, integral Double, Bool, numeric String).
    public var intValue: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): v.isFinite ? Int(v) : nil
        case .bool(let v): v ? 1 : 0
        case .string(let v): Int(v)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): v
        case .int(let v): v != 0
        case .string(let v): ["true", "1", "on"].contains(v.lowercased()) ? true : (["false", "0", "off"].contains(v.lowercased()) ? false : nil)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> GoveeJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// True for `null`, `""`, `[]` and `{}` (Govee uses an empty state value for "not queryable").
    public var isEmpty: Bool {
        switch self {
        case .null: true
        case .string(let s): s.isEmpty
        case .array(let a): a.isEmpty
        case .object(let o): o.isEmpty
        default: false
        }
    }

    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an integer that firmware may send as Int, Double, Bool or numeric String.
    func lenientInt(_ key: Key) -> Int? {
        guard let value = try? decodeIfPresent(GoveeJSONValue.self, forKey: key) else { return nil }
        return value.intValue
    }

    /// Decodes a string that may be sent as a number.
    func lenientString(_ key: Key) -> String? {
        guard let value = try? decodeIfPresent(GoveeJSONValue.self, forKey: key) else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
}

enum GoveeJSONCoding {
    /// Compact, key-sorted encoder (stable wire bytes for tests).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
