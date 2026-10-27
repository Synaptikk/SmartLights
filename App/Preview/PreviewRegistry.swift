#if DEBUG
import Foundation
import LightCore

/// Builds `AppModel`s backed by `FakeLightProvider`s so every view previews without hardware.
/// Uses in-memory secrets and library; nothing touches the network or the Keychain.
@MainActor
enum PreviewRegistry {
    /// A model with sample lights of every phase-1 brand, rooms, app and vendor scenes.
    /// Lights are available synchronously; fake providers are registered in the background
    /// so commands round-trip through the registry like real ones.
    static func model(latency: Duration = .milliseconds(60)) -> AppModel {
        let model = makeModel(library: PreviewData.library)
        for light in PreviewData.lights {
            model.lightsByID[light.id] = light
        }
        model.rooms = PreviewData.library.rooms
        model.groups = PreviewData.library.groups
        model.appScenes = PreviewData.library.scenes
        model.vendorScenes = PreviewData.vendorScenes
        model.seenLightIDs = Set(PreviewData.lights.map(\.id))
        model.isLoading = false
        Task {
            await registerFakeProviders(in: model, latency: latency)
            await model.start()
        }
        return model
    }

    /// A model with no providers and no lights (empty states).
    static func emptyModel() -> AppModel {
        let model = makeModel(library: AppLibrary())
        model.isLoading = false
        return model
    }

    static func registerFakeProviders(in model: AppModel, latency: Duration = .milliseconds(60), failing: Set<LightID> = []) async {
        let lights = PreviewData.lights
        let scenes = PreviewData.vendorScenes
        await model.registry.register(FakeLightProvider<FakeHue>(lights: lights, scenes: scenes, latency: latency, failing: failing))
        await model.registry.register(FakeLightProvider<FakeWiZ>(lights: lights, latency: latency, failing: failing))
        await model.registry.register(FakeLightProvider<FakeAiDot>(lights: lights, latency: latency, failing: failing))
        await model.registry.register(FakeLightProvider<FakeAppleHome>(lights: lights, latency: latency, failing: failing))
    }

    static func makeModel(library: AppLibrary) -> AppModel {
        let file = FileManager.default.temporaryDirectory.appending(path: "smartlights-preview-\(UUID().uuidString).json")
        return AppModel(
            deviceStore: JSONFileDeviceStore(fileURL: file),
            secretStore: InMemorySecretStore(),
            libraryStore: LibraryStore(fileURL: nil, initial: library)
        )
    }
}
#endif
