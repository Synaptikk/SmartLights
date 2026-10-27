import Foundation

/// TCP 10000 frame (python-aidot `DeviceClient.get_send_packet` / `receive_data`):
/// `>H 0x1EED`, `>H msgtype` (1 = login/action, 2 = ping), `>I bodysize`, then the AES-128-ECB/PKCS7 body.
public struct AiDotFrame: Sendable, Equatable {
    public static let magic: UInt16 = 0x1EED
    public static let headerSize = 8
    /// Upper bound accepted by the decoder (real messages are < 4 KiB).
    public static let maxBodySize = 1 << 20

    public enum MessageType: UInt16, Sendable {
        case action = 1
        case ping = 2
    }

    public var magic: UInt16
    public var msgType: UInt16
    public var body: Data

    public init(msgType: UInt16, body: Data, magic: UInt16 = AiDotFrame.magic) {
        self.magic = magic
        self.msgType = msgType
        self.body = body
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + body.count)
        out.append(UInt8(magic >> 8)); out.append(UInt8(magic & 0xFF))
        out.append(UInt8(msgType >> 8)); out.append(UInt8(msgType & 0xFF))
        let n = UInt32(body.count)
        out.append(UInt8(n >> 24)); out.append(UInt8((n >> 16) & 0xFF)); out.append(UInt8((n >> 8) & 0xFF)); out.append(UInt8(n & 0xFF))
        out.append(body)
        return out
    }

    /// Encrypts `json` (Python formatting) and frames it.
    public static func encrypted(_ json: AiDotJSON, type: MessageType, key: [UInt8]) throws -> AiDotFrame {
        AiDotFrame(msgType: type.rawValue, body: try AiDotCrypto.aesEncrypt(json.pythonData, key: key))
    }

    public func decryptedJSON(key: [UInt8]) throws -> AiDotJSON {
        try AiDotJSON.parse(AiDotCrypto.aesDecrypt(body, key: key))
    }
}

/// Incremental frame decoder for a TCP byte stream (frames may be split or coalesced).
public struct AiDotFrameDecoder: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case badMagic(UInt16)
        case oversized(Int)
    }

    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    /// Appends bytes and returns every complete frame. Throws on a corrupt stream (the session
    /// should then be reset; python-aidot ignores the magic, we are stricter to resync quickly).
    public mutating func append(_ bytes: Data) throws -> [AiDotFrame] {
        buffer.append(bytes)
        var frames: [AiDotFrame] = []
        while buffer.count >= AiDotFrame.headerSize {
            let b = [UInt8](buffer.prefix(AiDotFrame.headerSize))
            let magic = UInt16(b[0]) << 8 | UInt16(b[1])
            guard magic == AiDotFrame.magic else { throw Failure.badMagic(magic) }
            let type = UInt16(b[2]) << 8 | UInt16(b[3])
            let size = Int(UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]))
            guard size <= AiDotFrame.maxBodySize else { throw Failure.oversized(size) }
            guard buffer.count >= AiDotFrame.headerSize + size else { break }
            let start = buffer.startIndex + AiDotFrame.headerSize
            frames.append(AiDotFrame(msgType: type, body: Data(buffer[start..<start + size]), magic: magic))
            buffer = Data(buffer[(start + size)...])
        }
        return frames
    }

    public mutating func reset() { buffer = Data() }
}

/// `datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")` (local time, microseconds).
public enum AiDotTimestamp {
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let t = date.timeIntervalSince1970
        let seconds = t.rounded(.down)
        let micro = min(999_999, max(0, Int(((t - seconds) * 1_000_000).rounded(.down))))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%06d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micro)
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// Message builders (python-aidot `models/device_client_model.py`).
public enum AiDotMessages {
    /// `LoginRequest`: srcAddr is the bare userId; payload password is the device password.
    public static func loginRequest(seq: String, userId: String, deviceId: String, devicePassword: String?,
                                    timestamp: String, ascNumber: Int = 1) -> AiDotJSON {
        .obj([
            "service": "device",
            "method": "loginReq",
            "seq": .string(seq),
            "srcAddr": .string(userId),
            "deviceId": .string(deviceId),
            "payload": .obj([
                "userId": .string(userId),
                "password": devicePassword.map(AiDotJSON.string) ?? .null,
                "timestamp": .string(timestamp),
                "ascNumber": .integer(ascNumber),
            ]),
        ])
    }

    /// Login seq: `str(int(time.time() * 1000) + login_uuid)[-9:]`.
    public static func loginSeq(milliseconds: Int64, attempt: Int) -> String {
        String(String(milliseconds + Int64(attempt)).suffix(9))
    }

