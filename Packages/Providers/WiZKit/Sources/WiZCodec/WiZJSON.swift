import Foundation

/// A JSON value that keeps object member order.
///
/// WiZ signs the *compact* JSON text of `params` (firmware 1.34+), so the exact key order and
/// formatting matter. Serialisation mirrors JavaScript's `JSON.stringify` (as used by
/// `tools/probe/wiz.mjs`): no whitespace, insertion order, non-ASCII emitted as raw UTF-8,
/// control characters escaped as `\b \f \n \r \t` or `\u00xx`.
public enum WiZJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([WiZJSON])
    case object(WiZObject)
}

/// An insertion-ordered JSON object. Setting an existing key keeps its position (like JS
/// object spread `{...params, sigTs}`); setting a new key appends it; setting `nil` removes it.
public struct WiZObject: Sendable, Hashable, Sequence {
    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: WiZJSON

        public init(key: String, value: WiZJSON) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var members: [Member] = []

    public init() {}

    public init(_ pairs: [(String, WiZJSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }
    public var count: Int { members.count }

    public subscript(key: String) -> WiZJSON? {
        get { members.first(where: { $0.key == key })?.value }
        set {
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[Member]> { members.makeIterator() }

    /// Compact JSON text (see ``WiZJSON``).
    public var compactString: String { WiZJSON.object(self).compactString }
    /// Compact JSON as UTF-8 bytes.
    public var compactData: Data { Data(compactString.utf8) }

    // Typed accessors (lenient: WiZ firmware mixes ints, bools and numeric strings).
    public func int(_ key: String) -> Int? { self[key]?.intValue }
    public func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    public func string(_ key: String) -> String? { self[key]?.stringValue }
    public func ints(_ key: String) -> [Int]? { self[key]?.arrayValue?.compactMap(\.intValue) }
    public func object(_ key: String) -> WiZObject? { self[key]?.objectValue }
}

extension WiZObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, WiZJSON)...) { self.init(elements) }
}

extension WiZJSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    public init(dictionaryLiteral elements: (String, WiZJSON)...) { self = .object(WiZObject(elements)) }
    public init(arrayLiteral elements: WiZJSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Accessors

extension WiZJSON {
    public subscript(key: String) -> WiZJSON? { objectValue?[key] }

    public var objectValue: WiZObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [WiZJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Bools, plus `0`/`1` ints (WiZ uses both).
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    /// Ints, integral doubles and numeric strings (`"id":"1"` appears in discovery).
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite && d.rounded() == d && abs(d) < 9.0e18: return Int(d)
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
}

// MARK: - Serialisation (JavaScript JSON.stringify compatible)

extension WiZJSON {
    public var compactString: String {
        var out = ""
        write(to: &out)
        return out
    }

    public var compactData: Data { Data(compactString.utf8) }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += Self.formatNumber(d)
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let values):
            out += "["
            for (i, v) in values.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (i, m) in object.members.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(m.key, to: &out)
                out += ":"
                m.value.write(to: &out)
            }
            out += "}"
        }
    }

    /// JS number formatting for the values WiZ uses: integral values print without a fraction,
    /// non-finite values print as `null` (as `JSON.stringify` does).
    static func formatNumber(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e21 {
            if abs(d) < 9.0e18 { return String(Int(d)) }
            return String(format: "%.0f", d)
        }
        return "\(d)"
    }

    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Parsing

public struct WiZJSONParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public var description: String { "JSON parse error at byte \(offset): \(reason)" }
}

extension WiZJSON {
    /// Parses one JSON document (leading/trailing whitespace allowed).
    public static func parse(_ data: Data) throws -> WiZJSON {
        try parseDocument(Array(data)).value
    }

    public static func parse(_ text: String) throws -> WiZJSON {
        try parseDocument(Array(text.utf8)).value
    }

