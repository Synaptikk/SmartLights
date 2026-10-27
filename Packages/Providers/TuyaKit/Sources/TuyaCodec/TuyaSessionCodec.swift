import Foundation

/// Encrypts, frames and decodes the messages of one TCP connection (tinytuya `XenonDevice._encode_message`,
/// `_receive`, `_decode_payload` and the `_negotiate_session_key_*` steps).
///
/// | Version | Body encryption | Version header | Trailer |
/// |---|---|---|---|
/// | 3.1 | `CONTROL` only: `"3.1"` + md5 hex [8:24] + base64(AES-ECB) | – | CRC32 |
/// | 3.3 | AES-128-ECB/PKCS7 with the local key | prepended *after* encryption (not for query/heartbeat) | CRC32 |
/// | 3.4 | AES-128-ECB with the session key | prepended *before* encryption | HMAC-SHA256 (session key) |
/// | 3.5 | AES-128-GCM with the session key, AAD = header | prepended before encryption | GCM tag, 6699 framing |
///
/// The same codec serves both ends: `role: .device` writes retcodes and reads client frames
/// (used by the in-package fake device and future simulators).
public struct TuyaSessionCodec: Sendable {
    public enum Role: Sendable { case client, device }

    public enum Failure: Error, Sendable, Equatable {
        case badLocalKey
        case badTrailer
        case notNegotiated
        case negotiationFailed(String)
        case badPayload(String)
    }

    public let version: TuyaVersion
    public let deviceId: String
    public let role: Role
    public var deviceType: TuyaDeviceType
    /// dps listed in device22 queries.
    public var dpsToRequest: [String]
    /// The 16-byte local key ("real local key").
    public let localKey: [UInt8]
    /// 3.4/3.5 per-connection key once negotiated.
    public private(set) var sessionKey: [UInt8]?
    /// Next outgoing sequence number (tinytuya starts at 1 and increments per frame).
    public var seqno: UInt32 = 1

    private var localNonce: [UInt8]?
    private var remoteNonce: [UInt8]?

    public init(version: TuyaVersion, deviceId: String, localKey: [UInt8], role: Role = .client,
                deviceType: TuyaDeviceType = .default, dpsToRequest: [String] = TuyaDPS.lightQuery) throws {
        guard localKey.count == 16 else { throw Failure.badLocalKey }
        self.version = version
        self.deviceId = deviceId
        self.localKey = localKey
        self.role = role
        self.deviceType = deviceType
        self.dpsToRequest = dpsToRequest
    }

    public init(version: TuyaVersion, deviceId: String, localKey: String, role: Role = .client,
                deviceType: TuyaDeviceType = .default) throws {
        guard let key = TuyaCrypto.keyBytes(localKey) else { throw Failure.badLocalKey }
        try self.init(version: version, deviceId: deviceId, localKey: key, role: role, deviceType: deviceType)
    }

    /// Key for frame trailers and body encryption right now.
    public var activeKey: [UInt8] { sessionKey ?? localKey }
    public var needsNegotiation: Bool { version.negotiatesSessionKey && sessionKey == nil }

    // MARK: - Requests

    /// Builds, encrypts and frames `request`.
    public mutating func encode(_ request: TuyaRequest, time: Int, iv: [UInt8]? = nil) throws -> [UInt8] {
        let (command, json) = TuyaPayload.build(request, version: version, deviceType: deviceType, deviceId: deviceId,
                                                time: time, dpsToRequest: dpsToRequest)
        return try encode(command: command.rawValue, payload: json.compactData.bytes, iv: iv)
    }

    /// `_encode_message`: version header, encryption and framing for `command`. Uses (and increments)
    /// `seqno` unless `seqnoOverride` is given. Device-role frames carry `retcode`.
    public mutating func encode(command: UInt32, payload: [UInt8], iv: [UInt8]? = nil, seqnoOverride: UInt32? = nil,
                                retcode: UInt32 = 0) throws -> [UInt8] {
        if version.negotiatesSessionKey, sessionKey == nil, !Self.negotiationCommands.contains(command) {
            throw Failure.notNegotiated
        }
        let seq = seqnoOverride ?? seqno
        if seqnoOverride == nil { seqno &+= 1 }
        let rc: UInt32? = role == .device ? retcode : nil
        let wantsHeader = !TuyaCommand.withoutVersionHeader.contains(command)
        var body = payload

        switch version {
        case .v35:
            if wantsHeader { body = version.versionHeader + body }
            return try TuyaFrame.pack(TuyaMessage(seqno: seq, command: command, retcode: rc, payload: body, prefix: .p6699),
                                      hmacKey: activeKey, iv: iv)
        case .v34:
            if wantsHeader { body = version.versionHeader + body }
            body = try TuyaCrypto.ecbEncrypt(body, key: activeKey)
            return try TuyaFrame.pack(TuyaMessage(seqno: seq, command: command, retcode: rc, payload: body), hmacKey: activeKey)
        case .v33:
            body = try TuyaCrypto.ecbEncrypt(body, key: localKey)
            if wantsHeader { body = version.versionHeader + body }
            return try TuyaFrame.pack(TuyaMessage(seqno: seq, command: command, retcode: rc, payload: body))
        case .v31:
            let signedCommand: UInt32 = role == .client ? TuyaCommand.control.rawValue : TuyaCommand.status.rawValue
            if command == signedCommand, !body.isEmpty {
                let b64 = Array(Data(try TuyaCrypto.ecbEncrypt(body, key: localKey)).base64EncodedString().utf8)
                let digest = TuyaCrypto.md5Hex(Array("data=".utf8) + b64 + Array("||lpv=3.1||".utf8) + localKey)
                let sig = Array(digest.utf8)[8..<24]
                body = TuyaVersion.v31.versionBytes + sig + b64
            }
            return try TuyaFrame.pack(TuyaMessage(seqno: seq, command: command, retcode: rc, payload: body))
        }
    }

