import Foundation
import LightCore

/// A user-defined room. Any brand's lights can be in it; a light is in at most one room.
struct Room: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Ordered member lights (stable ids, never IPs).
    var lightIDs: [LightID]

    init(id: UUID = UUID(), name: String, lightIDs: [LightID] = []) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
    }
}

/// App-owned data persisted next to the device store: rooms, groups and app scenes.
struct AppLibrary: Codable, Sendable, Equatable {
    /// 2 added `groups`; version-1 files decode with no groups.
    static let currentVersion = 2

    var version: Int = AppLibrary.currentVersion
    var rooms: [Room] = []
    /// App scenes (`LightScene.Kind.app`).
    var scenes: [LightScene] = []
    /// Lights the app has seen at least once (room auto-assignment from provider hints
    /// happens only on first sighting, so a user's "unassign" sticks).
    var seenLightIDs: Set<LightID> = []
    /// Cross-brand light groups (`LightGroup`), in display order.
    var groups: [LightGroup] = []
}

extension AppLibrary {
    private enum CodingKeys: String, CodingKey { case version, rooms, scenes, seenLightIDs, groups }

    /// Tolerates fields missing from older files (version 1 has no `groups`).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        scenes = try c.decodeIfPresent([LightScene].self, forKey: .scenes) ?? []
        seenLightIDs = try c.decodeIfPresent(Set<LightID>.self, forKey: .seenLightIDs) ?? []
        groups = try c.decodeIfPresent([LightGroup].self, forKey: .groups) ?? []
    }
}

/// Reads/writes `AppLibrary` as one JSON file. `fileURL == nil` keeps it in memory (previews, tests).
/// SwiftData replaces this later together with the device store (PLAN.md D10, T1.6).
actor LibraryStore {
    private let fileURL: URL?
    private var memory: AppLibrary

    init(fileURL: URL?, initial: AppLibrary = AppLibrary()) {
        self.fileURL = fileURL
        self.memory = initial
    }

    func load() throws -> AppLibrary {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return memory }
        let data = try Data(contentsOf: fileURL)
        memory = try JSONDecoder().decode(AppLibrary.self, from: data)
        return memory
    }

    func save(_ library: AppLibrary) throws {
        memory = library
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
