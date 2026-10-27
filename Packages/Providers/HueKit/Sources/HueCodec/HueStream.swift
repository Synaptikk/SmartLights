import Foundation

// HueStream v2: the datagram format of the Hue Entertainment API, sent over DTLS-PSK to
// UDP 2100 on the bridge after `PUT entertainment_configuration/{id} {"action":"start"}`.
// Layout (research_hue.md §2.2; all multi-byte values big-endian):
//
//   offset size  content
//   0      9     ASCII "HueStream"
//   9      2     version 0x02 0x00
//   11     1     sequence id (ignored by the bridge)
//   12     2     reserved 0x00 0x00
//   14     1     colour space: 0x00 RGB, 0x01 CIE xy + brightness
//   15     1     reserved 0x00
//   16     36    entertainment_configuration id, ASCII (lower-case UUID text)
//   52     7*N   per channel: channel_id (1 byte) + three UInt16 (R,G,B or x,y,brightness)
//
// At most 20 channels per datagram.

/// Colour space byte of a HueStream v2 frame.
public enum HueStreamColorSpace: UInt8, Sendable, Hashable, CaseIterable {
    /// Three 16-bit values R, G, B (0...65535). The bridge maps them into each light's gamut.
    case rgb = 0x00
    /// Three 16-bit values x, y, brightness (each 0...1 scaled to 0...65535).
    case xyBrightness = 0x01
}

/// One channel entry of a HueStream v2 frame: a channel id from the entertainment
/// configuration's `channels[].channel_id` and three raw 16-bit components.
public struct HueStreamChannel: Sendable, Hashable {
    public var channelID: UInt8
    /// R,G,B (RGB colour space) or x,y,brightness (xy colour space), raw 0...65535.
    public var values: (UInt16, UInt16, UInt16)

    public init(channelID: UInt8, raw values: (UInt16, UInt16, UInt16)) {
        self.channelID = channelID
        self.values = values
    }

    /// RGB components 0...1 (clamped, scaled to 0...65535 and rounded).
    public static func rgb(_ channelID: UInt8, red: Double, green: Double, blue: Double) -> HueStreamChannel {
        HueStreamChannel(channelID: channelID, raw: (quantize(red), quantize(green), quantize(blue)))
    }

    /// CIE x, y and brightness, each 0...1 (clamped, scaled to 0...65535 and rounded).
    public static func xy(_ channelID: UInt8, x: Double, y: Double, brightness: Double) -> HueStreamChannel {
        HueStreamChannel(channelID: channelID, raw: (quantize(x), quantize(y), quantize(brightness)))
    }

    /// 0...1 to 0...65535; NaN maps to 0.
    public static func quantize(_ value: Double) -> UInt16 {
        if value.isNaN { return 0 }
        let clamped = min(max(value, 0), 1)
        return UInt16((clamped * Double(UInt16.max)).rounded())
    }

    public static func == (a: HueStreamChannel, b: HueStreamChannel) -> Bool {
        a.channelID == b.channelID && a.values == b.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(channelID)
        hasher.combine(values.0)
        hasher.combine(values.1)
        hasher.combine(values.2)
    }
}

public enum HueStreamError: Error, Sendable, Equatable, LocalizedError {
    /// The entertainment configuration id is not 36-character UUID text.
    case invalidConfigurationID(String)
    /// More than ``HueStreamFrame/maxChannels`` channels in one frame.
    case tooManyChannels(Int)
    /// A datagram that is not a well-formed HueStream v2 frame.
    case malformedFrame(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfigurationID(let id): "Invalid entertainment configuration id: \(id)"
        case .tooManyChannels(let n): "HueStream frames carry at most \(HueStreamFrame.maxChannels) channels, got \(n)"
        case .malformedFrame(let why): "Malformed HueStream frame: \(why)"
        }
    }
}

/// A HueStream v2 frame: encoder and (for tests and simulators) decoder.
public struct HueStreamFrame: Sendable, Hashable {
    public static let protocolName = Array("HueStream".utf8)
    public static let version: [UInt8] = [0x02, 0x00]
    public static let headerLength = 52
    public static let channelLength = 7
    public static let maxChannels = 20
    /// UDP port of the bridge's DTLS server.
    public static let port: UInt16 = 2100

