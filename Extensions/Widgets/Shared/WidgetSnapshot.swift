import Foundation

/// The lightweight state the widget extension reads (compiled into the app and the extension).
///
/// `AppModel` writes it to the App Group container whenever lights, rooms or scenes change
/// (`AppModel+WidgetSnapshot.swift`). The extension never runs discovery or loads providers; it
/// only renders this file. Ids are the stable ids the intents use (never IPs) and the file never
/// contains credentials.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = WidgetSnapshot.currentVersion
    var lights: [Light] = []
    var rooms: [Room] = []
    var scenes: [Scene] = []

    struct Light: Codable, Sendable, Equatable, Identifiable {
        /// `LightID` raw value ("wiz:a8bb50...").
        var id: String
        var name: String
        var brandName: String
        var roomName: String?
        var isAppleHome: Bool
        var isOn: Bool
        /// `0...1`; nil if unknown or not dimmable.
        var brightness: Double?
        var reachable: Bool
    }

    struct Room: Codable, Sendable, Equatable, Identifiable {
        /// `Room.id` UUID string.
        var id: String
        var name: String
        var lightIDs: [String]
    }

    struct Scene: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var detail: String
    }

    func light(id: String) -> Light? { lights.first { $0.id == id } }
    func room(id: String) -> Room? { rooms.first { $0.id == id } }
    func scene(id: String) -> Scene? { scenes.first { $0.id == id } }

    func lights(in room: Room) -> [Light] { room.lightIDs.compactMap(light(id:)) }
}

/// Reads / writes `WidgetSnapshot` as JSON in the shared App Group container.
/// `fileURL == nil` (no App Group, e.g. unsigned test builds) makes every call a no-op.
struct WidgetSnapshotStore: Sendable {
    static let appGroupID = "group.com.sinap.smartlights"

    static let appGroup = WidgetSnapshotStore(
        fileURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "widget-snapshot.json")
    )

    let fileURL: URL?

    func load() -> WidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion
        else { return WidgetSnapshot() }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

/// Widget and control kinds (shared so the app can reload them by kind if needed).
enum WidgetKind {
    static let light = "com.sinap.smartlights.widget.light"
    static let room = "com.sinap.smartlights.widget.room"
    static let scene = "com.sinap.smartlights.widget.scene"
    static let lightControl = "com.sinap.smartlights.control.light"
    static let sceneControl = "com.sinap.smartlights.control.scene"
}
