import Foundation
import LightCore

/// Pure mapping between HomeKit lightbulb snapshots and the SmartLights domain model.
public enum HomeKitMapper {
    /// HAP default colour temperature range when metadata is missing (mireds).
    public static let defaultMiredRange: ClosedRange<Int> = 140...500

    // MARK: - Identity

    /// `"applehome:<accessory uuid>/<service uuid>"`.
    public static func lightID(accessoryID: UUID, serviceID: UUID) -> LightID? {
        LightID(brand: .appleHome, stableId: stableID(accessoryID: accessoryID, serviceID: serviceID))
    }

    public static func lightID(for bulb: HomeKitLightbulb) -> LightID? {
        lightID(accessoryID: bulb.accessoryID, serviceID: bulb.serviceID)
    }

    /// `"<accessory uuid>/<service uuid>"`, also used as `Light.providerRef` and `DiscoveredDevice.id`.
    public static func stableID(accessoryID: UUID, serviceID: UUID) -> String {
        "\(accessoryID.uuidString)/\(serviceID.uuidString)"
    }

    /// Splits an Apple Home light id back into accessory and service identifiers.
    public static func identifiers(of id: LightID) -> (accessoryID: UUID, serviceID: UUID)? {
        guard id.brand == .appleHome else { return nil }
        return identifiers(stableID: id.stableId)
    }

    public static func identifiers(stableID: String) -> (accessoryID: UUID, serviceID: UUID)? {
        let parts = stableID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let accessory = UUID(uuidString: String(parts[0])),
              let service = UUID(uuidString: String(parts[1])) else { return nil }
        return (accessory, service)
    }

    // MARK: - Kelvin / mireds

    /// `1_000_000 / kelvin`, rounded. Non-positive input yields 0.
    public static func mireds(fromKelvin kelvin: Int) -> Int {
        guard kelvin > 0 else { return 0 }
        return Int((1_000_000.0 / Double(kelvin)).rounded())
    }

    /// `1_000_000 / mireds`, rounded. Non-positive input yields 0.
    public static func kelvin(fromMireds mireds: Int) -> Int {
        guard mireds > 0 else { return 0 }
        return Int((1_000_000.0 / Double(mireds)).rounded())
    }

    /// Mired range from characteristic metadata (HAP default 140...500 when absent).
    public static func miredRange(of characteristic: HomeKitCharacteristicSnapshot?) -> ClosedRange<Int> {
        var lo = characteristic?.minimum.map { Int($0.rounded()) } ?? defaultMiredRange.lowerBound
        var hi = characteristic?.maximum.map { Int($0.rounded()) } ?? defaultMiredRange.upperBound
        if lo <= 0 { lo = defaultMiredRange.lowerBound }
        if hi <= 0 { hi = defaultMiredRange.upperBound }
        return lo <= hi ? lo...hi : hi...lo
    }

    // MARK: - Capabilities and state

    /// Capabilities from the characteristics present on the service:
    /// power → onOff, brightness → brightness, hue + saturation → hs, colour temperature → colorTemp
    /// (Kelvin range from mired metadata). No transitions or effects through HomeKit.
    public static func capabilities(for bulb: HomeKitLightbulb) -> LightCapabilities {
        var modes: Set<ColorMode> = []
        if bulb.has(.hue) && bulb.has(.saturation) { modes.insert(.hs) }
        var minKelvin: Int?
        var maxKelvin: Int?
        if let ct = bulb.characteristics[.colorTemperature] {
            modes.insert(.colorTemp)
            let range = miredRange(of: ct)
            minKelvin = kelvin(fromMireds: range.upperBound)
            maxKelvin = kelvin(fromMireds: range.lowerBound)
        }
        if modes.isEmpty {
            modes.insert(bulb.has(.brightness) ? .brightness : .onOff)
        }
        return LightCapabilities(supportedColorModes: modes, minKelvin: minKelvin, maxKelvin: maxKelvin)
    }

