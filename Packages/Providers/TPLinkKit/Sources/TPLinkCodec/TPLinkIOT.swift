import Foundation

/// IOT protocol (legacy Kasa, and Kasa KLAP firmware): `{"<target>":{"<command>":{args}}}`.
/// Answers mirror the request: `{"<target>":{"<command>":{...,"err_code":0}}}`.
public enum TPLinkIOT {
    public static let systemTarget = "system"
    /// Bulbs (KL1xx, LB1xx).
    public static let bulbService = "smartlife.iot.smartbulb.lightingservice"
    /// Light strips (KL400/KL420/KL430).
    public static let stripService = "smartlife.iot.lightStrip"
    public static let bulbSetCommand = "transition_light_state"
    public static let stripSetCommand = "set_light_state"

    public static func request(target: String, command: String, args: TPLinkJSON = .emptyObject) -> TPLinkJSON {
        .object([target: .object([command: args])])
    }

    /// `{"system":{"get_sysinfo":{}}}` (also the UDP 9999 discovery query).
    public static var getSysinfo: TPLinkJSON { request(target: systemTarget, command: "get_sysinfo") }

    /// Light state change for a bulb (`transition_light_state`) or strip (`set_light_state`).
    public static func setLightState(_ state: TPLinkIOTLightPatch, strip: Bool) -> TPLinkJSON {
        request(target: strip ? stripService : bulbService, command: strip ? stripSetCommand : bulbSetCommand, args: state.json)
    }

    /// Unwraps `response[target][command]`, checking `err_code` at both levels.
    public static func result(of response: TPLinkJSON, target: String, command: String) throws -> TPLinkJSON {
        guard let t = response[target] else { throw TPLinkCodecError.missingField(target) }
        if let code = t["err_code"]?.intValue, code != 0 {
            throw TPLinkCodecError.iotError(target: target, command: command, code: code, message: t["err_msg"]?.stringValue)
        }
        guard let r = t[command] else { throw TPLinkCodecError.missingField("\(target).\(command)") }
        if let code = r["err_code"]?.intValue, code != 0 {
            throw TPLinkCodecError.iotError(target: target, command: command, code: code, message: r["err_msg"]?.stringValue)
        }
        return r
    }
}

/// Parameters of `transition_light_state` / `set_light_state`. Unset fields are omitted.
public struct TPLinkIOTLightPatch: Sendable, Hashable {
    public var onOff: Bool?
    /// 1...100 (0 is rejected by the bulbs; turn off instead).
    public var brightness: Int?
    /// 0...360.
    public var hue: Int?
    /// 0...100.
    public var saturation: Int?
    /// Kelvin; 0 selects hue/saturation.
    public var colorTemp: Int?
    /// Milliseconds.
    public var transitionPeriod: Int?

    public init(onOff: Bool? = nil, brightness: Int? = nil, hue: Int? = nil, saturation: Int? = nil,
                colorTemp: Int? = nil, transitionPeriod: Int? = nil) {
        self.onOff = onOff
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.colorTemp = colorTemp
        self.transitionPeriod = transitionPeriod
    }

    public var isEmpty: Bool { onOff == nil && brightness == nil && hue == nil && saturation == nil && colorTemp == nil }

    /// JSON args. Like python-kasa: `on_off` defaults to 1, and `ignore_default` is 0 only when
    /// turning on without colour/brightness (the bulb restores its last state), else 1 so the
    /// given values win over the bulb's default-on state.
    public var json: TPLinkJSON {
        var m: [String: TPLinkJSON] = [:]
        let on = onOff ?? true
        m["on_off"] = .int(on ? 1 : 0)
        if let brightness { m["brightness"] = .int(Int64(brightness)) }
        if let hue { m["hue"] = .int(Int64(hue)) }
        if let saturation { m["saturation"] = .int(Int64(saturation)) }
        if let colorTemp { m["color_temp"] = .int(Int64(colorTemp)) }
        if let transitionPeriod { m["transition_period"] = .int(Int64(transitionPeriod)) }
        let onlyPower = brightness == nil && hue == nil && saturation == nil && colorTemp == nil
        m["ignore_default"] = .int(on && onlyPower ? 0 : 1)
        return .object(m)
    }
}

