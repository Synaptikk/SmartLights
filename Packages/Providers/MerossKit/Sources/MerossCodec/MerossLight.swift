import Foundation
import LightCore

/// `Appliance.Control.Light` `capacity` bits (meross_lan `LIGHT_CAPACITY_*`, MerossIot `LightMode`).
/// In the ability it lists what the lamp can do; in a state/SET payload it says which fields apply.
public struct MerossLightCapacity: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let rgb = MerossLightCapacity(rawValue: 1)
    public static let temperature = MerossLightCapacity(rawValue: 2)
    public static let luminance = MerossLightCapacity(rawValue: 4)
    /// msl320/msl450 effect mode (meross_lan: "not tested").
    public static let effect = MerossLightCapacity(rawValue: 8)
}

/// What a device supports, from `Appliance.System.Ability` (or a model-based guess before that).
public struct MerossDeviceProfile: Sendable, Hashable, Codable {
    /// `ability["Appliance.Control.Light"].capacity`; nil when the device has no light namespace.
    public var lightCapacity: MerossLightCapacity?
    public var hasToggleX: Bool
    public var hasToggle: Bool
    /// The device wants `Appliance.Encrypt.ECDHE` AES bodies.
    public var encrypted: Bool

    public init(lightCapacity: MerossLightCapacity?, hasToggleX: Bool, hasToggle: Bool, encrypted: Bool = false) {
        self.lightCapacity = lightCapacity
        self.hasToggleX = hasToggleX
        self.hasToggle = hasToggle
        self.encrypted = encrypted
    }

    /// Parses an `Appliance.System.Ability` GETACK payload (`{"ability": {...}}`) or the bare map.
    public init(ability payload: MerossJSON) {
        let map = payload["ability"]?.objectValue ?? payload.objectValue ?? [:]
        if let light = map[MerossNamespace.controlLight] {
            // meross_lan defaults a missing capacity to luminance.
            lightCapacity = MerossLightCapacity(rawValue: light["capacity"]?.intValue ?? MerossLightCapacity.luminance.rawValue)
        } else {
            lightCapacity = nil
        }
        hasToggleX = map[MerossNamespace.controlToggleX] != nil
        hasToggle = map[MerossNamespace.controlToggle] != nil
        encrypted = map[MerossNamespace.encryptECDHE] != nil
    }

    /// Light-capable devices are exposed as lights; others (plugs, sensors) are ignored.
    public var isLight: Bool { lightCapacity != nil }

    /// Best guess from the cloud `deviceType` before the device has been asked for its abilities.
    /// msl100: dimmable white; other msl* bulbs/strips: RGB + temperature; mss56x/57x dimmers: luminance.
    public static func guess(deviceType: String) -> MerossDeviceProfile? {
        let t = deviceType.lowercased()
        if t.hasPrefix("msl100") {
            return MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: true, hasToggle: false)
        }
        if t.hasPrefix("msl") || t.hasPrefix("mdl") {
            return MerossDeviceProfile(lightCapacity: [.rgb, .temperature, .luminance], hasToggleX: true, hasToggle: false)
        }
        if t.hasPrefix("mss56") || t.hasPrefix("mss57") {
            return MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: true, hasToggle: false)
        }
        return nil
    }

    /// HA colour modes (meross_lan `MLLight.__init__`).
    public var capabilities: LightCapabilities {
        let capacity = lightCapacity ?? []
        var modes: Set<ColorMode> = []
        if capacity.contains(.rgb) { modes.insert(.rgb) }
        if capacity.contains(.temperature) { modes.insert(.colorTemp) }
        if modes.isEmpty { modes.insert(capacity.contains(.luminance) ? .brightness : .onOff) }
        let temperature = capacity.contains(.temperature)
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: temperature ? MerossLightScale.kelvinMin : nil,
            maxKelvin: temperature ? MerossLightScale.kelvinMax : nil)
    }
}

