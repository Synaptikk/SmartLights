import Foundation

/// Errors raised while decoding LIFX packets.
public enum LIFXCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Fewer bytes than the header or the message payload needs.
    case truncated(expected: Int, actual: Int)
    /// The `size` field does not match the datagram length.
    case sizeMismatch(declared: Int, actual: Int)
    /// `protocol` field is not 1024.
    case unsupportedProtocol(UInt16)
    case invalidField(String)

    public var description: String {
        switch self {
        case .truncated(let e, let a): "LIFX packet truncated (need \(e) bytes, got \(a))"
        case .sizeMismatch(let d, let a): "LIFX size field \(d) != datagram length \(a)"
        case .unsupportedProtocol(let p): "LIFX protocol \(p) is not 1024"
        case .invalidField(let f): "LIFX invalid field: \(f)"
        }
    }
}

/// Little-endian byte writer (the LIFX LAN protocol is little-endian throughout).
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }
    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
    mutating func raw<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
    /// Fixed-size field: copies up to `size` bytes and pads with zeros.
    mutating func fixed(_ data: [UInt8], size: Int) {
        bytes.append(contentsOf: data.prefix(size))
        if data.count < size { zeros(size - data.count) }
    }
    mutating func hsbk(_ c: HSBK) {
        u16(c.hue); u16(c.saturation); u16(c.brightness); u16(c.kelvin)
    }
}

/// Little-endian byte reader over a byte array; every read is bounds-checked.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw LIFXCodecError.truncated(expected: offset + n, actual: bytes.count) }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 {
        let s = try take(2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        let s = try take(4)
        var v: UInt32 = 0
        for (i, b) in s.enumerated() { v |= UInt32(b) << UInt32(8 * i) }
        return v
    }
    mutating func u64() throws -> UInt64 {
        let s = try take(8)
        var v: UInt64 = 0
        for (i, b) in s.enumerated() { v |= UInt64(b) << UInt64(8 * i) }
        return v
    }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func skip(_ n: Int) throws { _ = try take(n) }
    mutating func bytes(_ n: Int) throws -> [UInt8] { Array(try take(n)) }
    mutating func hsbk() throws -> HSBK {
        HSBK(hue: try u16(), saturation: try u16(), brightness: try u16(), kelvin: try u16())
    }
}
