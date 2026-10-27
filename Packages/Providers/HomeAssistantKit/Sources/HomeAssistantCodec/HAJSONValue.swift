import Foundation

/// A loosely typed JSON value. Home Assistant messages carry open-ended payloads (`result`,
/// event `data`, state `attributes`, `service_data`) that are kept as-is and read with the
/// typed accessors below.
public enum HAJSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([HAJSONValue])
    case object([String: HAJSONValue])

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
        } else if let v = try? c.decode([HAJSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: HAJSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
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

    public subscript(key: String) -> HAJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: HAJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [HAJSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Numbers as `Double`. HA sometimes sends numeric service data as strings (`"101"`);
    /// those are accepted too.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }

    /// Numbers rounded to the nearest integer.
    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, abs(d) < Double(Int.max) else { return nil }
        return Int(d.rounded())
    }

    public var isNull: Bool { self == .null }

    // MARK: Conversion

    /// Decodes a typed model from this value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Compact JSON with sorted keys (deterministic, used for wire messages and tests).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `encoded()` as a UTF-8 string.
    public func jsonString() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }

    /// Parses JSON text.
    public static func parse(_ data: Data) throws -> HAJSONValue {
        try JSONDecoder().decode(HAJSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> HAJSONValue {
        try parse(Data(text.utf8))
    }
}

extension HAJSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: HAJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, HAJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
