import AppIntents
import Foundation

// The light / room / scene entities shared by Siri, Shortcuts, widgets and controls.
//
// Compiled into the app AND the widget extension so a widget's or control's configured entity is
// the same type the app's intents resolve. Each target supplies its own `LightEntityQuery`,
// `RoomEntityQuery` and `SceneEntityQuery`: the app's read `AppModel`
// (App/Intents/IntentEntities.swift), the extension's read the App Group `WidgetSnapshot`
// (Extensions/Widgets/WidgetEntityQueries.swift). Keep this file Foundation + AppIntents only.

// MARK: - Light

/// A light as Siri / Shortcuts see it. `id` is the stable `LightID` string ("wiz:a8bb50..."),
/// never an IP, so saved shortcuts survive DHCP changes.
struct LightEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightEntityQuery()

    let id: String
    let name: String
    let brandName: String
    let roomName: String?
    let isAppleHome: Bool

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [brandName, roomName].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "lightbulb.fill")
        )
    }
}

// MARK: - Room

struct RoomEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomEntityQuery()

    /// `Room.id` UUID string.
    let id: String
    let name: String
    let lightCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(lightCount == 1 ? "1 light" : "\(lightCount) lights")",
            image: .init(systemName: "square.split.2x2")
        )
    }

    var roomID: UUID? { UUID(uuidString: id) }
}

// MARK: - Scene

/// An app scene (snapshot across brands) or a vendor scene (Hue scene, ...).
struct SceneEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneEntityQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: "sparkles"))
    }
}