/// Native scales (meross_lan `light.py`): luminance 1...100, temperature 1...100 mapped onto
/// 2700...6500 K (warm -> cool), rgb as a 24-bit integer.
public enum MerossLightScale {
    public static let kelvinMin = 2700
    public static let kelvinMax = 6500
    public static let nativeMin = 1
    public static let nativeMax = 100

    public static func kelvinToNative(_ kelvin: Int) -> Int {
        let scale = Double(nativeMax - nativeMin) / Double(kelvinMax - kelvinMin)
        let v = (Double(nativeMin) + Double(kelvin - kelvinMin) * scale).rounded(.toNearestOrEven) // Python round()
        return min(max(Int(v), nativeMin), nativeMax)
    }

    public static func nativeToKelvin(_ temperature: Int) -> Int {
        let scale = Double(nativeMax - nativeMin) / Double(kelvinMax - kelvinMin)
        let t = min(max(temperature, nativeMin), nativeMax)
        return Int((Double(kelvinMin) + Double(t - nativeMin) / scale).rounded(.toNearestOrEven))
    }

    /// `0...1` -> luminance `1...100` (0 is never sent; "off" goes through toggle).
    public static func luminance(fromBrightness b: Double) -> Int {
        guard b.isFinite else { return nativeMax }
        return min(max(Int((b * 100).rounded()), nativeMin), nativeMax)
    }

    public static func brightness(fromLuminance l: Int) -> Double {
        Double(min(max(l, 0), nativeMax)) / 100
    }

    public static func rgbInt(_ rgb: RGB) -> Int { (Int(rgb.r) << 16) | (Int(rgb.g) << 8) | Int(rgb.b) }

    public static func rgb(fromInt v: Int) -> RGB {
        RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
}

/// The `light` object of `Appliance.Control.Light` (state, push and SET).
public struct MerossLightPayload: Sendable, Hashable, Codable {
    public var channel: Int
    public var capacity: MerossLightCapacity?
    public var rgb: Int?
    public var temperature: Int?
    public var luminance: Int?
    /// Present on some firmware (msl120b) and on devices without toggle namespaces.
    public var onoff: Int?
    public var effect: Int?
    /// `gradual` in SET payloads (MerossIot sends 0).
    public var gradual: Int?

    public init(channel: Int = 0, capacity: MerossLightCapacity? = nil, rgb: Int? = nil, temperature: Int? = nil,
                luminance: Int? = nil, onoff: Int? = nil, effect: Int? = nil, gradual: Int? = nil) {
        self.channel = channel
        self.capacity = capacity
        self.rgb = rgb
        self.temperature = temperature
        self.luminance = luminance
        self.onoff = onoff
        self.effect = effect
        self.gradual = gradual
    }

    public init(json: MerossJSON) {
        channel = json["channel"]?.intValue ?? 0
        capacity = json["capacity"]?.intValue.map(MerossLightCapacity.init(rawValue:))
        rgb = json["rgb"]?.intValue
        temperature = json["temperature"]?.intValue
        luminance = json["luminance"]?.intValue
        onoff = json["onoff"]?.intValue
        effect = json["effect"]?.intValue
        gradual = json["gradual"]?.intValue
    }

    public var json: MerossJSON {
        var o: [String: MerossJSON] = ["channel": .int(channel)]
        if let capacity { o["capacity"] = .int(capacity.rawValue) }
        if let rgb { o["rgb"] = .int(rgb) }
        if let temperature { o["temperature"] = .int(temperature) }
        if let luminance { o["luminance"] = .int(luminance) }
        if let onoff { o["onoff"] = .int(onoff) }
        if let effect { o["effect"] = .int(effect) }
        if let gradual { o["gradual"] = .int(gradual) }
        return .object(o)
    }
}

/// Device-side light model: what the provider knows about one Meross light (channel 0).
public struct MerossLightModel: Sendable, Hashable {
    public var profile: MerossDeviceProfile
    public var isOn = false
    public var light = MerossLightPayload()
    /// Colour mode last reported/commanded (state payloads carry both rgb and temperature).
    public var colorMode: ColorMode?

    public init(profile: MerossDeviceProfile) {
        self.profile = profile
    }

