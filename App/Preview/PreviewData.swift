#if DEBUG
import Foundation
import LightCore

/// Sample lights for every phase-1 brand (Hue, WiZ, AiDot, Apple Home), rooms and scenes.
enum PreviewData {
    private static func id(_ brand: Brand, _ stableId: String) -> LightID {
        guard let id = LightID(brand: brand, stableId: stableId) else { preconditionFailure("bad preview id") }
        return id
    }

    static let hueColor = Light(
        id: id(.hue, "3f1c2a9e-0d6b-4c55-9a61-8d2b7e4f1a01"),
        name: "Sofa Lamp",
        roomHint: "Living Room",
        capabilities: LightCapabilities(
            supportedColorModes: [.xy, .colorTemp],
            minKelvin: 2000, maxKelvin: 6535,
            supportsTransition: true,
            effects: [
                EffectDescriptor(id: "candle", name: "Candle"),
                EffectDescriptor(id: "fire", name: "Fireplace"),
                EffectDescriptor(id: "sparkle", name: "Sparkle", isFast: true),
            ],
            gamut: .hueC
        ),
        state: LightState(isOn: true, brightness: 0.8, colorMode: .xy, xy: XY(x: 0.45, y: 0.41)),
        providerRef: "bridge-001788fffe000001/light/1",
        model: "LCA001"
    )

    static let hueAmbiance = Light(
        id: id(.hue, "7b2e1d40-5c3a-4f8e-b1d2-0a9c8e7f6d02"),
        name: "Ceiling",
        roomHint: "Living Room",
        capabilities: LightCapabilities(supportedColorModes: [.colorTemp], minKelvin: 2200, maxKelvin: 6500, supportsTransition: true),
        state: LightState(isOn: true, brightness: 0.55, colorMode: .colorTemp, kelvin: 2700),
        providerRef: "bridge-001788fffe000001/light/2",
        model: "LTA001"
    )

    static let wizColor = Light(
        id: id(.wiz, "a8bb5006033d"),
        name: "Desk Bulb",
        roomHint: "Office",
        capabilities: LightCapabilities(
            supportedColorModes: [.rgb, .colorTemp],
            minKelvin: 2200, maxKelvin: 6500,
            effects: [
                EffectDescriptor(id: "4", name: "Party", isFast: true),
                EffectDescriptor(id: "1", name: "Ocean"),
                EffectDescriptor(id: "12", name: "Cozy"),
            ]
        ),
        state: LightState(isOn: true, brightness: 0.6, colorMode: .rgb, rgb: RGB(r: 40, g: 120, b: 255)),
        providerRef: "mac:a8bb5006033d",
        model: "ESP01_SHRGB1C_31"
    )

    static let wizTunable = Light(
        id: id(.wiz, "a8bb50aa0101"),
        name: "Hallway",
        capabilities: LightCapabilities(supportedColorModes: [.colorTemp], minKelvin: 2700, maxKelvin: 6500),
        state: LightState(isOn: false, brightness: 0.4, colorMode: .colorTemp, kelvin: 3000),
        providerRef: "mac:a8bb50aa0101",
        model: "ESP05_SHTW_21"
    )

    static let aidotRGBW = Light(
        id: id(.aidot, "1234567890abcdef"),
        name: "Bedside",
        roomHint: "Bedroom",
        capabilities: LightCapabilities(supportedColorModes: [.rgbw, .colorTemp], minKelvin: 2700, maxKelvin: 6500),
        state: LightState(isOn: true, brightness: 0.3, colorMode: .rgbw, rgbw: RGBW(r: 255, g: 80, b: 20, w: 0)),
        providerRef: "dev:1234567890abcdef",
        model: "lk.WIFI-RGBWLight-D0006"
    )

    static let homePlug = Light(
        id: id(.appleHome, "4E2B7A10-0F3C-4D2E-9B1A-6C5D4E3F2A10"),
        name: "Fairy Lights",
        roomHint: "Bedroom",
        capabilities: .onOff,
        state: LightState(isOn: false),
        providerRef: "accessory/4E2B7A10",
        manufacturer: "Eve",
        model: "Energy"
    )

    static let homeDimmable = Light(
        id: id(.appleHome, "9A8B7C6D-1E2F-4A3B-8C9D-0E1F2A3B4C5D"),
        name: "Porch",
        capabilities: .dimmable,
        state: LightState(isOn: true, brightness: 0.9, reachable: false),
        providerRef: "accessory/9A8B7C6D",
        manufacturer: "Nanoleaf"
    )

    static let lights: [Light] = [hueColor, hueAmbiance, wizColor, wizTunable, aidotRGBW, homePlug, homeDimmable]

    static let livingRoom = Room(name: "Living Room", lightIDs: [hueColor.id, hueAmbiance.id])
    static let office = Room(name: "Office", lightIDs: [wizColor.id])
    static let bedroom = Room(name: "Bedroom", lightIDs: [aidotRGBW.id, homePlug.id])

    /// Cross-brand group: Hue, WiZ, AiDot and Apple Home lights together.
    static let everywhere = LightGroup(
        name: "Downstairs",
        lightIDs: [hueColor.id, wizColor.id, aidotRGBW.id, homeDimmable.id],
        transitionMilliseconds: 400
    )

    static let vendorScenes: [LightScene] = [
        LightScene(id: "hue:scene-relax", name: "Relax", kind: .vendor, brand: .hue, roomHint: "Living Room", lightIDs: [hueColor.id, hueAmbiance.id]),
        LightScene(id: "hue:scene-concentrate", name: "Concentrate", kind: .vendor, brand: .hue, roomHint: "Living Room", lightIDs: [hueColor.id, hueAmbiance.id]),
    ]

    static var library: AppLibrary {
        AppLibrary(
            rooms: [livingRoom, office, bedroom],
            scenes: [
                LightScene.snapshot(of: [hueColor, hueAmbiance, aidotRGBW], name: "Evening", id: "preview-evening"),
                LightScene.snapshot(of: [wizColor], name: "Focus", id: "preview-focus"),
            ],
            seenLightIDs: Set(lights.map(\.id)),
            groups: [everywhere]
        )
    }
}
#endif