    /// Current state from cached characteristic values.
    /// - Parameter colorModeHint: which colour mode was set last (HomeKit does not report the
    ///   active mode of lights that have both hue/saturation and colour temperature). Without a
    ///   hint such lights report `.hs` when saturation > 0, else `.colorTemp`.
    public static func state(for bulb: HomeKitLightbulb, colorModeHint: ColorMode? = nil, now: Date = Date()) -> LightState {
        let caps = capabilities(for: bulb)
        var state = LightState(reachable: bulb.isReachable, updatedAt: now)
        if let power = bulb.value(.powerState) {
            state.isOn = power != 0
        } else if let b = bulb.value(.brightness) {
            state.isOn = b > 0
        }
        if bulb.has(.brightness), let b = bulb.value(.brightness) {
            state.brightness = min(max(b / 100, 0), 1)
        }
        var hs: HS?
        if caps.supportedColorModes.contains(.hs), let h = bulb.value(.hue), let s = bulb.value(.saturation) {
            hs = HS(h: h, s: s / 100).clamped
        }
        var kelvin: Int?
        if caps.supportsColorTemp, let m = bulb.value(.colorTemperature), m > 0 {
            kelvin = self.kelvin(fromMireds: Int(m.rounded()))
        }
        state.hs = hs
        state.kelvin = kelvin
        switch (hs, kelvin) {
        case (.some(let v), .some):
            if let hint = colorModeHint, hint == .hs || hint == .colorTemp {
                state.colorMode = hint
            } else {
                state.colorMode = v.s > 0 ? .hs : .colorTemp
            }
        case (.some, nil): state.colorMode = .hs
        case (nil, .some): state.colorMode = .colorTemp
        case (nil, nil): state.colorMode = caps.supportsBrightness ? .brightness : .onOff
        }
        return state
    }

    public static func light(from bulb: HomeKitLightbulb, colorModeHint: ColorMode? = nil, now: Date = Date()) -> Light? {
        guard let id = lightID(for: bulb) else { return nil }
        return Light(
            id: id,
            name: bulb.displayName,
            roomHint: bulb.roomName,
            capabilities: capabilities(for: bulb),
            state: state(for: bulb, colorModeHint: colorModeHint, now: now),
            providerRef: stableID(accessoryID: bulb.accessoryID, serviceID: bulb.serviceID),
            manufacturer: bulb.manufacturer,
            model: bulb.model
        )
    }

    public static func discoveredDevice(for bulb: HomeKitLightbulb, now: Date = Date()) -> DiscoveredDevice {
        var metadata: [String: String] = [
            "accessoryID": bulb.accessoryID.uuidString,
            "serviceID": bulb.serviceID.uuidString,
            "reachable": bulb.isReachable ? "true" : "false",
        ]
        metadata["manufacturer"] = bulb.manufacturer
        metadata["room"] = bulb.roomName
        metadata["home"] = bulb.homeName
        metadata["firmware"] = bulb.firmwareVersion
        return DiscoveredDevice(
            id: stableID(accessoryID: bulb.accessoryID, serviceID: bulb.serviceID),
            brand: .appleHome,
            name: bulb.displayName,
            model: bulb.model,
            method: .homeKit,
            metadata: metadata,
            discoveredAt: now
        )
    }

    // MARK: - Commands

