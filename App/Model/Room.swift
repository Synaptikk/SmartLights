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

/// App-owned data persisted next to the device store: rooms and app scenes.
struct AppLibrary: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = AppLibrary.currentVersion
    var rooms: [Room] = []
    /// App scenes (`LightScene.Kind.app`).
    var scenes: [LightScene] = []
    /// Lights the app has seen at least once (room auto-assignment from provider hints
    /// happens only on first sighting, so a user's "unassign" sticks).
    var seenLightIDs: Set<LightID> = []
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
