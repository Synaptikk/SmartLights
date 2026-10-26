import LightCore
import SwiftUI

// AppModel adapter for Diagnostics (T0.7).
//
// This is the ONLY Diagnostics file that references `AppModel` (owned by T1.5). Assumptions:
//   - `AppModel` is an `@Observable` class injected with `.environment(appModel)`;
//   - it exposes `registry: ProviderRegistry` and `lights: [Light]`, readable on the main actor.
// If any of these differ, fix `DiagnosticsContext.init(appModel:)` below; nothing else needs to change.
//
// Also expected from AppModel (not enforced here): its single consumer loop over
// `registry.events` forwards each event with `DiagnosticsCollector.shared.ingest(event)`, and
// command call sites report `DiagnosticsCollector.shared.record(latency:for:)` /
// `record(error:for:)`.

/// Settings > Diagnostics. Type name is referenced by `SettingsView`; keep it.
struct DiagnosticsView: View {
    /// Optional so a missing `.environment(appModel)` (previews, tests) degrades instead of crashing.
    @Environment(AppModel.self) private var appModel: AppModel?

    var body: some View {
        DiagnosticsScreen(context: DiagnosticsContext(appModel: appModel))
    }
}

extension DiagnosticsContext {
    @MainActor
    init(appModel: AppModel?) {
        guard let appModel else {
            self = .empty
            return
        }
        self.init(registry: appModel.registry, lights: appModel.lights)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
