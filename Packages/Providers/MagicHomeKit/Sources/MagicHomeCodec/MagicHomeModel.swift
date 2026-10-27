import Foundation

/// How a device's channels are used, from the model table (or the state's mode byte for unknown
/// models). Mirrors flux_led's colour-mode sets.
public enum MagicHomeChannelLayout: String, Sendable, Hashable, Codable, CaseIterable {
    /// On/off only (plugs, switches).
    case `switch`
    /// One white channel (dimmer).
    case dim
    /// Warm + cold white.
    case cct
    case rgb
    /// RGB plus one white channel, settable together.
    case rgbw
    /// RGB plus warm and cold white, settable together.
    case rgbww
    /// RGB *or* one white channel (bulbs: the white LEDs light only when RGB is off).
    case rgbOrWhite
    /// RGB *or* warm/cold white (RGB/CCT bulbs and lamps).
    case rgbOrCCT

    public var hasColor: Bool {
        switch self {
        case .rgb, .rgbw, .rgbww, .rgbOrWhite, .rgbOrCCT: true
        case .switch, .dim, .cct: false
        }
    }

    /// Colour and white channels can be written in the same message.
    public var writesColorAndWhiteTogether: Bool { self == .rgbw || self == .rgbww }
}

/// Where the device reports/expects channels that flux_led's channel map moves.
public enum MagicHomeChannelMap: String, Sendable, Hashable, Codable {
    case none
    /// Single white channel lives in the red byte (dimmers, dimmable bulbs).
    case whiteInRed
    /// Warm white in the red byte, cold white in the green byte (8-byte CCT devices).
    case cctInRedGreen
}

/// One row of the model-id table (byte 1 of the state response).
///
/// Ported as data from flux_led's `models_db.py` (protocol per firmware version, colour modes,
/// channel maps); see NOTICES.md. Addressable strips (0xA1-0xA7), Christmas/string lights, the
/// original no-checksum protocol (0x01-0x03), 25-byte (0x35 firmware >= 10) and extended-state
/// (0xB6) devices are listed with `supported == false`.
public struct MagicHomeModel: Sendable, Hashable {
    public var number: UInt8
    public var name: String
    /// `(minimum firmware version, protocol)`, highest version first; nil protocol = unsupported dialect.
    public var protocols: [(minVersion: UInt8, protocol: MagicHomeProtocol?)]
    public var layout: MagicHomeChannelLayout
    /// Layout by the state's `mode` byte (multi-mode controllers); falls back to `layout`.
    public var layoutByMode: [UInt8: MagicHomeChannelLayout]
    public var channelMap: MagicHomeChannelMap
    /// The device needs write mode `all` even though it cannot mix colour and white.
    public var alwaysWritesWhiteAndColors: Bool
    public var microphone: Bool
    /// False for model ids whose dialect this package does not implement.
    public var known: Bool

    public init(
        number: UInt8, name: String, protocols: [(minVersion: UInt8, protocol: MagicHomeProtocol?)],
        layout: MagicHomeChannelLayout, layoutByMode: [UInt8: MagicHomeChannelLayout] = [:],
        channelMap: MagicHomeChannelMap = .none, alwaysWritesWhiteAndColors: Bool = false,
        microphone: Bool = false, known: Bool = true
    ) {
        self.number = number
        self.name = name
        self.protocols = protocols
        self.layout = layout
        self.layoutByMode = layoutByMode
        self.channelMap = channelMap
        self.alwaysWritesWhiteAndColors = alwaysWritesWhiteAndColors
        self.microphone = microphone
        self.known = known
    }

    public static func == (lhs: MagicHomeModel, rhs: MagicHomeModel) -> Bool {
        lhs.number == rhs.number && lhs.name == rhs.name && lhs.known == rhs.known
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(number)
        hasher.combine(name)
    }

    /// Protocol for a firmware version (byte 10 of the state); nil = unsupported dialect.
    public func `protocol`(forVersion version: UInt8) -> MagicHomeProtocol? {
        for entry in protocols where version >= entry.minVersion { return entry.protocol }
        return protocols.last?.protocol
    }

    public var supported: Bool { protocols.contains { $0.protocol != nil } }

    /// Channel layout for the state's mode byte.
    public func layout(forMode mode: UInt8) -> MagicHomeChannelLayout {
        if let l = layoutByMode[mode] { return l }
        if !known { return Self.baseModeLayout[mode & 0x0F] ?? .rgb }
        return layout
    }