    // MARK: - Responses

    /// `_receive` + `_decode_payload` for one raw frame. Throws `.badTrailer` when the CRC/HMAC/GCM tag
    /// does not match (tinytuya only rejects bad GCM tags; we drop all of them).
    public func decode(_ frame: [UInt8]) throws -> TuyaResponse {
        let hmacKey = version.negotiatesSessionKey ? activeKey : nil
        let message = try TuyaFrame.unpack(frame, hmacKey: hmacKey, retcode: role == .client ? .present : .absent)
        guard message.trailerValid else { throw Failure.badTrailer }
        return try decodePayload(message)
    }

    func decodePayload(_ message: TuyaMessage) throws -> TuyaResponse {
        var payload = message.payload
        var response = TuyaResponse(seqno: message.seqno, command: message.command, retcode: message.retcode,
                                    plaintext: [], json: nil, dps: nil, isDataUnvalid: false)
        guard !payload.isEmpty else { return response }

        if version == .v34 {
            do {
                payload = try TuyaCrypto.ecbDecrypt(payload, key: activeKey)
            } catch {
                throw Failure.badPayload("3.4 decrypt failed (\(payload.count) bytes)")
            }
        }
        let versionBytes = version.versionBytes
        if payload.starts(with: TuyaVersion.v31.versionBytes) {
            // "3.1" + 16 md5 hex chars + base64(AES-ECB).
            let b64 = Array(payload.dropFirst(3 + 16))
            guard let raw = Data(base64Encoded: Data(b64)) else { throw Failure.badPayload("3.1 base64") }
            payload = try TuyaCrypto.ecbDecrypt(Array(raw), key: localKey)
        } else if version >= .v33 {
            if payload.starts(with: versionBytes) {
                payload = Array(payload.dropFirst(version.versionHeader.count))
            } else if deviceType == .device22, payload.count & 0x0F != 0 {
                payload = Array(payload.dropFirst(version.versionHeader.count))
            }
            if version == .v33 {
                do {
                    payload = try TuyaCrypto.ecbDecrypt(payload, key: localKey)
                } catch {
                    throw Failure.badPayload("3.3 decrypt failed (\(payload.count) bytes)")
                }
            }
            if Self.contains(payload, "data unvalid") {
                response.isDataUnvalid = true
                response.plaintext = payload
                return response
            }
        } else if payload.first != UInt8(ascii: "{") {
            throw Failure.badPayload("unexpected 3.1 payload")
        }

        response.plaintext = payload
        guard let json = try? TuyaJSON.parse(Data(payload)) else {
            throw Failure.badPayload("invalid JSON (\(payload.count) bytes)")
        }
        response.json = json
        response.dps = json["dps"]?.dictionary ?? json["data"]?["dps"]?.dictionary
        return response
    }

    // MARK: - Session key negotiation (3.4 / 3.5)

    static let negotiationCommands: Set<UInt32> = [
        TuyaCommand.sessKeyNegStart.rawValue, TuyaCommand.sessKeyNegResp.rawValue, TuyaCommand.sessKeyNegFinish.rawValue,
    ]

    /// Step 1 (client): `SESS_KEY_NEG_START` carrying a fresh 16-byte nonce.
    public mutating func negotiationStart(localNonce: [UInt8] = TuyaCrypto.randomNonce(), iv: [UInt8]? = nil) throws -> [UInt8] {
        guard version.negotiatesSessionKey else { throw Failure.negotiationFailed("protocol \(version.rawValue) has no session key") }
        guard localNonce.count == 16 else { throw Failure.negotiationFailed("nonce must be 16 bytes") }
        sessionKey = nil
        self.localNonce = localNonce
        remoteNonce = nil
        return try encode(command: TuyaCommand.sessKeyNegStart.rawValue, payload: localNonce, iv: iv)
    }

