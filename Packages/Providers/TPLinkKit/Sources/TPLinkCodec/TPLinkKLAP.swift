import Crypto
import Foundation
import _CryptoExtras

/// KLAP, the authenticated transport of newer Kasa and all current Tapo firmware: plain HTTP on
/// port 80, a two-step handshake proving knowledge of the TP-Link account credentials, then
/// AES-128-CBC requests to `/app/request?seq=N`.
///
/// Re-implemented from the behaviour of python-kasa `transports/klaptransport.py` (GPL-3.0, no code
/// copied; test vectors are outputs of running it) and the MIT `mihai-dinculescu/tapo` crate:
///
/// 1. `POST /app/handshake1` body `local_seed` (16 random bytes) -> 200, body
///    `remote_seed (16) + server_hash (32)`, `Set-Cookie: TP_SESSIONID=...;TIMEOUT=86400`.
///    The client accepts if `server_hash == handshake1Hash(local, remote, auth_hash)` for one of its
///    candidate credentials (the account, blank, the vendor defaults).
/// 2. `POST /app/handshake2` with the cookie, body `handshake2Hash(local, remote, auth_hash)` -> 200.
/// 3. Session: `key = SHA256("lsk"+l+r+h)[0..<16]`, `iv = SHA256("iv"+l+r+h)`, IV prefix = first 12
///    bytes, `seq` = last 4 bytes as a signed big-endian Int32, `sig = SHA256("ldk"+l+r+h)[0..<28]`.
///    Each request increments `seq`; IV = prefix + seq (BE); body = `SHA256(sig + seq + ct) + ct`
///    with `ct = AES-128-CBC(PKCS7(json))`; the device answers with the same layout and sequence.
///
/// Version 1 (older Kasa KLAP firmware, `IOT.KLAP` with `lv` < 2) uses MD5 credential hashes;
/// version 2 (all Tapo, `SMART.KLAP`, Kasa `lv` >= 2) uses SHA-1/SHA-256.
public enum TPLinkKLAP {
    public enum Version: Int, Sendable, Hashable, Codable, CaseIterable {
        case v1 = 1
        case v2 = 2
    }

    public static let defaultPort: UInt16 = 80
    public static let sessionCookieName = "TP_SESSIONID"
    public static let timeoutCookieName = "TIMEOUT"
    /// Session lifetime when the device sends no `TIMEOUT` cookie.
    public static let defaultSessionSeconds = 86_400
    /// Renew this long before the announced expiry (python-kasa uses 20 minutes).
    public static let sessionRenewalMarginSeconds = 1_200

    public static let handshake1Path = "/app/handshake1"
    public static let handshake2Path = "/app/handshake2"
    public static let requestPath = "/app/request"

    // MARK: Credential hashes

    /// `auth_hash`: v1 `MD5(MD5(username) + MD5(password))`, v2 `SHA256(SHA1(username) + SHA1(password))`.
    /// Both username and password are case-sensitive (the TP-Link account email as typed at sign-up).
    public static func authHash(username: String, password: String, version: Version) -> Data {
        let u = Data(username.utf8)
        let p = Data(password.utf8)
        switch version {
        case .v1:
            return md5(md5(u) + md5(p))
        case .v2:
            return sha256(sha1(u) + sha1(p))
        }
    }

    /// The hash a device returns in handshake1 for `authHash`.
    /// v1 `SHA256(local + auth)`, v2 `SHA256(local + remote + auth)`.
    public static func handshake1Hash(localSeed: Data, remoteSeed: Data, authHash: Data, version: Version) -> Data {
        switch version {
        case .v1: sha256(localSeed + authHash)
        case .v2: sha256(localSeed + remoteSeed + authHash)
        }
    }

    /// The body of handshake2. v1 `SHA256(remote + auth)`, v2 `SHA256(remote + local + auth)`.
    public static func handshake2Hash(localSeed: Data, remoteSeed: Data, authHash: Data, version: Version) -> Data {
        switch version {
        case .v1: sha256(remoteSeed + authHash)
        case .v2: sha256(remoteSeed + localSeed + authHash)
        }
    }

