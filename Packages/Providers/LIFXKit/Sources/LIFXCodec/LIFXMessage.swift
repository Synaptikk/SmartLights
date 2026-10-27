import Foundation

/// LIFX colour: hue, saturation, brightness, kelvin as on the wire (`LightHsbk`, 8 bytes).
/// - hue `0...65535` maps to `0..<360` degrees;
/// - saturation and brightness `0...65535` map to `0...1`;
/// - kelvin is the white point, `1500...9000` on most products (newer firmware 1000...10000),
///   only visible when saturation is low.
public struct HSBK: Hashable, Sendable, Codable {
    public var hue: UInt16
    public var saturation: UInt16
    public var brightness: UInt16
    public var kelvin: UInt16

    public init(hue: UInt16, saturation: UInt16, brightness: UInt16, kelvin: UInt16) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.kelvin = kelvin
    }

    /// Builds from natural units: degrees, `0...1`, `0...1`, Kelvin (clamped to `0...65535`).
    public init(hueDegrees: Double, saturation: Double, brightness: Double, kelvin: Int) {
        self.hue = HSBK.encodeHue(hueDegrees)
        self.saturation = HSBK.encodeUnit(saturation)
        self.brightness = HSBK.encodeUnit(brightness)
        self.kelvin = UInt16(clamping: kelvin)
    }

    /// Hue in degrees `0..<360`.
    public var hueDegrees: Double { Double(hue) * 360 / 65536 }
    /// Saturation `0...1`.
    public var saturationFraction: Double { Double(saturation) / 65535 }
    /// Brightness `0...1`.
    public var brightnessFraction: Double { Double(brightness) / 65535 }

    /// Degrees (any value, wrapped) -> `0...65535` (`round(h / 360 * 65536) mod 65536`).
    public static func encodeHue(_ degrees: Double) -> UInt16 {
        guard degrees.isFinite else { return 0 }
        var h = degrees.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let raw = Int((h / 360 * 65536).rounded()) % 65536
        return UInt16(raw)
    }

    /// `0...1` (clamped) -> `0...65535`.
    public static func encodeUnit(_ value: Double) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(max(value, 0), 1) * 65535).rounded())
    }

    /// Neutral white at full brightness, 3500 K.
    public static let white = HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 3500)
}

/// `SetWaveform` (103) parameters.
public struct LIFXWaveform: Hashable, Sendable {
    public enum Shape: UInt8, Sendable, CaseIterable {
        case saw = 0
        case sine = 1
        case halfSine = 2
        case triangle = 3
        case pulse = 4
    }

    /// When true the light returns to its original colour after the effect.
    public var transient: Bool
    public var color: HSBK
    /// Duration of one cycle in milliseconds.
    public var periodMs: UInt32
    public var cycles: Float
    /// For `.pulse`: duty cycle in `-32768...32767` (0 = 50 %).
    public var skewRatio: Int16
    public var waveform: Shape

    public init(transient: Bool = true, color: HSBK, periodMs: UInt32, cycles: Float, skewRatio: Int16 = 0, waveform: Shape) {
        self.transient = transient
        self.color = color
        self.periodMs = periodMs
        self.cycles = cycles
        self.skewRatio = skewRatio
        self.waveform = waveform
    }
}

/// `LightState` (107) payload.
public struct LIFXLightStatePayload: Hashable, Sendable {
    public var color: HSBK
    /// 0 = off, 65535 = on.
    public var power: UInt16
    public var label: String

    public init(color: HSBK, power: UInt16, label: String) {
        self.color = color
        self.power = power
        self.label = label
    }

    public var isOn: Bool { power > 0 }
}

/// Multizone apply modes (`MultiZoneApplicationRequest`, also used by extended multizone).
public enum LIFXZoneApply: UInt8, Sendable, CaseIterable {
    /// Buffer the change; apply with a later `.apply` message.
    case noApply = 0
    /// Apply this and every buffered change.
    case apply = 1
    /// Apply buffered changes only, ignoring this message's colours.
    case applyOnly = 2
}

