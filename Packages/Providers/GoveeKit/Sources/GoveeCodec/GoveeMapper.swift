import Foundation
import LightCore

/// Maps Govee LAN/cloud data to the LightCore model and `LightCommand`s to Govee messages.
public enum GoveeMapper {

    // MARK: Colour packing

    /// Developer API colour integer: `r << 16 | g << 8 | b` (0...16777215).
    public static func packRGB(_ rgb: RGB) -> Int {
        Int(rgb.r) << 16 | Int(rgb.g) << 8 | Int(rgb.b)
    }

    /// Inverse of `packRGB`; values outside 0...0xFFFFFF are masked.
    public static func unpackRGB(_ value: Int) -> RGB {
        let v = value & 0xFFFFFF
        return RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    // MARK: Brightness

    /// `0...1` -> Govee percent `1...100` (LAN `brightness.value`, cloud `range/brightness`).
    public static func percent(fromBrightness brightness: Double, range: ClosedRange<Int> = GoveeLAN.brightnessRange) -> Int {
        ColorMath.deviceValue(forBrightness: brightness, in: range)
    }

    /// Govee percent -> `0...1`; values <= 0 give 0.
    public static func brightness(fromPercent value: Int, range: ClosedRange<Int> = GoveeLAN.brightnessRange) -> Double {
        value <= 0 ? 0 : ColorMath.brightness(fromDeviceValue: value, in: range)
    }

    // MARK: Capabilities

    /// Capabilities of a LAN model.
    public static func capabilities(for model: GoveeLANModel) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        if model.rgb { modes.insert(.rgb) }
        if model.colorTemperature { modes.insert(.colorTemp) }
        if modes.isEmpty { modes.insert(model.brightness ? .brightness : .onOff) }
        return LightCapabilities(
            supportedColorModes: modes,
            minKelvin: model.colorTemperature ? model.kelvinRange.lowerBound : nil,
            maxKelvin: model.colorTemperature ? model.kelvinRange.upperBound : nil
        )
    }

