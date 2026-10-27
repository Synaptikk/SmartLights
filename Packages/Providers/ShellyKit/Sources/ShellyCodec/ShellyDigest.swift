import Crypto
import Foundation

/// A digest challenge: from a `401` `WWW-Authenticate: Digest ...` header (HTTP) or from the
/// JSON in a Gen2+ RPC error 401 message (WebSocket).
public struct ShellyDigestChallenge: Sendable, Hashable {
    public enum Algorithm: String, Sendable, Hashable {
        case md5 = "MD5"
        case sha256 = "SHA-256"
    }

    public var realm: String
    public var nonce: String
    public var qop: String?
    public var algorithm: Algorithm
    public var opaque: String?
    /// RPC challenges carry the nonce count to use next.
    public var nc: Int?
    public var stale: Bool

    public init(realm: String, nonce: String, qop: String? = "auth", algorithm: Algorithm = .sha256,
                opaque: String? = nil, nc: Int? = nil, stale: Bool = false) {
        self.realm = realm
        self.nonce = nonce
        self.qop = qop
        self.algorithm = algorithm
        self.opaque = opaque
        self.nc = nc
        self.stale = stale
    }

    /// Parses `Digest qop="auth", realm="shellypro4pm-f008d1d8b8b8", nonce="60dc59c6", algorithm=SHA-256`.
    /// Returns nil for other schemes or unsupported algorithms.
    public init?(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest ") else { return nil }
        let params = Self.parseParameters(String(trimmed.dropFirst(7)))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        let algorithmName = params["algorithm"] ?? "MD5"
        guard let algorithm = Algorithm(rawValue: algorithmName.uppercased()) else { return nil }
        // qop may list several options ("auth,auth-int"); only "auth" is implemented.
        let qop = params["qop"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard qop == nil || qop!.contains("auth") else { return nil }
        self.init(realm: realm, nonce: nonce, qop: qop == nil ? nil : "auth", algorithm: algorithm,
                  opaque: params["opaque"], stale: params["stale"]?.lowercased() == "true")
    }

    /// Parses the RPC error message JSON `{"auth_type":"digest","nonce":1625038762,"nc":1,
    /// "realm":"shellypro4pm-f008d1d8b8b8","algorithm":"SHA-256"}`.
    public init?(rpcErrorMessage: String) {
        guard let json = try? ShellyJSON.parse(rpcErrorMessage), let realm = json["realm"]?.string else { return nil }
        let nonce = json["nonce"]?.string ?? json["nonce"]?.int.map(String.init)
        guard let nonce, let algorithm = Algorithm(rawValue: json["algorithm"]?.string ?? "SHA-256") else { return nil }
        self.init(realm: realm, nonce: nonce, qop: "auth", algorithm: algorithm,
                  nc: json["nc"]?.int ?? json["nc"]?.string.flatMap { Int($0) }, stale: json["stale"]?.bool ?? false)
    }

    /// `key=value` / `key="quoted, value"` pairs separated by commas.
    static func parseParameters(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == "," || s[i] == " " { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: eq)
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i])
                    i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let end = s[i...].firstIndex(of: ",") ?? s.endIndex
                value = s[i..<end].trimmingCharacters(in: .whitespaces)
                i = end
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

/// HTTP Digest (RFC 7616) and Shelly's RPC `auth` object. Gen2+ devices use user `admin` and
/// SHA-256; the realm is the device id.
public enum ShellyDigest {
    public static let defaultUser = "admin"

    public static func hash(_ s: String, _ algorithm: ShellyDigestChallenge.Algorithm) -> String {
        let data = Data(s.utf8)
        switch algorithm {
        case .md5: return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256: return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The `response` value: `H(H(user:realm:pass):nonce:nc:cnonce:qop:H(method:uri))`
    /// (without qop: `H(HA1:nonce:HA2)`). `nc` is the 8-hex-digit form.
    public static func response(
        challenge: ShellyDigestChallenge, method: String, uri: String, username: String, password: String,
        cnonce: String, nc: String
    ) -> String {
        let a = challenge.algorithm
        let ha1 = hash("\(username):\(challenge.realm):\(password)", a)
        let ha2 = hash("\(method):\(uri)", a)
        if let qop = challenge.qop {
            return hash("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)", a)
        }
        return hash("\(ha1):\(challenge.nonce):\(ha2)", a)
    }

    /// `Authorization` header value for one request. `nonceCount` starts at 1 per nonce.
    public static func authorization(
        challenge: ShellyDigestChallenge, method: String, uri: String, username: String = defaultUser,
        password: String, cnonce: String, nonceCount: Int
    ) -> String {
        let nc = String(format: "%08x", nonceCount)
        let r = response(challenge: challenge, method: method, uri: uri, username: username, password: password, cnonce: cnonce, nc: nc)
        var parts = [
            "username=\"\(username)\"", "realm=\"\(challenge.realm)\"", "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"", "algorithm=\(challenge.algorithm.rawValue)", "response=\"\(r)\"",
        ]
        if let qop = challenge.qop { parts += ["qop=\(qop)", "nc=\(nc)", "cnonce=\"\(cnonce)\""] }
        if let opaque = challenge.opaque { parts.append("opaque=\"\(opaque)\"") }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// The `auth` member of an RPC frame (WebSocket channel). Shelly hashes
    /// `HA1:nonce:nc:cnonce:auth:HA2` with decimal `nc` and `HA2 = H("dummy_method:dummy_uri")`.
    public static func rpcAuth(
        challenge: ShellyDigestChallenge, username: String = defaultUser, password: String, cnonce: String, nonceCount: Int
    ) -> ShellyJSON {
        let a = challenge.algorithm
        let ha1 = hash("\(username):\(challenge.realm):\(password)", a)
        let ha2 = hash("dummy_method:dummy_uri", a)
        let r = hash("\(ha1):\(challenge.nonce):\(nonceCount):\(cnonce):auth:\(ha2)", a)
        return [
            "realm": .string(challenge.realm), "username": .string(username), "nonce": .string(challenge.nonce),
            "cnonce": .string(cnonce), "response": .string(r), "algorithm": .string(a.rawValue),
            "nc": .number(Double(nonceCount)),
        ]
    }

    /// Gen1 HTTP Basic auth.
    public static func basicAuthorization(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Random client nonce (16 bytes, hex).
    public static func makeCnonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
