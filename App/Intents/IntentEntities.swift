import AppIntents
import Foundation
import LightCore

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

    var lightID: LightID? { LightID(id) }
}

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

    var roomID: Room.ID? { UUID(uuidString: id) }
}

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
