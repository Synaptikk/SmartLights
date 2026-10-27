import Foundation

/// A JSON value. Shelly payloads are loosely typed (component keys like `"light:0"`, partial
/// notification objects), so the codec works on this instead of fixed Codable structs.
public enum ShellyJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ShellyJSON])
    case object([String: ShellyJSON])

    // MARK: Access

    public subscript(key: String) -> ShellyJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> ShellyJSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var double: Double? { if case .number(let v) = self { return v }; return nil }
    public var int: Int? { double.flatMap { $0.isFinite ? Int($0.rounded()) : nil } }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [ShellyJSON]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: ShellyJSON]? { if case .object(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }

    /// Recursive merge (`patch` wins; nested objects merge), as notifications carry partial status.
    public func merging(_ patch: ShellyJSON) -> ShellyJSON {
        guard case .object(var base) = self, case .object(let p) = patch else { return patch }
        for (k, v) in p { base[k] = base[k].map { $0.merging(v) } ?? v }
        return .object(base)
    }

    // MARK: Coding

    /// Parses JSON text (RFC 8259). Own parser: identical number/bool handling on Apple and Linux.
    public static func parse(_ data: Data) throws(ShellyJSONError) -> ShellyJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw .invalid(at: parser.index) }
        return value
    }

    public static func parse(_ text: String) throws(ShellyJSONError) -> ShellyJSON {
        try parse(Data(text.utf8))
    }

    /// Compact JSON with sorted keys (deterministic bytes for tests and signatures).
    public func encoded() -> Data {
        var out = ""
        write(&out)
        return Data(out.utf8)
    }

    public var jsonString: String { String(decoding: encoded(), as: UTF8.self) }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { out += String(Int64(n)) } else if n.isFinite { out += "\(n)" } else { out += "null" }
        case .string(let s): Self.writeString(s, &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(&out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(k, &out)
                out += ":"
                o[k]!.write(&out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, _ out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }
}

public enum ShellyJSONError: Error, Sendable, Equatable {
    case invalid(at: Int)
    case tooDeep
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws(ShellyJSONError) -> ShellyJSON {
        guard depth < 64 else { throw .tooDeep }
        guard index < bytes.count else { throw .invalid(at: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var out: [String: ShellyJSON] = [:]
            skipSpace()
            if peek(UInt8(ascii: "}")) { index += 1; return .object(out) }
            while true {
                skipSpace()
                guard peek(UInt8(ascii: "\"")) else { throw .invalid(at: index) }
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                out[key] = try value(depth: depth + 1)
                skipSpace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(out)
            }
        case UInt8(ascii: "["):
            index += 1
            var out: [ShellyJSON] = []
            skipSpace()
            if peek(UInt8(ascii: "]")) { index += 1; return .array(out) }
            while true {
                skipSpace()
                out.append(try value(depth: depth + 1))
                skipSpace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(out)
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        default:
            return .number(try number())
        }
    }

    private func peek(_ b: UInt8) -> Bool { index < bytes.count && bytes[index] == b }

    private mutating func expect(_ b: UInt8) throws(ShellyJSONError) {
        guard peek(b) else { throw .invalid(at: index) }
        index += 1
    }

    private mutating func literal(_ word: String) throws(ShellyJSONError) {
        let w = Array(word.utf8)
        guard index + w.count <= bytes.count, Array(bytes[index..<(index + w.count)]) == w else { throw .invalid(at: index) }
        index += w.count
    }

    private mutating func number() throws(ShellyJSONError) -> Double {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii), let v = Double(text) else {
            throw .invalid(at: start)
        }
        return v
    }

    private mutating func hex4() throws(ShellyJSONError) -> UInt32 {
        guard index + 4 <= bytes.count, let s = String(bytes: bytes[index..<(index + 4)], encoding: .ascii),
              let v = UInt32(s, radix: 16) else { throw .invalid(at: index) }
        index += 4
        return v
    }

    private mutating func string() throws(ShellyJSONError) -> String {
        try expect(UInt8(ascii: "\""))
        var out = [UInt8]()
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw .invalid(at: index) }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low &- 0xDC00)
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8))
                default: throw .invalid(at: index - 1)
                }
            default:
                out.append(b)
            }
        }
        throw .invalid(at: index)
    }
}

extension ShellyJSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ShellyJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ShellyJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}
