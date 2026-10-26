import SwiftUI

/// Root tab container. Feature tabs (Rooms, Scenes, ...) are added by their own tasks.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Lights", systemImage: "lightbulb") {
                LightsPlaceholderView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
    }
}

/// Placeholder until the Rooms/Lights feature lands.
struct LightsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "SmartLights",
                systemImage: "lightbulb.2",
                description: Text("No lights yet. Add a brand from Settings once onboarding is available.")
            )
            .navigationTitle("SmartLights")
        }
    }
}

#Preview {
    ContentView()
}
