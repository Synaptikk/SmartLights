import Foundation

/// Frame prefixes (`core/header.py`).
public enum TuyaPrefix: UInt32, Sendable {
    /// 3.1-3.4: `>4I prefix seqno cmd length`, payload, CRC32 (or HMAC-SHA256 for 3.4), `0x0000AA55`.
    case p55AA = 0x0000_55AA
    /// 3.5: `>IHIII prefix 0 seqno cmd length`, 12-byte IV, AES-GCM ciphertext, 16-byte tag, `0x00009966`.
    case p6699 = 0x0000_6699

    public var suffix: UInt32 { self == .p55AA ? 0x0000_AA55 : 0x0000_9966 }
    public var headerSize: Int { self == .p55AA ? 16 : 18 }
    public var bytes: [UInt8] { TuyaBytes.be32(rawValue) }
}

/// One frame (tinytuya `TuyaMessage`). `payload` is what sits between header and trailer *after*
/// the GCM layer: still AES-ECB encrypted for 3.3/3.4, plaintext for 3.5. `retcode` is the 4-byte
/// return code that only device-to-client frames carry.
public struct TuyaMessage: Sendable, Equatable {
    public var seqno: UInt32
    public var command: UInt32
    public var retcode: UInt32?
    public var payload: [UInt8]
    public var prefix: TuyaPrefix
    /// GCM IV (6699 frames).
    public var iv: [UInt8]?
    /// CRC32/HMAC matched, or the GCM tag verified.
    public var trailerValid: Bool

    public init(seqno: UInt32, command: UInt32, retcode: UInt32? = nil, payload: [UInt8], prefix: TuyaPrefix = .p55AA,
                iv: [UInt8]? = nil, trailerValid: Bool = true) {
        self.seqno = seqno
        self.command = command
        self.retcode = retcode
        self.payload = payload
        self.prefix = prefix
        self.iv = iv
        self.trailerValid = trailerValid
    }
}

/// Whether a frame carries a retcode (`unpack_message(no_retcode=...)`).
public enum TuyaRetcodeMode: Sendable {
    /// Device -> client (`no_retcode=False`).
    case present
    /// Client -> device.
    case absent
    /// UDP broadcasts (`no_retcode=None`): strip 4 bytes only if JSON starts right after them.
    case detect
}

public enum TuyaFrameError: Error, Sendable, Equatable {
    case badPrefix(UInt32)
    case truncated(need: Int, have: Int)
    case oversized(Int)
    case keyRequired
    case lengthTooSmall(Int)
}

public enum TuyaFrame {
    /// `pack_message`. `hmacKey`: 55AA uses HMAC-SHA256 instead of CRC32 when set (3.4); 6699 requires it
    /// (the AES-GCM key). `iv` is used for 6699 (random when nil). A non-nil `message.retcode` is written
    /// (device frames); tinytuya's clients never send one.
    public static func pack(_ message: TuyaMessage, hmacKey: [UInt8]? = nil, iv: [UInt8]? = nil) throws -> [UInt8] {
        let raw = (message.retcode.map(TuyaBytes.be32) ?? []) + message.payload
        switch message.prefix {
        case .p55AA:
            let trailerSize = hmacKey == nil ? 8 : 36
            var data = TuyaBytes.be32(TuyaPrefix.p55AA.rawValue) + TuyaBytes.be32(message.seqno) + TuyaBytes.be32(message.command)
                + TuyaBytes.be32(UInt32(raw.count + trailerSize))
            data += raw
            if let hmacKey {
                data += TuyaCrypto.hmacSHA256(data, key: hmacKey)
            } else {
                data += TuyaBytes.be32(TuyaCrypto.crc32(data))
            }
            return data + TuyaBytes.be32(TuyaPrefix.p55AA.suffix)
        case .p6699:
            guard let key = hmacKey else { throw TuyaFrameError.keyRequired }
            let nonce = iv ?? message.iv ?? TuyaCrypto.randomIV()
            let length = UInt32(raw.count + 12 + 16)
            let header = TuyaBytes.be32(TuyaPrefix.p6699.rawValue) + [0, 0] + TuyaBytes.be32(message.seqno)
                + TuyaBytes.be32(message.command) + TuyaBytes.be32(length)
            let sealed = try TuyaCrypto.gcmSeal(raw, key: key, iv: nonce, aad: Array(header[4...]))
            return header + nonce + sealed.ciphertext + sealed.tag + TuyaBytes.be32(TuyaPrefix.p6699.suffix)
        }
    }

    /// Header fields and the full frame size.
    public struct Header: Sendable, Equatable {
        public var prefix: TuyaPrefix
        public var seqno: UInt32
        public var command: UInt32
        public var length: Int
        public var totalLength: Int
    }

    public static func parseHeader(_ data: some Collection<UInt8>, maxPayload: Int = TuyaConstants.maxPayloadLength) throws -> Header {
        let b = Array(data.prefix(18))
        guard b.count >= 16 else { throw TuyaFrameError.truncated(need: 16, have: b.count) }
        let prefixValue = TuyaBytes.readBE32(b, 0)
        guard let prefix = TuyaPrefix(rawValue: prefixValue) else { throw TuyaFrameError.badPrefix(prefixValue) }
        switch prefix {
        case .p55AA:
            let length = Int(TuyaBytes.readBE32(b, 12))
            guard length <= maxPayload else { throw TuyaFrameError.oversized(length) }
            return Header(prefix: prefix, seqno: TuyaBytes.readBE32(b, 4), command: TuyaBytes.readBE32(b, 8),
                          length: length, totalLength: 16 + length)
        case .p6699:
            guard b.count >= 18 else { throw TuyaFrameError.truncated(need: 18, have: b.count) }
            let length = Int(TuyaBytes.readBE32(b, 14))
            guard length <= maxPayload else { throw TuyaFrameError.oversized(length) }
            return Header(prefix: prefix, seqno: TuyaBytes.readBE32(b, 6), command: TuyaBytes.readBE32(b, 10),
                          length: length, totalLength: 18 + length + 4)
        }
    }

