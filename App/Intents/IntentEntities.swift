import AppIntents
import Foundation
import LightCore

// Entity types live in Extensions/Widgets/Shared/IntentEntityTypes.swift (compiled into the app and
// the widget extension). The queries below are the app-process ones (backed by `AppModel`); the
// extension has its own snapshot-backed queries with the same names (WidgetEntityQueries.swift).

// MARK: - Light

extension LightEntity {
    init(_ light: Light, roomName: String?) {
        self.init(
            id: light.id.rawValue,
            name: light.name,
            brandName: light.brand.displayName,
            roomName: roomName,
            isAppleHome: light.brand == .appleHome
        )
    }

    var lightID: LightID? { LightID(id) }
}

struct LightEntityQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func entities(for identifiers: [LightEntity.ID]) async throws -> [LightEntity] {
        await model.prepareForIntents()
        return identifiers.compactMap { LightID($0).flatMap { model.lightsByID[$0] } }.map(model.lightEntity)
    }

    @MainActor
    func entities(matching string: String) async throws -> [LightEntity] {
        await model.prepareForIntents()
        return model.intentLights(matching: string).map(model.lightEntity)
    }

    @MainActor
    func suggestedEntities() async throws -> [LightEntity] {
        await model.prepareForIntents()
        return model.lights.map(model.lightEntity)
    }
}

// MARK: - Room

extension RoomEntity {
    init(_ room: Room) {
        self.init(id: room.id.uuidString, name: room.name, lightCount: room.lightIDs.count)
    }
}

struct RoomEntityQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func entities(for identifiers: [RoomEntity.ID]) async throws -> [RoomEntity] {
        await model.prepareForIntents()
        return identifiers.compactMap { id in model.rooms.first { $0.id.uuidString == id } }.map(RoomEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [RoomEntity] {
        await model.prepareForIntents()
        return model.intentRooms(matching: string).map(RoomEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RoomEntity] {
        await model.prepareForIntents()
        return model.rooms.map(RoomEntity.init)
    }
}

// MARK: - Scene

extension SceneEntity {
    init(_ scene: LightScene) {
        let count = scene.kind == .app ? scene.commands.count : scene.lightIDs.count
        let lights = count == 1 ? "1 light" : "\(count) lights"
        let detail: String
        switch scene.kind {
        case .app: detail = lights
        case .vendor: detail = [scene.brand?.displayName, scene.roomHint].compactMap { $0 }.joined(separator: " · ")
        }
        self.init(id: scene.id, name: scene.name, detail: detail)
    }
}

struct SceneEntityQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    init() {}

    @MainActor
    func entities(for identifiers: [SceneEntity.ID]) async throws -> [SceneEntity] {
        await model.prepareForIntents()
        return identifiers.compactMap(model.intentScene(id:)).map(SceneEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SceneEntity] {
        await model.prepareForIntents()
        return model.intentScenes(matching: string).map(SceneEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SceneEntity] {
        await model.prepareForIntents()
        return model.intentScenes.map(SceneEntity.init)
    }
}

// MARK: - Model helpers

extension AppModel {
    func lightEntity(_ light: Light) -> LightEntity {
        LightEntity(light, roomName: room(containing: light.id)?.name)
    }
}