/// Kasa `light_state`: when off, the colour fields live in `dft_on_state`.
public struct TPLinkIOTLightState: Sendable, Hashable {
    public var isOn: Bool
    public var brightness: Int?
    public var hue: Int?
    public var saturation: Int?
    public var colorTemp: Int?
    public var mode: String?

    public init(isOn: Bool, brightness: Int? = nil, hue: Int? = nil, saturation: Int? = nil, colorTemp: Int? = nil, mode: String? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.colorTemp = colorTemp
        self.mode = mode
    }

    public init(_ json: TPLinkJSON) throws {
        guard let on = json["on_off"]?.boolValue else { throw TPLinkCodecError.missingField("light_state.on_off") }
        isOn = on
        let source = on ? json : (json["dft_on_state"] ?? json)
        brightness = source["brightness"]?.intValue
        hue = source["hue"]?.intValue
        saturation = source["saturation"]?.intValue
        colorTemp = source["color_temp"]?.intValue
        mode = source["mode"]?.stringValue
    }
}

/// The parts of IOT `system.get_sysinfo` used for lights.
public struct TPLinkIOTSysInfo: Sendable, Hashable {
    public var deviceID: String?
    /// `mic_mac` (bulbs, `1C3BF3001122` or `E8:48:B8:00:11:22`) or `mac` (plugs).
    public var mac: String?
    /// e.g. `KL130(US)`.
    public var model: String?
    public var alias: String?
    /// `mic_type` or `type`, e.g. `IOT.SMARTBULB`.
    public var type: String?
    public var firmware: String?
    public var hardware: String?
    public var isColor: Bool
    public var isDimmable: Bool
    public var isVariableColorTemp: Bool
    /// Strips report their zone count.
    public var length: Int?
    /// Plugs/switches report `relay_state` instead of `light_state`.
    public var relayState: Bool?
    public var brightness: Int?
    public var lightState: TPLinkIOTLightState?
    /// KL4xx `lighting_effect_state.enable`.
    public var effectActive: Bool
    public var effectName: String?

    public init(_ json: TPLinkJSON) throws {
        guard json.objectValue != nil else { throw TPLinkCodecError.missingField("get_sysinfo") }
        deviceID = json["deviceId"]?.stringValue
        mac = json["mic_mac"]?.stringValue ?? json["mac"]?.stringValue ?? json["ethernet_mac"]?.stringValue
        model = json["model"]?.stringValue
        alias = json["alias"]?.stringValue
        type = json["mic_type"]?.stringValue ?? json["type"]?.stringValue
        firmware = json["sw_ver"]?.stringValue
        hardware = json["hw_ver"]?.stringValue
        isColor = json["is_color"]?.boolValue ?? false
        isDimmable = json["is_dimmable"]?.boolValue ?? (json["brightness"] != nil)
        isVariableColorTemp = json["is_variable_color_temp"]?.boolValue ?? false
        length = json["length"]?.intValue
        relayState = json["relay_state"]?.boolValue
        brightness = json["brightness"]?.intValue
        lightState = try json["light_state"].map { try TPLinkIOTLightState($0) }
        let effect = json["lighting_effect_state"]
        effectActive = effect?["enable"]?.boolValue ?? false
        effectName = effectActive ? effect?["name"]?.stringValue : nil
    }

    /// Light strip (KL400/KL420/KL430): uses `smartlife.iot.lightStrip`.
    public var isStrip: Bool {
        length != nil || (model.map { TPLinkModelTable.normalizedModel($0).hasPrefix("KL4") } ?? false)
    }

    public var isBulb: Bool { type == "IOT.SMARTBULB" || lightState != nil }
}