    /// `unpack_message`. For 55AA the trailer is CRC32, or HMAC-SHA256 with `hmacKey`; for 6699 `hmacKey`
    /// is the GCM key and the payload comes back decrypted. A failed check sets `trailerValid = false`
    /// (the 6699 payload is then empty).
    public static func unpack(_ data: [UInt8], hmacKey: [UInt8]? = nil, retcode mode: TuyaRetcodeMode = .present) throws -> TuyaMessage {
        let header = try parseHeader(data, maxPayload: Int.max)
        guard data.count >= header.totalLength else { throw TuyaFrameError.truncated(need: header.totalLength, have: data.count) }
        switch header.prefix {
        case .p55AA:
            let trailerSize = hmacKey == nil ? 8 : 36
            let retcodeSize = mode == .present ? 4 : 0
            guard header.length >= trailerSize + retcodeSize else { throw TuyaFrameError.lengthTooSmall(header.length) }
            let end = header.totalLength
            let trailerStart = end - trailerSize
            let signed = Array(data[0..<trailerStart])
            let valid: Bool
            if let hmacKey {
                valid = TuyaCrypto.hmacSHA256(signed, key: hmacKey) == Array(data[trailerStart..<trailerStart + 32])
            } else {
                valid = TuyaCrypto.crc32(signed) == TuyaBytes.readBE32(data, trailerStart)
            }
            var retcode: UInt32?
            var bodyStart = 16
            if mode == .present {
                retcode = TuyaBytes.readBE32(data, 16)
                bodyStart = 20
            }
            var payload = Array(data[bodyStart..<trailerStart])
            if mode == .detect, payload.count > 4, payload.first != UInt8(ascii: "{"), payload[4] == UInt8(ascii: "{") {
                retcode = TuyaBytes.readBE32(payload, 0)
                payload.removeFirst(4)
            }
            return TuyaMessage(seqno: header.seqno, command: header.command, retcode: retcode, payload: payload,
                               prefix: .p55AA, trailerValid: valid)
        case .p6699:
            guard let key = hmacKey else { throw TuyaFrameError.keyRequired }
            guard header.length >= 28 else { throw TuyaFrameError.lengthTooSmall(header.length) }
            let iv = Array(data[18..<30])
            let tagStart = 18 + header.length - 16
            let ciphertext = Array(data[30..<tagStart])
            let tag = Array(data[tagStart..<tagStart + 16])
            guard var plain = try? TuyaCrypto.gcmOpen(ciphertext, tag: tag, key: key, iv: iv, aad: Array(data[4..<18])) else {
                return TuyaMessage(seqno: header.seqno, command: header.command, payload: [], prefix: .p6699, iv: iv,
                                   trailerValid: false)
            }
            var retcode: UInt32?
            switch mode {
            case .present:
                if plain.count >= 4 {
                    retcode = TuyaBytes.readBE32(plain, 0)
                    plain.removeFirst(4)
                }
            case .detect:
                if plain.count > 4, plain.first != UInt8(ascii: "{"), plain[4] == UInt8(ascii: "{") {
                    retcode = TuyaBytes.readBE32(plain, 0)
                    plain.removeFirst(4)
                }
            case .absent:
                break
            }
            return TuyaMessage(seqno: header.seqno, command: header.command, retcode: retcode, payload: plain,
                               prefix: .p6699, iv: iv, trailerValid: true)
        }
    }
}

/// Incremental splitter for the TCP byte stream: frames may be split or coalesced, and junk before a
/// prefix is skipped (tinytuya `_receive` resyncs on the next `0x000055AA`/`0x00006699`).
public struct TuyaFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public let maxPayload: Int

    public init(maxPayload: Int = TuyaConstants.maxPayloadLength) {
        self.maxPayload = maxPayload
    }

    public var bufferedByteCount: Int { buffer.count }

    /// Appends bytes and returns every complete raw frame. Throws `.oversized` on a header claiming more
    /// than `maxPayload` (the caller should reset the connection).
    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var frames: [[UInt8]] = []
        while true {
            guard let start = Self.prefixOffset(in: buffer) else {
                // Keep the last 3 bytes: they may be the start of a prefix.
                if buffer.count > 3 { buffer.removeFirst(buffer.count - 3) }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 18 || (buffer.count >= 16 && buffer[2] == 0x55) else { break }
            let header = try TuyaFrame.parseHeader(buffer, maxPayload: maxPayload)
            guard buffer.count >= header.totalLength else { break }
            frames.append(Array(buffer[0..<header.totalLength]))
            buffer.removeFirst(header.totalLength)
        }
        return frames
    }

    public mutating func reset() { buffer = [] }

    static func prefixOffset(in b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 0 && b[i + 1] == 0 {
            if (b[i + 2] == 0x55 && b[i + 3] == 0xAA) || (b[i + 2] == 0x66 && b[i + 3] == 0x99) { return i }
        }
        return nil
    }
}

enum TuyaBytes {
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func readBE32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16 | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
    }
}
