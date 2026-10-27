import Foundation

/// UDP discovery (https://xled-docs.readthedocs.io/en/latest/protocol_details.html#discovery-protocol).
///
/// Request: `0x01` + ASCII `discover`, sent to UDP 5555 (broadcast, or unicast to one host).
/// Reply: 4 bytes of the device IPv4 address in reverse octet order, ASCII `OK`, the device id
/// (e.g. `Twinkly_33AAFF`) and a terminating zero byte.
public enum TwinklyDiscovery {
    public static let port: UInt16 = 5555

    /// `\x01discover` (xled `PING_MESSAGE`).
    public static let request = Data([0x01] + Array("discover".utf8))

    public struct Reply: Sendable, Hashable {
        /// Dotted-quad address the device reports for itself.
        public var ip: String
        /// Device id / default name, e.g. `Twinkly_33AAFF` (not the MAC; see `TwinklyGestalt.mac`).
        public var deviceID: String

        public init(ip: String, deviceID: String) {
            self.ip = ip
            self.deviceID = deviceID
        }
    }

    /// Parses a discovery reply; nil for anything that is not `<ip reversed> "OK" <id> [0x00]`.
    /// Our own request (looped back on broadcast) is rejected because it lacks `OK` at offset 4.
    public static func parseReply(_ data: Data) -> Reply? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[4] == UInt8(ascii: "O"), bytes[5] == UInt8(ascii: "K") else { return nil }
        let ip = "\(bytes[3]).\(bytes[2]).\(bytes[1]).\(bytes[0])"
        var idBytes = bytes[6...]
        if let zero = idBytes.firstIndex(of: 0) { idBytes = idBytes[..<zero] }
        guard !idBytes.isEmpty, let id = String(bytes: idBytes, encoding: .utf8) else { return nil }
        return Reply(ip: ip, deviceID: id)
    }

    /// Builds a reply datagram (used by fakes and tests).
    public static func makeReply(ip: String, deviceID: String) -> Data? {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return Data(octets.reversed() + Array("OK".utf8) + Array(deviceID.utf8) + [0])
    }
}
