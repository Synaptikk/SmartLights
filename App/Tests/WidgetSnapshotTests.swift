import Foundation
import Testing
import LightCore
@testable import SmartLights

@Suite("Widget snapshot")
struct WidgetSnapshotStoreTests {
    @Test("Round-trips through the store file; no App Group means no-op")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "widget-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(fileURL: url)
        let snapshot = WidgetSnapshot(
            lights: [.init(id: "wiz:a8bb50", name: "Desk", brandName: "WiZ", roomName: "Office",
                           isAppleHome: false, isOn: true, brightness: 0.5, reachable: true)],
            rooms: [.init(id: UUID().uuidString, name: "Office", lightIDs: ["wiz:a8bb50"])],
            scenes: [.init(id: "s1", name: "Evening", detail: "1 light")]
        )
        try store.save(snapshot)
        #expect(store.load() == snapshot)
        #expect(store.load().lights(in: snapshot.rooms[0]).map(\.name) == ["Desk"])

        let none = WidgetSnapshotStore(fileURL: nil)
        try none.save(snapshot)
        #expect(none.load() == WidgetSnapshot())
    }
}

#if DEBUG
@Suite("AppModel widget snapshot")
@MainActor
struct AppModelWidgetSnapshotTests {
    @Test("Snapshot mirrors lights, rooms and scenes by stable id")
    func mirrorsModel() async {
        let model = PreviewRegistry.makeModel(library: AppLibrary())
        await PreviewRegistry.registerFakeProviders(in: model, latency: .milliseconds(5))
        await model.start()

        let snapshot = model.widgetSnapshot
        #expect(snapshot.lights.count == model.lights.count)
        #expect(Set(snapshot.lights.map(\.id)) == Set(model.lightsByID.keys.map(\.rawValue)))
        #expect(snapshot.lights.contains { $0.isAppleHome })
        #expect(snapshot.rooms.map(\.name) == model.rooms.map(\.name))
        #expect(snapshot.scenes.map(\.id) == model.intentScenes.map(\.id))

        let hue = PreviewData.hueColor
        let entry = snapshot.light(id: hue.id.rawValue)
        #expect(entry?.roomName == model.room(containing: hue.id)?.name)
        #expect(entry?.isOn == model.lightsByID[hue.id]?.state.isOn)
    }
}
#endif
