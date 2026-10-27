import Foundation
import LightCore

/// Govee LAN API constants (https://app-h5.govee.com/user-manual/wlan-guide; same values in
/// govee-local-api `controller.py` and homebridge-govee `lan.js`).
///
/// 1. The client sends `scan` to the multicast group `239.255.255.250:4001` (devices with
///    "LAN Control" on join the group), or unicast to a known device IP on port 4001.
/// 2. Each device answers with a `scan` response to the client's UDP **4002**.
/// 3. Commands go to the device's UDP **4003**; only `devStatus` gets an answer (to 4002).
public enum GoveeLAN {
    public static let multicastAddress = "239.255.255.250"
    public static let scanPort: UInt16 = 4001
    public static let listenPort: UInt16 = 4002
    public static let controlPort: UInt16 = 4003
    /// LAN brightness range (`brightness.value`).
    public static let brightnessRange: ClosedRange<Int> = 1...100
    /// Colour-temperature range assumed when a model does not declare its own (govee-local-api
    /// `DEFAULT_TEMPERATURE_RANGE`).
    public static let defaultKelvinRange: ClosedRange<Int> = 2000...9000
}

/// Govee device ids are MAC-like strings (`"1F:80:C5:32:32:36:72:4E"`, 8 bytes). The same id is
/// used by the LAN API (`device`) and the Developer API (`device`), so it is the stable key.
public enum GoveeDeviceID {
    /// Uppercased, trimmed; dashes become colons (some tools print `1F-80-...`).
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    /// `govee:<device id>`; nil for empty ids.
    public static func lightID(_ device: String) -> LightID? {
        LightID(brand: .govee, stableId: normalize(device))
    }
}

/// RGB triple as Govee sends it (`{"r":255,"g":0,"b":0}`), 0...255 per channel.
public struct GoveeRGB: Codable, Sendable, Hashable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(_ rgb: RGB) {
        self.init(r: Int(rgb.r), g: Int(rgb.g), b: Int(rgb.b))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = c.lenientInt(.r) ?? 0
        g = c.lenientInt(.g) ?? 0
        b = c.lenientInt(.b) ?? 0
    }

    /// Clamped to `0...255`.
    public var rgb: RGB {
        RGB(r: UInt8(clamping: r), g: UInt8(clamping: g), b: UInt8(clamping: b))
    }

    public var isBlack: Bool { r <= 0 && g <= 0 && b <= 0 }
}

/// `scan` response data.
public struct GoveeScanResponse: Codable, Sendable, Hashable {
    public var ip: String
    public var device: String
    public var sku: String
    public var bleVersionHard: String?
    public var bleVersionSoft: String?
    public var wifiVersionHard: String?
    public var wifiVersionSoft: String?

    public init(ip: String, device: String, sku: String, bleVersionHard: String? = nil, bleVersionSoft: String? = nil,
                wifiVersionHard: String? = nil, wifiVersionSoft: String? = nil) {
        self.ip = ip
        self.device = device
        self.sku = sku
        self.bleVersionHard = bleVersionHard
        self.bleVersionSoft = bleVersionSoft
        self.wifiVersionHard = wifiVersionHard
        self.wifiVersionSoft = wifiVersionSoft
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let device = c.lenientString(.device), !device.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.device, .init(codingPath: c.codingPath, debugDescription: "scan response without device"))
        }
        self.device = device
        ip = c.lenientString(.ip) ?? ""
        sku = c.lenientString(.sku) ?? ""
        bleVersionHard = c.lenientString(.bleVersionHard)
        bleVersionSoft = c.lenientString(.bleVersionSoft)
        wifiVersionHard = c.lenientString(.wifiVersionHard)
        wifiVersionSoft = c.lenientString(.wifiVersionSoft)
    }

    /// Normalised stable id.
    public var deviceID: String { GoveeDeviceID.normalize(device) }

    /// Non-secret metadata for `DiscoveredDevice.metadata` / `PairedDevice.metadata`.
    public var metadata: [String: String] {
        var m: [String: String] = ["sku": sku]
        if let bleVersionHard { m["bleVersionHard"] = bleVersionHard }
        if let bleVersionSoft { m["bleVersionSoft"] = bleVersionSoft }
        if let wifiVersionHard { m["wifiVersionHard"] = wifiVersionHard }
        if let wifiVersionSoft { m["wifiVersionSoft"] = wifiVersionSoft }
        return m
    }
}

/// `devStatus` response data. The response carries no device id; correlate by source IP.
public struct GoveeDevStatus: Codable, Sendable, Hashable {
    public var onOff: Int
    /// 1...100 (0 seen on some firmware while off).
    public var brightness: Int
    public var color: GoveeRGB
    /// Non-zero when the light is in white (colour-temperature) mode.
    public var colorTemInKelvin: Int

    public init(onOff: Int, brightness: Int, color: GoveeRGB = GoveeRGB(r: 0, g: 0, b: 0), colorTemInKelvin: Int = 0) {
        self.onOff = onOff
        self.brightness = brightness
        self.color = color
        self.colorTemInKelvin = colorTemInKelvin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onOff = c.lenientInt(.onOff) ?? 0
        brightness = c.lenientInt(.brightness) ?? 0
        color = (try? c.decodeIfPresent(GoveeRGB.self, forKey: .color)) ?? GoveeRGB(r: 0, g: 0, b: 0)
        colorTemInKelvin = c.lenientInt(.colorTemInKelvin) ?? 0
    }

    public var isOn: Bool { onOff != 0 }
}

