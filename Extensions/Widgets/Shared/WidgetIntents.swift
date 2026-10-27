import AppIntents
import Foundation

// Action intents for widget buttons/toggles and Control Center / Lock Screen controls.
//
// Compiled into the app AND the widget extension (the extension needs the types to build its
// views). In the app they conform to `ForegroundContinuableIntent`, which is unavailable to
// extensions, so the system performs them in the app process: HomeKit calls fail inside the
// extension (HMError 80, Packages/Providers/HomeKitProvider/README.md), and the app owns the
// registered providers with their cached IPs. The app path never runs discovery
// (`AppModel.performIntent` / `recallForIntent`). Apple Home lights bring the app to the
// foreground first (`continueInForegroundIfNeeded`); other brands run without opening it.
//
// `WIDGET_EXTENSION` is set only for the extension target (project.yml).

struct LightPowerControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Light Power"
    static let description = IntentDescription("Turns a light on or off from a widget or control.")
    static let openAppWhenRun = false
    /// Siri / Shortcuts use `TurnLightOnOffIntent`; this one only backs widgets and controls.
    static let isDiscoverable = false

    @Parameter(title: "Light")
    var light: LightEntity

    @Parameter(title: "On")
    var value: Bool

    #if !WIDGET_EXTENSION
    @Dependency private var model: AppModel
    #endif

    init() {}

    init(light: LightEntity, isOn: Bool) {
        self.light = light
        self.value = isOn
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try WidgetIntentError.failInExtension()
        #else
        _ = try await setPower(value, light: light, model: model)
        model.saveWidgetSnapshotNow()
        #endif
        return .result()
    }
}

struct SceneControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Scene from Widget"
    static let description = IntentDescription("Recalls a scene from a widget or control.")
    static let openAppWhenRun = false
    /// Siri / Shortcuts use `RecallSceneIntent`; this one only backs widgets and controls.
    static let isDiscoverable = false

    @Parameter(title: "Scene")
    var scene: SceneEntity

    #if !WIDGET_EXTENSION
    @Dependency private var model: AppModel
    #endif

    init() {}

    init(scene: SceneEntity) {
        self.scene = scene
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try WidgetIntentError.failInExtension()
        #else
        _ = try await recallScene(scene, model: model)
        model.saveWidgetSnapshotNow()
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
extension LightPowerControlIntent: ForegroundContinuableIntent {}
extension SceneControlIntent: ForegroundContinuableIntent {}
#endif

/// Shown only if the system ever performs an action intent inside the extension (it should not:
/// the app declares them `ForegroundContinuableIntent`).
enum WidgetIntentError: Error, CustomLocalizedStringResourceConvertible {
    case needsApp

    var localizedStringResource: LocalizedStringResource {
        "Open SmartLights to control your lights."
    }

    static func failInExtension() throws {
        throw WidgetIntentError.needsApp
    }
}
