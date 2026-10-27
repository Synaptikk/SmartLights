import Foundation
import _CryptoExtras

/// Discovery datagrams and answers.
///
/// - **UDP 9999 (legacy Kasa)**: `{"system":{"get_sysinfo":{}}}` XORed *without* the length
///   prefix; the device answers the same way with its sysinfo.
/// - **UDP 20002 (Tapo, Kasa KLAP firmware)**: a 16-byte TDP header followed by an optional JSON
///   payload (`{"params":{"rsa_key":"<PEM>"}}`). Header, big-endian:
///   `version 2 | msg_type 0 | op_code 1 (probe) | payload size (u16) | flags | 0 | serial (u32) | CRC32`.
///   The CRC32 (zlib) is computed over the whole datagram with `0x5A6B7C8D` in the CRC field, then
///   written there. The answer carries a 16-byte header and the JSON
///   `{"error_code":0,"result":{"device_id","device_model","device_type","mac","ip","mgt_encrypt_schm":{...}}}`.
///   Format as sent by python-kasa `discover.py` (`_AesDiscoveryQuery`, `DISCOVERY_QUERY_2`).
public enum TPLinkDiscovery {
    public static let legacyPort: UInt16 = 9999
    public static let port: UInt16 = 20002
    /// Some firmware listens on 20004 as well (python-kasa sends there too).
    public static let alternatePort: UInt16 = 20004
    public static let headerLength = 16
    static let initialCRC: UInt32 = 0x5A6B_7C8D

    /// UDP 9999 query: XORed `{"system":{"get_sysinfo":{}}}` without length prefix.
    public static var legacyQuery: Data { TPLinkXOR.encrypt(TPLinkIOT.getSysinfo.data) }

    /// UDP 20002 query. Without a payload, serial 0 and flags 0 this is python-kasa's fixed
    /// `DISCOVERY_QUERY_2` (`020000010000000000000000463cb5d3`). python-kasa sends flags 17, a
    /// random serial and an RSA public key so devices can encrypt `encrypt_info` for it.
    public static func query(payload: Data = Data(), serial: UInt32 = 0, flags: UInt8 = 0) -> Data {
        var bytes: [UInt8] = [0x02, 0x00, 0x00, 0x01]
        let size = UInt16(clamping: payload.count)
        bytes += [UInt8(size >> 8), UInt8(size & 0xFF), flags, 0]
        bytes += be32(serial)
        bytes += be32(initialCRC)
        bytes += Array(payload)
        let crc = crc32(bytes)
        let crcBytes = be32(crc)
        for i in 0..<4 { bytes[12 + i] = crcBytes[i] }
        return Data(bytes)
    }

    /// The JSON payload python-kasa sends with the 20002 probe.
    public static func rsaKeyPayload(publicKeyPEM: String) -> Data {
        TPLinkJSON.obj(["params": .obj(["rsa_key": .string(publicKeyPEM)])]).data
    }

    /// A fresh 2048-bit RSA public key (PEM, SubjectPublicKeyInfo) for the keyed 20002 probe.
    /// Devices use it only to encrypt `encrypt_info`, which the provider does not need, so the
    /// private key is discarded. Generation takes a moment: call it once, off the main actor.
    public static func makeProbeKeyPEM() throws -> String {
        try _RSA.Signing.PrivateKey(keySize: .bits2048).publicKey.pemRepresentation
    }

    /// Parses an answer according to the port it came from.
    public static func parse(_ data: Data, fromPort port: UInt16, host: String) throws -> TPLinkDiscoveryResult {
        if port == legacyPort { return try parseLegacy(data, host: host) }
        return try parseNew(data, host: host)
    }

    /// UDP 9999 answer: XORed sysinfo.
    public static func parseLegacy(_ data: Data, host: String) throws -> TPLinkDiscoveryResult {
        let json = try TPLinkJSON.parse(TPLinkXOR.decrypt(data))
        let info = try TPLinkIOTSysInfo(TPLinkIOT.result(of: json, target: TPLinkIOT.systemTarget, command: "get_sysinfo"))
        return TPLinkDiscoveryResult(
            host: host,
            deviceID: info.deviceID,
            mac: info.mac,
            model: info.model,
            deviceType: info.type,
            name: info.alias,
            connection: .legacy,
            firmware: info.firmware,
            sysinfo: info
        )
    }