    /// Parses a document and returns the exact bytes of each top-level member value (used to
    /// verify signatures over the bytes the bulb actually sent).
    static func parseDocument(_ bytes: [UInt8]) throws -> (value: WiZJSON, rawMembers: [String: [UInt8]]) {
        var parser = WiZJSONParser(bytes: bytes)
        parser.skipWhitespace()
        var ranges: [String: Range<Int>] = [:]
        let value: WiZJSON
        if parser.peek() == UInt8(ascii: "{") {
            value = try parser.parseObject(depth: 0, record: &ranges)
        } else {
            value = try parser.parseValue(depth: 0)
        }
        parser.skipWhitespace()
        // Some firmware pads datagrams with NUL bytes; tolerate them after the document.
        while parser.peek() == 0 { parser.index += 1 }
        guard parser.index == bytes.count else { throw parser.error("trailing characters") }
        var raw: [String: [UInt8]] = [:]
        for (key, range) in ranges { raw[key] = Array(bytes[range]) }
        return (value, raw)
    }
}

struct WiZJSONParser {
    let bytes: [UInt8]
    var index = 0
    static let maxDepth = 64

    init(bytes: [UInt8]) { self.bytes = bytes }

    func error(_ reason: String) -> WiZJSONParseError { WiZJSONParseError(offset: index, reason: reason) }
    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    mutating func expect(_ c: UInt8) throws {
        guard peek() == c else { throw error("expected '\(Character(Unicode.Scalar(c)))'") }
        index += 1
    }

    mutating func parseValue(depth: Int) throws -> WiZJSON {
        guard depth < Self.maxDepth else { throw error("nesting too deep") }
        skipWhitespace()
        guard let c = peek() else { throw error("unexpected end of input") }
        switch c {
        case UInt8(ascii: "{"):
            var ignored: [String: Range<Int>] = [:]
            return try parseObject(depth: depth + 1, record: &ignored, recording: false)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func literal(_ word: String) throws {
        for b in word.utf8 {
            guard peek() == b else { throw error("invalid literal") }
            index += 1
        }
    }

    mutating func parseObject(depth: Int, record: inout [String: Range<Int>], recording: Bool = true) throws -> WiZJSON {
        try expect(UInt8(ascii: "{"))
        var object = WiZObject()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            let start = index
            let value = try parseValue(depth: depth + 1)
            if recording { record[key] = start..<index }
            object[key] = value
            skipWhitespace()
            guard let c = peek() else { throw error("unterminated object") }
            index += 1
            if c == UInt8(ascii: "}") { return .object(object) }
            guard c == UInt8(ascii: ",") else { throw error("expected ',' or '}'") }
        }
    }

    mutating func parseArray(depth: Int) throws -> WiZJSON {
        try expect(UInt8(ascii: "["))
        var values: [WiZJSON] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard let c = peek() else { throw error("unterminated array") }
            index += 1
            if c == UInt8(ascii: "]") { return .array(values) }
            guard c == UInt8(ascii: ",") else { throw error("expected ',' or ']'") }
        }
    }

    mutating func parseHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count,
              let v = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("invalid \\u escape") }
        index += 4
        return v
    }

    mutating func parseString() throws -> String {
        try expect(UInt8(ascii: "\""))
        var utf16: [UInt16] = []
        var pending: [UInt8] = []
        func flush() {
            if !pending.isEmpty {
                utf16.append(contentsOf: String(decoding: pending, as: UTF8.self).utf16)
                pending.removeAll()
            }
        }
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            index += 1
            if c == UInt8(ascii: "\"") { break }
            if c == UInt8(ascii: "\\") {
                flush()
                guard let e = peek() else { throw error("invalid escape") }
                index += 1
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
                default: throw error("invalid escape")
                }
            } else {
                guard c >= 0x20 else { throw error("control character in string") }
                pending.append(c)
            }
        }
        flush()
        return String(decoding: utf16, as: UTF16.self)
    }

    mutating func parseNumber() throws -> WiZJSON {
        let start = index
        var isInteger = true
        if peek() == UInt8(ascii: "-") { index += 1 }
        while let c = peek() {
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                index += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+")
                || (c == UInt8(ascii: "-") && index > start)
            {
                isInteger = false
                index += 1
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !text.isEmpty, text != "-" else { throw error("unexpected character") }
        if isInteger, let v = Int(text) { return .int(v) }
        guard let d = Double(text) else { throw error("invalid number") }
        return .double(d)
    }
}
