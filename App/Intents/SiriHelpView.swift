import AppIntents
import SwiftUI

/// Settings > Siri & Shortcuts: what to say, and how Apple Home lights relate to plain Siri.
struct SiriHelpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(examples, id: \.self) { phrase in
                    Label {
                        Text("“Hey Siri, \(phrase)”")
                    } icon: {
                        Image(systemName: "quote.bubble")
                    }
                }
            } header: {
                Text("Say")
            } footer: {
                Text("Include “SmartLights” in the sentence. If you leave out a name or a value, Siri asks for it — for example “Set Sofa Lamp brightness in SmartLights” is followed by “What brightness, in percent?”.")
            }

            Section {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
            } footer: {
                Text("Every action (toggle, on/off, brightness, colour, colour temperature, room, scene) is also available in the Shortcuts app, where you can give it your own phrase or run it from an automation.")
            }

            Section("Apple Home lights") {
                Text("Lights you added to the Apple Home app also answer plain Siri without “SmartLights”, for example “Hey Siri, turn on the porch light”.")
                Text("When SmartLights controls an Apple Home light from Siri, it has to open briefly: Apple only lets apps change Home accessories while they are on screen.")
                    .foregroundStyle(.secondary)
            }

            Section("Other brands") {
                Text("Hue, WiZ, AiDot and other lights are controlled directly on your Wi-Fi, so Siri works without opening the app. Your phone has to be on the same network as the lights.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
    }

    /// Example phrases using the user's own names where possible.
    private var examples: [String] {
        let room = model.rooms.first?.name ?? "Living Room"
        let light = model.lights.first?.name ?? "Desk Lamp"
        let scene = model.intentScenes.first?.name ?? "Evening"
        return [
            "turn on SmartLights lights in \(room)",
            "turn off the \(room) lights in SmartLights",
            "turn on \(light) in SmartLights",
            "toggle \(light) in SmartLights",
            "set \(light) brightness in SmartLights",
            "make a light blue in SmartLights",
            "set the colour temperature of \(light) in SmartLights",
            "run \(scene) scene in SmartLights",
        ]
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SiriHelpView()
    }
    .environment(PreviewRegistry.model())
}
#endif