    /// Applies an `Appliance.System.All` GETACK payload. Returns the device facts found
    /// (`hardware.type`, `uuid`, `macAddress`, `firmware.version`, `firmware.innerIp`).
    @discardableResult
    public mutating func apply(all payload: MerossJSON) -> MerossSystemInfo {
        let all = payload["all"] ?? payload
        let digest = all["digest"]
        if let light = digest?["light"] { apply(light: light) }
        if let togglex = digest?["togglex"] { apply(togglex: togglex) }
        if let toggle = all["control"]?["toggle"] ?? digest?["toggle"], let on = toggle["onoff"]?.intValue {
            isOn = on != 0
        }
        return MerossSystemInfo(all: payload)
    }

    /// Applies an `Appliance.Control.Light` object (GETACK, PUSH, or our own SET).
    public mutating func apply(light json: MerossJSON) {
        let incoming = MerossLightPayload(json: json)
        guard incoming.channel == 0 else { return }
        if let v = incoming.rgb { light.rgb = v }
        if let v = incoming.temperature { light.temperature = v }
        if let v = incoming.luminance { light.luminance = v }
        if let v = incoming.effect { light.effect = v }
        if let capacity = incoming.capacity {
            light.capacity = capacity
            if capacity.contains(.rgb) {
                colorMode = .rgb
            } else if capacity.contains(.temperature) {
                colorMode = .colorTemp
            }
        }
        // Devices with toggle namespaces report power there; the light "onoff" is only
        // authoritative without them (meross_lan #218 discussion).
        if let on = incoming.onoff, !(profile.hasToggleX || profile.hasToggle) { isOn = on != 0 }
    }

    /// Applies a `togglex` value: an object or an array of per-channel objects.
    public mutating func apply(togglex json: MerossJSON) {
        let entries = json.arrayValue ?? [json]
        for entry in entries where (entry["channel"]?.intValue ?? 0) == 0 {
            if let on = entry["onoff"]?.intValue { isOn = on != 0 }
        }
    }

    /// Applies any namespace payload (PUSH or GETACK) the provider receives.
    public mutating func apply(namespace: String, payload: MerossJSON) {
        switch namespace {
        case MerossNamespace.systemAll: apply(all: payload)
        case MerossNamespace.controlLight: if let l = payload["light"] { apply(light: l) }
        case MerossNamespace.controlToggleX: if let t = payload["togglex"] { apply(togglex: t) }
        case MerossNamespace.controlToggle:
            if let on = payload["toggle"]?["onoff"]?.intValue { isOn = on != 0 }
        default: break
        }
    }

    public func lightState(reachable: Bool, at date: Date = Date()) -> LightState {
        let capabilities = profile.capabilities
        var state = LightState(isOn: isOn, reachable: reachable, updatedAt: date)
        if capabilities.supportsBrightness, let l = light.luminance {
            state.brightness = MerossLightScale.brightness(fromLuminance: l)
        }
        let mode = colorMode.flatMap { capabilities.supportedColorModes.contains($0) ? $0 : nil }
            ?? (capabilities.supportedColorModes.contains(.colorTemp) ? .colorTemp
                : capabilities.supportedColorModes.contains(.rgb) ? .rgb
                : capabilities.supportsBrightness ? .brightness : .onOff)
        state.colorMode = mode
        if capabilities.supportedColorModes.contains(.rgb), let v = light.rgb {
            state.rgb = MerossLightScale.rgb(fromInt: v)
        }
        if capabilities.supportsColorTemp, let t = light.temperature {
            state.kelvin = MerossLightScale.nativeToKelvin(t)
        }
        return state
    }

    /// Records a request we sent successfully (optimistic update).
    public mutating func applySent(_ request: MerossRequest) {
        apply(namespace: request.namespace, payload: request.payload)
        if request.namespace == MerossNamespace.controlLight, request.payload["light"]?["luminance"] != nil,
           !(profile.hasToggleX || profile.hasToggle) {
            isOn = true
        }
    }
}

/// Facts from `Appliance.System.All`.
public struct MerossSystemInfo: Sendable, Hashable {
    public var type: String?
    public var uuid: String?
    public var macAddress: String?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    /// The device's own idea of its LAN IP.
    public var innerIp: String?
    /// `system.online.status` (1 = online to the cloud).
    public var onlineStatus: Int?

