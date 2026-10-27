import AppIntents
import Foundation

/// Siri / Spotlight / Shortcuts phrases that work with no setup ("App Shortcuts").
///
/// Platform rules that shape these phrases:
/// - every phrase must contain `.applicationName` ("SmartLights");
/// - a phrase may contain at most one parameter, and only `AppEntity` / `AppEnum` parameters,
///   so "set the lamp to 30 percent" asks for the percentage as a follow-up question; the
///   on/off variants are separate one-parameter intents (`TurnOnRoomIntent`, ...);
/// - at most 10 App Shortcuts per app.
/// Entity names (lights, rooms, scenes) reach Siri via `updateAppShortcutParameters()`, which
/// `SmartLightsApp` calls whenever those names change.
struct SmartLightsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnRoomIntent(),
            phrases: [
                "Turn on \(.applicationName) lights in \(\.$room)",
                "Turn on the \(\.$room) lights in \(.applicationName)",
                "Turn on \(\.$room) in \(.applicationName)",
                "Turn on a room in \(.applicationName)",
            ],
            shortTitle: "Room On",
            systemImageName: "lightbulb.2.fill"
        )
        AppShortcut(
            intent: TurnOffRoomIntent(),
            phrases: [
                "Turn off \(.applicationName) lights in \(\.$room)",
                "Turn off the \(\.$room) lights in \(.applicationName)",
                "Turn off \(\.$room) in \(.applicationName)",
                "Turn off a room in \(.applicationName)",
            ],
            shortTitle: "Room Off",
            systemImageName: "lightbulb.2"
        )
        AppShortcut(
            intent: TurnOnLightIntent(),
            phrases: [
                "Turn on \(\.$light) in \(.applicationName)",
                "Switch on \(\.$light) in \(.applicationName)",
                "Turn on a light in \(.applicationName)",
            ],
            shortTitle: "Light On",
            systemImageName: "lightbulb.fill"
        )
        AppShortcut(
            intent: TurnOffLightIntent(),
            phrases: [
                "Turn off \(\.$light) in \(.applicationName)",
                "Switch off \(\.$light) in \(.applicationName)",
                "Turn off a light in \(.applicationName)",
            ],
            shortTitle: "Light Off",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: ToggleLightIntent(),
            phrases: [
                "Toggle \(\.$light) in \(.applicationName)",
                "Toggle a light in \(.applicationName)",
            ],
            shortTitle: "Toggle Light",
            systemImageName: "lightswitch.on"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Set \(\.$light) brightness in \(.applicationName)",
                "Dim \(\.$light) in \(.applicationName)",
                "Set the brightness in \(.applicationName)",
            ],
            shortTitle: "Brightness",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: SetColorIntent(),
            phrases: [
                "Change the colour of \(\.$light) in \(.applicationName)",
                "Change the color of \(\.$light) in \(.applicationName)",
                "Make a light \(\.$color) in \(.applicationName)",
                "Change a light colour in \(.applicationName)",
            ],
            shortTitle: "Colour",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: SetColorTemperatureIntent(),
            phrases: [
                "Set the colour temperature of \(\.$light) in \(.applicationName)",
                "Set the color temperature of \(\.$light) in \(.applicationName)",
                "Change the white of a light in \(.applicationName)",
            ],
            shortTitle: "Temperature",
            systemImageName: "thermometer.sun"
        )
        AppShortcut(
            intent: RecallSceneIntent(),
            phrases: [
                "Run \(\.$scene) scene in \(.applicationName)",
                "Run the \(\.$scene) scene in \(.applicationName)",
                "Activate \(\.$scene) in \(.applicationName)",
                "Run a scene in \(.applicationName)",
            ],
            shortTitle: "Run Scene",
            systemImageName: "sparkles"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .yellow
}