/// A message the client sends (and the in-package fake device parses).
public enum GoveeLANCommand: Sendable, Hashable {
    /// `{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}`
    case scan
    /// `{"msg":{"cmd":"devStatus","data":{}}}`
    case devStatus
    /// `turn` with `value` 0/1.
    case turn(Bool)
    /// `brightness` with `value` 1...100 (clamped when encoding).
    case brightness(Int)
    /// `colorwc` with an RGB colour and `colorTemInKelvin: 0`.
    case color(RGB)
    /// `colorwc` with `color` 0/0/0 and the given Kelvin.
    case colorTemperature(Int)

    public var cmd: String {
        switch self {
        case .scan: "scan"
        case .devStatus: "devStatus"
        case .turn: "turn"
        case .brightness: "brightness"
        case .color, .colorTemperature: "colorwc"
        }
    }

    /// Port the command is sent to.
    public var port: UInt16 {
        if case .scan = self { return GoveeLAN.scanPort }
        return GoveeLAN.controlPort
    }

    /// Compact, key-sorted JSON bytes.
    public func encoded() -> Data {
        let data: GoveeJSONValue = switch self {
        case .scan: .object(["account_topic": .string("reserve")])
        case .devStatus: .object([:])
        case .turn(let on): .object(["value": .int(on ? 1 : 0)])
        case .brightness(let v):
            .object(["value": .int(min(max(v, GoveeLAN.brightnessRange.lowerBound), GoveeLAN.brightnessRange.upperBound))])
        case .color(let rgb):
            .object([
                "color": .object(["r": .int(Int(rgb.r)), "g": .int(Int(rgb.g)), "b": .int(Int(rgb.b))]),
                "colorTemInKelvin": .int(0),
            ])
        case .colorTemperature(let k):
            .object([
                "color": .object(["r": .int(0), "g": .int(0), "b": .int(0)]),
                "colorTemInKelvin": .int(max(0, k)),
            ])
        }
        let envelope: GoveeJSONValue = .object(["msg": .object(["cmd": .string(cmd), "data": data])])
        return (try? GoveeJSONCoding.encoder().encode(envelope)) ?? Data()
    }

    /// Parses a client message (used by the fake device in tests and by diagnostics).
    public static func decode(_ data: Data) -> GoveeLANCommand? {
        guard let (cmd, payload) = GoveeLANEnvelope.split(data) else { return nil }
        switch cmd {
        case "scan": return .scan
        case "devStatus": return .devStatus
        case "turn": return payload["value"]?.intValue.map { .turn($0 != 0) }
        case "brightness": return payload["value"]?.intValue.map { .brightness($0) }
        case "colorwc":
            let kelvin = payload["colorTemInKelvin"]?.intValue ?? 0
            if kelvin > 0 { return .colorTemperature(kelvin) }
            let c = payload["color"]
            let rgb = RGB(
                r: UInt8(clamping: c?["r"]?.intValue ?? 0),
                g: UInt8(clamping: c?["g"]?.intValue ?? 0),
                b: UInt8(clamping: c?["b"]?.intValue ?? 0)
            )
            return .color(rgb)
        default: return nil
        }
    }
}

/// A message a device sends to the client's port 4002.
public enum GoveeLANResponse: Sendable, Hashable {
    case scan(GoveeScanResponse)
    case devStatus(GoveeDevStatus)

    /// Parses a datagram received on 4002. Returns nil for anything that is not a Govee
    /// `scan`/`devStatus` response (port 4002 also sees other traffic; drop it silently).
    public static func decode(_ data: Data) -> GoveeLANResponse? {
        guard let (cmd, payload) = GoveeLANEnvelope.split(data),
              let payloadData = try? JSONEncoder().encode(payload) else { return nil }
        let decoder = JSONDecoder()
        switch cmd {
        case "scan":
            // A client's own scan request (looped back by multicast) has only account_topic.
            guard payload["device"] != nil,
                  let scan = try? decoder.decode(GoveeScanResponse.self, from: payloadData) else { return nil }
            return .scan(scan)
        case "devStatus":
            guard case .object(let o) = payload, !o.isEmpty,
                  let status = try? decoder.decode(GoveeDevStatus.self, from: payloadData) else { return nil }
            return .devStatus(status)
        default:
            return nil
        }
    }

    /// Encodes a response (used by the fake device in tests).
    public func encoded() -> Data {
        let encoder = GoveeJSONCoding.encoder()
        let (cmd, data): (String, Data?) = switch self {
        case .scan(let s): ("scan", try? encoder.encode(s))
        case .devStatus(let s): ("devStatus", try? encoder.encode(s))
        }
        guard let data, let payload = try? JSONDecoder().decode(GoveeJSONValue.self, from: data) else { return Data() }
        let envelope: GoveeJSONValue = .object(["msg": .object(["cmd": .string(cmd), "data": payload])])
        return (try? encoder.encode(envelope)) ?? Data()
    }
}

enum GoveeLANEnvelope {
    /// `{"msg":{"cmd":..., "data":...}}` -> (cmd, data). Missing `data` becomes `{}`.
    static func split(_ data: Data) -> (String, GoveeJSONValue)? {
        guard data.first == UInt8(ascii: "{") || data.contains(UInt8(ascii: "{")),
              let root = try? JSONDecoder().decode(GoveeJSONValue.self, from: data),
              let msg = root["msg"],
              let cmd = msg["cmd"]?.stringValue else { return nil }
        return (cmd, msg["data"] ?? .object([:]))
    }
}
