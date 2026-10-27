import Crypto
import Foundation
import _CryptoExtras

/// Crypto used by the AiDot protocol (python-aidot `aes_utils.py`, `client.rsa_password_encrypt`,
/// `discover.py`, `device_client.py`). Built on swift-crypto so it runs on Linux and Apple platforms.
public enum AiDotCrypto {
    public enum Failure: Error, Sendable, Equatable {
        case badKeyLength(Int)
        case badCiphertextLength(Int)
        case badPadding
        case invalidUTF8
        case rsa(String)
    }

    // MARK: AES-ECB

    /// AES-ECB over whole 16-byte blocks without padding. Key: 16, 24 or 32 bytes.
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

    public static func pkcs7Unpad(_ data: [UInt8]) throws -> [UInt8] {
        guard let pad = data.last, pad >= 1, pad <= 16, Int(pad) <= data.count,
              data.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { throw Failure.badPadding }
        return Array(data.dropLast(Int(pad)))
    }

    /// `aes_utils.aes_encrypt`: PKCS7 + AES-ECB.
    public static func aesEncrypt(_ plaintext: Data, key: [UInt8]) throws -> Data {
        Data(try ecbEncryptBlocks(pkcs7Pad(Array(plaintext)), key: key))
    }

    /// `aes_utils.aes_decrypt`: AES-ECB + PKCS7 unpad.
    public static func aesDecrypt(_ ciphertext: Data, key: [UInt8]) throws -> Data {
        guard !ciphertext.isEmpty else { throw Failure.badCiphertextLength(0) }
        return Data(try pkcs7Unpad(ecbDecryptBlocks(Array(ciphertext), key: key)))
    }

    // MARK: Keys

    /// Discovery key: `b"T54uednca587".ljust(32, b"\x00")` (AES-256).
    public static let discoveryKey: [UInt8] = Array("T54uednca587".utf8) + [UInt8](repeating: 0, count: 20)

    /// Device session key from cloud `aesKey[0]` (`device_client.py`):
    /// `key = bytearray(16); key[:len(b)] = b`. Shorter keys are zero-padded to 16 bytes; 16/24/32-byte
    /// keys are used as-is (AES-128/192/256, as Python does). Other longer lengths would make Python
    /// fail; we truncate them to 16 bytes as the most plausible device behaviour [unverified].
    public static func deviceKey(_ aesKey: String) -> [UInt8] {
        let bytes = Array(aesKey.utf8)
        if bytes.count < 16 { return bytes + [UInt8](repeating: 0, count: 16 - bytes.count) }
        if [16, 24, 32].contains(bytes.count) { return bytes }
        return Array(bytes.prefix(16))
    }

    // MARK: RSA (login password)

    /// Public key copied verbatim from python-aidot `aidot/login_const.py` (1024-bit RSA).
    public static let publicKeyPEM = """
        -----BEGIN PUBLIC KEY-----
        MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCtQAnPCi8ksPnS1Du6z96PsKfN
        p2Gp/f/bHwlrAdplbX3p7/TnGpnbJGkLq8uRxf6cw+vOthTsZjkPCF7CatRvRnTj
        c9fcy7yE0oXa5TloYyXD6GkxgftBbN/movkJJGQCc7gFavuYoAdTRBOyQoXBtm0m
        kXMSjXOldI/290b9BQIDAQAB
        -----END PUBLIC KEY-----
        """

    /// The hardcoded login key (1024 bit, so it must be loaded through the `unsafe` initialiser).
    public static func loginPublicKey() throws -> _RSA.Encryption.PublicKey {
        do {
            return try _RSA.Encryption.PublicKey(unsafePEMRepresentation: publicKeyPEM)
        } catch {
            throw Failure.rsa("cannot load AiDot public key: \(error)")
        }
    }

    /// `client.rsa_password_encrypt`: RSA PKCS#1 v1.5 (random padding) then base64.
    public static func encryptPassword(_ password: String) throws -> String {
        try encryptPassword(password, with: loginPublicKey())
    }

    /// Same with an explicit key (tests use a generated key pair to round-trip).
    public static func encryptPassword(_ password: String, with key: _RSA.Encryption.PublicKey) throws -> String {
        do {
            return try key.encrypt(Data(password.utf8), padding: ._WEAK_AND_INSECURE_PKCS_V1_5).base64EncodedString()
        } catch {
            throw Failure.rsa("password encryption failed: \(error)")
        }
    }

    // MARK: Misc

    /// `hashlib.md5(raw.encode()).hexdigest()` (terminalId).
    public static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }
}
