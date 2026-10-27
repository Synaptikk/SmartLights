import AppIntents
import SwiftUI

@main
struct SmartLightsApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        // Siri / Shortcuts intents run in this process (no extension) and share this model (T1.10).
        AppDependencyManager.shared.add(dependency: model)
    }

    // `SwiftUI.Scene` is spelled out because LightCore also exports a `Scene` typealias.
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .onChange(of: model.intentVocabulary, initial: true) {
                    // Lets Siri learn light / room / scene names for the App Shortcut phrases.
                    SmartLightsShortcuts.updateAppShortcutParameters()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(isActive: phase == .active)
        }
    }
}
