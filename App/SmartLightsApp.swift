import SwiftUI

@main
struct SmartLightsApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    // `SwiftUI.Scene` is spelled out because LightCore also exports a `Scene` typealias.
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(isActive: phase == .active)
        }
    }
}
