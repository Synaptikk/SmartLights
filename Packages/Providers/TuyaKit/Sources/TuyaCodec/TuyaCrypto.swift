import Crypto
import Foundation
import _CryptoExtras

/// Crypto used by the Tuya LAN protocol (tinytuya `core/crypto_helper.py`, `message_helper.py`,
/// `udp_helper.py`). Built on swift-crypto so it runs on Linux and Apple platforms.
public enum TuyaCrypto {
    public enum Failure: Error, Sendable, Equatable {
        case badKeyLength(Int)
        case badCiphertextLength(Int)
        case badPadding
        case badNonceLength(Int)
        case authenticationFailed
        case badBase64
    }

    /// `md5(b"yGAdlopoPVldABfn")`: key of encrypted UDP broadcasts (port 6667, and 6699-framed v3.5).
    public static let udpKey: [UInt8] = Array(Insecure.MD5.hash(data: Array("yGAdlopoPVldABfn".utf8)))

    // MARK: AES-128-ECB

    /// AES-ECB over whole 16-byte blocks without padding.
    public static func ecbEncryptBlocks(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try ecb(data, key: key, decrypt: false)
    }

    public static func ecbDecryptBlocks(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try ecb(data, key: key, decrypt: true)
    }

    private static func ecb(_ data: [UInt8], key: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength(key.count) }
        guard data.count % 16 == 0 else { throw Failure.badCiphertextLength(data.count) }
        let symmetricKey = SymmetricKey(data: key)
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            var block = Array(data[offset..<offset + 16])
            if decrypt {
                try AES.inversePermute(&block, key: symmetricKey)
            } else {
                try AES.permute(&block, key: symmetricKey)
            }
            out += block
            offset += 16
        }
        return out
    }

    /// PKCS#7 pad to a multiple of 16 (always adds 1...16 bytes).
    public static func pkcs7Pad(_ data: [UInt8]) -> [UInt8] {
        let pad = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(pad), count: pad)
    }

    /// Strips PKCS#7 padding. Like tinytuya's `_unpad(verify_padding=False)` only the length byte is
    /// checked (1...16), not the padding bytes themselves.
    public static func pkcs7Unpad(_ data: [UInt8]) throws -> [UInt8] {
        guard let last = data.last, (1...16).contains(Int(last)), Int(last) <= data.count else { throw Failure.badPadding }
        return Array(data.dropLast(Int(last)))
    }

    /// `AESCipher(key).encrypt(raw, use_base64=False, pad=True)`.
    public static func ecbEncrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try ecbEncryptBlocks(pkcs7Pad(data), key: key)
    }

    /// `AESCipher(key).decrypt(enc, use_base64=False)`.
    public static func ecbDecrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try pkcs7Unpad(ecbDecryptBlocks(data, key: key))
    }

    // MARK: AES-128-GCM (protocol 3.5)

    /// Returns `(ciphertext, tag)`; `aad` is the 6699 header after the prefix.
    public static func gcmSeal(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], aad: [UInt8] = []) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength(key.count) }
        guard iv.count == 12 else { throw Failure.badNonceLength(iv.count) }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
        return (Array(box.ciphertext), Array(box.tag))
    }

    public static func gcmOpen(_ ciphertext: [UInt8], tag: [UInt8], key: [UInt8], iv: [UInt8], aad: [UInt8] = []) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength(key.count) }
        guard iv.count == 12 else { throw Failure.badNonceLength(iv.count) }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
        } catch {
            throw Failure.authenticationFailed
        }
    }

    /// A fresh random 12-byte GCM IV (tinytuya uses `os.urandom(12)`; the IV travels in the frame).
    public static func randomIV() -> [UInt8] { randomBytes(12) }

    /// A fresh random 16-byte session-negotiation nonce.
    public static func randomNonce() -> [UInt8] { randomBytes(16) }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    // MARK: Hashes

    public static func hmacSHA256(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func md5Hex(_ data: [UInt8]) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// zlib/`binascii.crc32` (reflected polynomial 0xEDB88320).
    public static func crc32(_ data: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    // MARK: Helpers

    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let v = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(v)
            i += 2
        }
        return out
    }

    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Local keys are 16 printable characters, used as raw bytes (`local_key.encode("latin1")`).
    public static func keyBytes(_ localKey: String) -> [UInt8]? {
        let scalars = localKey.unicodeScalars
        guard scalars.allSatisfy({ $0.value < 256 }) else { return nil }
        let bytes = scalars.map { UInt8($0.value) }
        return bytes.count == 16 ? bytes : nil
    }
}
