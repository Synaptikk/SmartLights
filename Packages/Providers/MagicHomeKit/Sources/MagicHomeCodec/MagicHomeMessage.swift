import Foundation

/// The LEDENET wire dialects this package speaks. Which one a device uses follows from its model
/// id and firmware version (`MagicHomeModel.protocol(forVersion:)`), both read from the state
/// response.
public enum MagicHomeProtocol: String, Sendable, Hashable, Codable, CaseIterable {
    /// Checksummed messages, levels `31 r g b w mode 0f`. Levels do not turn the device on.
    case ledenet8Byte = "LEDENET_8BYTE"
    /// As `ledenet8Byte`, but setting levels or an effect turns the device on.
    case ledenet8ByteAutoOn = "LEDENET_8BYTE_AUTO_ON"
    /// As `ledenet8ByteAutoOn`, plus dimmable preset effects (`38 pattern delay brightness`) and
    /// state pushes on external changes.
    case ledenet8ByteDimmableEffects = "LEDENET_8BYTE_DIMMABLE_EFFECTS"
    /// Checksummed, levels `31 r g b ww cw mode 0f` (separate warm and cold white).
    case ledenet9Byte = "LEDENET_9BYTE"
    case ledenet9ByteAutoOn = "LEDENET_9BYTE_AUTO_ON"
    case ledenet9ByteDimmableEffects = "LEDENET_9BYTE_DIMMABLE_EFFECTS"
    /// Smart plugs / switches: power only, state pushes.
    case socket = "LEDENET_SOCKET"
    /// CCT bulbs that take `35 b1 temp% brightness% 00 00 00 03`.
    case cct = "LEDENET_CCT"
    /// `cct` inside the `b0 b1 b2 b3` outer wrapper (table lamp 0x1C).
    case cctWrapped = "LEDENET_CCT_WRAPPED"

    /// Levels and effects turn the device on by themselves (no separate power-on needed).
    public var autoOn: Bool {
        switch self {
        case .ledenet8Byte, .ledenet9Byte, .socket, .cct: false
        case .ledenet8ByteAutoOn, .ledenet8ByteDimmableEffects, .ledenet9ByteAutoOn, .ledenet9ByteDimmableEffects, .cctWrapped: true
        }
    }

    /// Preset effects take a brightness byte.
    public var dimmableEffects: Bool {
        self == .ledenet8ByteDimmableEffects || self == .ledenet9ByteDimmableEffects
    }

    /// Separate warm and cold white bytes in the levels message.
    public var nineByteLevels: Bool {
        switch self {
        case .ledenet9Byte, .ledenet9ByteAutoOn, .ledenet9ByteDimmableEffects: true
        default: false
        }
    }

    /// White channels in the state response are a temperature percentage (`warm_white`) and a
    /// brightness percentage (`cool_white`) instead of 0...255 levels.
    public var whitesAreTemperatureAndBrightness: Bool { self == .cct || self == .cctWrapped }

    /// Messages travel inside the `b0 b1 b2 b3` outer wrapper.
    public var wrapped: Bool { self == .cctWrapped }

    /// The device pushes a state or power response when changed from a remote, the vendor app or
    /// another client.
    public var pushesUpdates: Bool {
        switch self {
        case .ledenet8ByteDimmableEffects, .ledenet9ByteDimmableEffects, .socket, .cct, .cctWrapped: true
        default: false
        }
    }
}

/// Which channel groups a levels message overwrites (byte 5 of 8-byte, byte 7 of 9-byte levels).
public enum MagicHomeWriteMode: UInt8, Sendable, Hashable {
    /// Colours and whites together (RGBW/RGBWW controllers, single-mode devices).
    case all = 0x00
    /// Only the RGB channels (RGB/W and RGB/CCT split devices in colour mode).
    case colors = 0xF0
    /// Only the white channels.
    case whites = 0x0F
}

/// Channel levels for one levels message, already remapped to wire order. `nil` channels are sent
/// as 0 (the device ignores them in `colors`/`whites` write modes).
public struct MagicHomeLevels: Sendable, Hashable {
    public var red: UInt8?
    public var green: UInt8?
    public var blue: UInt8?
    public var warmWhite: UInt8?
    public var coolWhite: UInt8?

