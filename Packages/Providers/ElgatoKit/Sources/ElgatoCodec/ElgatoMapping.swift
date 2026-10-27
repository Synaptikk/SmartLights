import Foundation
import LightCore

/// Pure mapping between Elgato wire values and the SmartLights domain model (`LightCore`).
public enum ElgatoMapping {
    /// Colour temperature range on the wire (mireds), per python-elgato / HA.
    public static let miredRange = 143...344
    /// Brightness range on the wire. `0` is never sent: "off" uses `on: 0`.
    public static let brightnessRange = 1...100

    /// Kelvin equivalent of `miredRange`: 2907...6993 K.
    public static var kelvinRange: ClosedRange<Int> { kelvin(fromMireds: miredRange.upperBound)...kelvin(fromMireds: miredRange.lowerBound) }

    /// Mireds -> Kelvin, rounded (297 -> 3367). Round-trips exactly with `mireds(fromKelvin:)`
    /// because one mired step is more than 8 K in this range.
    public static func kelvin(fromMireds mireds: Int) -> Int {
        guard mireds > 0 else { return 0 }
        return Int((1_000_000 / Double(mireds)).rounded())
    }

    /// Kelvin -> mireds, rounded and clamped into `miredRange` (3367 -> 297, 2000 -> 344).
    public static func mireds(fromKelvin kelvin: Int) -> Int {
        guard kelvin > 0 else { return miredRange.upperBound }
        let m = Int((1_000_000 / Double(kelvin)).rounded())
        return min(max(m, miredRange.lowerBound), miredRange.upperBound)
    }

    // MARK: Identity

    /// `"elgato:<serial number>"`. Whitespace is stripped (LightID forbids it).
    public static func lightID(serial: String) -> LightID? {
        LightID(brand: .elgato, stableId: stableID(serial: serial))
    }

    /// Serial number as used in `LightID`/`PairedDevice.id`.
    public static func stableID(serial: String) -> String {
        String(serial.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    // MARK: Capabilities

    /// Whether the accessory has colour (Light Strip). Any of: the state reports a hue, the
    /// settings carry `powerOnHue` (what HA checks), or the product is a Light Strip.
    public static func supportsColor(info: ElgatoAccessoryInfo?, settings: ElgatoSettings?, state: ElgatoLightState?) -> Bool {
        if state?.hue != nil || settings?.powerOnHue != nil { return true }
        return info?.productName.localizedCaseInsensitiveContains("light strip") ?? false
    }

    /// Key Light family -> `[.colorTemp]`; Light Strip -> `[.colorTemp, .hs]`. No transitions
    /// (fade times are device settings, not per command) and no effects.
    public static func capabilities(supportsColor: Bool) -> LightCapabilities {
        LightCapabilities(
            supportedColorModes: supportsColor ? [.colorTemp, .hs] : [.colorTemp],
            minKelvin: kelvinRange.lowerBound,
            maxKelvin: kelvinRange.upperBound
        )
    }

    // MARK: State

    /// Domain state from one light entry. A reported hue means colour mode (Light Strip);
    /// otherwise the temperature is authoritative.
    public static func state(from light: ElgatoLightState, supportsColor: Bool, at date: Date = Date()) -> LightState {
        var s = LightState(isOn: light.isOn, reachable: true, updatedAt: date)
        if let b = light.brightness {
            s.brightness = ColorMath.brightness(fromDeviceValue: b, in: brightnessRange)
        }
        if supportsColor, let hue = light.hue {
            let hs = HS(h: hue, s: (light.saturation ?? 100) / 100).clamped
            s.colorMode = .hs
            s.hs = hs
            s.rgb = ColorMath.hsToRGB(hs)
        } else if let t = light.temperature {
            s.colorMode = .colorTemp
            s.kelvin = kelvin(fromMireds: min(max(t, miredRange.lowerBound), miredRange.upperBound))
        } else {
            s.colorMode = .brightness
        }
        return s
    }

    // MARK: Commands

    /// The partial light entry to `PUT` for `command`, or nil if nothing would change.
    ///
    /// - The command is normalised for the light (`LightCommand.normalized(for:)`): RGB/xy become
    ///   hue/saturation on a Light Strip, any colour becomes a temperature on a Key Light.
    /// - Brightness and colour go in one `PUT` (no flash).
    /// - `brightness == 0` without `on` switches off and keeps the stored brightness;
    ///   `brightness > 0` without `on` on an off light switches it on.
    /// - Effects and transitions are not supported and are dropped.
    public static func plan(_ command: LightCommand, current: ElgatoLightState?, supportsColor: Bool) -> ElgatoLightState? {
        let cmd = command.normalized(for: capabilities(supportsColor: supportsColor))
        let isOn = current?.isOn ?? false
        var out = ElgatoLightState()

        var power = cmd.on
        var brightness = cmd.brightness
        if let b = brightness, b <= 0 {
            brightness = nil
            if power == nil { power = false }
        }
        if brightness != nil, power == nil, !isOn { power = true }
        if let power { out.on = power ? 1 : 0 }
        if let b = brightness { out.brightness = ColorMath.deviceValue(forBrightness: b, in: brightnessRange) }

        switch cmd.color {
        case .kelvin(let k):
            out.temperature = mireds(fromKelvin: k)
        case .hs(let hs):
            let c = hs.clamped
            out.hue = (c.h * 10).rounded() / 10
            out.saturation = (c.s * 1000).rounded() / 10
        default:
            break
        }
        return out.isEmpty ? nil : out
    }

    /// The `PUT /elgato/lights` document for one light entry (index 0; every accessory in the
    /// family reports `numberOfLights: 1`).
    public static func putDocument(_ light: ElgatoLightState) -> ElgatoLightsDocument {
        ElgatoLightsDocument(lights: [light])
    }
}