    /// `DeviceActionRequest.from_params` (+ fixed `tst`). With `simpleVersion != nil` the payload
    /// carries devId/parentId/userId/password and `clientId = "ha-<userId>"`; otherwise those are "".
    /// `attr` is an object for `setDevAttrReq` and a list of names for `getDevAttrReq`.
    public static func actionRequest(method: String, userId: String, deviceId: String, devicePassword: String?,
                                     ascNumber: Int, attr: AiDotJSON, seq: String, simpleVersion: String?,
                                     tst: Int64) -> AiDotJSON {
        let full = simpleVersion != nil
        return .obj([
            "method": .string(method),
            "service": "device",
            "clientId": .string(full ? "ha-\(userId)" : ""),
            "srcAddr": .string("0.\(userId)"),
            "seq": .string(seq),
            "payload": .obj([
                "devId": .string(full ? deviceId : ""),
                "parentId": .string(full ? deviceId : ""),
                "userId": .string(full ? userId : ""),
                "password": full ? (devicePassword.map(AiDotJSON.string) ?? .null) : .string(""),
                "attr": attr,
                "channel": "tcp",
                "ascNumber": .integer(ascNumber),
            ]),
            "tst": .int(tst),
            "deviceId": .string(deviceId),
        ])
    }

    public static func setDevAttrRequest(userId: String, deviceId: String, devicePassword: String?, ascNumber: Int,
                                         attributes: AiDotAttributes, seq: String, simpleVersion: String?, tst: Int64) -> AiDotJSON {
        actionRequest(method: "setDevAttrReq", userId: userId, deviceId: deviceId, devicePassword: devicePassword,
                      ascNumber: ascNumber, attr: attributes.json, seq: seq, simpleVersion: simpleVersion, tst: tst)
    }

    /// `getDevAttrReq` with the attribute names to read (`[]` = all, as python sends for current models).
    public static func getDevAttrRequest(userId: String, deviceId: String, devicePassword: String?, ascNumber: Int,
                                         properties: [String], seq: String, simpleVersion: String?, tst: Int64) -> AiDotJSON {
        actionRequest(method: "getDevAttrReq", userId: userId, deviceId: deviceId, devicePassword: devicePassword,
                      ascNumber: ascNumber, attr: .array(properties.map(AiDotJSON.string)), seq: seq,
                      simpleVersion: simpleVersion, tst: tst)
    }

    /// `PingRequest` (sent with msgtype 2).
    public static let pingRequest: AiDotJSON = .obj([
        "service": "test",
        "method": "pingreq",
        "seq": "123456",
        "srcAddr": "123456",
        "payload": .object([]),
    ])
}

/// A decrypted message from a device (`DeviceResponse`).
public struct AiDotDeviceMessage: Sendable, Equatable {
    public var service: String?
    public var method: String?
    public var seq: String?
    public var ackCode: Int?
    public var ascNumber: Int?
    public var attributes: AiDotAttributes?
    public var raw: AiDotJSON

    public init(json: AiDotJSON) {
        raw = json
        service = json["service"]?.stringValue
        method = json["method"]?.stringValue
        seq = json["seq"]?.looseString
        ackCode = json["ack"]?["code"]?.intValue
        ascNumber = json["payload"]?["ascNumber"]?.intValue
        if let attr = json["payload"]?["attr"], attr.members != nil {
            attributes = AiDotAttributes(json: attr)
        }
    }

    /// Keepalive answers (`service == "test"`) carry no state.
    public var isPing: Bool { service == "test" }
}

/// Per-connection counters (python `DeviceClient.seq_num` / `ascNumber`).
public struct AiDotSessionCounters: Sendable, Equatable {
    /// Reset to 1 on every connect; incremented before each action.
    public private(set) var seqNumber: Int = 1
    /// Device sequence number echoed in every action payload.
    public private(set) var ascNumber: Int = 1

    public init() {}

    /// `"ha93" + str(seq).zfill(5)` for the next action.
    public mutating func nextActionSeq() -> String {
        seqNumber += 1
        return "ha93" + String(format: "%05d", seqNumber)
    }

    /// After a successful login: `ascNumber = payload.ascNumber + 1`.
    public mutating func loggedIn(deviceAscNumber: Int?) {
        ascNumber = (deviceAscNumber ?? 0) + 1
    }

    /// Any later message with a truthy `payload.ascNumber` replaces ours (python does not increment
    /// on send; the device reports the value to use).
    public mutating func observe(_ message: AiDotDeviceMessage) {
        if let asc = message.ascNumber, asc != 0 { ascNumber = asc }
    }
}

/// Encrypts/decrypts frames for one device.
public struct AiDotSessionCodec: Sendable {
    public let key: [UInt8]

    public init(aesKey: String) { key = AiDotCrypto.deviceKey(aesKey) }
    public init(key: [UInt8]) { self.key = key }

    public func frame(_ json: AiDotJSON, type: AiDotFrame.MessageType = .action) throws -> Data {
        try AiDotFrame.encrypted(json, type: type, key: key).encoded()
    }

    public func message(from frame: AiDotFrame) throws -> AiDotDeviceMessage {
        AiDotDeviceMessage(json: try frame.decryptedJSON(key: key))
    }
}