    /// Step 3 (client): checks the device's `SESS_KEY_NEG_RESP` (remote nonce + HMAC(local key, our
    /// nonce)), returns the `SESS_KEY_NEG_FINISH` frame (HMAC(local key, remote nonce)) and derives the
    /// session key. Frames after this use the session key.
    public mutating func negotiationFinish(response frame: [UInt8], iv: [UInt8]? = nil) throws -> [UInt8] {
        guard let localNonce else { throw Failure.negotiationFailed("step 1 not sent") }
        let message = try TuyaFrame.unpack(frame, hmacKey: localKey, retcode: .present)
        guard message.trailerValid else { throw Failure.negotiationFailed("bad trailer on step 2") }
        guard message.command == TuyaCommand.sessKeyNegResp.rawValue else {
            throw Failure.negotiationFailed("step 2 returned command \(message.command)")
        }
        var payload = message.payload
        if version == .v34 {
            guard let plain = try? TuyaCrypto.ecbDecrypt(payload, key: localKey) else {
                throw Failure.negotiationFailed("step 2 decrypt failed")
            }
            payload = plain
        }
        guard payload.count >= 48 else { throw Failure.negotiationFailed("step 2 too short (\(payload.count))") }
        let remote = Array(payload[0..<16])
        guard Array(payload[16..<48]) == TuyaCrypto.hmacSHA256(localNonce, key: localKey) else {
            throw Failure.negotiationFailed("step 2 HMAC mismatch (wrong local key?)")
        }
        let finish = try encode(command: TuyaCommand.sessKeyNegFinish.rawValue,
                                payload: TuyaCrypto.hmacSHA256(remote, key: localKey), iv: iv)
        remoteNonce = remote
        sessionKey = try Self.deriveSessionKey(version: version, localKey: localKey, localNonce: localNonce, remoteNonce: remote)
        return finish
    }

    /// `_negotiate_session_key_generate_finalize`: XOR the nonces, then encrypt the result with the
    /// local key (3.4: AES-ECB; 3.5: AES-GCM with IV = local nonce [0..<12], ciphertext only).
    public static func deriveSessionKey(version: TuyaVersion, localKey: [UInt8], localNonce: [UInt8], remoteNonce: [UInt8]) throws -> [UInt8] {
        let xor = zip(localNonce, remoteNonce).map { $0 ^ $1 }
        if version == .v35 {
            return try TuyaCrypto.gcmSeal(xor, key: localKey, iv: Array(localNonce[0..<12])).ciphertext
        }
        return try TuyaCrypto.ecbEncryptBlocks(xor, key: localKey)
    }

    /// Device side of step 2: decodes the client's `SESS_KEY_NEG_START` and answers with `remoteNonce`.
    public mutating func deviceNegotiationResponse(to frame: [UInt8], remoteNonce: [UInt8], iv: [UInt8]? = nil,
                                                   seqno: UInt32? = nil) throws -> [UInt8] {
        let message = try TuyaFrame.unpack(frame, hmacKey: localKey, retcode: .absent)
        guard message.trailerValid, message.command == TuyaCommand.sessKeyNegStart.rawValue else {
            throw Failure.negotiationFailed("expected step 1")
        }
        var nonce = message.payload
        if version == .v34 { nonce = (try? TuyaCrypto.ecbDecrypt(nonce, key: localKey)) ?? [] }
        guard nonce.count == 16 else { throw Failure.negotiationFailed("bad client nonce") }
        sessionKey = nil
        localNonce = nonce
        self.remoteNonce = remoteNonce
        return try encode(command: TuyaCommand.sessKeyNegResp.rawValue,
                          payload: remoteNonce + TuyaCrypto.hmacSHA256(nonce, key: localKey), iv: iv, seqnoOverride: seqno)
    }

    /// Device side of step 3: verifies HMAC(local key, remote nonce) and switches to the session key.
    public mutating func deviceNegotiationFinish(_ frame: [UInt8]) throws {
        guard let localNonce, let remoteNonce else { throw Failure.negotiationFailed("step 2 not sent") }
        let message = try TuyaFrame.unpack(frame, hmacKey: localKey, retcode: .absent)
        guard message.trailerValid, message.command == TuyaCommand.sessKeyNegFinish.rawValue else {
            throw Failure.negotiationFailed("expected step 3")
        }
        var payload = message.payload
        if version == .v34 { payload = (try? TuyaCrypto.ecbDecrypt(payload, key: localKey)) ?? [] }
        guard payload == TuyaCrypto.hmacSHA256(remoteNonce, key: localKey) else {
            throw Failure.negotiationFailed("step 3 HMAC mismatch")
        }
        sessionKey = try Self.deriveSessionKey(version: version, localKey: localKey, localNonce: localNonce, remoteNonce: remoteNonce)
    }

    private static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard haystack.count >= n.count else { return false }
        for i in 0...(haystack.count - n.count) where haystack[i] == n[0] && Array(haystack[i..<i + n.count]) == n {
            return true
        }
        return false
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}