    /// UDP 20002 answer: 16-byte header + `{"error_code":0,"result":{...}}`.
    public static func parseNew(_ data: Data, host: String) throws -> TPLinkDiscoveryResult {
        guard data.count > headerLength else {
            throw TPLinkCodecError.truncatedFrame(expected: headerLength + 2, actual: data.count)
        }
        let json = try TPLinkJSON.parse(Data(data.dropFirst(headerLength)))
        let r = json["result"] ?? json
        guard r.objectValue != nil else { throw TPLinkCodecError.missingField("result") }
        if let code = json["error_code"]?.intValue, code != 0 {
            throw TPLinkCodecError.smartError(method: "discovery", code: TPLinkSmartErrorCode(rawValue: code))
        }
        let scheme = r["mgt_encrypt_schm"]
        var encryptType = scheme?["encrypt_type"]?.stringValue ?? r["encrypt_info"]?["sym_schm"]?.stringValue
        var loginVersion = scheme?["lv"]?.intValue
        if loginVersion == nil, let types = r["encrypt_type"]?.arrayValue {
            loginVersion = types.compactMap(\.intValue).max()
        }
        let https = scheme?["is_support_https"]?.boolValue ?? false
        if encryptType == nil, https, loginVersion == 3 { encryptType = "AES" }
        let deviceType = r["device_type"]?.stringValue
        let connection = TPLinkConnection(
            deviceType: deviceType,
            encryptType: encryptType,
            loginVersion: loginVersion,
            https: https,
            httpPort: scheme?["http_port"]?.intValue
        )
        return TPLinkDiscoveryResult(
            host: r["ip"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? host,
            deviceID: r["device_id"]?.stringValue,
            mac: r["mac"]?.stringValue,
            model: r["device_model"]?.stringValue,
            deviceType: deviceType,
            name: r["device_name"]?.stringValue.map { TPLinkSmartDeviceInfo.decodeBase64($0) ?? $0 },
            connection: connection,
            firmware: r["firmware_version"]?.stringValue,
            sysinfo: nil
        )
    }

    // MARK: Helpers

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// zlib/IEEE CRC-32 (python `binascii.crc32`).
    public static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// One device found by discovery (either port).
public struct TPLinkDiscoveryResult: Sendable, Hashable {
    public var host: String
    public var deviceID: String?
    public var mac: String?
    /// `KL130(US)` (legacy) or `L530E(EU)` (20002).
    public var model: String?
    /// `IOT.SMARTBULB`, `SMART.TAPOBULB`, ...
    public var deviceType: String?
    public var name: String?
    /// How to talk to it; nil when the advertised scheme is unknown.
    public var connection: TPLinkConnection?
    public var firmware: String?
    /// Full sysinfo for legacy answers.
    public var sysinfo: TPLinkIOTSysInfo?

    public init(host: String, deviceID: String?, mac: String?, model: String?, deviceType: String?, name: String?,
                connection: TPLinkConnection?, firmware: String?, sysinfo: TPLinkIOTSysInfo?) {
        self.host = host
        self.deviceID = deviceID
        self.mac = mac
        self.model = model
        self.deviceType = deviceType
        self.name = name
        self.connection = connection
        self.firmware = firmware
        self.sysinfo = sysinfo
    }

    /// Stable id: the MAC (12 lowercase hex digits), else the device id.
    public var stableID: String? { TPLinkIdentity.stableID(mac: mac, deviceID: deviceID) }

    /// Lights and light strips (bulbs, strips); plugs and switches are skipped by the provider.
    public var isLight: Bool {
        if let t = deviceType?.uppercased() { return t.contains("BULB") || t.contains("LIGHT") }
        return model.map { TPLinkModelTable.lookup($0) != nil } ?? false
    }
}

/// Stable identity helpers (devices are keyed by MAC, never by IP).
public enum TPLinkIdentity {
    /// `AA-BB-CC-DD-EE-FF`, `aa:bb:...`, `AABBCCDDEEFF` -> `aabbccddeeff`; nil when not 12 hex digits.
    public static func normalizedMAC(_ mac: String?) -> String? {
        guard let mac else { return nil }
        let hex = mac.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12, hex != "000000000000" else { return nil }
        return hex
    }

    /// MAC when usable, else the device id (lowercased), else nil.
    public static func stableID(mac: String?, deviceID: String?) -> String? {
        if let m = normalizedMAC(mac) { return m }
        guard let id = deviceID?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              !id.allSatisfy({ $0 == "0" }), !id.contains(where: { $0.isWhitespace }) else { return nil }
        return id.lowercased()
    }

    /// `aabbccddeeff` -> `AA:BB:CC:DD:EE:FF`.
    public static func displayMAC(_ normalized: String) -> String {
        var parts: [String] = []
        var i = normalized.startIndex
        while i < normalized.endIndex {
            let j = normalized.index(i, offsetBy: 2, limitedBy: normalized.endIndex) ?? normalized.endIndex
            parts.append(String(normalized[i..<j]).uppercased())
            i = j
        }
        return parts.joined(separator: ":")
    }
}
