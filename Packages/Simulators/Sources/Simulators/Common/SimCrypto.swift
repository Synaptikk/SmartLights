import Crypto
import Foundation
import _CryptoExtras

/// Crypto primitives the fakes need, built on swift-crypto so they run on Linux.
public enum SimCrypto {
    public enum Failure: Error { case badKeyLength, badCiphertextLength, badPadding }

    // MARK: AES-ECB + PKCS7 (AiDot)

    /// AES-ECB encrypt with PKCS7 padding. Key must be 16, 24 or 32 bytes.
    public static func aesECBEncrypt(_ plaintext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength }
        let symKey = SymmetricKey(data: key)
        let pad = 16 - plaintext.count % 16
        let padded = plaintext + [UInt8](repeating: UInt8(pad), count: pad)
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        var offset = 0
        while offset < padded.count {
            var block = Array(padded[offset..<offset + 16])
            try AES.permute(&block, key: symKey)
            out += block
            offset += 16
        }
        return out
    }

    /// AES-ECB decrypt and strip PKCS7 padding.
    public static func aesECBDecrypt(_ ciphertext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw Failure.badCiphertextLength }
        let symKey = SymmetricKey(data: key)
        var out: [UInt8] = []
        out.reserveCapacity(ciphertext.count)
        var offset = 0
        while offset < ciphertext.count {
            var block = Array(ciphertext[offset..<offset + 16])
            try AES.inversePermute(&block, key: symKey)
            out += block
            offset += 16
        }
        guard let pad = out.last, pad >= 1, pad <= 16, out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw Failure.badPadding
        }
        return Array(out.dropLast(Int(pad)))
    }

    /// Zero-pads (or truncates) a key string to `length` bytes, like python-aidot.
    public static func paddedKey(_ s: String, length: Int) -> [UInt8] {
        var k = Array(s.utf8.prefix(length))
        k += [UInt8](repeating: 0, count: length - k.count)
        return k
    }

    /// AiDot LAN discovery key: "T54uednca587" zero-padded to 32 bytes (AES-256).
    public static let aidotDiscoveryKey: [UInt8] = paddedKey("T54uednca587", length: 32)

    // MARK: HMAC (WiZ)

    /// base64(HMAC-SHA256(key, message)).
    public static func hmacSHA256Base64(_ message: [UInt8], key: [UInt8]) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    public static func hexDecode(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    public static func hexEncode(_ bytes: [UInt8], uppercase: Bool = false) -> String {
        bytes.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
    }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// Random UUID-shaped lowercase string (Hue resource ids).
    public static func uuid() -> String { UUID().uuidString.lowercased() }
}
