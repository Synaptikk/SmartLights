import Foundation

/// A device announcement (UDP 6666 plaintext, 6667 AES-ECB or 6699/GCM), e.g.
/// `{"ip":"192.168.1.42","gwId":"bf…","active":2,"ability":0,"mode":0,"encrypt":true,"productKey":"…","version":"3.3"}`.
public struct TuyaDiscoveryInfo: Sendable, Equatable {
    public var deviceId: String
    /// IP the device reports for itself (the datagram source is preferred by the provider).
    public var ip: String?
    public var productKey: String?
    public var versionString: String?
    public var version: TuyaVersion?
    public var encrypt: Bool?
    public var raw: TuyaJSON

    public init?(json: TuyaJSON) {
        guard let id = json["gwId"]?.stringValue ?? json["devId"]?.stringValue, !id.isEmpty else { return nil }
        deviceId = id
        ip = json["ip"]?.stringValue
        productKey = json["productKey"]?.stringValue
        let v = json["version"]?.stringValue ?? json["version"]?.doubleValue.map { String($0) }
        versionString = v
        version = v.flatMap(TuyaVersion.init(string:))
        encrypt = json["encrypt"]?.boolValue
        raw = json
    }

    /// Non-secret extras for `DiscoveredDevice.metadata`.
    public var metadata: [String: String] {
        var m: [String: String] = [:]
        if let v = versionString { m["version"] = v }
        if let p = productKey { m["productKey"] = p }
        if let ip { m["reportedIP"] = ip }
        return m
    }
}

public enum TuyaDiscovery {
    public enum Failure: Error, Sendable, Equatable {
        case undecodable
    }

    /// tinytuya `decrypt_udp`: returns the JSON of an announcement.
    public static func decode(_ datagram: [UInt8]) throws -> TuyaJSON {
        let key = TuyaCrypto.udpKey
        guard let header = try? TuyaFrame.parseHeader(datagram, maxPayload: Int.max) else {
            // Bare ECB ciphertext (no framing).
            guard let plain = try? TuyaCrypto.ecbDecrypt(datagram, key: key) else { throw Failure.undecodable }
            return try parse(plain)
        }
        switch header.prefix {
        case .p55AA:
            let message = try TuyaFrame.unpack(datagram, retcode: .present)
            let payload = message.payload
            if payload.first == UInt8(ascii: "{"), payload.last == UInt8(ascii: "}") { return try parse(payload) }
            guard let plain = try? TuyaCrypto.ecbDecrypt(payload, key: key) else { throw Failure.undecodable }
            return try parse(plain)
        case .p6699:
            let message = try TuyaFrame.unpack(datagram, hmacKey: key, retcode: .detect)
            guard message.trailerValid else { throw Failure.undecodable }
            var payload = message.payload
            while payload.last == 0 { payload.removeLast() }
            return try parse(payload)
        }
    }

    /// Decoded device announcement, or nil (app broadcasts `{"from":"app",…}` and junk are skipped).
    public static func parse(datagram: [UInt8]) -> TuyaDiscoveryInfo? {
        guard let json = try? decode(datagram), json["from"]?.stringValue != "app" else { return nil }
        return TuyaDiscoveryInfo(json: json)
    }

    /// `REQ_DEVINFO` broadcast to UDP 7000 that prompts 3.5 devices to announce (tinytuya scanner).
    public static func deviceInfoRequest(localIP: String, iv: [UInt8]? = nil) throws -> [UInt8] {
        let body = Array(#"{"from": "app", "ip": "\#(localIP)"}"#.utf8)
        return try TuyaFrame.pack(TuyaMessage(seqno: 0, command: TuyaCommand.reqDevInfo.rawValue, payload: body, prefix: .p6699),
                                  hmacKey: TuyaCrypto.udpKey, iv: iv)
    }

    /// Builds an announcement like a device does (for fakes/simulators): 3.1 plaintext on 6666,
    /// 3.3/3.4 AES-ECB on 6667, 3.5 6699/GCM on 6667.
    public static func announcement(_ json: TuyaJSON, version: TuyaVersion, iv: [UInt8]? = nil) throws -> [UInt8] {
        let body = Array(json.compactString().utf8)
        switch version {
        case .v31:
            return try TuyaFrame.pack(TuyaMessage(seqno: 0, command: TuyaCommand.updateDps.rawValue, retcode: 0, payload: body))
        case .v33, .v34:
            return try TuyaFrame.pack(TuyaMessage(seqno: 0, command: TuyaCommand.udpNew.rawValue, retcode: 0,
                                                  payload: TuyaCrypto.ecbEncrypt(body, key: TuyaCrypto.udpKey)))
        case .v35:
            return try TuyaFrame.pack(TuyaMessage(seqno: 0, command: TuyaCommand.broadcastLPV34.rawValue, retcode: 0,
                                                  payload: body, prefix: .p6699), hmacKey: TuyaCrypto.udpKey, iv: iv)
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> TuyaJSON {
        guard let json = try? TuyaJSON.parse(Data(bytes)) else { throw Failure.undecodable }
        return json
    }
}
