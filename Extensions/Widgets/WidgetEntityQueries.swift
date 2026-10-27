import AppIntents
import Foundation

// Extension-side entity queries: they read the App Group `WidgetSnapshot` the app writes and
// never touch providers, the network or discovery. The app target has queries with the same names
// backed by `AppModel` (App/Intents/IntentEntities.swift).

struct LightEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [LightEntity.ID]) async throws -> [LightEntity] {
        let snapshot = WidgetSnapshotStore.appGroup.load()
        return identifiers.compactMap(snapshot.light(id:)).map(LightEntity.init)
    }

    func entities(matching string: String) async throws -> [LightEntity] {
        WidgetSnapshotStore.appGroup.load().lights
            .filter { $0.name.localizedStandardContains(string) }
            .map(LightEntity.init)
    }

    func suggestedEntities() async throws -> [LightEntity] {
        WidgetSnapshotStore.appGroup.load().lights.map(LightEntity.init)
    }
}

struct RoomEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [RoomEntity.ID]) async throws -> [RoomEntity] {
        let snapshot = WidgetSnapshotStore.appGroup.load()
        return identifiers.compactMap(snapshot.room(id:)).map(RoomEntity.init)
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        WidgetSnapshotStore.appGroup.load().rooms
            .filter { $0.name.localizedStandardContains(string) }
            .map(RoomEntity.init)
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        WidgetSnapshotStore.appGroup.load().rooms.map(RoomEntity.init)
    }
}

struct SceneEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [SceneEntity.ID]) async throws -> [SceneEntity] {
        let snapshot = WidgetSnapshotStore.appGroup.load()
        return identifiers.compactMap(snapshot.scene(id:)).map(SceneEntity.init)
    }

    func entities(matching string: String) async throws -> [SceneEntity] {
        WidgetSnapshotStore.appGroup.load().scenes
            .filter { $0.name.localizedStandardContains(string) }
            .map(SceneEntity.init)
    }

    func suggestedEntities() async throws -> [SceneEntity] {
        WidgetSnapshotStore.appGroup.load().scenes.map(SceneEntity.init)
    }
}

extension LightEntity {
    init(_ light: WidgetSnapshot.Light) {
        self.init(
            id: light.id,
            name: light.name,
            brandName: light.brandName,
            roomName: light.roomName,
            isAppleHome: light.isAppleHome
        )
    }
}

extension RoomEntity {
    init(_ room: WidgetSnapshot.Room) {
        self.init(id: room.id, name: room.name, lightCount: room.lightIDs.count)
    }
}

extension SceneEntity {
    init(_ scene: WidgetSnapshot.Scene) {
        self.init(id: scene.id, name: scene.name, detail: scene.detail)
    }
}
