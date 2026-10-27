import Foundation

/// How to reach one device: transport (XOR TCP 9999, KLAP over HTTP, or the unsupported AES
/// "securePassthrough" of early Tapo firmware), JSON dialect (IOT or SMART) and port.
/// Mirrors python-kasa `get_protocol`: `IOT.XOR`, `IOT.KLAP` (v1, v2 when `lv` >= 2),
/// `SMART.KLAP` (always v2), `SMART.AES`.
public struct TPLinkConnection: Sendable, Hashable, Codable {
    public enum Transport: String, Sendable, Hashable, Codable {
        case xor
        case klap
        /// Tapo firmware before KLAP (RSA + AES `securePassthrough`). Not implemented.
        case aes
    }

    public enum Family: String, Sendable, Hashable, Codable {
        /// Kasa JSON (`{"system":{"get_sysinfo":{}}}`).
        case iot = "IOT"
        /// Tapo JSON (`{"method":"get_device_info"}`).
        case smart = "SMART"
    }

    public var transport: Transport
    public var family: Family
    /// Set for `.klap`.
    public var klapVersion: TPLinkKLAP.Version?
    public var port: UInt16
    /// Device advertises HTTPS (port 4433 by default). Not implemented; see README.
    public var https: Bool

    public init(transport: Transport, family: Family, klapVersion: TPLinkKLAP.Version? = nil, port: UInt16, https: Bool = false) {
        self.transport = transport
        self.family = family
        self.klapVersion = klapVersion
        self.port = port
        self.https = https
    }

    /// Legacy Kasa: XOR JSON over TCP 9999, no credentials.
    public static let legacy = TPLinkConnection(transport: .xor, family: .iot, port: TPLinkXOR.port)

    /// Tapo default: SMART over KLAP v2 on HTTP 80.
    public static let tapo = TPLinkConnection(transport: .klap, family: .smart, klapVersion: .v2, port: TPLinkKLAP.defaultPort)

    /// From a 20002 discovery answer. Returns nil when the device type or encryption is unknown.
    public init?(deviceType: String?, encryptType: String?, loginVersion: Int?, https: Bool, httpPort: Int?) {
        guard let deviceType, let encryptType else { return nil }
        let familyName = deviceType.split(separator: ".").first.map(String.init)?.uppercased()
        guard let familyName, let family = Family(rawValue: familyName) else { return nil }
        let port = httpPort.flatMap { UInt16(exactly: $0) } ?? (https ? 4433 : TPLinkKLAP.defaultPort)
        switch encryptType.uppercased() {
        case "KLAP":
            let version: TPLinkKLAP.Version = family == .smart || (loginVersion ?? 1) >= 2 ? .v2 : .v1
            self.init(transport: .klap, family: family, klapVersion: version, port: port, https: https)
        case "AES":
            self.init(transport: .aes, family: family, port: port, https: https)
        case "XOR":
            self.init(transport: .xor, family: .iot, port: TPLinkXOR.port)
        default:
            return nil
        }
    }

    public var needsCredentials: Bool { transport != .xor }

    public var isSupported: Bool {
        switch transport {
        case .xor: true
        case .klap: !https
        case .aes: false
        }
    }

    /// Short form for `PairedDevice.metadata["connection"]`: `xor`, `klap1-iot:80`, `klap2-smart:80`, `aes-smart:80`.
    public var descriptor: String {
        switch transport {
        case .xor: return "xor:\(port)"
        case .klap: return "klap\(klapVersion?.rawValue ?? 2)-\(family.rawValue.lowercased()):\(port)\(https ? "s" : "")"
        case .aes: return "aes-\(family.rawValue.lowercased()):\(port)\(https ? "s" : "")"
        }
    }

    public init?(descriptor: String) {
        let parts = descriptor.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var portText = parts[1]
        let https = portText.hasSuffix("s")
        if https { portText.removeLast() }
        guard let port = UInt16(portText) else { return nil }
        let head = parts[0]
        if head == "xor" {
            self.init(transport: .xor, family: .iot, port: port)
            return
        }
        let pieces = head.split(separator: "-").map(String.init)
        guard pieces.count == 2, let family = Family(rawValue: pieces[1].uppercased()) else { return nil }
        if pieces[0] == "aes" {
            self.init(transport: .aes, family: family, port: port, https: https)
        } else if pieces[0].hasPrefix("klap"), let v = Int(pieces[0].dropFirst(4)), let version = TPLinkKLAP.Version(rawValue: v) {
            self.init(transport: .klap, family: family, klapVersion: version, port: port, https: https)
        } else {
            return nil
        }
    }
}
