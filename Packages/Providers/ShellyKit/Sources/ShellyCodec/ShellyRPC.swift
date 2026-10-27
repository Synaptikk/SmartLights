import Foundation

/// A Gen2+ JSON-RPC 2.0-style request frame: `{"id":1,"src":"smartlights-1a2b","method":"Light.Set","params":{...}}`.
/// The same frame is POSTed to `/rpc` or sent over the `/rpc` WebSocket.
public struct ShellyRPCRequest: Sendable, Hashable {
    public var id: Int
    /// Client id; the device addresses replies and notifications to it (`dst`).
    public var src: String
    public var method: String
    public var params: ShellyJSON?
    /// Digest `auth` object for the WebSocket channel (HTTP uses the `Authorization` header).
    public var auth: ShellyJSON?

    public init(id: Int, src: String, method: String, params: ShellyJSON? = nil, auth: ShellyJSON? = nil) {
        self.id = id
        self.src = src
        self.method = method
        self.params = params
        self.auth = auth
    }

    public var json: ShellyJSON {
        var o: [String: ShellyJSON] = ["id": .number(Double(id)), "src": .string(src), "method": .string(method)]
        if let params { o["params"] = params }
        if let auth { o["auth"] = auth }
        return .object(o)
    }

    public func encoded() -> Data { json.encoded() }
}

/// RPC error codes seen from Shelly devices.
public enum ShellyRPCErrorCode {
    public static let unauthorized = 401
    public static let notFound = 404
    public static let invalidArgument = -103
    public static let unavailable = -114
}

/// One frame received from a Gen2+ device: a response to a request, or a notification.
public enum ShellyRPCFrame: Sendable, Hashable {
    case result(id: Int, result: ShellyJSON)
    case error(id: Int?, code: Int, message: String)
    /// `NotifyStatus` (partial component status), `NotifyFullStatus`, `NotifyEvent`.
    case notification(method: String, src: String?, params: ShellyJSON)

    public static func parse(_ data: Data) -> ShellyRPCFrame? {
        guard let json = try? ShellyJSON.parse(data) else { return nil }
        return parse(json)
    }

    public static func parse(_ json: ShellyJSON) -> ShellyRPCFrame? {
        if let method = json["method"]?.string, json["id"] == nil || json["result"] == nil {
            return .notification(method: method, src: json["src"]?.string, params: json["params"] ?? .object([:]))
        }
        if let error = json["error"] {
            return .error(id: json["id"]?.int, code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "")
        }
        if let id = json["id"]?.int {
            return .result(id: id, result: json["result"] ?? .null)
        }
        return nil
    }
}

/// Gen1 REST: `GET /light/0?turn=on&brightness=50&temp=3000&transition=500`.
public struct ShellyGen1Request: Sendable, Hashable {
    /// `/light/0`, `/color/0`, `/white/2`, `/status`, `/settings`, `/shelly`.
    public var path: String
    public var query: [(String, String)]

    public init(path: String, query: [(String, String)] = []) {
        self.path = path
        self.query = query
    }

    public static func == (a: ShellyGen1Request, b: ShellyGen1Request) -> Bool {
        a.path == b.path && a.query.map { "\($0)=\($1)" } == b.query.map { "\($0)=\($1)" }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        for (k, v) in query { hasher.combine(k); hasher.combine(v) }
    }

    /// Path plus percent-encoded query, e.g. `/light/0?turn=on&brightness=50`.
    public var uri: String {
        guard !query.isEmpty else { return path }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let q = query.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }
        return path + "?" + q.joined(separator: "&")
    }

    /// Parses `uri` back (fakes and tests).
    public static func parse(uri: String) -> ShellyGen1Request {
        let parts = uri.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [(String, String)] = []
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query.append((kv[0], kv.count > 1 ? kv[1] : ""))
            }
        }
        return ShellyGen1Request(path: parts.first ?? uri, query: query)
    }
}