    /// Capabilities from a cloud device's capability list.
    public static func capabilities(for device: GoveeCloudDevice) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        var minK: Int?
        var maxK: Int?
        if device.capability(GoveeCapabilityType.colorSetting, GoveeCapabilityInstance.colorRgb) != nil {
            modes.insert(.rgb)
        }
        if let ct = device.capability(GoveeCapabilityType.colorSetting, GoveeCapabilityInstance.colorTemperatureK) {
            modes.insert(.colorTemp)
            let range = ct.parameters?.range?.closedRange ?? GoveeLAN.defaultKelvinRange
            minK = range.lowerBound
            maxK = range.upperBound
        }
        if modes.isEmpty {
            let dimmable = device.capability(GoveeCapabilityType.range, GoveeCapabilityInstance.brightness) != nil
            modes.insert(dimmable ? .brightness : .onOff)
        }
        return LightCapabilities(supportedColorModes: modes, minKelvin: minK, maxKelvin: maxK, effects: effects(for: device))
    }

    /// Brightness range a cloud device declares (default 1...100).
    public static func brightnessRange(for device: GoveeCloudDevice) -> ClosedRange<Int> {
        guard let r = device.capability(GoveeCapabilityType.range, GoveeCapabilityInstance.brightness)?.parameters?.range,
              r.max > r.min else { return GoveeLAN.brightnessRange }
        return max(1, r.min)...r.max
    }

    /// `dynamic_scene` options (snapshots, DIY scenes, light scenes when listed) as effects.
    /// Effect id: `"<instance>/<option name>"`.
    public static func effects(for device: GoveeCloudDevice) -> [EffectDescriptor] {
        var out: [EffectDescriptor] = []
        var seen: Set<String> = []
        for cap in device.capabilities(ofType: GoveeCapabilityType.dynamicScene) {
            for option in cap.parameters?.options ?? [] where !option.name.isEmpty {
                let id = effectID(instance: cap.instance, name: option.name)
                guard seen.insert(id).inserted else { continue }
                out.append(EffectDescriptor(id: id, name: option.name))
            }
        }
        return out
    }

    public static func effectID(instance: String, name: String) -> String { "\(instance)/\(name)" }

    /// The `dynamic_scene` command for an effect id produced by `effects(for:)`.
    public static func effectCommand(_ effectID: String, device: GoveeCloudDevice) -> GoveeCapabilityCommand? {
        for cap in device.capabilities(ofType: GoveeCapabilityType.dynamicScene) {
            for option in cap.parameters?.options ?? [] where effectID == self.effectID(instance: cap.instance, name: option.name) {
                return GoveeCapabilityCommand(type: cap.type, instance: cap.instance, value: option.value)
            }
        }
        return nil
    }

    // MARK: State

    /// LAN `devStatus` -> state. `colorTemInKelvin > 0` means white mode, otherwise RGB.
    public static func state(from status: GoveeDevStatus, capabilities: LightCapabilities? = nil, at date: Date = Date()) -> LightState {
        var state = LightState(isOn: status.isOn, reachable: true, updatedAt: date)
        let modes = capabilities?.supportedColorModes
        if modes == nil || capabilities?.supportsBrightness == true {
            state.brightness = brightness(fromPercent: status.brightness)
        }
        if status.colorTemInKelvin > 0, modes?.contains(.colorTemp) ?? true {
            state.colorMode = .colorTemp
            state.kelvin = status.colorTemInKelvin
        } else if modes?.contains(.rgb) ?? true, !status.color.isBlack {
            state.colorMode = .rgb
            state.rgb = status.color.rgb
        } else if let modes {
            state.colorMode = modes.contains(.brightness) ? .brightness : (modes.contains(.onOff) ? .onOff : nil)
        }
        return state
    }

    /// Cloud `device/state` capabilities -> state. Instances that are missing or empty keep the
    /// value from `previous`.
    public static func state(fromCloud states: [GoveeCapabilityState], device: GoveeCloudDevice? = nil,
                             previous: LightState? = nil, at date: Date = Date()) -> LightState {
        var state = previous ?? LightState()
        state.updatedAt = date
        state.reachable = true
        func value(_ type: String, _ instance: String) -> GoveeJSONValue? {
            guard let v = states.first(where: { $0.type == type && $0.instance == instance })?.value, !v.isEmpty else { return nil }
            return v
        }
        if let online = value(GoveeCapabilityType.online, GoveeCapabilityInstance.online)?.boolValue {
            state.reachable = online
        }
        if let power = value(GoveeCapabilityType.onOff, GoveeCapabilityInstance.powerSwitch)?.intValue {
            state.isOn = power != 0
        }
        if let b = value(GoveeCapabilityType.range, GoveeCapabilityInstance.brightness)?.intValue {
            let range = device.map(brightnessRange(for:)) ?? GoveeLAN.brightnessRange
            state.brightness = brightness(fromPercent: b, range: range)
        }
        let kelvin = value(GoveeCapabilityType.colorSetting, GoveeCapabilityInstance.colorTemperatureK)?.intValue ?? 0
        let rgb = value(GoveeCapabilityType.colorSetting, GoveeCapabilityInstance.colorRgb)?.intValue
        if kelvin > 0 {
            state.colorMode = .colorTemp
            state.kelvin = kelvin
            state.rgb = nil
        } else if let rgb {
            state.colorMode = .rgb
            state.rgb = unpackRGB(rgb)
            state.kelvin = nil
        }
        return state
    }

    // MARK: Commands

    /// LAN messages for `command`, in send order (power on, brightness, colour). Turning off
    /// sends only `turn 0`; brightness 0 turns off. Effects are not available over LAN and are
    /// dropped. `isOn` is the light's current power state if known: a brightness change on a
    /// light that is off also turns it on (matches `LightState.applying`).
    public static func lanCommands(for command: LightCommand, capabilities: LightCapabilities, isOn: Bool? = nil) -> [GoveeLANCommand] {
        let c = command.normalized(for: capabilities)
        if c.on == false { return [.turn(false)] }
        if let b = c.brightness, b <= 0, c.on != true { return [.turn(false)] }
        var out: [GoveeLANCommand] = []
        if c.on == true || (c.brightness != nil && isOn == false) { out.append(.turn(true)) }
        if let b = c.brightness, b > 0 { out.append(.brightness(percent(fromBrightness: b))) }
        switch c.color {
        case .rgb(let rgb)?: out.append(.color(rgb))
        case .kelvin(let k)?: out.append(.colorTemperature(capabilities.clampKelvin(k)))
        default: break
        }
        return out
    }

    /// Developer API capability commands for `command` (one HTTP request each), same order and
    /// power rules as `lanCommands`. Effects map to the device's `dynamic_scene` options.
    public static func cloudCommands(for command: LightCommand, device: GoveeCloudDevice, isOn: Bool? = nil) -> [GoveeCapabilityCommand] {
        let caps = capabilities(for: device)
        let c = command.normalized(for: caps)
        if c.on == false { return [.power(false)] }
        if let b = c.brightness, b <= 0, c.on != true { return [.power(false)] }
        var out: [GoveeCapabilityCommand] = []
        if c.on == true || (c.brightness != nil && isOn == false) { out.append(.power(true)) }
        if let b = c.brightness, b > 0 { out.append(.brightness(percent(fromBrightness: b, range: brightnessRange(for: device)))) }
        switch c.color {
        case .rgb(let rgb)?: out.append(.colorRGB(packRGB(rgb)))
        case .kelvin(let k)?: out.append(.colorTemperature(caps.clampKelvin(k)))
        default: break
        }
        if let effect = c.effect, let cmd = effectCommand(effect, device: device) { out.append(cmd) }
        return out
    }

    // MARK: Lights

    /// Display name: cloud `deviceName`, else "Govee <sku>".
    public static func displayName(sku: String, deviceName: String?) -> String {
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty { return deviceName }
        return sku.isEmpty ? "Govee light" : "Govee \(sku)"
    }
}