    /// Model for a state byte; unknown ids become an 8-byte device whose layout follows the mode byte.
    public static func lookup(_ number: UInt8) -> MagicHomeModel {
        table[number] ?? MagicHomeModel(number: number, name: "Unknown model", protocols: [(0, .ledenet8Byte)],
                                        layout: .rgb, known: false)
    }

    /// Low nibble of the mode byte on multi-mode controllers (flux_led `BASE_MODE_MAP`).
    public static let baseModeLayout: [UInt8: MagicHomeChannelLayout] = [
        0x01: .dim, 0x02: .cct, 0x03: .rgb, 0x04: .rgbw, 0x05: .rgbww, 0x06: .rgbOrWhite, 0x07: .rgbOrCCT,
    ]

    // MARK: Table

    private static let rgbModes: [UInt8: MagicHomeChannelLayout] = [0x13: .rgb, 0x23: .rgb, 0x33: .rgb]
    private static let rgbwModes: [UInt8: MagicHomeChannelLayout] = [
        0x14: .rgbw, 0x24: .rgbw, 0x34: .rgbw, 0x16: .rgbOrWhite, 0x26: .rgbOrWhite, 0x36: .rgbOrWhite,
    ]
    private static let rgbwwModes: [UInt8: MagicHomeChannelLayout] = {
        var m: [UInt8: MagicHomeChannelLayout] = [:]
        for hi: UInt8 in 1...0xF {
            m[hi << 4 | 0x07] = .rgbOrCCT
            m[hi << 4 | 0x05] = .rgbww
        }
        return m
    }()
    private static let rgbCCTBulbModes: [UInt8: MagicHomeChannelLayout] = [0x01: .rgbOrCCT, 0x17: .rgbOrCCT]

