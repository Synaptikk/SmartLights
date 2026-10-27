import Foundation

/// Well-known ports and addresses of the Yeelight LAN protocol (Yeelight Inter-Operation Spec).
public enum YeelightProtocol {
    /// SSDP-style multicast group used for discovery and advertisements.
    public static let ssdpGroup = "239.255.255.250"
    /// Discovery port (not the standard SSDP 1900).
    public static let ssdpPort: UInt16 = 1982
    /// TCP control port.
    public static let controlPort: UInt16 = 55443
    /// Search target understood by Yeelight devices.
    public static let searchTarget = "wifi_bulb"
    /// Bonjour service advertised by Yeelight (miio) devices, instance names `yeelink-*`.
    public static let bonjourServiceType = "_miio._udp"
    /// Documented command quota: 60 commands per minute per device (spec §4.1, HA docs).
    public static let commandsPerMinute = 60
    /// Documented maximum number of simultaneous TCP connections a device accepts.
    public static let maxConnections = 4
    /// Minimum duration for the "smooth" effect, in milliseconds.
    public static let minimumSmoothDuration = 30
}

/// A JSON-RPC call without its id: what the planner produces and the session numbers.
public struct YeelightCall: Sendable, Hashable, CustomStringConvertible {
    public var method: String
    public var params: [YeelightValue]

    public init(method: String, params: [YeelightValue] = []) {
        self.method = method
        self.params = params
    }

    public func request(id: Int) -> YeelightRequest {
        YeelightRequest(id: id, method: method, params: params)
    }

    public var description: String { "\(method)\(YeelightValue.array(params).jsonText)" }
}

/// One JSON-RPC request line: `{"id":1,"method":"set_power","params":["on","smooth",500]}\r\n`.
public struct YeelightRequest: Sendable, Hashable {
    public var id: Int
    public var method: String
    public var params: [YeelightValue]

    public init(id: Int, method: String, params: [YeelightValue] = []) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// The JSON object text without the line terminator (keys in spec order: id, method, params).
    public var jsonText: String {
        var out = "{\"id\":\(id),\"method\":"
        YeelightValue.writeString(method, into: &out)
        out += ",\"params\":"
        YeelightValue.array(params).write(into: &out)
        out += "}"
        return out
    }

    /// Wire bytes: JSON followed by `\r\n` (the spec terminates every message with CRLF).
    public var encoded: Data { Data((jsonText + "\r\n").utf8) }
}

/// Error object returned by a device: `{"id":2,"error":{"code":-1,"message":"unsupported method"}}`.
public struct YeelightRPCError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "Yeelight error \(code): \(message)" }

    /// The device rejected the call because its command quota is exhausted.
    public var isQuotaExceeded: Bool { message.lowercased().contains("quota") }
}

/// A message received from a device on the control connection.
public enum YeelightMessage: Sendable, Hashable {
    /// Successful reply (`"result":["ok"]` for setters, property values for `get_prop`).
    case result(id: Int, values: [YeelightValue])
    /// Error reply. `id` may be missing for malformed requests.
    case error(id: Int?, YeelightRPCError)
    /// Unsolicited notification, e.g. `{"method":"props","params":{"power":"on","bright":"10"}}`.
    case notification(method: String, params: [String: YeelightValue])

    /// The request id this message answers, if any.
    public var id: Int? {
        switch self {
        case .result(let id, _): id
        case .error(let id, _): id
        case .notification: nil
        }
    }

    /// Parses one line (with or without trailing CR/LF). Returns nil for blank or unrecognised lines.
    public static func parse(_ line: Data) -> YeelightMessage? {
        var bytes = line[...]
        while let last = bytes.last, last == 0x0A || last == 0x0D || last == 0x20 { bytes = bytes.dropLast() }
        guard !bytes.isEmpty,
              let object = try? JSONDecoder().decode([String: YeelightValue].self, from: Data(bytes))
        else { return nil }
        return parse(object: object)
    }

    /// Parses one line of text.
    public static func parse(_ line: String) -> YeelightMessage? { parse(Data(line.utf8)) }

    static func parse(object: [String: YeelightValue]) -> YeelightMessage? {
        let id = object["id"]?.intValue
        if let error = object["error"] {
            let body = error.objectValue ?? [:]
            let code = body["code"]?.intValue ?? -1
            let message = body["message"]?.stringValue ?? error.stringValue ?? "unknown error"
            return .error(id: id, YeelightRPCError(code: code, message: message))
        }
        if let id, let result = object["result"] {
            switch result {
            case .array(let values): return .result(id: id, values: values)
            case .null: return .result(id: id, values: [])
            default: return .result(id: id, values: [result])
            }
        }
        if let method = object["method"]?.stringValue {
            return .notification(method: method, params: object["params"]?.objectValue ?? [:])
        }
        return nil
    }
}

/// Splits a TCP byte stream into lines. Devices terminate messages with `\r\n`; a bare `\n` is
/// accepted too, and empty lines are skipped. A guard drops runaway partial lines.
public struct YeelightLineFramer: Sendable {
    private var buffer = Data()
    /// Partial lines longer than this are discarded (protects against garbage streams).
    public var maximumLineLength: Int

    public init(maximumLineLength: Int = 64 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Appends received bytes and returns every complete line (without terminators).
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > maximumLineLength { buffer.removeAll() }
        return lines
    }

    /// Bytes held back waiting for a terminator.
    public var pendingByteCount: Int { buffer.count }

    public mutating func reset() { buffer.removeAll() }
}