    /// Splits a handshake1 response body into `remote_seed` and `server_hash`.
    public static func parseHandshake1(_ body: Data) throws -> (remoteSeed: Data, serverHash: Data) {
        guard body.count == 48 else {
            throw TPLinkCodecError.badHandshake("handshake1 body has \(body.count) bytes, expected 48")
        }
        let b = Data(body)
        return (Data(b[0..<16]), Data(b[16..<48]))
    }

    /// Picks the candidate whose handshake1 hash matches the device's `serverHash`.
    /// Returns the index into `candidates`, or nil (wrong credentials).
    public static func matchCandidate(_ candidates: [Data], localSeed: Data, remoteSeed: Data, serverHash: Data, version: Version) -> Int? {
        candidates.firstIndex { handshake1Hash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: $0, version: version) == serverHash }
    }

    // MARK: Vendor default credentials

    /// Credentials some devices answer with instead of the account (python-kasa documents that
    /// cloud-connected Kasa KLAP devices intermittently switch to these). Public knowledge, not
    /// secrets; listed so the handshake can recognise them.
    public static let defaultCredentials: [(username: String, password: String)] = [
        ("kasa@tp-link.net", "kasaSetup"),
        ("test@tp-link.net", "test"),
    ]

    /// Candidate auth hashes in the order they are tried: account, vendor defaults, blank
    /// (devices never bound to a cloud account accept empty credentials).
    public static func candidateHashes(username: String?, password: String?, version: Version) -> [Data] {
        var out: [Data] = []
        if let username, let password { out.append(authHash(username: username, password: password, version: version)) }
        for d in defaultCredentials { out.append(authHash(username: d.username, password: d.password, version: version)) }
        let blank = authHash(username: "", password: "", version: version)
        if !out.contains(blank) { out.append(blank) }
        return out
    }

    // MARK: Cookies

    /// Parses `Set-Cookie` header values (`TP_SESSIONID=ABC;TIMEOUT=86400`, possibly several values
    /// merged with `,`) into name/value pairs. Attributes such as `Path` are returned as well.
    public static func parseCookies(_ headerValues: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for value in headerValues {
            for part in value.split(whereSeparator: { $0 == ";" || $0 == "," }) {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                let v = pair[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, out[name] == nil { out[name] = v }
            }
        }
        return out
    }

    // MARK: Hash helpers

    static func md5(_ d: Data) -> Data { Data(Insecure.MD5.hash(data: d)) }
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
}

/// Encryption state of one KLAP session (after a successful handshake).
/// A value type: the owner (one per device) serialises requests and stores it back.
public struct TPLinkKLAPSession: Sendable, Equatable {
    public let key: Data
    /// First 12 bytes of the IV; the last 4 are the sequence number.
    public let ivPrefix: Data
    public let signature: Data
    /// Sequence of the last encrypted request (starts at the derived value; incremented before use).
    public private(set) var sequence: Int32

    public init(localSeed: Data, remoteSeed: Data, authHash: Data) {
        let material = localSeed + remoteSeed + authHash
        key = Data(TPLinkKLAP.sha256(Data("lsk".utf8) + material).prefix(16))
        let fullIV = TPLinkKLAP.sha256(Data("iv".utf8) + material)
        ivPrefix = Data(fullIV.prefix(12))
        let tail = Array(fullIV.suffix(4))
        sequence = Int32(bitPattern: UInt32(tail[0]) << 24 | UInt32(tail[1]) << 16 | UInt32(tail[2]) << 8 | UInt32(tail[3]))
        signature = Data(TPLinkKLAP.sha256(Data("ldk".utf8) + material).prefix(28))
    }

