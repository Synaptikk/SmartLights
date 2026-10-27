import Foundation

/// Minimal JSON value for the Kasa (IOT) and Tapo (SMART) JSON protocols.
///
/// Both protocols nest arbitrary objects (`{"system":{"get_sysinfo":{}}}`), so requests and
/// responses are handled as values rather than fixed `Codable` structs. Parsing keeps integers
/// and doubles apart and behaves the same on Linux and Apple platforms (no `JSONSerialization`
/// `NSNumber` bridging). ``compact`` serialises with sorted keys and no whitespace, so encoded
/// requests are deterministic (devices do not care about key order).
public enum TPLinkJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([TPLinkJSON])
    case object([String: TPLinkJSON])

    // MARK: Accessors

    public subscript(key: String) -> TPLinkJSON? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var objectValue: [String: TPLinkJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [TPLinkJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Integer from an int, an integral double or a bool (Kasa uses `0`/`1` for flags).
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.isFinite && d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Bool from a bool or a `0`/`1` number.
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        default: return nil
        }
    }

    // MARK: Building

    public static func obj(_ pairs: KeyValuePairs<String, TPLinkJSON>) -> TPLinkJSON {
        var members: [String: TPLinkJSON] = [:]
        for (k, v) in pairs { members[k] = v }
        return .object(members)
    }

    public static let emptyObject = TPLinkJSON.object([:])

    // MARK: Serialisation

    /// Compact JSON (`{"a":1}`), keys sorted.
    public var compact: String {
        var out = ""
        write(into: &out)
        return out
    }

    public var data: Data { Data(compact.utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 {
                out += String(Int64(d))
            } else if d.isFinite {
                out += String(d)
            } else {
                out += "null"
            }
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, key) in members.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                members[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
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
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing

    /// Parses UTF-8 JSON. Throws `TPLinkCodecError.invalidJSON`.
    public static func parse(_ data: Data) throws -> TPLinkJSON {
        do {
            return try JSONDecoder().decode(TPLinkJSON.self, from: data)
        } catch {
            throw TPLinkCodecError.invalidJSON(String(decoding: data.prefix(120), as: UTF8.self))
        }
    }

    public static func parse(_ string: String) throws -> TPLinkJSON {
        try parse(Data(string.utf8))
    }
}

extension TPLinkJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([TPLinkJSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: TPLinkJSON].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension TPLinkJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: TPLinkJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, TPLinkJSON)...) {
        var members: [String: TPLinkJSON] = [:]
        for (k, v) in elements { members[k] = v }
        self = .object(members)
    }
}

/// Errors from the codec. Messages never contain credentials or keys.
public enum TPLinkCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case truncatedFrame(expected: Int, actual: Int)
    case frameTooLarge(Int)
    case badCiphertext(String)
    case badHandshake(String)
    case missingField(String)
    /// IOT `err_code` != 0 (target, command, code, message).
    case iotError(target: String, command: String, code: Int, message: String?)
    /// SMART `error_code` != 0.
    case smartError(method: String, code: TPLinkSmartErrorCode)

    public var description: String {
        switch self {
        case .invalidJSON(let s): "invalid JSON: \(s)"
        case .truncatedFrame(let e, let a): "truncated frame (expected \(e) bytes, got \(a))"
        case .frameTooLarge(let n): "frame of \(n) bytes is too large"
        case .badCiphertext(let s): "cannot decrypt: \(s)"
        case .badHandshake(let s): "KLAP handshake: \(s)"
        case .missingField(let s): "missing field \(s)"
        case .iotError(let t, let c, let code, let m): "\(t).\(c) failed with err_code \(code)\(m.map { " (\($0))" } ?? "")"
        case .smartError(let m, let code): "\(m) failed with error_code \(code.rawValue) (\(code.name))"
        }
    }
}