    public init(all payload: MerossJSON) {
        let system = (payload["all"] ?? payload)["system"]
        type = system?["hardware"]?["type"]?.stringValue
        uuid = system?["hardware"]?["uuid"]?.stringValue
        macAddress = system?["hardware"]?["macAddress"]?.stringValue
        hardwareVersion = system?["hardware"]?["version"]?.stringValue
        firmwareVersion = system?["firmware"]?["version"]?.stringValue
        innerIp = system?["firmware"]?["innerIp"]?.stringValue
        onlineStatus = system?["online"]?["status"]?.intValue
    }

    /// `aa:bb:cc:dd:ee:ff` from the last 12 characters of the uuid (meross_lan `get_macaddress_from_uuid`).
    public static func macAddress(fromUUID uuid: String) -> String {
        let tail = Array(uuid.suffix(12).lowercased())
        return stride(from: 0, to: tail.count, by: 2).map { String(tail[$0..<min($0 + 2, tail.count)]) }.joined(separator: ":")
    }
}

/// `LightCommand` -> ordered Meross requests (meross_lan `MLLight.async_turn_on/off`).
public enum MerossCommandPlanner {
    /// - off (or brightness 0): one toggle (ToggleX, else Toggle, else `light.onoff = 0`);
    /// - colour and/or brightness: one `Appliance.Control.Light` SET carrying luminance and the colour
    ///   with the matching capacity bits (5 = rgb+lum, 6 = temp+lum, 4 = lum); devices without toggle
    ///   namespaces also get `onoff: 1`; devices with ToggleX that are off get a ToggleX on afterwards
    ///   (some firmware, e.g. msl120j, ignores `onoff` in the light payload);
    /// - on only: one toggle.
    /// Effects are not supported (empty result if nothing else is requested).
    public static func requests(for command: LightCommand, model: MerossLightModel) -> [MerossRequest] {
        let profile = model.profile
        let normalized = command.normalized(for: profile.capabilities)
        let wantsOff = normalized.on == false || (normalized.brightness.map { $0 <= 0 } ?? false)
        if wantsOff { return [power(false, profile: profile)] }

        var light = MerossLightPayload(channel: 0, gradual: 0)
        var capacity: MerossLightCapacity = []
        if let b = normalized.brightness, profile.capabilities.supportsBrightness {
            light.luminance = MerossLightScale.luminance(fromBrightness: b)
        }
        switch normalized.color {
        case .rgb(let rgb)?:
            light.rgb = MerossLightScale.rgbInt(rgb)
            capacity.insert(.rgb)
        case .kelvin(let k)?:
            light.temperature = MerossLightScale.kelvinToNative(k)
            capacity.insert(.temperature)
        default:
            break
        }
        let changesLight = light.luminance != nil || !capacity.isEmpty
        guard changesLight else {
            return normalized.on == true ? [power(true, profile: profile)] : []
        }
        if profile.lightCapacity?.contains(.luminance) == true {
            // meross_lan always sends a luminance (current, or 100 if unknown/0).
            if light.luminance == nil { light.luminance = (model.light.luminance ?? 0) > 0 ? model.light.luminance : MerossLightScale.nativeMax }
            capacity.insert(.luminance)
        }
        light.capacity = capacity
        let hasToggles = profile.hasToggleX || profile.hasToggle
        if !hasToggles { light.onoff = 1 }
        var out = [MerossRequest.setLight(light)]
        if hasToggles, !model.isOn || normalized.on == true {
            out.append(power(true, profile: profile))
        }
        return out
    }

    public static func power(_ on: Bool, profile: MerossDeviceProfile) -> MerossRequest {
        if profile.hasToggleX { return .toggleX(on: on) }
        if profile.hasToggle { return .toggle(on: on) }
        return .setLight(MerossLightPayload(channel: 0, onoff: on ? 1 : 0))
    }
}