    /// Big-endian bytes of a sequence number (signed, as python's `struct.pack(">l")`).
    public static func sequenceBytes(_ seq: Int32) -> Data {
        let u = UInt32(bitPattern: seq)
        return Data([UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)])
    }

    public func iv(for seq: Int32) -> Data { ivPrefix + Self.sequenceBytes(seq) }

    /// Encrypts a request: increments the sequence and returns `(body, seq)` where body is
    /// `SHA256(sig + seq + ct) + ct`. The sequence goes into the `seq` query parameter.
    public mutating func encrypt(_ plaintext: Data) throws -> (body: Data, sequence: Int32) {
        sequence &+= 1
        return (try seal(plaintext, sequence: sequence), sequence)
    }

    /// Encrypts with an explicit sequence (the device side of the exchange, tests).
    public func seal(_ plaintext: Data, sequence seq: Int32) throws -> Data {
        let ct = try TPLinkAESCBC.encrypt(plaintext, key: key, iv: iv(for: seq))
        let mac = TPLinkKLAP.sha256(signature + Self.sequenceBytes(seq) + ct)
        return mac + ct
    }

    /// Decrypts a body (`32-byte signature + ciphertext`) for `seq`. The signature is verified.
    public func open(_ body: Data, sequence seq: Int32) throws -> Data {
        guard body.count >= 48, (body.count - 32) % 16 == 0 else {
            throw TPLinkCodecError.badCiphertext("KLAP body of \(body.count) bytes")
        }
        let b = Data(body)
        let mac = Data(b[0..<32])
        let ct = Data(b[32...])
        guard TPLinkKLAP.sha256(signature + Self.sequenceBytes(seq) + ct) == mac else {
            throw TPLinkCodecError.badCiphertext("KLAP signature mismatch")
        }
        return try TPLinkAESCBC.decrypt(ct, key: key, iv: iv(for: seq))
    }

    /// Decrypts the device's answer to the last `encrypt` (same sequence number).
    public func decryptResponse(_ body: Data) throws -> Data { try open(body, sequence: sequence) }
}

/// AES-CBC with PKCS#7 padding, built on the swift-crypto AES block primitive so it behaves the
/// same on Linux and Apple platforms.
public enum TPLinkAESCBC {
    public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw TPLinkCodecError.badCiphertext("key length \(key.count)") }
        guard iv.count == 16 else { throw TPLinkCodecError.badCiphertext("IV length \(iv.count)") }
        let symmetricKey = SymmetricKey(data: key)
        let padded = pkcs7Pad(Array(plaintext))
        var previous = Array(iv)
        var out = [UInt8]()
        out.reserveCapacity(padded.count)
        var offset = 0
        while offset < padded.count {
            var block = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { block[i] = padded[offset + i] ^ previous[i] }
            try AES.permute(&block, key: symmetricKey)
            out += block
            previous = block
            offset += 16
        }
        return Data(out)
    }

    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw TPLinkCodecError.badCiphertext("key length \(key.count)") }
        guard iv.count == 16 else { throw TPLinkCodecError.badCiphertext("IV length \(iv.count)") }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else {
            throw TPLinkCodecError.badCiphertext("ciphertext length \(ciphertext.count)")
        }
        let symmetricKey = SymmetricKey(data: key)
        let bytes = Array(ciphertext)
        var previous = Array(iv)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var offset = 0
        while offset < bytes.count {
            let cipherBlock = Array(bytes[offset..<offset + 16])
            var block = cipherBlock
            try AES.inversePermute(&block, key: symmetricKey)
            for i in 0..<16 { block[i] ^= previous[i] }
            out += block
            previous = cipherBlock
            offset += 16
        }
        return Data(try pkcs7Unpad(out))
    }

    static func pkcs7Pad(_ data: [UInt8]) -> [UInt8] {
        let pad = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(pad), count: pad)
    }

    static func pkcs7Unpad(_ data: [UInt8]) throws -> [UInt8] {
        guard let pad = data.last, pad >= 1, pad <= 16, Int(pad) <= data.count,
              data.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { throw TPLinkCodecError.badCiphertext("bad PKCS7 padding") }
        return Array(data.dropLast(Int(pad)))
    }
}
