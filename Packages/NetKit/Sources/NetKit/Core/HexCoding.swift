import Foundation

/// Hex encoding/decoding helpers.
public enum Hex {
    private static let lower = Array("0123456789abcdef".utf8)
    private static let upper = Array("0123456789ABCDEF".utf8)

    /// Encodes bytes as hex, optionally upper-case and with a separator between bytes (e.g. `":"`).
    public static func encode<S: Sequence>(_ bytes: S, uppercase: Bool = false, separator: String = "") -> String
    where S.Element == UInt8 {
        let table = uppercase ? upper : lower
        var out: [UInt8] = []
        let sep = Array(separator.utf8)
        var first = true
        for byte in bytes {
            if !first { out.append(contentsOf: sep) }
            first = false
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes hex. Accepts an optional `0x` prefix, either case, and ignores whitespace, `:` and `-`
    /// separators (as in certificate fingerprints or MAC addresses). Returns `nil` on invalid input.
    public static func decode(_ string: String) -> Data? {
        var text = Substring(string)
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = text.dropFirst(2) }
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(text.utf8.count)
        for c in text.utf8 {
            switch c {
            case 0x30...0x39: nibbles.append(c - 0x30)
            case 0x41...0x46: nibbles.append(c - 0x41 + 10)
            case 0x61...0x66: nibbles.append(c - 0x61 + 10)
            case 0x20, 0x09, 0x0A, 0x0D, 0x3A, 0x2D: continue
            default: return nil
            }
        }
        guard nibbles.count % 2 == 0 else { return nil }
        var data = Data(capacity: nibbles.count / 2)
        var i = 0
        while i < nibbles.count {
            data.append(nibbles[i] << 4 | nibbles[i + 1])
            i += 2
        }
        return data
    }
}

extension Data {
    /// `Data(hexString: "deadbeef")`; see ``Hex/decode(_:)`` for accepted formats.
    public init?(hexString: String) {
        guard let data = Hex.decode(hexString) else { return nil }
        self = data
    }

    public func hexString(uppercase: Bool = false, separator: String = "") -> String {
        Hex.encode(self, uppercase: uppercase, separator: separator)
    }
}
