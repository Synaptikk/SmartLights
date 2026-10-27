import SwiftUI
import LightCore

/// Controls for one cross-brand group: power, brightness, colour/temperature, the group's
/// transition, Light Sync and its member lights.
struct GroupDetailView: View {
    let groupID: LightGroup.ID
    var onOpenLight: (LightID) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ColorControlMode?
    @State private var editing = false

    var body: some View {
        if let group = model.group(groupID) {
            let members = model.lights(inGroup: groupID)
            Form {
                if members.isEmpty {
                    Section {
                        Text("No lights in this group yet. Tap **Edit** to choose lights from any brand.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    powerSection(group, members: members)
                    colorSection(group, members: members)
                }
                transitionSection(group)
                syncSection(group)
                membersSection(members)
                Section {
                    Button("Delete Group", role: .destructive) {
                        model.deleteGroup(groupID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    GroupEditorView(groupID: groupID)
                }
            }
        } else {
            ContentUnavailableView("Group Deleted", systemImage: "square.grid.2x2")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func powerSection(_ group: LightGroup, members: [Light]) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.isAnyOn(inGroup: groupID) },
                set: { model.setPower($0, forGroup: groupID) }
            )) {
                Label("Power", systemImage: "power")
            }
            .accessibilityLabel(Text("\(group.name) power"))
            if members.contains(where: { $0.capabilities.supportsBrightness }) {
                BrightnessSlider(name: group.name, value: Binding(
                    get: { model.averageBrightness(inGroup: groupID) },
                    set: { model.setBrightness($0, forGroup: groupID) }
                ))
            }
            let unreachable = members.filter { !$0.state.reachable }
            if !unreachable.isEmpty {
                Label("\(unreachable.map(\.name).joined(separator: ", ")) not responding.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func colorSection(_ group: LightGroup, members: [Light]) -> some View {
        let modes = Self.colorModes(for: members)
        if !modes.isEmpty {
            let mode = selectedMode.flatMap { modes.contains($0) ? $0 : nil } ?? modes[0]
            Section {
                if modes.count > 1 {
                    Picker("Mode", selection: Binding(get: { mode }, set: { selectedMode = $0 })) {
                        ForEach(modes) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                switch mode {
                case .temperature:
                    let range = Self.kelvinRange(for: members)
                    KelvinSlider(range: range, kelvin: Self.currentKelvin(members, range: range)) { kelvin in
                        model.setKelvin(kelvin, forGroup: groupID)
                    }
                case .color, .white:
                    ColorWheel(hs: members.first { $0.capabilities.supportsColor }?.currentHS ?? HS(h: 0, s: 0)) { hs in
                        model.setColor(hs, forGroup: groupID)
                    }
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } header: {
                Text("Colour")
            } footer: {
                Text("Each light shows the closest colour or temperature it supports.")
            }
        }
    }

    private func transitionSection(_ group: LightGroup) -> some View {
        Section {
            Picker("Transition", selection: Binding(
                get: { TransitionOption(milliseconds: group.transitionMilliseconds) },
                set: { model.setTransition(milliseconds: $0.milliseconds, forGroup: groupID) }
            )) {
                ForEach(TransitionOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } footer: {
            Text("How quickly every change to this group fades in, on lights that support fades.")
        }
    }

    private func syncSection(_ group: LightGroup) -> some View {
        Section {
            Picker("Follow", selection: Binding(
                get: { group.syncSourceID },
                set: { _ = model.setSyncSource($0, forGroup: groupID) }
            )) {
                Text("Off").tag(LightID?.none)
                ForEach(model.sortedLights) { light in
                    Text("\(light.name) (\(light.badgeText))").tag(LightID?.some(light.id))
                }
            }
        } header: {
            Text("Light Sync")
        } footer: {
            Text("Mirrors one light to the rest of the group: when it changes, from this app or its own app, the other lights follow.")
        }
    }

    @ViewBuilder
    private func membersSection(_ members: [Light]) -> some View {
        if !members.isEmpty {
            Section("Lights") {
                ForEach(members) { light in
                    LightRow(light: light) { onOpenLight(light.id) }
                }
            }
        }
    }

    // MARK: Helpers

    /// Temperature if any member has it, colour if any member has it (white-only groups get none).
    static func colorModes(for lights: [Light]) -> [ColorControlMode] {
        var modes: [ColorControlMode] = []
        if lights.contains(where: { $0.capabilities.supportsColorTemp }) { modes.append(.temperature) }
        if lights.contains(where: { $0.capabilities.supportsColor }) { modes.append(.color) }
        return modes
    }

    /// Union of the members' Kelvin ranges.
    static func kelvinRange(for lights: [Light]) -> ClosedRange<Int> {
        let ranges = lights.filter { $0.capabilities.supportsColorTemp }.map(\.capabilities.kelvinRange)
        guard let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() else { return 2000...6535 }
        return low...high
    }

    static func currentKelvin(_ lights: [Light], range: ClosedRange<Int>) -> Int {
        let kelvin = lights.first { $0.state.colorMode == .colorTemp && $0.state.kelvin != nil }?.state.kelvin ?? 2700
        return min(max(kelvin, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
#Preview {
    let model = PreviewRegistry.model()
    NavigationStack {
        GroupDetailView(groupID: PreviewData.everywhere.id) { _ in }
    }
    .environment(model)
}
#endif
