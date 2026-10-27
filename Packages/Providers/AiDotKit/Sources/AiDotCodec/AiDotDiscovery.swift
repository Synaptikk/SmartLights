import Foundation

/// UDP 6666 discovery (python-aidot `discover.py`, `models/discover_model.py`).
/// Datagrams are AES-256-ECB/PKCS7 under ``AiDotCrypto/discoveryKey``.
public enum AiDotDiscovery {
    /// `DiscoverRequest.from_params(userId)` with an explicit clock.
    /// - Parameter milliseconds: Unix time in ms (`tst`); `seq` is `str(ms + 1)[-9:]`.
    public static func request(userId: String, milliseconds: Int64) -> AiDotJSON {
        .obj([
            "protocolVer": "2.0.0",
            "service": "device",
            "method": "devDiscoveryReq",
            "seq": .string(String(String(milliseconds + 1).suffix(9))),
            "srcAddr": .string("0.\(userId)"),
            "tst": .int(milliseconds),
            "payload": .obj([
                "extends": .object([]),
                "localCtrFlag": 1,
                "timestamp": .string(String(milliseconds)),
            ]),
        ])
    }

    /// Encrypted discovery datagram. Without a userId (not signed in) python would send `0.None`;
    /// we send `0.0`, which devices are reported to answer as well [unverified].
    public static func datagram(userId: String?, at date: Date = Date()) throws -> Data {
        try datagram(userId: userId, milliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    public static func datagram(userId: String?, milliseconds: Int64) throws -> Data {
        try AiDotCrypto.aesEncrypt(request(userId: userId ?? "0", milliseconds: milliseconds).pythonData, key: AiDotCrypto.discoveryKey)
    }

    /// Decrypts and parses a reply. Returns `nil` for anything that is not a device answer
    /// (including our own broadcast looped back).
    public static func parseReply(_ data: Data) -> AiDotDiscoveryReply? {
        guard let plain = try? AiDotCrypto.aesDecrypt(data, key: AiDotCrypto.discoveryKey),
              let json = try? AiDotJSON.parse(plain) else { return nil }
        return AiDotDiscoveryReply(json: json)
    }
}

/// `DiscoverResponse` (fields per `discover_model.py`).
public struct AiDotDiscoveryReply: Sendable, Equatable {
    public var method: String?
    public var seq: String?
    public var ackCode: Int?
    public var devId: String
    public var ip: String?
    public var mac: String?
    public var productModel: String?
    public var bindFlag: Int?
    public var conMode: Int?
    public var lanMode: Int?
    public var wifiMode: Int?
    public var wifiBand: Int?
    public var version: Int?
    public var srvHost: String?

    public init?(json: AiDotJSON) {
        let method = json["method"]?.stringValue
        // Our own request carries no ack and no payload.devId.
        guard let payload = json["payload"], let devId = payload["devId"]?.looseString, !devId.isEmpty else { return nil }
        if method == "devDiscoveryReq", json["ack"] == nil { return nil }
        self.method = method
        self.seq = json["seq"]?.looseString
        self.ackCode = json["ack"]?["code"]?.intValue
        self.devId = devId
        self.ip = payload["ip"]?.stringValue
        self.mac = payload["mac"]?.stringValue
        self.productModel = payload["productModel"]?.stringValue
        self.bindFlag = payload["bindFlag"]?.intValue
        self.conMode = payload["conMode"]?.intValue
        self.lanMode = payload["lanMode"]?.intValue
        self.wifiMode = payload["wifiMode"]?.intValue
        self.wifiBand = payload["wifiBand"]?.intValue
        self.version = payload["version"]?.intValue
        self.srvHost = payload["extends"]?["srvHost"]?.stringValue
    }

    /// Non-secret metadata for `DiscoveredDevice.metadata`.
    public var metadata: [String: String] {
        var m: [String: String] = [:]
        if let productModel { m["productModel"] = productModel }
        if let bindFlag { m["bindFlag"] = String(bindFlag) }
        if let lanMode { m["lanMode"] = String(lanMode) }
        if let conMode { m["conMode"] = String(conMode) }
        if let wifiBand { m["wifiBand"] = String(wifiBand) }
        if let version { m["version"] = String(version) }
        if let srvHost { m["srvHost"] = srvHost }
        return m
    }
}