    public var sequence: UInt8
    public var colorSpace: HueStreamColorSpace
    /// Lower-case UUID text, exactly 36 ASCII bytes.
    public var configurationID: String
    public var channels: [HueStreamChannel]

    /// Validates the configuration id (lower-cased) and the channel count.
    public init(
        configurationID: String, sequence: UInt8 = 0, colorSpace: HueStreamColorSpace,
        channels: [HueStreamChannel]
    ) throws {
        let id = configurationID.lowercased()
        guard Self.isValidConfigurationID(id) else { throw HueStreamError.invalidConfigurationID(configurationID) }
        guard channels.count <= Self.maxChannels else { throw HueStreamError.tooManyChannels(channels.count) }
        self.configurationID = id
        self.sequence = sequence
        self.colorSpace = colorSpace
        self.channels = channels
    }

    /// 8-4-4-4-12 hexadecimal digits separated by dashes.
    public static func isValidConfigurationID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                guard b == UInt8(ascii: "-") else { return false }
            } else {
                let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(b)
                guard isHex else { return false }
            }
        }
        return true
    }

    /// The datagram bytes (52 + 7 * channels.count).
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerLength + channels.count * Self.channelLength)
        out += Self.protocolName
        out += Self.version
        out.append(sequence)
        out += [0x00, 0x00]
        out.append(colorSpace.rawValue)
        out.append(0x00)
        out += Array(configurationID.utf8)
        for channel in channels {
            out.append(channel.channelID)
            for value in [channel.values.0, channel.values.1, channel.values.2] {
                out.append(UInt8(value >> 8))
                out.append(UInt8(value & 0xFF))
            }
        }
        return out
    }

    public var data: Data { Data(encoded()) }

    /// Splits `channels` into as many frames as needed (20 channels each), sharing one sequence id.
    public static func frames(
        configurationID: String, sequence: UInt8, colorSpace: HueStreamColorSpace, channels: [HueStreamChannel]
    ) throws -> [HueStreamFrame] {
        if channels.isEmpty {
            return [try HueStreamFrame(configurationID: configurationID, sequence: sequence, colorSpace: colorSpace, channels: [])]
        }
        return try stride(from: 0, to: channels.count, by: maxChannels).map { start in
            let chunk = Array(channels[start..<min(start + maxChannels, channels.count)])
            return try HueStreamFrame(
                configurationID: configurationID, sequence: sequence, colorSpace: colorSpace, channels: chunk)
        }
    }

    /// Parses a datagram (used by the DTLS echo test and simulators).
    public init(decoding bytes: some Collection<UInt8>) throws {
        let b = Array(bytes)
        guard b.count >= Self.headerLength else { throw HueStreamError.malformedFrame("\(b.count) bytes, header is 52") }
        guard Array(b[0..<9]) == Self.protocolName else { throw HueStreamError.malformedFrame("missing \"HueStream\"") }
        guard Array(b[9..<11]) == Self.version else {
            throw HueStreamError.malformedFrame("version \(b[9]).\(b[10]), expected 2.0")
        }
        guard let space = HueStreamColorSpace(rawValue: b[14]) else {
            throw HueStreamError.malformedFrame("colour space \(b[14])")
        }
        let body = b.count - Self.headerLength
        guard body % Self.channelLength == 0 else {
            throw HueStreamError.malformedFrame("\(body) channel bytes is not a multiple of 7")
        }
        let id = String(decoding: b[16..<52], as: UTF8.self)
        var channels: [HueStreamChannel] = []
        var i = Self.headerLength
        while i < b.count {
            func u16(_ at: Int) -> UInt16 { UInt16(b[at]) << 8 | UInt16(b[at + 1]) }
            channels.append(HueStreamChannel(channelID: b[i], raw: (u16(i + 1), u16(i + 3), u16(i + 5))))
            i += Self.channelLength
        }
        try self.init(configurationID: id, sequence: b[11], colorSpace: space, channels: channels)
    }
}

/// DTLS pre-shared key material for the Entertainment stream.
public enum HueClientKey {
    /// Decodes the `clientkey` returned by pairing (32 hex digits) into the 16-byte PSK.
    /// Returns nil for odd length, non-hex characters or an empty string.
    public static func psk(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count.isMultiple(of: 2) else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
