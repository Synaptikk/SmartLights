// Minimal order-preserving JSON value used by all fakes.
//
// Real devices emit keys in a fixed order and WiZ signs the *compact* JSON of
// `params`, so we keep insertion order and serialise exactly like Python's
// `json.dumps(obj, separators=(",", ":"))` for ASCII content.

import Foundation

public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// Ordered JSON object.
public struct JSONObject: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSON
    }

    public private(set) var members: [Member] = []

    public init() {}
    public init(_ pairs: [(String, JSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }
    public var count: Int { members.count }

    public subscript(key: String) -> JSON? {
        get { members.first(where: { $0.key == key })?.value }
        set {
            if let idx = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[idx].value = newValue } else { members.remove(at: idx) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }

    /// Recursively merges `other` into self (objects merge, everything else replaces).
    public mutating func deepMerge(_ other: JSONObject) {
        for m in other.members {
            if case .object(let mine)? = self[m.key], case .object(let theirs) = m.value {
                var merged = mine
                merged.deepMerge(theirs)
                self[m.key] = .object(merged)
            } else {
                self[m.key] = m.value
            }
        }
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self.init(elements)
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Accessors

extension JSON {
    public subscript(key: String) -> JSON? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            if case .object(var o) = self { o[key] = newValue; self = .object(o) }
        }
    }

    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int(d)
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
    public var isNull: Bool { self == .null }
}

// MARK: - Serialisation

extension JSON {
    /// Compact serialisation (`separators=(",", ":")`), non-ASCII escaped as `\uXXXX` like Python.
    public var compact: String {
        var out = ""
        write(to: &out)
        return out
    }

    public var compactBytes: [UInt8] { Array(compact.utf8) }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 {
                out += String(format: "%.1f", d)
            } else if d.isFinite {
                out += "\(d)"
            } else {
                out += "null"
            }
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, m) in o.members.enumerated() {
                if i > 0 { out += "," }
                JSON.writeString(m.key, to: &out)
                out += ":"
                m.value.write(to: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.utf16 {
            switch u {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(u)))
            default: out += String(format: "\\u%04x", u)
            }
        }
        out += "\""
    }
}

extension JSONObject {
    public var compact: String { JSON.object(self).compact }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public var offset: Int
    public var reason: String
    public var description: String { "JSON parse error at \(offset): \(reason)" }
}

extension JSON {
    public static func parse(_ string: String) throws -> JSON {
        try parse(Array(string.utf8))
    }

    public static func parse<C: Collection>(_ bytes: C) throws -> JSON where C.Element == UInt8 {
        var p = JSONParser(bytes: Array(bytes))
        return try p.parseDocument().value
    }

    /// Parses a top-level object and also returns the raw byte range of each
    /// top-level member value (used to verify signatures over the exact bytes sent).
    public static func parseWithRawMembers<C: Collection>(_ bytes: C) throws -> (JSON, [String: [UInt8]])
    where C.Element == UInt8 {
        var p = JSONParser(bytes: Array(bytes))
        let result = try p.parseDocument()
        var raw: [String: [UInt8]] = [:]
        for (k, r) in result.topLevelRanges { raw[k] = Array(p.bytes[r]) }
        return (result.value, raw)
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> (value: JSON, topLevelRanges: [String: Range<Int>]) {
        skipWS()
        var ranges: [String: Range<Int>] = [:]
        let v: JSON
        if peek() == UInt8(ascii: "{") {
            v = try parseObject(recordRanges: &ranges)
        } else {
            v = try parseValue()
        }
        skipWS()
        guard i == bytes.count else { throw err("trailing characters") }
        return (v, ranges)
    }

    func err(_ r: String) -> JSONParseError { JSONParseError(offset: i, reason: r) }
    func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }

    mutating func skipWS() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func expect(_ c: UInt8) throws {
        guard peek() == c else { throw err("expected '\(Character(Unicode.Scalar(c)))'") }
        i += 1
    }

