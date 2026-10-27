import Foundation

/// UDP 48899 discovery (HF-LPB100 style "assist thread"). Send `HF-A11ASSISTHREAD` (broadcast,
/// or unicast to one host); each device answers `"<ip>,<MAC>,<model>"`, e.g.
/// `192.168.214.252,B4E842E10588,AK001-ZJ2145`. `AT+LVER\r` then returns
/// `+ok=<model id hex>_<version hex>_<YYYYMMDD>_<info>`, e.g. `+ok=07_06_20210106_ZG-BL`.
public enum MagicHomeDiscovery {
    public static let port: UInt16 = 48899
    public static let request = Data("HF-A11ASSISTHREAD".utf8)
    public static let versionRequest = Data("AT+LVER\r".utf8)

    /// Answer to `request`.
    public struct Reply: Sendable, Hashable {
        public var ip: String
        /// 12 lowercase hex digits.
        public var mac: String
        /// Hardware model string ("AK001-ZJ2145").
        public var model: String

        public init(ip: String, mac: String, model: String) {
            self.ip = ip
            self.mac = mac
            self.model = model
        }
    }

    /// Answer to `versionRequest`.
    public struct Version: Sendable, Hashable {
        public var modelNumber: UInt8?
        public var version: UInt8?
        /// `YYYYMMDD` as sent.
        public var firmwareDate: String?
        /// "IR", "ZG-BL", ...
        public var info: String?

        public init(modelNumber: UInt8? = nil, version: UInt8? = nil, firmwareDate: String? = nil, info: String? = nil) {
            self.modelNumber = modelNumber
            self.version = version
            self.firmwareDate = firmwareDate
            self.info = info
        }
    }

    public static func parseReply(_ data: Data) -> Reply? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let mac = normalizeMAC(parts[1]), !parts[0].isEmpty else { return nil }
        return Reply(ip: parts[0], mac: mac, model: parts[2])
    }

    public static func parseVersion(_ data: Data) -> Version? {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("+ok=") else { return nil }
        let body = text.dropFirst(4).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let parts = body.split(separator: "_", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return Version(version: UInt8(parts[0], radix: 16)) }
        var v = Version(modelNumber: UInt8(parts[0], radix: 16), version: UInt8(parts[1], radix: 16))
        if parts.count >= 3, parts[2].count == 8 { v.firmwareDate = parts[2] }
        if parts.count == 4 { v.info = parts[3] }
        return v
    }

    /// `B4E842E10588` / `b4:e8:42:e1:05:88` -> `b4e842e10588`; nil if not 12 hex digits.
    public static func normalizeMAC(_ s: String) -> String? {
        let hex = s.lowercased().filter { $0 != ":" && $0 != "-" && !$0.isWhitespace }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Wire form of a reply (fakes and tests).
    public static func encode(_ reply: Reply) -> Data {
        Data("\(reply.ip),\(reply.mac.uppercased()),\(reply.model)".utf8)
    }
}
