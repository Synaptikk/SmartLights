import Crypto
import Foundation
import _CryptoExtras

/// Hashing and the `Appliance.Encrypt.ECDHE` HTTP body cipher (meross_lan `httpclient.py`,
/// `MerossMessage.compute_encryption_key`). swift-crypto, so it runs on Linux and Apple platforms.
public enum MerossCrypto {
    public enum Failure: Error, Sendable, Equatable {
        case badKeyLength(Int)
        case badCiphertextLength(Int)
        case notBase64
    }

    /// Lowercase hex MD5 of the UTF-8 bytes of `string`.
    public static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: ECDHE body encryption

    /// Fixed IV used by Meross for the encrypted HTTP body: ASCII `"0000000000000000"`.
    public static let encryptionIV: [UInt8] = Array("0000000000000000".utf8)

    /// `md5(uuid[3:22] + key[1:9] + mac + key[10:28])` as 32 ASCII hex bytes (an AES-256 key).
    /// Slices follow Python semantics (short strings give short slices, never a crash).
    public static func encryptionKey(uuid: String, key: String, mac: String) -> [UInt8] {
        let material = pySlice(uuid, 3, 22) + pySlice(key, 1, 9) + mac + pySlice(key, 10, 28)
        return Array(md5Hex(material).utf8)
    }

    /// Zero-pads to 16 bytes, AES-CBC encrypts and base64-encodes (the HTTP body of an encrypted device).
    public static func encryptBody(_ plaintext: Data, key: [UInt8]) throws -> Data {
        var bytes = [UInt8](plaintext)
        if bytes.count % 16 != 0 { bytes += [UInt8](repeating: 0, count: 16 - bytes.count % 16) }
        let cipher = try cbc(bytes, key: key, iv: encryptionIV, decrypt: false)
        return Data(Data(cipher).base64EncodedString().utf8)
    }

    /// Base64-decodes, AES-CBC decrypts and strips the trailing zero padding.
    public static func decryptBody(_ body: Data, key: [UInt8]) throws -> Data {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text) else { throw Failure.notBase64 }
        var plain = try cbc([UInt8](raw), key: key, iv: encryptionIV, decrypt: true)
        while plain.last == 0 { plain.removeLast() }
        return Data(plain)
    }

    /// AES-CBC over whole blocks, no padding. Key: 16, 24 or 32 bytes.
    public static func cbc(_ data: [UInt8], key: [UInt8], iv: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength(key.count) }
        guard data.count % 16 == 0, iv.count == 16 else { throw Failure.badCiphertextLength(data.count) }
        let symmetricKey = SymmetricKey(data: key)
        var previous = iv
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            let input = Array(data[offset..<offset + 16])
            var block = input
            if decrypt {
                try AES.inversePermute(&block, key: symmetricKey)
                for i in 0..<16 { block[i] ^= previous[i] }
                previous = input
            } else {
                for i in 0..<16 { block[i] ^= previous[i] }
                try AES.permute(&block, key: symmetricKey)
                previous = block
            }
            out += block
            offset += 16
        }
        return out
    }

    /// Python `s[start:end]` for non-negative bounds.
    static func pySlice(_ s: String, _ start: Int, _ end: Int) -> String {
        let chars = Array(s)
        let lo = min(start, chars.count)
        let hi = max(lo, min(end, chars.count))
        return String(chars[lo..<hi])
    }
}
