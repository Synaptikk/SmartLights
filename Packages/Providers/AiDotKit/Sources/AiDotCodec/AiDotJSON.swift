import Foundation

/// Minimal ordered JSON value.
///
/// python-aidot serialises with `json.dumps(dict)` (separators `", "`/`": "`, `ensure_ascii=True`,
/// dataclass field order). Ciphertexts are only byte-identical to the Python library if the plaintext
/// is too, so the codec keeps key order and reproduces that formatting in ``pythonDumps()``.
/// Parsing keeps integers and doubles apart and works the same on Linux and Apple platforms.
public enum AiDotJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AiDotJSON])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: AiDotJSON
        public init(_ key: String, _ value: AiDotJSON) {
            self.key = key
            self.value = value
        }
    }

    /// Ordered object from key/value pairs (later duplicates replace earlier ones in place).
    public static func obj(_ pairs: KeyValuePairs<String, AiDotJSON>) -> AiDotJSON {
        var members: [Member] = []
        for (k, v) in pairs {
            if let i = members.firstIndex(where: { $0.key == k }) { members[i].value = v } else { members.append(Member(k, v)) }
        }
        return .object(members)
    }

    // MARK: Accessors

    public subscript(key: String) -> AiDotJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    public subscript(index: Int) -> AiDotJSON? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var members: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var arrayValue: [AiDotJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Strict string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// String, or a number rendered as a string (cloud ids are sometimes numeric).
    public var looseString: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    /// Integer from an int, an integral double, a numeric string or a bool (cloud `properties`
    /// values are typed `str` in python-aidot but arrive as numbers from devices).
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.isFinite && d == d.rounded() && abs(d) < 9e15 ? Int(d) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite, d == d.rounded(), abs(d) < 9e15 { return Int(d) }
            return nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .string(let s): ["true", "1"].contains(s.lowercased()) ? true : (["false", "0"].contains(s.lowercased()) ? false : nil)
        default: nil
        }
    }

    /// Returns a copy with `key` set (appended if new, replaced in place otherwise).
    public func setting(_ key: String, _ value: AiDotJSON) -> AiDotJSON {
        guard case .object(var members) = self else { return self }
        if let i = members.firstIndex(where: { $0.key == key }) { members[i].value = value } else { members.append(Member(key, value)) }
        return .object(members)
    }

    // MARK: Serialisation

    /// `json.dumps(value)` with Python's defaults (`", "`, `": "`, `ensure_ascii=True`).
    public func pythonDumps() -> String {
        var out = ""
        write(into: &out, itemSeparator: ", ", keySeparator: ": ")
        return out
    }

    /// Compact form (`","`, `":"`), e.g. for HTTP bodies.
    public func compactString() -> String {
        var out = ""
        write(into: &out, itemSeparator: ",", keySeparator: ":")
        return out
    }

    public var pythonData: Data { Data(pythonDumps().utf8) }

    private func write(into out: inout String, itemSeparator: String, keySeparator: String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += Self.formatDouble(d)
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += itemSeparator }
                item.write(into: &out, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += itemSeparator }
                Self.writeString(m.key, into: &out)
                out += keySeparator
                m.value.write(into: &out, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            out += "}"
        }
    }

    private static func formatDouble(_ d: Double) -> String {
        guard d.isFinite else { return d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity") }
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    private static let hexDigits = Array("0123456789abcdef")

    /// Python `json` string escaping with `ensure_ascii=True`.
    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                out += "\\u"
                out.append(hexDigits[Int(unit >> 12) & 0xF])
                out.append(hexDigits[Int(unit >> 8) & 0xF])
                out.append(hexDigits[Int(unit >> 4) & 0xF])
                out.append(hexDigits[Int(unit) & 0xF])
            }
        }
        out += "\""
    }

    // MARK: Parsing

    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public var offset: Int
        public var reason: String
        public var description: String { "JSON parse error at \(offset): \(reason)" }
    }

    public static func parse(_ data: Data) throws -> AiDotJSON {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> AiDotJSON {
        try parse(Data(string.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            // Skip a UTF-8 BOM.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { self.bytes = Array(bytes.dropFirst(3)) } else { self.bytes = bytes }
        }

        func fail(_ reason: String) -> ParseError { ParseError(offset: i, reason: reason) }

        mutating func parseDocument() throws -> AiDotJSON {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard i == bytes.count else { throw fail("trailing characters") }
            return value
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func parseValue(depth: Int) throws -> AiDotJSON {
            guard depth < 64 else { throw fail("nesting too deep") }
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard i + lit.count <= bytes.count, Array(bytes[i..<i + lit.count]) == lit else { throw fail("expected \(literal)") }
            i += lit.count
        }

        mutating func parseObject(depth: Int) throws -> AiDotJSON {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(Member(key, value))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> AiDotJSON {
            i += 1
            var items: [AiDotJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func parseHex4() throws -> UInt16 {
            guard i + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw fail("bad \\u escape")
            }
            i += 4
            return v
        }

        mutating func parseString() throws -> String {
            i += 1
            var buffer: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let c = bytes[i]
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return String(decoding: buffer, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard i < bytes.count else { throw fail("bad escape") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): buffer.append(0x22)
                    case UInt8(ascii: "\\"): buffer.append(0x5C)
                    case UInt8(ascii: "/"): buffer.append(0x2F)
                    case UInt8(ascii: "b"): buffer.append(0x08)
                    case UInt8(ascii: "f"): buffer.append(0x0C)
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "u"):
                        var units = [try parseHex4()]
                        if (0xD800...0xDBFF).contains(units[0]), i + 1 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            units.append(try parseHex4())
                        }
                        let s = String(decoding: units, as: UTF16.self)
                        buffer.append(contentsOf: Array(s.utf8))
                    default: throw fail("bad escape")
                    }
                default:
                    buffer.append(c)
                }
            }
        }

        mutating func parseNumber() throws -> AiDotJSON {
            let start = i
            var isInteger = true
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            while i < bytes.count {
                let c = bytes[i]
                if c >= 0x30 && c <= 0x39 { i += 1; continue }
                if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+")
                    || (c == UInt8(ascii: "-") && i > start) {
                    isInteger = false
                    i += 1
                    continue
                }
                break
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard !text.isEmpty, text != "-" else { throw fail("unexpected character") }
            if isInteger, let v = Int64(text) { return .int(v) }
            guard let d = Double(text) else { throw fail("bad number \(text)") }
            return .double(d)
        }
    }
}

extension AiDotJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: AiDotJSON...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

extension AiDotJSON {
    /// `.int` from a platform `Int`.
    public static func integer(_ v: Int) -> AiDotJSON { .int(Int64(v)) }
}
