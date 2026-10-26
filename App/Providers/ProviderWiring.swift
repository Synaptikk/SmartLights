import Foundation
import LightCore

/// Registers the brand providers with the app model at launch.
///
/// T1.6 owns this file's body: create each provider (Hue, WiZ, AiDot, HomeKit) with
/// `model.deviceStore` / `model.secretStore`, restore paired devices, and call
/// `await model.registry.register(provider)` for each. `AppModel.start()` calls this once and
/// then `refresh()`, so providers registered here are loaded automatically.
///
/// Previews never call this path with real providers: `PreviewRegistry` registers
/// `FakeLightProvider`s directly.
enum ProviderWiring {
    @MainActor
    static func registerAll(in model: AppModel) async {
        // Intentionally empty until T1.6.
    }
}
