import Foundation

/// The 14-byte answer to the `81 8a 8b` state query:
///
/// ```
/// pos  0  1  2  3  4  5  6  7  8  9 10 11 12 13
///     81 25 23 61 21 06 38 05 06 f9 01 00 0f 9d
///      |  |  |  |  |  |  |  |  |  |  |  |  |  checksum
///      |  |  |  |  |  |  |  |  |  |  |  |  colour mode / wiring
///      |  |  |  |  |  |  |  |  |  |  |  cold white
///      |  |  |  |  |  |  |  |  |  |  version
///      |  |  |  |  |  |  |  |  |  warm white
///      |  |  |  |  |  |  red green blue
///      |  |  |  |  |  speed (effect delay)
///      |  |  |  |  mode
///      |  |  |  preset pattern (0x61 static colour, 0x25... built-in effects)
///      |  |  power 0x23 on / 0x24 off
///      |  model id
///      head
/// ```
///
/// Values are as sent by the device; per-model channel remapping happens in `MagicHomeMapping`.
public struct MagicHomeRawState: Sendable, Hashable {
    public static let length = 14
    public static let head: UInt8 = 0x81
    public static let onByte: UInt8 = 0x23
    public static let offByte: UInt8 = 0x24

    public var modelNumber: UInt8
    public var power: UInt8
    public var presetPattern: UInt8
    public var mode: UInt8
    public var speed: UInt8
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var warmWhite: UInt8
    public var version: UInt8
    public var coolWhite: UInt8
    public var colorMode: UInt8

    public init(
        modelNumber: UInt8, power: UInt8, presetPattern: UInt8 = 0x61, mode: UInt8 = 0x23, speed: UInt8 = 0x01,
        red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, warmWhite: UInt8 = 0, version: UInt8 = 1,
        coolWhite: UInt8 = 0, colorMode: UInt8 = 0
    ) {
        self.modelNumber = modelNumber
        self.power = power
        self.presetPattern = presetPattern
        self.mode = mode
        self.speed = speed
        self.red = red
        self.green = green
        self.blue = blue
        self.warmWhite = warmWhite
        self.version = version
        self.coolWhite = coolWhite
        self.colorMode = colorMode
    }

    public var isOn: Bool { power == Self.onByte }

    /// Parses a 14-byte state (head `0x81`, valid checksum).
    public init(_ data: Data) throws(MagicHomeDecodeError) {
        let b = [UInt8](data)
        guard b.count == Self.length else { throw .length(expected: Self.length, got: b.count) }
        guard b[0] == Self.head else { throw .unexpectedHead(b[0]) }
        guard MagicHomeMessage.isChecksumValid(data) else { throw .checksum }
        self.init(modelNumber: b[1], power: b[2], presetPattern: b[3], mode: b[4], speed: b[5],
                  red: b[6], green: b[7], blue: b[8], warmWhite: b[9], version: b[10],
                  coolWhite: b[11], colorMode: b[12])
    }

    /// Wire form with checksum (used by fakes and tests).
    public func encode() -> Data {
        MagicHomeMessage.withChecksum([Self.head, modelNumber, power, presetPattern, mode, speed,
                                       red, green, blue, warmWhite, version, coolWhite, colorMode])
    }
}

public enum MagicHomeDecodeError: Error, Sendable, Equatable {
    case length(expected: Int, got: Int)
    case unexpectedHead(UInt8)
    case checksum
}

/// One message read from a device.
public enum MagicHomeResponse: Sendable, Hashable {
    /// Answer to the state query (also pushed by some devices after external changes).
    case state(MagicHomeRawState)
    /// `xx 71 23|24 cs`: answer to a power change, pushed by some devices.
    case power(on: Bool)
    /// Any other complete message (timers, clock, remote config...), kept for diagnostics.
    case other(Data)
}

/// Splits the TCP byte stream into LEDENET messages using each message type's fixed length
/// (flux_led's framing rules), unwrapping `b0 b1 b2 b3` outer messages.
public struct MagicHomeFramer: Sendable {
    private var buffer: [UInt8] = []
    /// Upper bound on buffered bytes; garbage beyond it is discarded.
    public var maxBuffer = 4096

    public init() {}

    /// Feeds received bytes; returns every complete message decoded so far.
    public mutating func push(_ data: Data) -> [MagicHomeResponse] {
        buffer += data
        var out: [MagicHomeResponse] = []
        while !buffer.isEmpty {
            guard let needed = Self.expectedLength(buffer) else {
                // Unknown message: the device sends one per segment; drop what we have.
                out.append(.other(Data(buffer)))
                buffer.removeAll()
                break
            }
            guard buffer.count >= needed else {
                if buffer.count > maxBuffer { buffer.removeAll() }
                break
            }
            let message = Data(buffer[0..<needed])
            buffer.removeFirst(needed)
            out.append(contentsOf: Self.decode(message))
        }
        return out
    }

    /// Bytes needed for the message starting at `bytes[0]`; nil when the type is unknown.
    static func expectedLength(_ bytes: [UInt8]) -> Int? {
        guard let first = bytes.first else { return nil }
        if first == MagicHomeMessage.wrapperPrefix[0] {
            guard bytes.count >= MagicHomeMessage.wrapperHeaderLength else { return MagicHomeMessage.wrapperHeaderLength }
            return MagicHomeMessage.wrapperHeaderLength + (Int(bytes[8]) << 8 | Int(bytes[9])) + 1
        }
        if bytes.count >= 2, [0x00, 0x01, 0x0F, 0xF0].contains(first) {
            switch bytes[1] {
            case 0x71: return 4     // power
            case 0x11: return 12    // clock
            case 0x32: return 7     // power-restore settings
            case 0x63: return 11    // device config
            default: break
            }
        }
        switch first {
        case MagicHomeRawState.head: return MagicHomeRawState.length
        case 0x66: return 11        // original (no checksum) protocol state
        case 0x78: return 4         // original protocol power
        case 0x72: return 13        // music mode
        case 0x2B: return 14        // remote config
        default: return bytes.count >= 2 ? nil : 2
        }
    }

    static func decode(_ message: Data) -> [MagicHomeResponse] {
        let bytes = [UInt8](message)
        if bytes.first == MagicHomeMessage.wrapperPrefix[0] {
            guard let inner = MagicHomeMessage.unwrap(message) else { return [.other(message)] }
            var framer = MagicHomeFramer()
            return framer.push(inner)
        }
        if bytes.count == MagicHomeRawState.length, bytes[0] == MagicHomeRawState.head, let state = try? MagicHomeRawState(message) {
            return [.state(state)]
        }
        // Power responses: checksum does not always match on real devices, so it is not checked.
        if bytes.count == 4, bytes[1] == 0x71, bytes[2] == MagicHomeRawState.onByte || bytes[2] == MagicHomeRawState.offByte {
            return [.power(on: bytes[2] == MagicHomeRawState.onByte)]
        }
        return [.other(message)]
    }
}
