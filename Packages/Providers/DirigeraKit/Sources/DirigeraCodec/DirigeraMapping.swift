import Foundation
import LightCore

/// Pure mapping between hub devices and the LightCore model.
public enum DirigeraMapping {
    /// Bounds in Kelvin, low...high. Values below 1000 are mireds (some bulbs, e.g. KAJPLATS,
    /// report mired bounds while `colorTemperature` itself is Kelvin; Leggin/dirigera `_bound_to_kelvin`).
    public static func kelvinRange(_ a: DirigeraLightAttributes) -> ClosedRange<Int>? {
        guard let lo = a.colorTemperatureMin.map(toKelvin), let hi = a.colorTemperatureMax.map(toKelvin), lo > 0, hi > 0 else {
            return nil
        }
        return min(lo, hi)...max(lo, hi)
    }

    static func toKelvin(_ bound: Int) -> Int {
        (0 < bound && bound < 1000) ? Int((1_000_000 / Double(bound)).rounded()) : bound
    }

    /// From `capabilities.canReceive`: `colorHue`+`colorSaturation` -> `.hs`, `colorTemperature`
    /// -> `.colorTemp`, otherwise `lightLevel` -> `.brightness`, otherwise `.onOff`.
    public static func capabilities(_ device: DirigeraDevice) -> LightCapabilities {
        let receive = device.canReceive
        var modes: Set<ColorMode> = []
        if receive.contains("colorHue"), receive.contains("colorSaturation") { modes.insert(.hs) }
        if receive.contains("colorTemperature") { modes.insert(.colorTemp) }
        if modes.isEmpty { modes = receive.contains("lightLevel") ? [.brightness] : [.onOff] }
        let range = modes.contains(.colorTemp) ? kelvinRange(device.attributes) : nil
        return LightCapabilities(supportedColorModes: modes, minKelvin: range?.lowerBound, maxKelvin: range?.upperBound)
    }

    public static func state(_ device: DirigeraDevice, at date: Date = Date()) -> LightState {
        let a = device.attributes
        let caps = capabilities(device)
        var state = LightState(isOn: a.isOn ?? false, reachable: device.isReachable, updatedAt: date)
        if caps.supportsBrightness, let level = a.lightLevel { state.brightness = Double(min(max(level, 0), 100)) / 100 }
        let hs: HS? = (a.colorHue).flatMap { h in a.colorSaturation.map { HS(h: h, s: $0).clamped } }
        let wantsColor = a.colorMode == "color" || (a.colorMode == nil && !caps.supportsColorTemp)
        if caps.supportsColor, let hs, wantsColor {
            state.colorMode = .hs
            state.hs = hs
            state.rgb = ColorMath.hsToRGB(hs)
        } else if caps.supportsColorTemp, let k = a.colorTemperature, k > 0 {
            state.colorMode = .colorTemp
            state.kelvin = k
        }
        return state
    }

    /// Light for a hub device (`roomHint` = room name, `providerRef` = `<hubID>/<deviceID>`).
    public static func light(_ device: DirigeraDevice, hubID: String, at date: Date = Date()) -> Light? {
        guard let id = DirigeraIdentifiers.lightID(hubID: hubID, deviceID: device.id) else { return nil }
        return Light(
            id: id, name: device.attributes.customName ?? device.attributes.model ?? "IKEA light", roomHint: device.room?.name,
            capabilities: capabilities(device), state: state(device, at: date), providerRef: "\(hubID)/\(device.id)",
            manufacturer: device.attributes.manufacturer, model: device.attributes.model)
    }

    /// Attribute objects to PATCH, in order.
    ///
    /// - Off (`on == false`, or `brightness == 0` without `on`): `{isOn: false}` only.
    /// - Otherwise `isOn: true` when asked or implied (brightness/colour on an off light),
    ///   `lightLevel` 1...100, and `colorTemperature` (Kelvin) or `colorHue`+`colorSaturation`.
    /// - `split == false`: one object with everything (one request, no flash);
    ///   `split == true`: one object per attribute group like Leggin/dirigera's setters
    ///   (`isOn`, `lightLevel`, `colorTemperature`, `colorHue`+`colorSaturation`).
    ///   Attributes the device does not list in `canReceive` are never sent.
    public static func plan(_ command: LightCommand, device: DirigeraDevice, split: Bool) -> [[String: DirigeraJSON]] {
        let caps = capabilities(device)
        let cmd = command.normalized(for: caps)
        let receive = device.canReceive
        let isOn = device.attributes.isOn ?? false
        if cmd.on == false || (cmd.on == nil && cmd.brightness == 0) {
            return receive.contains("isOn") ? [["isOn": false]] : []
        }
        var groups: [[String: DirigeraJSON]] = []
        let changesSomething = cmd.brightness != nil || cmd.color != nil
        if receive.contains("isOn"), cmd.on == true || (!isOn && changesSomething) {
            groups.append(["isOn": true])
        }
        if let b = cmd.brightness, receive.contains("lightLevel") {
            groups.append(["lightLevel": .number(Double(min(max(Int((b * 100).rounded()), 1), 100)))])
        }
        switch cmd.color {
        case .kelvin(let k) where receive.contains("colorTemperature"):
            groups.append(["colorTemperature": .number(Double(k))])
        case .hs(let hs) where receive.contains("colorHue") && receive.contains("colorSaturation"):
            let c = hs.clamped
            groups.append(["colorHue": .number((c.h * 10).rounded() / 10), "colorSaturation": .number((c.s * 1000).rounded() / 1000)])
        default:
            break
        }
        if split || groups.count <= 1 { return groups }
        return [groups.reduce(into: [:]) { $0.merge($1) { _, b in b } }]
    }
}
