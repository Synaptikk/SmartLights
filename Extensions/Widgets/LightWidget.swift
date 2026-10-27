import AppIntents
import SwiftUI
import WidgetKit

/// Small widget: one configurable light with an interactive on/off toggle.
struct LightWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.light, intent: SelectLightIntent.self, provider: LightWidgetProvider()) { entry in
            LightWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Light")
        .description("Turn a light on or off.")
        .supportedFamilies([.systemSmall])
    }
}

struct LightWidgetEntry: TimelineEntry {
    let date: Date
    let light: WidgetSnapshot.Light?
}

struct LightWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LightWidgetEntry {
        LightWidgetEntry(date: .now, light: .sample)
    }

    func snapshot(for configuration: SelectLightIntent, in context: Context) async -> LightWidgetEntry {
        entry(for: configuration) ?? placeholder(in: context)
    }

    /// No polling: the app reloads timelines whenever its snapshot changes.
    func timeline(for configuration: SelectLightIntent, in context: Context) async -> Timeline<LightWidgetEntry> {
        Timeline(entries: [entry(for: configuration) ?? LightWidgetEntry(date: .now, light: nil)], policy: .never)
    }

    private func entry(for configuration: SelectLightIntent) -> LightWidgetEntry? {
        guard let id = configuration.light?.id else { return nil }
        return LightWidgetEntry(date: .now, light: WidgetSnapshotStore.appGroup.load().light(id: id))
    }
}

struct LightWidgetView: View {
    let entry: LightWidgetEntry

    var body: some View {
        if let light = entry.light {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.title2)
                    .foregroundStyle(light.isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                Text(light.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(light.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Toggle(isOn: light.isOn, intent: LightPowerControlIntent(light: LightEntity(light), isOn: !light.isOn)) {
                    Text(light.isOn ? "On" : "Off")
                }
                .disabled(!light.reachable)
            }
        } else {
            WidgetPlaceholderView(systemImage: "lightbulb", message: "Edit the widget to choose a light.")
        }
    }
}

/// Shown when nothing is configured or the configured item no longer exists.
struct WidgetPlaceholderView: View {
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

extension WidgetSnapshot.Light {
    static let sample = WidgetSnapshot.Light(
        id: "sample",
        name: "Desk Lamp",
        brandName: "WiZ",
        roomName: "Office",
        isAppleHome: false,
        isOn: true,
        brightness: 0.8,
        reachable: true
    )

    var statusText: String {
        guard reachable else { return "Not responding" }
        guard isOn else { return "Off" }
        if let brightness { return "\(Int((brightness * 100).rounded()))%" }
        return "On"
    }
}
