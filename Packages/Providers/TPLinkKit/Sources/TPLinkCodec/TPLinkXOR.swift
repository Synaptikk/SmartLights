import Foundation

/// Legacy Kasa "Smart Home Protocol" obfuscation: XOR autokey with initial key 171 (0xAB).
/// Each plaintext byte is XORed with the previous *ciphertext* byte (the first with 0xAB).
///
/// - TCP 9999: every message is `UInt32 big-endian length` + XORed JSON, both directions.
/// - UDP 9999 (discovery): the XORed JSON without the length prefix.
///
/// Described by softScheck's HS110 write-up (https://www.softscheck.com/en/reverse-engineering-tp-link-hs110/,
/// Apache-2.0 reference code) and implemented the same way by python-kasa `XorEncryption`.
public enum TPLinkXOR {
    public static let initialKey: UInt8 = 0xAB
    /// TCP and UDP port of the legacy protocol.
    public static let port: UInt16 = 9999
    /// Largest response we accept on TCP (a KL430 sysinfo is ~1.5 KB; 1 MB leaves ample room).
    public static let maxFrameLength = 1 << 20

    public static func encrypt(_ plaintext: Data) -> Data {
        var key = initialKey
        var out = Data(count: plaintext.count)
        for (i, byte) in plaintext.enumerated() {
            key ^= byte
            out[i] = key
        }
        return out
    }

    public static func decrypt(_ ciphertext: Data) -> Data {
        var key = initialKey
        var out = Data(count: ciphertext.count)
        for (i, byte) in ciphertext.enumerated() {
            out[i] = key ^ byte
            key = byte
        }
        return out
    }

    /// TCP frame: 4-byte big-endian length + XORed payload.
    public static func frame(_ plaintext: Data) -> Data {
        let length = UInt32(plaintext.count)
        var out = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        out.append(encrypt(plaintext))
        return out
    }

    public static func frame(_ json: TPLinkJSON) -> Data { frame(json.data) }

    /// Length announced by a frame header (`nil` until 4 bytes are available).
    public static func announcedLength(_ header: Data) -> Int? {
        guard header.count >= 4 else { return nil }
        let b = Array(header.prefix(4))
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    /// Splits complete frames off the front of `buffer` (TCP reads may split or merge frames).
    /// Returns the decrypted payloads; incomplete trailing bytes stay in `buffer`.
    public static func deframe(_ buffer: inout Data) throws -> [Data] {
        var out: [Data] = []
        while let length = announcedLength(buffer) {
            guard length <= maxFrameLength else { throw TPLinkCodecError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            out.append(decrypt(Data(buffer[start..<start + length])))
            buffer = Data(buffer[(start + length)...])
        }
        return out
    }

    /// Decodes one complete TCP frame (length prefix + payload).
    public static func unframe(_ frame: Data) throws -> Data {
        guard let length = announcedLength(frame) else { throw TPLinkCodecError.truncatedFrame(expected: 4, actual: frame.count) }
        guard length <= maxFrameLength else { throw TPLinkCodecError.frameTooLarge(length) }
        guard frame.count >= 4 + length else { throw TPLinkCodecError.truncatedFrame(expected: 4 + length, actual: frame.count) }
        let start = frame.startIndex + 4
        return decrypt(Data(frame[start..<start + length]))
    }
}
