import SwiftUI
import LightCore

/// Group actions for a room: all on, all off, room brightness. Sent as one group command
/// (providers can use native groups such as Hue grouped_light).
struct RoomControlRow: View {
    let room: Room
    let lights: [Light]

    @Environment(AppModel.self) private var model

    private var anyOn: Bool { lights.contains { $0.state.isOn } }
    private var dimmable: [Light] { lights.filter { $0.capabilities.supportsBrightness } }

    /// Average brightness of the dimmable lights that are on.
    private var averageBrightness: Double {
        let on = dimmable.filter(\.state.isOn)
        guard !on.isEmpty else { return 1 }
        return on.map { $0.state.brightness ?? 1 }.reduce(0, +) / Double(on.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    model.send(.turnOn, toRoom: room.id)
                } label: {
                    Label("All On", systemImage: "lightbulb.fill")
                }
                .accessibilityLabel(Text("Turn on all lights in \(room.name)"))

                Spacer()

                Button {
                    model.send(.turnOff, toRoom: room.id)
                } label: {
                    Label("All Off", systemImage: "lightbulb.slash")
                }
                .accessibilityLabel(Text("Turn off all lights in \(room.name)"))
            }
            .buttonStyle(.borderless)
            .font(.subheadline)

            if !dimmable.isEmpty && anyOn {
                BrightnessSlider(name: room.name, value: Binding(
                    get: { averageBrightness },
                    set: { model.send(LightCommand(on: true, brightness: $0), toLights: dimmable.map(\.id), groupKey: .group("room-brightness-\(room.id.uuidString)")) }
                ))
            }
        }
        .padding(.vertical, 2)
    }
}