    /// Characteristic writes that apply `command` to `bulb`, in the order they should be sent.
    ///
    /// - Normalises with `LightCommand.normalized(for:)` first (colour → one supported attribute,
    ///   Kelvin clamped to the light's range).
    /// - Brightness `0...1` → percent `0...100` (clamped to metadata); brightness 0 without an
    ///   explicit `on` turns the light off; brightness > 0 on an off light also turns it on
    ///   (same semantics as `LightState.applying`).
    /// - Kelvin → mireds (clamped to metadata); HS → degrees / percent.
    /// - Turning off writes only the power state.
    /// - Values equal to the cached value are skipped (colour only when the cached colour mode,
    ///   `colorModeHint`, already matches; otherwise the mode switch must be written).
    public static func writes(for command: LightCommand, to bulb: HomeKitLightbulb, colorModeHint: ColorMode? = nil) -> [HomeKitWrite] {
        let caps = capabilities(for: bulb)
        let cmd = command.normalized(for: caps)
        let hasPower = bulb.has(.powerState)

        var targetOn = hasPower ? cmd.on : nil
        var targetBrightness: Int?
        if let b = cmd.brightness, let ch = bulb.characteristics[.brightness] {
            let lo = Int((ch.minimum ?? 0).rounded())
            let hi = Int((ch.maximum ?? 100).rounded())
            let percent = Int((b * 100).rounded())
            if percent <= 0 {
                switch cmd.on {
                case nil:
                    if hasPower { targetOn = false } else { targetBrightness = max(lo, 0) }
                case true?:
                    targetBrightness = min(max(1, lo), hi)
                case false?:
                    break
                }
            } else {
                targetBrightness = min(max(percent, lo), hi)
                if cmd.on == nil && hasPower { targetOn = true }
            }
        }

        // Turning off: only the power write.
        if targetOn == false {
            return isUnchanged(.powerState, 0, in: bulb) ? [] : [.power(false)]
        }

        var writes: [HomeKitWrite] = []
        if targetOn == true, !isUnchanged(.powerState, 1, in: bulb) {
            writes.append(.power(true))
        }
        if let b = targetBrightness, !isUnchanged(.brightness, Double(b), in: bulb) {
            writes.append(.brightness(b))
        }

        let currentMode = state(for: bulb, colorModeHint: colorModeHint).colorMode
        switch cmd.color {
        case .hs(let hs)?:
            let v = hs.clamped
            let hue = (v.h * 10).rounded() / 10
            let sat = (v.s * 1000).rounded() / 10
            let sameMode = currentMode == .hs
            if !sameMode || !isUnchanged(.hue, hue, in: bulb, tolerance: 0.5) { writes.append(.hue(hue)) }
            if !sameMode || !isUnchanged(.saturation, sat, in: bulb, tolerance: 0.5) { writes.append(.saturation(sat)) }
        case .kelvin(let k)?:
            let range = miredRange(of: bulb.characteristics[.colorTemperature])
            let m = min(max(mireds(fromKelvin: k), range.lowerBound), range.upperBound)
            if currentMode != .colorTemp || !isUnchanged(.colorTemperature, Double(m), in: bulb) {
                writes.append(.colorTemperature(mireds: m))
            }
        default:
            break // HomeKit lights only expose hs / colorTemp; normalisation converted everything else.
        }
        return writes
    }

    /// The snapshot after `writes` succeeded (HomeKit does not notify the writing app of its own writes).
    public static func applying(_ writes: [HomeKitWrite], to bulb: HomeKitLightbulb) -> HomeKitLightbulb {
        var next = bulb
        for w in writes {
            if next.characteristics[w.kind] != nil {
                next.characteristics[w.kind]?.value = w.value
            } else {
                next.characteristics[w.kind] = HomeKitCharacteristicSnapshot(value: w.value)
            }
        }
        return next
    }

    /// The colour mode a set of writes switches the light to, if any.
    public static func colorMode(of writes: [HomeKitWrite]) -> ColorMode? {
        if writes.contains(where: { $0.kind == .colorTemperature }) { return .colorTemp }
        if writes.contains(where: { $0.kind == .hue || $0.kind == .saturation }) { return .hs }
        return nil
    }

    private static func isUnchanged(_ kind: HomeKitCharacteristicKind, _ value: Double, in bulb: HomeKitLightbulb, tolerance: Double = 0.001) -> Bool {
        guard let current = bulb.value(kind) else { return false }
        if kind == .powerState { return (current != 0) == (value != 0) }
        return abs(current - value) < tolerance
    }
}
