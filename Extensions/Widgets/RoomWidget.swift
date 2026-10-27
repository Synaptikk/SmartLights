import AppIntents
import SwiftUI
import WidgetKit

/// Medium / large widget: one configurable room with a toggle per light.
struct RoomWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.room, intent: SelectRoomIntent.self, provider: RoomWidgetProvider()) { entry in
            RoomWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Room")
        .description("Turn the lights in a room on or off.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RoomWidgetEntry: TimelineEntry {
    let date: Date
    let room: WidgetSnapshot.Room?
    let lights: [WidgetSnapshot.Light]
}

struct RoomWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RoomWidgetEntry {
        RoomWidgetEntry(
            date: .now,
            room: WidgetSnapshot.Room(id: "sample", name: "Office", lightIDs: ["sample"]),
            lights: [.sample]
        )
    }

    func snapshot(for configuration: SelectRoomIntent, in context: Context) async -> RoomWidgetEntry {
        entry(for: configuration) ?? placeholder(in: context)
    }

    func timeline(for configuration: SelectRoomIntent, in context: Context) async -> Timeline<RoomWidgetEntry> {
        Timeline(entries: [entry(for: configuration) ?? RoomWidgetEntry(date: .now, room: nil, lights: [])], policy: .never)
    }

    private func entry(for configuration: SelectRoomIntent) -> RoomWidgetEntry? {
        guard let id = configuration.room?.id else { return nil }
        let snapshot = WidgetSnapshotStore.appGroup.load()
        guard let room = snapshot.room(id: id) else { return RoomWidgetEntry(date: .now, room: nil, lights: []) }
        return RoomWidgetEntry(date: .now, room: room, lights: snapshot.lights(in: room))
    }
}

struct RoomWidgetView: View {
    let entry: RoomWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var maxRows: Int { family == .systemLarge ? 8 : 3 }

    var body: some View {
        if let room = entry.room {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(room.name).font(.headline)
                    Spacer()
                    let onCount = entry.lights.filter(\.isOn).count
                    Text("\(onCount) of \(entry.lights.count) on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.lights.isEmpty {
                    Spacer()
                    Text("No lights in this room.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(entry.lights.prefix(maxRows)) { light in
                    Toggle(isOn: light.isOn, intent: LightPowerControlIntent(light: LightEntity(light), isOn: !light.isOn)) {
                        HStack(spacing: 6) {
                            Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                                .foregroundStyle(light.isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                            Text(light.name).lineLimit(1)
                        }
                        .font(.subheadline)
                    }
                    .disabled(!light.reachable)
                }
                if entry.lights.count > maxRows {
                    Text("+\(entry.lights.count - maxRows) more").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        } else {
            WidgetPlaceholderView(systemImage: "square.split.2x2", message: "Edit the widget to choose a room.")
        }
    }
}
