import Foundation

/// Untyped JSON used for Meross payloads, whose shape depends on the namespace and firmware
/// (`togglex` is an object on some devices and an array on others, see meross_lan #357).
public enum MerossJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MerossJSON])
    case object([String: MerossJSON])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([MerossJSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: MerossJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Accessors

    public subscript(key: String) -> MerossJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: MerossJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [MerossJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Strings are returned as-is; numbers are formatted (Meross sometimes sends ids as numbers).
    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        default: nil
        }
    }

    /// Integers, integral doubles, booleans (0/1) and numeric strings.
    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): d.isFinite ? Int(d.rounded()) : nil
        case .bool(let b): b ? 1 : 0
        case .string(let s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .double(let d): d != 0
        case .string(let s): ["1", "true", "on"].contains(s.lowercased()) ? true : (["0", "false", "off"].contains(s.lowercased()) ? false : nil)
        default: nil
        }
    }

    // MARK: Encoding

    /// Compact JSON with sorted keys (deterministic; the Meross signature does not cover the body).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func encodedString() -> String { String(decoding: encoded(), as: UTF8.self) }

    public static func decode(_ data: Data) throws -> MerossJSON {
        try JSONDecoder().decode(MerossJSON.self, from: data)
    }
}

extension MerossJSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral
{
    public init(dictionaryLiteral elements: (String, MerossJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }

    public init(arrayLiteral elements: MerossJSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
