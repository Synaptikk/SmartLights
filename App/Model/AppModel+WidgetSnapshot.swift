import Foundation
import LightCore
import Observation
import WidgetKit

/// Keeps the App Group `WidgetSnapshot` in step with the model (T2.7).
///
/// Widgets and controls run in the extension, which never loads providers or runs discovery; it
/// renders this snapshot. Observation tracking re-writes it (debounced) whenever lights, rooms or
/// scenes change, and reloads widgets and controls only when the content actually changed.
extension AppModel {
    /// The widget-facing view of the current lights, rooms and scenes.
    var widgetSnapshot: WidgetSnapshot {
        WidgetSnapshot(
            lights: lights.map { light in
                WidgetSnapshot.Light(
                    id: light.id.rawValue,
                    name: light.name,
                    brandName: light.brand.displayName,
                    roomName: room(containing: light.id)?.name,
                    isAppleHome: light.brand == .appleHome,
                    isOn: light.state.isOn,
                    brightness: light.state.brightness,
                    reachable: light.state.reachable
                )
            },
            rooms: rooms.map { WidgetSnapshot.Room(id: $0.id.uuidString, name: $0.name, lightIDs: $0.lightIDs.map(\.rawValue)) },
            scenes: intentScenes.map(SceneEntity.init).map { WidgetSnapshot.Scene(id: $0.id, name: $0.name, detail: $0.detail) }
        )
    }

    /// Writes the snapshot now and re-writes it after every change. Called once by `start()`.
    func trackWidgetSnapshot() {
        let snapshot = withObservationTracking {
            widgetSnapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.trackWidgetSnapshot()
            }
        }
        saveWidgetSnapshot(snapshot)
    }

    /// Writes immediately (after a widget / control action, before the app may be suspended).
    func saveWidgetSnapshotNow() {
        saveWidgetSnapshot(widgetSnapshot)
    }

    private func saveWidgetSnapshot(_ snapshot: WidgetSnapshot) {
        guard snapshot != lastWidgetSnapshot else { return }
        do {
            try widgetSnapshotStore.save(snapshot)
            lastWidgetSnapshot = snapshot
        } catch {
            record(error: "Could not update widgets: \(error.localizedDescription)")
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