/// The LIFX LAN messages SmartLights uses. Unknown types decode as `.unknown`.
/// Ids from https://github.com/LIFX/public-protocol/blob/master/protocol.yml .
public enum LIFXMessage: Hashable, Sendable {
    // Device
    case getService                                        // 2
    case stateService(service: UInt8, port: UInt32)        // 3
    case getHostFirmware                                   // 14
    case stateHostFirmware(build: UInt64, major: UInt16, minor: UInt16) // 15
    case getPower                                          // 20
    case setPower(level: UInt16)                           // 21
    case statePower(level: UInt16)                         // 22
    case getLabel                                          // 23
    case stateLabel(String)                                // 25
    case getVersion                                        // 32
    case stateVersion(vendor: UInt32, product: UInt32)     // 33
    case acknowledgement                                   // 45
    case stateUnhandled(type: UInt16)                      // 223
    // Light
    case lightGet                                          // 101
    case lightSetColor(HSBK, durationMs: UInt32)           // 102
    case lightSetWaveform(LIFXWaveform)                    // 103
    case lightState(LIFXLightStatePayload)                 // 107
    case lightGetPower                                     // 116
    case lightSetPower(level: UInt16, durationMs: UInt32)  // 117
    case lightStatePower(level: UInt16)                    // 118
    // Multizone
    case setColorZones(start: UInt8, end: UInt8, color: HSBK, durationMs: UInt32, apply: LIFXZoneApply) // 501
    case getColorZones(start: UInt8, end: UInt8)           // 502
    case stateZone(count: UInt8, index: UInt8, color: HSBK) // 503
    case stateMultiZone(count: UInt8, index: UInt8, colors: [HSBK]) // 506 (8 colours)
    case extendedSetColorZones(durationMs: UInt32, apply: LIFXZoneApply, index: UInt16, colors: [HSBK]) // 510 (<= 82)
    case extendedGetColorZones                             // 511
    case extendedStateMultiZone(count: UInt16, index: UInt16, colors: [HSBK]) // 512 (<= 82)
    case unknown(type: UInt16, payload: [UInt8])

    /// Message type ids.
    public enum Kind {
        public static let getService: UInt16 = 2
        public static let stateService: UInt16 = 3
        public static let getHostFirmware: UInt16 = 14
        public static let stateHostFirmware: UInt16 = 15
        public static let getPower: UInt16 = 20
        public static let setPower: UInt16 = 21
        public static let statePower: UInt16 = 22
        public static let getLabel: UInt16 = 23
        public static let stateLabel: UInt16 = 25
        public static let getVersion: UInt16 = 32
        public static let stateVersion: UInt16 = 33
        public static let acknowledgement: UInt16 = 45
        public static let stateUnhandled: UInt16 = 223
        public static let lightGet: UInt16 = 101
        public static let lightSetColor: UInt16 = 102
        public static let lightSetWaveform: UInt16 = 103
        public static let lightState: UInt16 = 107
        public static let lightGetPower: UInt16 = 116
        public static let lightSetPower: UInt16 = 117
        public static let lightStatePower: UInt16 = 118
        public static let setColorZones: UInt16 = 501
        public static let getColorZones: UInt16 = 502
        public static let stateZone: UInt16 = 503
        public static let stateMultiZone: UInt16 = 506
        public static let extendedSetColorZones: UInt16 = 510
        public static let extendedGetColorZones: UInt16 = 511
        public static let extendedStateMultiZone: UInt16 = 512
    }

    /// Max colours in one extended multizone message.
    public static let extendedZoneCapacity = 82
    /// Colours in one `StateMultiZone` (506).
    public static let multiZoneCapacity = 8
    /// `DeviceService` value for UDP in `StateService`.
    public static let serviceUDP: UInt8 = 1

    public var type: UInt16 {
        switch self {
        case .getService: Kind.getService
        case .stateService: Kind.stateService
        case .getHostFirmware: Kind.getHostFirmware
        case .stateHostFirmware: Kind.stateHostFirmware
        case .getPower: Kind.getPower
        case .setPower: Kind.setPower
        case .statePower: Kind.statePower
        case .getLabel: Kind.getLabel
        case .stateLabel: Kind.stateLabel
        case .getVersion: Kind.getVersion
        case .stateVersion: Kind.stateVersion
        case .acknowledgement: Kind.acknowledgement
        case .stateUnhandled: Kind.stateUnhandled
        case .lightGet: Kind.lightGet
        case .lightSetColor: Kind.lightSetColor
        case .lightSetWaveform: Kind.lightSetWaveform
        case .lightState: Kind.lightState
        case .lightGetPower: Kind.lightGetPower
        case .lightSetPower: Kind.lightSetPower
        case .lightStatePower: Kind.lightStatePower
        case .setColorZones: Kind.setColorZones
        case .getColorZones: Kind.getColorZones
        case .stateZone: Kind.stateZone
        case .stateMultiZone: Kind.stateMultiZone
        case .extendedSetColorZones: Kind.extendedSetColorZones
        case .extendedGetColorZones: Kind.extendedGetColorZones
        case .extendedStateMultiZone: Kind.extendedStateMultiZone
        case .unknown(let type, _): type
        }
    }

