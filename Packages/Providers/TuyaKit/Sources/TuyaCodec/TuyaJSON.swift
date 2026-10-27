import Foundation

/// JSON value with ordered object members.
///
/// Tuya devices are picky about request bodies: tinytuya builds them with `json.dumps(dict)` and then
/// strips **every** space (`payload.replace(" ", "")`, "if spaces are not removed device does not
/// respond!"). `compactString()` reproduces that byte for byte: insertion order, `ensure_ascii`
/// escapes, no whitespace anywhere (also inside strings, as upstream does).
public indirect enum TuyaJSON: Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([TuyaJSON])
    case object([(String, TuyaJSON)])

    public enum ParseError: Error, Sendable, Equatable {
        case invalidUTF8
        case unexpected(String, offset: Int)
        case trailingData(offset: Int)
    }

    // MARK: Accessors

    public subscript(key: String) -> TuyaJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.0 == key }?.1
    }

    public var members: [(String, TuyaJSON)]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var arrayValue: [TuyaJSON]? {
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

    /// Integer value (doubles with an integral value included).
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
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

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Object members as a dictionary (last duplicate wins).
    public var dictionary: [String: TuyaJSON]? {
        members.map { Dictionary($0, uniquingKeysWith: { _, b in b }) }
    }

    /// Returns a copy with `key` set (replacing an existing member in place, else appended).
    public func setting(_ key: String, _ value: TuyaJSON) -> TuyaJSON {
        guard case .object(var m) = self else { return self }
        if let i = m.firstIndex(where: { $0.0 == key }) { m[i].1 = value } else { m.append((key, value)) }
        return .object(m)
    }

    // MARK: Encoding (tinytuya formatting)

    /// `json.dumps(value).replace(" ", "")`.
    public func compactString() -> String {
        var out = ""
        write(into: &out)
        return out.replacingOccurrences(of: " ", with: "")
    }

    public var compactData: Data { Data(compactString().utf8) }

    public var description: String { compactString() }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += Self.pythonFloat(d)
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let m):
            out += "{"
            for (i, (k, v)) in m.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(k, into: &out)
                out += ":"
                v.write(into: &out)
            }
            out += "}"
        }
    }

    private static func pythonFloat(_ d: Double) -> String {
        guard d.isFinite else { return d.isNaN ? "NaN" : (d < 0 ? "-Infinity" : "Infinity") }
        if d.rounded() == d && abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    /// Python `json.dumps` string escaping with `ensure_ascii=True`.
    private static func writeString(_ s: String, into out: inout String) {
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
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        out += "\""
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> TuyaJSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> TuyaJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.trailingData(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail(_ what: String) -> ParseError { .unexpected(what, offset: index) }

        mutating func value() throws -> TuyaJSON {
            guard index < bytes.count else { throw fail("end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { throw fail(word) }
            index += w.count
        }

        mutating func object() throws -> TuyaJSON {
            index += 1
            var members: [(String, TuyaJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("object key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail(":") }
                index += 1
                skipWhitespace()
                members.append((key, try value()))
                skipWhitespace()
                guard index < bytes.count else { throw fail("}") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw fail(", or }")
            }
        }

        mutating func array() throws -> TuyaJSON {
            index += 1
            var items: [TuyaJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw fail("]") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw fail(", or ]")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flushRaw() throws {
                guard !raw.isEmpty else { return }
                guard let s = String(bytes: raw, encoding: .utf8) else { throw ParseError.invalidUTF8 }
                units += Array(s.utf16)
                raw.removeAll()
            }
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    try flushRaw()
                    return String(decoding: units, as: UTF16.self)
                }
                if b == UInt8(ascii: "\\") {
                    try flushRaw()
                    guard index + 1 < bytes.count else { throw fail("escape") }
                    let e = bytes[index + 1]
                    index += 2
                    switch e {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count,
                              let v = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                        else { throw fail("\\u escape") }
                        units.append(v)
                        index += 4
                    default: throw fail("escape")
                    }
                    continue
                }
                raw.append(b)
                index += 1
            }
            throw fail("unterminated string")
        }

        mutating func number() throws -> TuyaJSON {
            let start = index
            var isDouble = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count {
                let b = bytes[index]
                if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) {
                    index += 1
                } else if b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
                            || ((b == UInt8(ascii: "+") || b == UInt8(ascii: "-")) && isDouble) {
                    isDouble = true
                    index += 1
                } else {
                    break
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, text != "-" else { throw fail("value") }
            if !isDouble, let i = Int(text) { return .int(i) }
            guard let d = Double(text) else { throw fail("number") }
            return .double(d)
        }
    }
}

extension TuyaJSON: Equatable {
    /// Objects compare as dictionaries (member order ignored); numbers compare by value.
    public static func == (lhs: TuyaJSON, rhs: TuyaJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.int, .double), (.double, .int), (.double, .double): return lhs.doubleValue == rhs.doubleValue
        case (.array(let a), .array(let b)): return a == b
        case (.object, .object): return lhs.dictionary == rhs.dictionary
        default: return false
        }
    }
}

extension TuyaJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: TuyaJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, TuyaJSON)...) { self = .object(elements) }
    public init(nilLiteral: ()) { self = .null }
}