    public init(red: UInt8? = nil, green: UInt8? = nil, blue: UInt8? = nil, warmWhite: UInt8? = nil, coolWhite: UInt8? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.warmWhite = warmWhite
        self.coolWhite = coolWhite
    }

    public var hasColor: Bool { red != nil || green != nil || blue != nil }
    public var hasWhite: Bool { warmWhite != nil || coolWhite != nil }
}

/// Builders for the LEDENET messages SmartLights sends. Every message of the checksummed dialects
/// ends with `sum(bytes) & 0xff`.
public enum MagicHomeMessage {
    /// TCP control port.
    public static let port: UInt16 = 5577

    /// `sum(bytes) mod 256`.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    /// `bytes` + checksum.
    public static func withChecksum(_ bytes: [UInt8]) -> Data {
        Data(bytes + [checksum(bytes)])
    }

    /// Whether the last byte is the checksum of the others.
    public static func isChecksumValid(_ message: Data) -> Bool {
        guard let last = message.last, message.count >= 2 else { return false }
        return checksum(message.dropLast()) == last
    }

    // MARK: Outer wrapper

    /// First bytes of a wrapped message: `b0 b1 b2 b3 00 01`, then version, counter, u16 length.
    public static let wrapperPrefix: [UInt8] = [0xB0, 0xB1, 0xB2, 0xB3, 0x00, 0x01]
    /// Bytes before the inner message (prefix + version + counter + length).
    public static let wrapperHeaderLength = 10

    /// Wraps an inner (already checksummed) message: header, inner, outer checksum.
    public static func wrap(_ inner: Data, counter: UInt8, version: UInt8 = 0x01) -> Data {
        let length = UInt16(clamping: inner.count)
        return withChecksum(wrapperPrefix + [version, counter, UInt8(length >> 8), UInt8(length & 0xFF)] + [UInt8](inner))
    }

    /// The inner message of a wrapped one, or nil if `message` is not a valid wrapper.
    public static func unwrap(_ message: Data) -> Data? {
        let bytes = [UInt8](message)
        guard bytes.count > wrapperHeaderLength, bytes.starts(with: wrapperPrefix.prefix(4)), isChecksumValid(message) else { return nil }
        let length = Int(bytes[8]) << 8 | Int(bytes[9])
        guard bytes.count == wrapperHeaderLength + length + 1 else { return nil }
        return Data(bytes[wrapperHeaderLength..<(wrapperHeaderLength + length)])
    }

    // MARK: Requests

    /// State query `81 8a 8b` + checksum (`0x96`). The device answers with a 14-byte state.
    public static func stateQuery(_ proto: MagicHomeProtocol = .ledenet8Byte, counter: UInt8 = 0) -> Data {
        let inner = withChecksum([0x81, 0x8A, 0x8B])
        return proto.wrapped ? wrap(inner, counter: counter) : inner
    }

    /// Power `71 23 0f` (on) / `71 24 0f` (off) + checksum.
    public static func power(_ on: Bool, protocol proto: MagicHomeProtocol = .ledenet8Byte, counter: UInt8 = 0) -> Data {
        let inner = withChecksum([0x71, on ? MagicHomeRawState.onByte : MagicHomeRawState.offByte, 0x0F])
        return proto.wrapped ? wrap(inner, counter: counter) : inner
    }

