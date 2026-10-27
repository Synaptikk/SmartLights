import Crypto
import Foundation

/// The per-home `udp_signing_key` (WiZ app > Home settings > Integrations > Local integrations):
/// 32 hex characters = 16 key bytes. `description` never reveals the key.
public struct WiZSigningKey: Sendable, Hashable, CustomStringConvertible {
    /// The 16 key bytes.
    public let bytes: [UInt8]

    /// Strict 32-hex form (surrounding whitespace ignored), as `wiz.mjs` checks with
    /// `/^[0-9a-fA-F]{32}$/`.
    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 32 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        var high: UInt8?
        for c in text.utf8 {
            guard let nibble = Self.nibble(c) else { return nil }
            if let h = high {
                out.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        bytes = out
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Lower-case 32-hex form (what is stored in the Keychain). Never log it.
    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public var description: String { "WiZSigningKey(<redacted>)" }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    // MARK: Import

    public enum ImportError: Error, Sendable, Hashable, CustomStringConvertible {
        case empty
        /// JSON without a `udp_signing_key` string anywhere in it.
        case keyNotFound
        /// The text/key is not 32 hex characters.
        case invalidKey

        public var description: String {
            switch self {
            case .empty: "The file or text is empty."
            case .keyNotFound: "No \"udp_signing_key\" was found in that file."
            case .invalidKey: "The key must be exactly 32 hexadecimal characters (0-9, a-f)."
            }
        }
    }

    /// JSON keys accepted for the key inside an export.
    static let importKeyNames: Set<String> = ["udp_signing_key", "udpSigningKey"]

    /// Accepts the Local-integrations JSON export (the `udp_signing_key` may be nested anywhere),
    /// a JSON string literal, or the raw 32-hex key (whitespace/newlines ignored).
    public static func parseImport(_ data: Data) throws -> WiZSigningKey {
        try parseImport(String(decoding: data, as: UTF8.self))
    }

    public static func parseImport(_ input: String) throws -> WiZSigningKey {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.empty }
        if text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("\"") {
            guard let json = try? WiZJSON.parse(text) else {
                throw text.hasPrefix("\"") ? ImportError.invalidKey : ImportError.keyNotFound
            }
            if case .string(let s) = json {
                guard let key = WiZSigningKey(hex: s) else { throw ImportError.invalidKey }
                return key
            }
            guard let found = findKey(in: json) else { throw ImportError.keyNotFound }
            guard let key = WiZSigningKey(hex: found) else { throw ImportError.invalidKey }
            return key
        }
        guard let key = WiZSigningKey(hex: text) else { throw ImportError.invalidKey }
        return key
    }

    private static func findKey(in json: WiZJSON) -> String? {
        switch json {
        case .object(let o):
            for m in o where importKeyNames.contains(m.key) {
                if let s = m.value.stringValue { return s }
            }
            for m in o { if let s = findKey(in: m.value) { return s } }
            return nil
        case .array(let a):
            for v in a { if let s = findKey(in: v) { return s } }
            return nil
        default:
            return nil
        }
    }
}

/// HMAC-SHA256 request signing for firmware 1.34+ (pywizlight issue #213 / PR #216,
/// research_wiz.md §1.7), mirroring `signParams` in `tools/probe/wiz.mjs`:
///
/// ```js
/// const signed = { ...params, sigTs: Math.floor(Date.now() / 1000) };
/// const hmac = crypto.createHmac('sha256', Buffer.from(hexKey, 'hex'))
///                    .update(JSON.stringify(signed)).digest('base64');
/// ```
///
/// i.e. `sigTs` is appended after the existing params (or replaced in place if present), the
/// MAC covers the compact JSON of the whole `params` object, and the base64 result goes into a
/// top-level `"hmac"` member.
public enum WiZSigner {
    public static func sign(_ params: WiZObject, key: WiZSigningKey, sigTs: Int) -> (params: WiZObject, hmac: String) {
        var signed = params
        signed["sigTs"] = .int(sigTs)
        return (signed, hmac(Array(signed.compactString.utf8), key: key))
    }

    /// base64(HMAC-SHA256(key, message)).
    public static func hmac(_ message: [UInt8], key: WiZSigningKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.bytes))
        return Data(mac).base64EncodedString()
    }

    /// Current unix time in whole seconds (`Math.floor(Date.now() / 1000)`), optionally shifted
    /// by a learned bulb clock offset.
    public static func timestamp(now: Date = Date(), offset: Int = 0) -> Int {
        Int(now.timeIntervalSince1970.rounded(.down)) + offset
    }
}
