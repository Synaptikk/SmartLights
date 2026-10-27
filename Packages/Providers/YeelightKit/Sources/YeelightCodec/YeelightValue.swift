import Foundation

/// A JSON value as it appears in Yeelight JSON-RPC params, results and notifications.
///
/// Bulbs report most properties as strings (`"bright":"100"`) in `get_prop` results but sometimes
/// as numbers in `props` notifications (`"ct":6500`); use ``intValue``/``stringValue`` which accept
/// both.
public enum YeelightValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([YeelightValue])
    case object([String: YeelightValue])

    /// Integer value of a number or a numeric string (`"100"`, `" 42 "`, `"4.0"`).
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v.isFinite ? Int(v.rounded()) : nil
        case .bool(let v): return v ? 1 : 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let v = Int(t) { return v }
            if let d = Double(t), d.isFinite { return Int(d.rounded()) }
            return nil
        case .null, .array, .object: return nil
        }
    }

    /// String value; numbers are rendered in decimal.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public var objectValue: [String: YeelightValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [YeelightValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Compact JSON text. Object keys are sorted so output is deterministic.
    public var jsonText: String {
        var out = ""
        write(into: &out)
        return out
    }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .int(let v): out += String(v)
        case .double(let v):
            if v.isFinite {
                if v == v.rounded(), abs(v) < 1e15 { out += String(Int(v)) } else { out += String(v) }
            } else {
                out += "null"
            }
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                o[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension YeelightValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension YeelightValue: Codable {
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
        } else if let v = try? c.decode([YeelightValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: YeelightValue].self) {
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
}