    public static let all: [MagicHomeModel] = [
        // Unsupported dialects (listed so diagnostics can name them).
        MagicHomeModel(number: 0x01, name: "Legacy Controller RGB", protocols: [(0, nil)], layout: .rgb),
        MagicHomeModel(number: 0x02, name: "Legacy Controller Dimmable", protocols: [(0, nil)], layout: .dim),
        MagicHomeModel(number: 0x03, name: "Legacy Controller CCT", protocols: [(0, nil)], layout: .cct),
        MagicHomeModel(number: 0x10, name: "Christmas Light", protocols: [(0, nil)], layout: .rgb),
        MagicHomeModel(number: 0x1A, name: "String Lights", protocols: [(0, nil)], layout: .rgb),
        MagicHomeModel(number: 0xA1, name: "Addressable v1", protocols: [(0, nil)], layout: .rgb),
        MagicHomeModel(number: 0xA2, name: "Addressable v2", protocols: [(0, nil)], layout: .rgb, microphone: true),
        MagicHomeModel(number: 0xA3, name: "Addressable v3", protocols: [(0, nil)], layout: .rgb, microphone: true),
        MagicHomeModel(number: 0xA4, name: "Addressable v4", protocols: [(0, nil)], layout: .rgb),
        MagicHomeModel(number: 0xA6, name: "Addressable v6", protocols: [(0, nil)], layout: .rgb, microphone: true),
        MagicHomeModel(number: 0xA7, name: "Addressable v7", protocols: [(0, nil)], layout: .rgb, microphone: true),
        MagicHomeModel(number: 0xB6, name: "Surplife Outdoor Permanent Lighting", protocols: [(0, nil)], layout: .rgbOrWhite),

        // Controllers.
        MagicHomeModel(number: 0x04, name: "Controller RGB&W", protocols: [(6, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .rgbw, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x06, name: "Controller RGBW",
                       protocols: [(2, .ledenet8ByteDimmableEffects), (1, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .rgbw, layoutByMode: rgbwModes),
        MagicHomeModel(number: 0x07, name: "Controller RGBCW", protocols: [(2, .ledenet9ByteDimmableEffects), (0, .ledenet9Byte)],
                       layout: .rgbww, layoutByMode: rgbwwModes),
        MagicHomeModel(number: 0x08, name: "Controller RGB with MIC",
                       protocols: [(2, .ledenet8ByteDimmableEffects), (1, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .rgb, layoutByMode: rgbModes, alwaysWritesWhiteAndColors: true, microphone: true),
        MagicHomeModel(number: 0x25, name: "Controller RGB/WW/CW", protocols: [(0, .ledenet9Byte)],
                       layout: .rgbww, layoutByMode: baseModeLayout, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x33, name: "Controller RGB",
                       protocols: [(9, .ledenet8ByteDimmableEffects), (6, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .rgb, layoutByMode: rgbModes, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x41, name: "Controller Dimmable", protocols: [(2, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .dim, channelMap: .whiteInRed),
        MagicHomeModel(number: 0x45, name: "Unknown model 0x45", protocols: [(0, .ledenet8Byte)], layout: .rgbOrWhite),
        MagicHomeModel(number: 0x62, name: "Controller CCT", protocols: [(0, .ledenet8Byte)],
                       layout: .cct, channelMap: .cctInRedGreen, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x81, name: "Unknown model 0x81", protocols: [(0, .ledenet8Byte)],
                       layout: .rgbw, alwaysWritesWhiteAndColors: true),

        // Bulbs and lamps.
        MagicHomeModel(number: 0x09, name: "High Voltage Bulb CCT", protocols: [(0, .cct)], layout: .cct),
        MagicHomeModel(number: 0x0E, name: "Floor Lamp RGBCW",
                       protocols: [(9, .ledenet9ByteDimmableEffects), (7, .ledenet9ByteAutoOn), (0, .ledenet9Byte)],
                       layout: .rgbOrCCT, layoutByMode: rgbCCTBulbModes),
        MagicHomeModel(number: 0x16, name: "Magnetic Light CCT", protocols: [(0, .ledenet8Byte)],
                       layout: .cct, channelMap: .cctInRedGreen, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x17, name: "Magnetic Light Dimmable", protocols: [(0, .ledenet8Byte)],
                       layout: .dim, channelMap: .whiteInRed, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x1B, name: "Aroma Fragrance Light", protocols: [(0, .ledenet8Byte)], layout: .rgb),
        MagicHomeModel(number: 0x1C, name: "Table Light CCT", protocols: [(0, .cctWrapped)], layout: .cct),
        MagicHomeModel(number: 0x1D, name: "Fill Light", protocols: [(2, .ledenet8ByteAutoOn)],
                       layout: .dim, channelMap: .whiteInRed, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x1E, name: "Ceiling Light RGBCW",
                       protocols: [(9, .ledenet9ByteDimmableEffects), (7, .ledenet9ByteAutoOn), (0, .ledenet9Byte)],
                       layout: .rgbOrCCT, layoutByMode: rgbCCTBulbModes),
        MagicHomeModel(number: 0x21, name: "Bulb Dimmable", protocols: [(2, .ledenet8ByteAutoOn), (0, .ledenet8Byte)],
                       layout: .dim, channelMap: .whiteInRed, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x35, name: "Bulb RGBCW",
                       protocols: [(10, nil), (9, .ledenet9ByteDimmableEffects), (7, .ledenet9ByteAutoOn), (0, .ledenet9Byte)],
                       layout: .rgbOrCCT, layoutByMode: rgbCCTBulbModes),
        MagicHomeModel(number: 0x44, name: "Bulb RGBW", protocols: [(9, .ledenet8ByteAutoOn), (0, .ledenet8Byte)], layout: .rgbOrWhite),
        MagicHomeModel(number: 0x52, name: "Bulb CCT", protocols: [(0, .ledenet8Byte)],
                       layout: .cct, channelMap: .cctInRedGreen, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0x54, name: "Downlight RGBW", protocols: [(0, .ledenet8Byte)], layout: .rgbOrWhite),
        MagicHomeModel(number: 0xE1, name: "Ceiling Light CCT", protocols: [(0, .ledenet8Byte)],
                       layout: .cct, channelMap: .cctInRedGreen, alwaysWritesWhiteAndColors: true),
        MagicHomeModel(number: 0xE2, name: "Ceiling Light CCT Assist", protocols: [(0, .ledenet8Byte)],
                       layout: .cct, channelMap: .cctInRedGreen, alwaysWritesWhiteAndColors: true),

        // Switches and plugs (power only).
        MagicHomeModel(number: 0x0B, name: "Switch 1 Channel", protocols: [(0, .ledenet8Byte)], layout: .switch),
        MagicHomeModel(number: 0x18, name: "Plant Grow Light", protocols: [(0, .ledenet8Byte)], layout: .switch),
        MagicHomeModel(number: 0x19, name: "Socket with 2 USB", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0x93, name: "Switch", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0x94, name: "Switch Watt", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0x95, name: "Switch 2 Channel", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0x96, name: "Switch 4 Channel", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0x97, name: "Socket", protocols: [(0, .socket)], layout: .switch),
        MagicHomeModel(number: 0xD1, name: "Digital Time Light", protocols: [(0, .ledenet8Byte)], layout: .switch),
    ]

    public static let table: [UInt8: MagicHomeModel] = Dictionary(all.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
}
