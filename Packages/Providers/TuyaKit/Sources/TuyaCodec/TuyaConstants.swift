import Foundation

/// Ports and timings (tinytuya `core/const.py`, scanner).
public enum TuyaConstants {
    /// Control connection; a device accepts **one** TCP client at a time.
    public static let tcpPort: UInt16 = 6668
    /// Plaintext broadcasts from protocol 3.1 devices.
    public static let discoveryPortPlain: UInt16 = 6666
    /// Encrypted broadcasts (AES-ECB with `TuyaCrypto.udpKey`; 3.5 devices use 6699 GCM frames).
    public static let discoveryPortEncrypted: UInt16 = 6667
    /// Apps broadcast `REQ_DEVINFO` here so 3.5 devices announce themselves sooner.
    public static let appBroadcastPort: UInt16 = 7000
    /// Devices broadcast roughly every 5 s; tinytuya scans for 18 s.
    public static let scanTime: Duration = .seconds(18)
    /// Keepalive cadence used by the provider (tinytuya monitor examples send a heartbeat every ~10 s;
    /// devices drop idle connections after ~30 s).
    public static let heartbeatInterval: Duration = .seconds(10)
    /// tinytuya `MAX_PAYLOAD_LENGTH` is 1440; we accept somewhat more before calling a stream corrupt.
    public static let maxPayloadLength = 4096
}

/// Command codes (tinytuya `core/command_types.py`, Tuya `lan_protocol.h`).
public enum TuyaCommand: UInt32, Sendable, CaseIterable {
    case apConfig = 1
    case active = 2
    case sessKeyNegStart = 3
    case sessKeyNegResp = 4
    case sessKeyNegFinish = 5
    case unbind = 6
    case control = 7
    case status = 8
    case heartBeat = 9
    case dpQuery = 10
    case queryWifi = 11
    case tokenBind = 12
    case controlNew = 13
    case enableWifi = 14
    case wifiInfo = 15
    case dpQueryNew = 16
    case sceneExecute = 17
    case updateDps = 18
    case udpNew = 19
    case apConfigNew = 20
    case broadcastLPV34 = 35
    case reqDevInfo = 37
    case lanExtStream = 64

    /// Commands sent without the `"3.x" + 12×NUL` version header (`NO_PROTOCOL_HEADER_CMDS`).
    public static let withoutVersionHeader: Set<UInt32> = [
        TuyaCommand.dpQuery, .dpQueryNew, .updateDps, .heartBeat, .sessKeyNegStart, .sessKeyNegResp,
        .sessKeyNegFinish, .lanExtStream,
    ].reduce(into: []) { $0.insert($1.rawValue) }
}

/// Local protocol versions. 3.2 (3.3 framing with "device22" quirks) is rare and not offered.
public enum TuyaVersion: String, Sendable, Codable, CaseIterable, Comparable {
    case v31 = "3.1"
    case v33 = "3.3"
    case v34 = "3.4"
    case v35 = "3.5"

    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        if let v = TuyaVersion(rawValue: s) { self = v; return }
        // "3.30", "v3.3", 3.3 as a JSON double formatted by someone else.
        let digits = s.hasPrefix("v") ? String(s.dropFirst()) : s
        guard let d = Double(digits) else { return nil }
        switch (d * 10).rounded() {
        case 31: self = .v31
        case 33: self = .v33
        case 34: self = .v34
        case 35: self = .v35
        default: return nil
        }
    }

    public var number: Double { Double(rawValue) ?? 3.1 }
    public var versionBytes: [UInt8] { Array(rawValue.utf8) }
    /// `"3.x"` + 12 NUL bytes (15 bytes).
    public var versionHeader: [UInt8] { versionBytes + [UInt8](repeating: 0, count: 12) }
    /// 3.4 and 3.5 negotiate a per-connection session key.
    public var negotiatesSessionKey: Bool { self >= .v34 }
    public var usesGCM: Bool { self == .v35 }

    public static func < (lhs: TuyaVersion, rhs: TuyaVersion) -> Bool { lhs.number < rhs.number }
}

/// tinytuya `dev_type`: "device22" devices (often 22-character ids on 3.3) answer `DP_QUERY` with
/// "json obj data unvalid" and must be polled with `CONTROL_NEW` listing the wanted dps.
public enum TuyaDeviceType: String, Sendable, Codable {
    case `default`
    case device22
}
