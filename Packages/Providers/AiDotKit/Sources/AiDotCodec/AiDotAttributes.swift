import Foundation
import LightCore

/// Device attributes as carried in `payload.attr` (`OnOff`, `Dimming`, `CCT`, `RGBW`).
public struct AiDotAttributes: Sendable, Equatable {
    /// 0 / 1.
    public var onOff: Int?
    /// Percent 0...100.
    public var dimming: Int?
    /// Colour temperature in Kelvin.
    public var cct: Int?
    /// Signed int32 `(r<<24)|(g<<16)|(b<<8)|w`.
    public var rgbw: Int32?
    public var effectUniqueID: String?
    public var effectMode: String?

    public init(onOff: Int? = nil, dimming: Int? = nil, cct: Int? = nil, rgbw: Int32? = nil,
                effectUniqueID: String? = nil, effectMode: String? = nil) {
        self.onOff = onOff
        self.dimming = dimming
        self.cct = cct
        self.rgbw = rgbw
        self.effectUniqueID = effectUniqueID
        self.effectMode = effectMode
    }

    /// Parses an `attr` object; numbers may arrive as JSON numbers or numeric strings (cloud
    /// `properties`). RGBW values outside int32 are wrapped (python uses `ctypes.c_uint32` on read).
    public init(json: AiDotJSON) {
        onOff = json["OnOff"]?.intValue
        dimming = json["Dimming"]?.intValue
        cct = json["CCT"]?.intValue
        rgbw = json["RGBW"]?.intValue.map { Int32(truncatingIfNeeded: $0) }
        effectUniqueID = json["effectUniqueID"]?.looseString
        effectMode = json["EffectMode"]?.looseString
    }

    public var isEmpty: Bool { onOff == nil && dimming == nil && cct == nil && rgbw == nil }

    /// The `attr` object for `setDevAttrReq` (only writable keys).
    public var json: AiDotJSON {
        var members: [AiDotJSON.Member] = []
        if let onOff { members.append(.init("OnOff", .integer(onOff))) }
        if let dimming { members.append(.init("Dimming", .integer(dimming))) }
        if let cct { members.append(.init("CCT", .integer(cct))) }
        if let rgbw { members.append(.init("RGBW", .int(Int64(rgbw)))) }
        return .object(members)
    }

    // MARK: RGBW packing

    /// `ctypes.c_int32((r << 24) | (g << 16) | (b << 8) | w).value`.
    public static func packRGBW(_ v: RGBW) -> Int32 {
        Int32(bitPattern: UInt32(v.r) << 24 | UInt32(v.g) << 16 | UInt32(v.b) << 8 | UInt32(v.w))
    }

    /// `DeviceStatusData.update`: 0 means "default red" (255, 0, 0, 0).
    public static func unpackRGBW(_ value: Int32) -> RGBW {
        let u = value == 0 ? 0xFF00_0000 : UInt32(bitPattern: value)
        return RGBW(r: UInt8(u >> 24), g: UInt8((u >> 16) & 0xFF), b: UInt8((u >> 8) & 0xFF), w: UInt8(u & 0xFF))
    }
}

/// What a device supports, inferred like python-aidot `DeviceInformation`.
public struct AiDotFeatures: Sendable, Equatable {
    public var rgbw: Bool
    public var cct: Bool
    public var dimming: Bool
    public var minKelvin: Int?
    public var maxKelvin: Int?

    public init(rgbw: Bool, cct: Bool, dimming: Bool = true, minKelvin: Int? = nil, maxKelvin: Int? = nil) {
        self.rgbw = rgbw
        self.cct = cct
        self.dimming = dimming
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
    }

    /// `control.light.rgbw` => RGBW + CCT; `control.light.cct` => CCT with `properties[0].min/maxValue`.
    /// Without product modules, falls back to the presence of `RGBW`/`CCT` in the cloud `properties`.
    public init(product: AiDotProduct?, properties: AiDotJSON) {
        var rgbw = false, cct = false
        var minK: Int?, maxK: Int?
        let modules = product?.serviceModules ?? []
        for m in modules {
            if m.identity == AiDotServiceModule.rgbwIdentity {
                rgbw = true
                cct = true
            } else if m.identity == AiDotServiceModule.cctIdentity {
                cct = true
                minK = m.properties.first?.minValue
                maxK = m.properties.first?.maxValue
            }
        }
        if modules.isEmpty {
            rgbw = !(properties["RGBW"]?.isNull ?? true)
            cct = rgbw || !(properties["CCT"]?.isNull ?? true)
        }
        if let lo = minK, let hi = maxK, lo > hi { (minK, maxK) = (hi, lo) }
        self.init(rgbw: rgbw, cct: cct, dimming: true, minKelvin: minK, maxKelvin: maxK)
    }