    /// Levels change. `persist` selects `0x31` (stored as the power-on colour) or `0x41`
    /// (transient, for fast changes such as slider drags).
    ///
    /// - 8-byte: `31 r g b w mode 0f cs`
    /// - 9-byte: `31 r g b ww cw mode 0f cs`
    /// - CCT: `35 b1 temp% brightness% 00 00 00 03 cs` from the white levels (wrapped for 0x1C).
    public static func levels(
        _ levels: MagicHomeLevels,
        writeMode: MagicHomeWriteMode,
        protocol proto: MagicHomeProtocol,
        persist: Bool = true,
        counter: UInt8 = 0
    ) -> Data {
        let head: UInt8 = persist ? 0x31 : 0x41
        let r = levels.red ?? 0, g = levels.green ?? 0, b = levels.blue ?? 0
        let ww = levels.warmWhite ?? 0, cw = levels.coolWhite ?? 0
        switch proto {
        case .cct, .cctWrapped:
            let scaled = MagicHomeWhite.scaledTemperature(warm: ww, cool: cw)
            // Below 2 % the device flips from cold to warm.
            let inner = withChecksum([0x35, 0xB1, scaled.temperature, max(2, scaled.brightness), 0x00, 0x00, 0x00, 0x03])
            return proto.wrapped ? wrap(inner, counter: counter) : inner
        case .ledenet9Byte, .ledenet9ByteAutoOn, .ledenet9ByteDimmableEffects:
            return withChecksum([head, r, g, b, ww, cw, writeMode.rawValue, 0x0F])
        case .ledenet8Byte, .ledenet8ByteAutoOn, .ledenet8ByteDimmableEffects, .socket:
            return withChecksum([head, r, g, b, ww, writeMode.rawValue, 0x0F])
        }
    }

    /// Built-in effect. Dimmable-effect devices: `38 pattern delay brightness%`; others:
    /// `61 pattern delay 0f`. `speed` 0...100 maps to the 1...31 delay byte (1 = fastest).
    public static func presetPattern(_ pattern: UInt8, speed: Int, brightness: Int, protocol proto: MagicHomeProtocol) -> Data {
        let delay = MagicHomeEffect.delay(forSpeed: speed)
        if proto.dimmableEffects {
            return withChecksum([0x38, pattern, delay, UInt8(clamping: min(max(brightness, 0), 100))])
        }
        return withChecksum([0x61, pattern, delay, 0x0F])
    }
}

/// Warm/cold white helpers (2700-6500 K linear mix, as the vendor app does).
public enum MagicHomeWhite {
    public static let minKelvin = 2700
    public static let maxKelvin = 6500

    /// Kelvin + brightness (0...255) -> warm and cold levels (0...255).
    public static func levels(kelvin: Int, brightness: Int, minKelvin: Int = minKelvin, maxKelvin: Int = maxKelvin) -> (warm: UInt8, cool: UInt8) {
        let k = Double(min(max(kelvin, minKelvin), maxKelvin))
        let b = (Double(min(max(brightness, 0), 255)) / 255 * 100).rounded() / 100
        let warm = (Double(maxKelvin) - k) / Double(maxKelvin - minKelvin) * b
        let cold = b - warm
        return (UInt8(clamping: Int((255 * warm).rounded())), UInt8(clamping: Int((255 * cold).rounded())))
    }

    /// Warm and cold levels -> (Kelvin, brightness 0...255).
    public static func kelvin(warm: UInt8, cool: UInt8, minKelvin: Int = minKelvin, maxKelvin: Int = maxKelvin) -> (kelvin: Int, brightness: Int) {
        let w = Double(warm) / 255, c = Double(cool) / 255
        let b = w + c
        let k = b == 0 ? Double(minKelvin) : c / b * Double(maxKelvin - minKelvin) + Double(minKelvin)
        return (Int(k.rounded()), min(255, Int((b * 255).rounded())))
    }

    /// Warm/cold levels -> (cold share 0...100, brightness 0...100) for the CCT dialect.
    public static func scaledTemperature(warm: UInt8, cool: UInt8) -> (temperature: UInt8, brightness: UInt8) {
        let w = Double(warm) / 255, c = Double(cool) / 255
        let b = w + c
        let t = b == 0 ? 0 : c / b * 100
        return (UInt8(clamping: Int(t.rounded())), UInt8(clamping: min(100, Int((b * 100).rounded()))))
    }

    /// CCT dialect state (cold share 0...100, brightness 0...100) -> warm/cold levels 0...255.
    public static func levels(scaledTemperature t: UInt8, brightness: UInt8) -> (warm: UInt8, cool: UInt8) {
        let temp = Double(min(t, 100)), bri = Double(min(brightness, 100)) / 100
        let warm = (100 - temp) / 100 * bri
        let cold = bri - warm
        return (UInt8(clamping: Int((255 * warm).rounded())), UInt8(clamping: Int((255 * cold).rounded())))
    }
}