    mutating func parseValue() throws -> JSON {
        skipWS()
        guard let c = peek() else { throw err("unexpected end") }
        switch c {
        case UInt8(ascii: "{"):
            var ignored: [String: Range<Int>] = [:]
            return try parseObject(recordRanges: &ignored, record: false)
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func literal(_ s: String) throws {
        for b in s.utf8 {
            guard peek() == b else { throw err("bad literal") }
            i += 1
        }
    }

    mutating func parseObject(recordRanges: inout [String: Range<Int>], record: Bool = true) throws -> JSON {
        try expect(UInt8(ascii: "{"))
        var obj = JSONObject()
        skipWS()
        if peek() == UInt8(ascii: "}") { i += 1; return .object(obj) }
        while true {
            skipWS()
            let key = try parseString()
            skipWS()
            try expect(UInt8(ascii: ":"))
            skipWS()
            let start = i
            let v = try parseValue()
            if record { recordRanges[key] = start..<i }
            obj[key] = v
            skipWS()
            guard let c = peek() else { throw err("unterminated object") }
            i += 1
            if c == UInt8(ascii: "}") { return .object(obj) }
            guard c == UInt8(ascii: ",") else { throw err("expected ',' or '}'") }
        }
    }

    mutating func parseArray() throws -> JSON {
        try expect(UInt8(ascii: "["))
        var arr: [JSON] = []
        skipWS()
        if peek() == UInt8(ascii: "]") { i += 1; return .array(arr) }
        while true {
            arr.append(try parseValue())
            skipWS()
            guard let c = peek() else { throw err("unterminated array") }
            i += 1
            if c == UInt8(ascii: "]") { return .array(arr) }
            guard c == UInt8(ascii: ",") else { throw err("expected ',' or ']'") }
        }
    }

    mutating func parseHex4() throws -> UInt16 {
        guard i + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
        else { throw err("bad unicode escape") }
        i += 4
        return v
    }

    mutating func parseString() throws -> String {
        try expect(UInt8(ascii: "\""))
        var utf16: [UInt16] = []
        var raw: [UInt8] = []
        func flushRaw() {
            if !raw.isEmpty { utf16.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16); raw.removeAll() }
        }
        while true {
            guard let c = peek() else { throw err("unterminated string") }
            i += 1
            if c == UInt8(ascii: "\"") { break }
            if c == UInt8(ascii: "\\") {
                flushRaw()
                guard let e = peek() else { throw err("bad escape") }
                i += 1
                switch e {
                case UInt8(ascii: "\""): utf16.append(0x22)
                case UInt8(ascii: "\\"): utf16.append(0x5C)
                case UInt8(ascii: "/"): utf16.append(0x2F)
                case UInt8(ascii: "b"): utf16.append(0x08)
                case UInt8(ascii: "f"): utf16.append(0x0C)
                case UInt8(ascii: "n"): utf16.append(0x0A)
                case UInt8(ascii: "r"): utf16.append(0x0D)
                case UInt8(ascii: "t"): utf16.append(0x09)
                case UInt8(ascii: "u"): utf16.append(try parseHex4())
                default: throw err("bad escape")
                }
            } else {
                if c < 0x20 { throw err("control character in string") }
                raw.append(c)
            }
        }
        flushRaw()
        return String(decoding: utf16, as: UTF16.self)
    }

    mutating func parseNumber() throws -> JSON {
        let start = i
        var isDouble = false
        if peek() == UInt8(ascii: "-") { i += 1 }
        while let c = peek() {
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                i += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
                || c == UInt8(ascii: "+") || (c == UInt8(ascii: "-") && i > start)
            {
                isDouble = true
                i += 1
            } else {
                break
            }
        }
        let s = String(decoding: bytes[start..<i], as: UTF8.self)
        guard !s.isEmpty, s != "-" else { throw err("unexpected character") }
        if !isDouble, let v = Int(s) { return .int(v) }
        guard let d = Double(s) else { throw err("bad number") }
        return .double(d)
    }
}