    public init(record: AiDotDeviceRecord) {
        self.init(product: record.product, properties: record.properties)
    }

    /// HA mapping: RGBW lights => {rgbw, colorTemp}; CCT => {colorTemp}; else {brightness}.
    public var capabilities: LightCapabilities {
        var modes: Set<ColorMode>
        if rgbw {
            modes = [.rgbw, .colorTemp]
        } else if cct {
            modes = [.colorTemp]
        } else {
            modes = dimming ? [.brightness] : [.onOff]
        }
        return LightCapabilities(supportedColorModes: modes, minKelvin: cct ? minKelvin : nil, maxKelvin: cct ? maxKelvin : nil,
                                 supportsTransition: false, supportsEffects: false)
    }
}

/// Accumulated light state built from status pushes / poll answers.
public struct AiDotLightModel: Sendable, Equatable {
    public var features: AiDotFeatures
    public var isOn: Bool = false
    public var dimming: Int?
    public var cct: Int?
    public var rgbw: RGBW?
    public var colorMode: ColorMode?
    public var effectUniqueID: String?

    public init(features: AiDotFeatures) {
        self.features = features
    }

    /// Seeds from the cloud record `properties` (last known values).
    public init(record: AiDotDeviceRecord) {
        self.init(features: AiDotFeatures(record: record))
        apply(AiDotAttributes(json: record.properties))
    }

    /// Applies an `attr` set. When both CCT and RGBW are reported (full status) the previous colour
    /// mode is kept; python-aidot has no notion of an active mode either [unverified on hardware].
    public mutating func apply(_ a: AiDotAttributes) {
        if let v = a.onOff { isOn = v != 0 }
        if let v = a.dimming { dimming = min(max(v, 0), 100) }
        if let v = a.cct { cct = v }
        if let v = a.rgbw { rgbw = AiDotAttributes.unpackRGBW(v) }
        let hasCCT = a.cct != nil, hasRGBW = a.rgbw != nil && features.rgbw
        if hasRGBW && !hasCCT {
            colorMode = .rgbw
        } else if hasCCT && !hasRGBW && features.cct {
            colorMode = .colorTemp
        } else if colorMode == nil {
            if features.cct && cct != nil {
                colorMode = .colorTemp
            } else if features.rgbw && rgbw != nil {
                colorMode = .rgbw
            } else if features.dimming {
                colorMode = .brightness
            }
        }
        if hasCCT || hasRGBW { effectUniqueID = nil }
        if let e = a.effectUniqueID, !e.isEmpty { effectUniqueID = e }
    }

    public func lightState(reachable: Bool, at date: Date = Date()) -> LightState {
        LightState(
            isOn: isOn,
            brightness: features.dimming ? dimming.map { Double($0) / 100 } : nil,
            colorMode: colorMode,
            kelvin: features.cct ? cct : nil,
            rgbw: features.rgbw ? rgbw : nil,
            effect: effectUniqueID,
            reachable: reachable,
            updatedAt: date
        )
    }
}

/// `LightCommand` -> one `setDevAttrReq` attribute set.
public enum AiDotCommandMapper {
    /// - Parameters:
    ///   - currentlyOn: last known power state. Like python `send_dev_attr`, a brightness/colour change
    ///     on a light that is off also sends `OnOff: 1`.
    public static func attributes(for command: LightCommand, features: AiDotFeatures, currentlyOn: Bool) -> AiDotAttributes {
        let n = command.normalized(for: features.capabilities)
        var a = AiDotAttributes()
        if n.on == false {
            a.onOff = 0
            return a
        }
        if let on = n.on { a.onOff = on ? 1 : 0 }
        if let b = n.brightness {
            if b <= 0 {
                if n.on == nil { a.onOff = 0 }
                return a.onOff == 0 ? AiDotAttributes(onOff: 0) : a
            }
            a.dimming = min(100, max(1, Int((b * 100).rounded())))
        }
        switch n.color {
        case .kelvin(let k)?: a.cct = k
        case .rgbw(let v)?: a.rgbw = AiDotAttributes.packRGBW(v)
        default: break
        }
        if a.onOff == nil, !currentlyOn, a.dimming != nil || a.cct != nil || a.rgbw != nil { a.onOff = 1 }
        return a
    }
}
