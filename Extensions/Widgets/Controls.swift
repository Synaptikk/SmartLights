import AppIntents
import SwiftUI
import WidgetKit

// Control Center / Lock Screen / Action button controls (iOS 18). Controls cannot show errors
// (research_ios_platform.md A5); failures are recorded by the app in Diagnostics.

/// Toggle for one chosen light.
struct LightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetKind.lightControl, provider: LightControlProvider()) { value in
            ControlWidgetToggle(value.name, isOn: value.isOn, action: value.action) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            }
        }
        .displayName("Light")
        .description("Turn a light on or off.")
        .promptsForUserConfiguration()
    }
}

struct LightControlValue: Sendable {
    var light: LightEntity?
    var isOn: Bool

    var name: String { light?.name ?? "Light" }

    var action: LightPowerControlIntent {
        guard let light else { return LightPowerControlIntent() }
        return LightPowerControlIntent(light: light, isOn: !isOn)
    }
}

struct LightControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectLightControlIntent) -> LightControlValue {
        LightControlValue(light: configuration.light, isOn: false)
    }

    /// Reads the cached state from the snapshot; never contacts the light.
    func currentValue(configuration: SelectLightControlIntent) async throws -> LightControlValue {
        guard let entity = configuration.light else { return LightControlValue(light: nil, isOn: false) }
        let light = WidgetSnapshotStore.appGroup.load().light(id: entity.id)
        return LightControlValue(light: light.map(LightEntity.init) ?? entity, isOn: light?.isOn ?? false)
    }
}

/// Button that runs one chosen scene.
struct SceneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetKind.sceneControl, intent: SelectSceneControlIntent.self) { configuration in
            ControlWidgetButton(action: configuration.scene.map(SceneControlIntent.init(scene:)) ?? SceneControlIntent()) {
                Label(configuration.scene?.name ?? "Scene", systemImage: "sparkles")
            }
        }
        .displayName("Scene")
        .description("Run a scene.")
        .promptsForUserConfiguration()
    }
}
