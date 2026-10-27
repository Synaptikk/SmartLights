import AppIntents
import SwiftUI
import WidgetKit

/// Small widget: one configurable scene with a run button.
struct SceneWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.scene, intent: SelectSceneIntent.self, provider: SceneWidgetProvider()) { entry in
            SceneWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Scene")
        .description("Run a scene.")
        .supportedFamilies([.systemSmall])
    }
}

struct SceneWidgetEntry: TimelineEntry {
    let date: Date
    let scene: WidgetSnapshot.Scene?
}

struct SceneWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SceneWidgetEntry {
        SceneWidgetEntry(date: .now, scene: WidgetSnapshot.Scene(id: "sample", name: "Evening", detail: "3 lights"))
    }

    func snapshot(for configuration: SelectSceneIntent, in context: Context) async -> SceneWidgetEntry {
        entry(for: configuration) ?? placeholder(in: context)
    }

    func timeline(for configuration: SelectSceneIntent, in context: Context) async -> Timeline<SceneWidgetEntry> {
        Timeline(entries: [entry(for: configuration) ?? SceneWidgetEntry(date: .now, scene: nil)], policy: .never)
    }

    private func entry(for configuration: SelectSceneIntent) -> SceneWidgetEntry? {
        guard let id = configuration.scene?.id else { return nil }
        return SceneWidgetEntry(date: .now, scene: WidgetSnapshotStore.appGroup.load().scene(id: id))
    }
}

struct SceneWidgetView: View {
    let entry: SceneWidgetEntry

    var body: some View {
        if let scene = entry.scene {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(scene.name)
                    .font(.headline)
                    .lineLimit(2)
                if !scene.detail.isEmpty {
                    Text(scene.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(intent: SceneControlIntent(scene: SceneEntity(scene))) {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            WidgetPlaceholderView(systemImage: "sparkles", message: "Edit the widget to choose a scene.")
        }
    }
}
