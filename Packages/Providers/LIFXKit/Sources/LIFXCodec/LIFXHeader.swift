import Foundation

/// A LIFX device serial number: the 6-byte MAC address, sent in the header `target` field.
/// Its lowercase hex form (`"d073d5001337"`) is the stable id used in `LightID`s.
public struct LIFXSerial: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Exactly 6 bytes.
    public let bytes: [UInt8]

    /// All zeros: "every device" (used with `tagged` broadcasts).
    public static let all = LIFXSerial(unchecked: [0, 0, 0, 0, 0, 0])

    private init(unchecked bytes: [UInt8]) { self.bytes = bytes }

    /// Creates a serial from exactly 6 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// Parses `"d073d5001337"`, `"D0:73:D5:00:13:37"` or `"d0-73-d5-00-13-37"`.
    public init?(_ string: String) {
        let hex = string.filter { $0 != ":" && $0 != "-" }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.bytes = out
    }

    /// Lowercase hex without separators, e.g. `"d073d5001337"` (the stable id).
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    /// Colon separated MAC address, e.g. `"d0:73:d5:00:13:37"`.
    public var macAddress: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
    public var isAll: Bool { bytes.allSatisfy { $0 == 0 } }
    public var description: String { hex }

    public static func < (lhs: LIFXSerial, rhs: LIFXSerial) -> Bool { lhs.hex < rhs.hex }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard let serial = LIFXSerial(s) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid LIFX serial \(s)")
        }
        self = serial
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The 36-byte LIFX header: frame header (8 bytes), frame address (16 bytes) and protocol header
/// (12 bytes). See https://lan.developer.lifx.com/docs/encoding-a-packet .
///
/// ```
/// offset  size  field
///  0      2     size (whole packet, header + payload)
///  2      2     protocol:12 = 1024 | addressable:1 = 1 | tagged:1 | origin:2 = 0
///  4      4     source (client id, echoed in replies)
///  8      8     target (6-byte serial + 2 zero bytes; all zero = every device)
/// 16      6     reserved
/// 22      1     res_required:1 | ack_required:1 | reserved:6
/// 23      1     sequence (wrapping, echoed in replies)
/// 24      8     reserved
/// 32      2     type (message id)
/// 34      2     reserved
/// ```
public struct LIFXHeader: Hashable, Sendable {
    public static let size = 36
    public static let protocolNumber: UInt16 = 1024

    /// Total packet size (header + payload). Filled in by `LIFXPacket.encode()`.
    public var size: UInt16
    /// True for broadcasts addressed to every device (`target` must be all zeros).
    public var tagged: Bool
    /// Always true in practice ("the frame address contains a target").
    public var addressable: Bool
    public var source: UInt32
    public var target: LIFXSerial
    public var resRequired: Bool
    public var ackRequired: Bool
    public var sequence: UInt8
    public var type: UInt16

    public init(
        size: UInt16 = UInt16(LIFXHeader.size),
        tagged: Bool = false,
        addressable: Bool = true,
        source: UInt32,
        target: LIFXSerial = .all,
        resRequired: Bool = false,
        ackRequired: Bool = false,
        sequence: UInt8 = 0,
        type: UInt16
    ) {
        self.size = size
        self.tagged = tagged
        self.addressable = addressable
        self.source = source
        self.target = target
        self.resRequired = resRequired
        self.ackRequired = ackRequired
        self.sequence = sequence
        self.type = type
    }

    func write(into w: inout ByteWriter) {
        w.u16(size)
        var flags = Self.protocolNumber & 0x0FFF
        if addressable { flags |= 1 << 12 }
        if tagged { flags |= 1 << 13 }
        w.u16(flags)
        w.u32(source)
        w.fixed(target.bytes, size: 8)
        w.zeros(6)
        var response: UInt8 = 0
        if resRequired { response |= 0x01 }
        if ackRequired { response |= 0x02 }
        w.u8(response)
        w.u8(sequence)
        w.zeros(8)
        w.u16(type)
        w.zeros(2)
    }

    static func read(from r: inout ByteReader) throws -> LIFXHeader {
        let size = try r.u16()
        let flags = try r.u16()
        let proto = flags & 0x0FFF
        guard proto == protocolNumber else { throw LIFXCodecError.unsupportedProtocol(proto) }
        let source = try r.u32()
        let targetBytes = try r.bytes(8)
        try r.skip(6)
        let response = try r.u8()
        let sequence = try r.u8()
        try r.skip(8)
        let type = try r.u16()
        try r.skip(2)
        return LIFXHeader(
            size: size,
            tagged: flags & (1 << 13) != 0,
            addressable: flags & (1 << 12) != 0,
            source: source,
            target: LIFXSerial(bytes: Array(targetBytes.prefix(6)))!,
            resRequired: response & 0x01 != 0,
            ackRequired: response & 0x02 != 0,
            sequence: sequence,
            type: type
        )
    }
}

/// A complete LIFX datagram: header + typed message.
public struct LIFXPacket: Hashable, Sendable {
    public var header: LIFXHeader
    public var message: LIFXMessage

    /// Builds a packet; `header.type` and `header.size` are derived from `message`.
    public init(
        _ message: LIFXMessage,
        source: UInt32,
        target: LIFXSerial = .all,
        tagged: Bool? = nil,
        ackRequired: Bool = false,
        resRequired: Bool = false,
        sequence: UInt8 = 0
    ) {
        self.message = message
        self.header = LIFXHeader(
            size: UInt16(LIFXHeader.size + message.encodePayload().count),
            tagged: tagged ?? target.isAll,
            source: source,
            target: target,
            resRequired: resRequired,
            ackRequired: ackRequired,
            sequence: sequence,
            type: message.type
        )
    }

    public init(header: LIFXHeader, message: LIFXMessage) {
        self.header = header
        self.message = message
    }

    /// Wire bytes. `size` and `type` are always recomputed from the message.
    public func encode() -> Data {
        let payload = message.encodePayload()
        var h = header
        h.size = UInt16(LIFXHeader.size + payload.count)
        h.type = message.type
        var w = ByteWriter(capacity: Int(h.size))
        h.write(into: &w)
        w.raw(payload)
        return Data(w.bytes)
    }

    /// Parses one datagram. Throws `LIFXCodecError` for malformed packets; unknown message types
    /// decode as `.unknown(type:payload:)`.
    public static func decode(_ data: Data) throws -> LIFXPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= LIFXHeader.size else {
            throw LIFXCodecError.truncated(expected: LIFXHeader.size, actual: bytes.count)
        }
        var r = ByteReader(bytes)
        let header = try LIFXHeader.read(from: &r)
        guard Int(header.size) == bytes.count else {
            throw LIFXCodecError.sizeMismatch(declared: Int(header.size), actual: bytes.count)
        }
        let message = try LIFXMessage.decode(type: header.type, payload: Array(bytes[LIFXHeader.size...]))
        return LIFXPacket(header: header, message: message)
    }
}
