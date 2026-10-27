import Foundation
import LightCore
import SwiftUI // MutableCollection.move(fromOffsets:toOffset:)

// MARK: - Queries

extension AppModel {
    /// All lights sorted by name (read by Diagnostics, intents). Keyed access: `lightsByID`.
    var lights: [Light] { sortedLights }

    /// All lights sorted by name.
    var sortedLights: [Light] {
        lightsByID.values.sorted(by: Self.byName)
    }

    func lights(inRoom roomID: Room.ID) -> [Light] {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return [] }
        return room.lightIDs.compactMap { lightsByID[$0] }
    }

    /// Lights not in any room, sorted by name.
    var unassignedLights: [Light] {
        let assigned = Set(rooms.flatMap(\.lightIDs))
        return lightsByID.values.filter { !assigned.contains($0.id) }.sorted(by: Self.byName)
    }

    func room(containing id: LightID) -> Room? {
        rooms.first { $0.lightIDs.contains(id) }
    }

    /// Lookup by name for intents/Siri (case- and diacritic-insensitive).
    func light(named name: String) -> Light? {
        lightsByID.values.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func room(named name: String) -> Room? {
        rooms.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Vendor scenes that include the light.
    func vendorScenes(for id: LightID) -> [LightScene] {
        vendorScenes.filter { $0.lightIDs.contains(id) }
    }

    static func byName(_ a: Light, _ b: Light) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// MARK: - Rooms

extension AppModel {
    @discardableResult
    func addRoom(named name: String, lightIDs: [LightID] = []) -> Room {
        let room = Room(name: name.trimmingCharacters(in: .whitespacesAndNewlines), lightIDs: [])
        rooms.append(room)
        for id in lightIDs { assign(id, toRoom: room.id) }
        scheduleLibrarySave()
        return rooms.first { $0.id == room.id } ?? room
    }

    func renameRoom(_ roomID: Room.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].name = trimmed
        scheduleLibrarySave()
    }

    /// Deletes a room; its lights become unassigned.
    func deleteRoom(_ roomID: Room.ID) {
        rooms.removeAll { $0.id == roomID }
        scheduleLibrarySave()
    }

    func moveRooms(fromOffsets source: IndexSet, toOffset destination: Int) {
        rooms.move(fromOffsets: source, toOffset: destination)
        scheduleLibrarySave()
    }

    /// Moves a light into a room (removing it from any other), or unassigns it when `roomID` is nil.
    func assign(_ id: LightID, toRoom roomID: Room.ID?) {
        for index in rooms.indices {
            rooms[index].lightIDs.removeAll { $0 == id }
        }
        if let roomID, let index = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[index].lightIDs.append(id)
        }
        scheduleLibrarySave()
    }

    /// First sighting of a light: put it in the room matching the provider's hint (Hue room,
    /// HomeKit room), creating the room if needed.
    func autoAssignRoom(for light: Light) {
        guard room(containing: light.id) == nil,
              let hint = light.roomHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty
        else { return }
        if let existing = room(named: hint) {
            assign(light.id, toRoom: existing.id)
        } else {
            rooms.append(Room(name: hint, lightIDs: [light.id]))
        }
    }
}

// MARK: - Scenes

extension AppModel {
    /// Snapshots the current state of the given lights into a new app scene and saves it.
    @discardableResult
    func createSnapshotScene(name: String, lightIDs: [LightID]) -> LightScene {
        let members = lightIDs.compactMap { lightsByID[$0] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = LightScene.snapshot(of: members, name: trimmed.isEmpty ? "Scene" : trimmed)
        saveScene(scene)
        return scene
    }

    /// Inserts or replaces an app scene.
    func saveScene(_ scene: LightScene) {
        if let index = appScenes.firstIndex(where: { $0.id == scene.id }) {
            appScenes[index] = scene
        } else {
            appScenes.append(scene)
        }
        scheduleLibrarySave()
    }

    func deleteScene(_ id: LightScene.ID) {
        appScenes.removeAll { $0.id == id }
        scheduleLibrarySave()
    }

    func moveScenes(fromOffsets source: IndexSet, toOffset destination: Int) {
        appScenes.move(fromOffsets: source, toOffset: destination)
        scheduleLibrarySave()
    }

    /// Recalls a scene. App scenes are grouped by identical command and each bucket goes out as
    /// one group send through the coalescer (optimistic UI, rate limits); the registry splits it
    /// by brand and sends to the providers concurrently, so a mixed-brand scene lands together.
    /// Vendor scenes go to their provider.
    func recall(_ scene: LightScene) {
        switch scene.kind {
        case .app:
            for (index, bucket) in Self.commandBuckets(scene.commands).enumerated() {
                send(bucket.command, toLights: bucket.lightIDs, groupKey: .group("scene-\(scene.id)-\(index)"))
            }
        case .vendor:
            Task {
                do {
                    try await registry.recall(scene)
                } catch {
                    showError(error)
                }
            }
        }
    }

    /// Lights that receive the same command, in a stable order (by first light id).
    nonisolated static func commandBuckets(_ commands: [LightID: LightCommand]) -> [(command: LightCommand, lightIDs: [LightID])] {
        Dictionary(grouping: commands, by: \.value)
            .map { command, entries in (command: command, lightIDs: entries.map(\.key).sorted()) }
            .sorted { $0.lightIDs[0] < $1.lightIDs[0] }
    }
}
