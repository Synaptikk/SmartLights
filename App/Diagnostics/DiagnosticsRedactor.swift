import Foundation
import LightCore

/// Scrubs secrets from diagnostics text before it leaves the device. Every match is replaced with
/// `Log.redact(match)` (`<redacted N chars>`), the same placeholder providers use in their logs.
///
/// Rules, applied in order:
/// 1. `Bearer`/`Basic` authorization values.
/// 2. JWTs (`eyJ...`).
/// 3. Credentials in URLs (`https://user:pass@host`).
/// 4. `key: value` / `key=value` / `"key":"value"` pairs whose key names a secret (password, token,
///    clientkey, appkey, hue-application-key, aes key, signing key, api key, username, ...).
/// 5. E-mail addresses (AiDot/TP-Link/Meross logins).
/// 6. Opaque tokens: runs of 32+ `[A-Za-z0-9_-]` (hex keys such as the WiZ key or Hue client key,
///    Hue app keys, cloud tokens). UUIDs and the stable ids in `allowList` are kept, so light ids
///    stay readable.
///
/// Compiles its expressions per call; use it once on a whole bundle, not per line.
enum DiagnosticsRedactor {
    static func redact(_ text: String, allowList: Set<String> = []) -> String {
        var result = text

        result = replace(in: result, pattern: #"(?i)\b(Bearer|Basic)\s+([A-Za-z0-9._~+/=-]{4,})"#) { g in
            "\(g[1]) \(Log.redact(g[2]))"
        }

        result = replace(in: result, pattern: #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#) { g in
            Log.redact(g[0])
        }

        result = replace(in: result, pattern: #"(?i)\b([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@"#) { g in
            "\(g[1])\(Log.redact(g[2] + ":" + g[3]))@"
        }

        let secretKeys = [
            "password", "passwd", "pwd", "pass", "passphrase",
            "token", "access_?token", "refresh_?token", "id_?token", "auth_?token", "session_?token",
            "secret", "client_?secret", "client_?key", "clientkey", "app_?key", "appkey",
            "hue-application-key", "application_?key", "api_?key", "apikey", "x-api-key", "govee-api-key",
            "aes_?key", "aeskey", "signing_?key", "private_?key", "psk", "key",
            "authorization", "cookie", "set-cookie", "session_?id", "sessionid",
            "username", "user_?name", "account", "email",
        ].joined(separator: "|")
        let keyValuePattern = #"(?i)(?<![A-Za-z0-9_-])((?:"|')?(?:"# + secretKeys + #")(?:"|')?\s*[:=]\s*(?:"|')?)([^"'\s,;&}\]<]+)"#
        result = replace(in: result, pattern: keyValuePattern) { g in
            g[2].hasPrefix("<redacted") ? nil : g[1] + Log.redact(g[2])
        }

        result = replace(in: result, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) { g in
            Log.redact(g[0])
        }

        result = replace(in: result, pattern: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#) { g in
            let token = g[0]
            if allowList.contains(token) || isUUID(token) { return nil }
            return Log.redact(token)
        }

        return result
    }

    private static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Replaces every match of `pattern`; `transform` receives the capture groups (0 = whole match,
    /// "" for groups that did not participate) and returns the replacement, or nil to keep the match.
    private static func replace(in text: String, pattern: String, transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            assertionFailure("Invalid redaction pattern: \(pattern)")
            return text
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            var groups: [String] = []
            groups.reserveCapacity(match.numberOfRanges)
            for i in 0..<match.numberOfRanges {
                let range = match.range(at: i)
                groups.append(range.location == NSNotFound ? "" : source.substring(with: range))
            }
            if let replacement = transform(groups) {
                output.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return output as String
    }
}