    /// Payload bytes (without the 36-byte header).
    public func encodePayload() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .getService, .getHostFirmware, .getPower, .getLabel, .getVersion, .acknowledgement,
             .lightGet, .lightGetPower, .extendedGetColorZones:
            break
        case .stateService(let service, let port):
            w.u8(service); w.u32(port)
        case .stateHostFirmware(let build, let major, let minor):
            w.u64(build); w.zeros(8); w.u16(minor); w.u16(major)
        case .setPower(let level), .statePower(let level), .lightStatePower(let level):
            w.u16(level)
        case .stateLabel(let label):
            w.fixed(Self.labelBytes(label), size: 32)
        case .stateVersion(let vendor, let product):
            w.u32(vendor); w.u32(product); w.zeros(4)
        case .stateUnhandled(let type):
            w.u16(type)
        case .lightSetColor(let color, let duration):
            w.zeros(1); w.hsbk(color); w.u32(duration)
        case .lightSetWaveform(let wf):
            w.zeros(1); w.bool(wf.transient); w.hsbk(wf.color); w.u32(wf.periodMs); w.f32(wf.cycles)
            w.i16(wf.skewRatio); w.u8(wf.waveform.rawValue)
        case .lightState(let s):
            w.hsbk(s.color); w.zeros(2); w.u16(s.power); w.fixed(Self.labelBytes(s.label), size: 32); w.zeros(8)
        case .lightSetPower(let level, let duration):
            w.u16(level); w.u32(duration)
        case .setColorZones(let start, let end, let color, let duration, let apply):
            w.u8(start); w.u8(end); w.hsbk(color); w.u32(duration); w.u8(apply.rawValue)
        case .getColorZones(let start, let end):
            w.u8(start); w.u8(end)
        case .stateZone(let count, let index, let color):
            w.u8(count); w.u8(index); w.hsbk(color)
        case .stateMultiZone(let count, let index, let colors):
            w.u8(count); w.u8(index)
            Self.writeColors(colors, slots: Self.multiZoneCapacity, into: &w)
        case .extendedSetColorZones(let duration, let apply, let index, let colors):
            w.u32(duration); w.u8(apply.rawValue); w.u16(index)
            w.u8(UInt8(min(colors.count, Self.extendedZoneCapacity)))
            Self.writeColors(colors, slots: Self.extendedZoneCapacity, into: &w)
        case .extendedStateMultiZone(let count, let index, let colors):
            w.u16(count); w.u16(index)
            w.u8(UInt8(min(colors.count, Self.extendedZoneCapacity)))
            Self.writeColors(colors, slots: Self.extendedZoneCapacity, into: &w)
        case .unknown(_, let payload):
            w.raw(payload)
        }
        return w.bytes
    }

    private static func writeColors(_ colors: [HSBK], slots: Int, into w: inout ByteWriter) {
        for i in 0..<slots {
            w.hsbk(i < colors.count ? colors[i] : HSBK(hue: 0, saturation: 0, brightness: 0, kelvin: 0))
        }
    }

    /// Decodes a payload for `type`. Extra trailing bytes are ignored; missing bytes throw.
    public static func decode(type: UInt16, payload: [UInt8]) throws -> LIFXMessage {
        var r = ByteReader(payload)
        switch type {
        case Kind.getService: return .getService
        case Kind.stateService: return .stateService(service: try r.u8(), port: try r.u32())
        case Kind.getHostFirmware: return .getHostFirmware
        case Kind.stateHostFirmware:
            let build = try r.u64()
            try r.skip(8)
            let minor = try r.u16()
            let major = try r.u16()
            return .stateHostFirmware(build: build, major: major, minor: minor)
        case Kind.getPower: return .getPower
        case Kind.setPower: return .setPower(level: try r.u16())
        case Kind.statePower: return .statePower(level: try r.u16())
        case Kind.getLabel: return .getLabel
        case Kind.stateLabel: return .stateLabel(Self.label(try r.bytes(32)))
        case Kind.getVersion: return .getVersion
        case Kind.stateVersion:
            let vendor = try r.u32()
            let product = try r.u32()
            return .stateVersion(vendor: vendor, product: product)
        case Kind.acknowledgement: return .acknowledgement
        case Kind.stateUnhandled: return .stateUnhandled(type: try r.u16())
        case Kind.lightGet: return .lightGet
        case Kind.lightSetColor:
            try r.skip(1)
            return .lightSetColor(try r.hsbk(), durationMs: try r.u32())
        case Kind.lightSetWaveform:
            try r.skip(1)
            let transient = try r.bool()
            let color = try r.hsbk()
            let period = try r.u32()
            let cycles = try r.f32()
            let skew = try r.i16()
            let raw = try r.u8()
            guard let shape = LIFXWaveform.Shape(rawValue: raw) else { throw LIFXCodecError.invalidField("waveform \(raw)") }
            return .lightSetWaveform(LIFXWaveform(transient: transient, color: color, periodMs: period, cycles: cycles, skewRatio: skew, waveform: shape))
        case Kind.lightState:
            let color = try r.hsbk()
            try r.skip(2)
            let power = try r.u16()
            let label = Self.label(try r.bytes(32))
            return .lightState(LIFXLightStatePayload(color: color, power: power, label: label))
        case Kind.lightGetPower: return .lightGetPower
        case Kind.lightSetPower: return .lightSetPower(level: try r.u16(), durationMs: try r.u32())
        case Kind.lightStatePower: return .lightStatePower(level: try r.u16())
        case Kind.setColorZones:
            let start = try r.u8()
            let end = try r.u8()
            let color = try r.hsbk()
            let duration = try r.u32()
            let apply = LIFXZoneApply(rawValue: try r.u8()) ?? .apply
            return .setColorZones(start: start, end: end, color: color, durationMs: duration, apply: apply)
        case Kind.getColorZones: return .getColorZones(start: try r.u8(), end: try r.u8())
        case Kind.stateZone: return .stateZone(count: try r.u8(), index: try r.u8(), color: try r.hsbk())
        case Kind.stateMultiZone:
            let count = try r.u8()
            let index = try r.u8()
            var colors: [HSBK] = []
            for _ in 0..<multiZoneCapacity { colors.append(try r.hsbk()) }
            return .stateMultiZone(count: count, index: index, colors: colors)
        case Kind.extendedSetColorZones:
            let duration = try r.u32()
            let apply = LIFXZoneApply(rawValue: try r.u8()) ?? .apply
            let index = try r.u16()
            let n = Int(try r.u8())
            let colors = try readColors(&r, slots: extendedZoneCapacity, keep: n)
            return .extendedSetColorZones(durationMs: duration, apply: apply, index: index, colors: colors)
        case Kind.extendedGetColorZones: return .extendedGetColorZones
        case Kind.extendedStateMultiZone:
            let count = try r.u16()
            let index = try r.u16()
            let n = Int(try r.u8())
            let colors = try readColors(&r, slots: extendedZoneCapacity, keep: n)
            return .extendedStateMultiZone(count: count, index: index, colors: colors)
        default:
            return .unknown(type: type, payload: payload)
        }
    }

    private static func readColors(_ r: inout ByteReader, slots: Int, keep: Int) throws -> [HSBK] {
        guard keep <= slots else { throw LIFXCodecError.invalidField("colors_count \(keep) > \(slots)") }
        var colors: [HSBK] = []
        for i in 0..<slots {
            let c = try r.hsbk()
            if i < keep { colors.append(c) }
        }
        return colors
    }

    /// UTF-8 bytes of `label`, truncated to 32 bytes on a character boundary.
    static func labelBytes(_ label: String) -> [UInt8] {
        var out: [UInt8] = []
        for ch in label {
            let bytes = Array(String(ch).utf8)
            if out.count + bytes.count > 32 { break }
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// 32-byte label: UTF-8 up to the first NUL (invalid UTF-8 is repaired).
    static func label(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
