import SwiftUI
import LightCore

/// Full controls for one light. Only the controls its capabilities support are shown.
struct LightDetailView: View {
    let lightID: LightID

    @Environment(AppModel.self) private var model
    @State private var selectedMode: ColorControlMode?
    @State private var transition: TransitionOption = .providerDefault
    @State private var pendingFastEffect: EffectDescriptor?

    var body: some View {
        if let light = model.lightsByID[lightID] {
            Form {
                powerSection(light)
                if light.capabilities.supportsBrightness {
                    Section("Brightness") {
                        BrightnessSlider(name: light.name, value: brightnessBinding(light))
                    }
                }
                colorSection(light)
                if light.capabilities.supportsTransition {
                    Section {
                        Picker("Transition", selection: $transition) {
                            ForEach(TransitionOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } footer: {
                        Text("How quickly changes fade in on this light.")
                    }
                }
                LightEffectsSection(light: light) { effect in
                    if effect.isFast {
                        pendingFastEffect = effect
                    } else {
                        send(LightCommand(on: true, effect: effect.id), to: light)
                    }
                }
                roomSection(light)
                LightInfoSection(light: light, lastSeen: model.lastSeen[light.id])
            }
            .navigationTitle(light.name)
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Photosensitivity Warning",
                isPresented: Binding(get: { pendingFastEffect != nil }, set: { if !$0 { pendingFastEffect = nil } }),
                presenting: pendingFastEffect
            ) { effect in
                Button("Start Effect") { send(LightCommand(on: true, effect: effect.id), to: light) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This effect flashes or changes quickly. It may trigger seizures in people with photosensitive epilepsy. Stop it if anyone feels unwell.")
            }
        } else {
            ContentUnavailableView("Light Not Found", systemImage: "lightbulb.slash", description: Text("It may have been removed."))
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func powerSection(_ light: Light) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.lightsByID[lightID]?.state.isOn ?? false },
                set: { send(LightCommand(on: $0), to: light) }
            )) {
                Label {
                    Text("Power")
                } icon: {
                    LightSwatch(light: light).frame(width: 28, height: 28)
                }
            }
            .accessibilityLabel(Text("\(light.name) power"))
            if !light.state.reachable {
                Label("Not responding. Check that it is powered and on your Wi-Fi.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func colorSection(_ light: Light) -> some View {
        let modes = light.capabilities.colorControlModes
        if !modes.isEmpty {
            let mode = effectiveMode(for: light, modes: modes)
            Section("Colour") {
                if modes.count > 1 {
                    Picker("Mode", selection: Binding(get: { mode }, set: { selectedMode = $0 })) {
                        ForEach(modes) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                switch mode {
                case .white:
                    Button {
                        send(LightCommand(on: true, color: light.capabilities.plainWhite), to: light)
                    } label: {
                        Label("Use White", systemImage: "sun.max")
                    }
                case .temperature:
                    KelvinSlider(
                        range: light.capabilities.kelvinRange,
                        kelvin: light.state.kelvin ?? light.capabilities.clampKelvin(2700)
                    ) { kelvin in
                        send(LightCommand(on: true, color: .kelvin(light.capabilities.clampKelvin(kelvin))), to: light)
                    }
                case .color:
                    ColorWheel(hs: light.currentHS) { hs in
                        send(LightCommand(on: true, color: .hs(hs)), to: light)
                    }
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    if let gamut = light.capabilities.gamut, !gamut.contains(ColorMath.hsToXY(light.currentHS)) {
                        Label("This colour is outside what the lamp can show; it uses the closest colour.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func roomSection(_ light: Light) -> some View {
        Section("Room") {
            Picker("Room", selection: Binding(
                get: { model.room(containing: lightID)?.id },
                set: { model.assign(lightID, toRoom: $0) }
            )) {
                Text("None").tag(Room.ID?.none)
                ForEach(model.rooms) { room in
                    Text(room.name).tag(Room.ID?.some(room.id))
                }
            }
        }
    }

    // MARK: Commands

    private func effectiveMode(for light: Light, modes: [ColorControlMode]) -> ColorControlMode {
        if let selectedMode, modes.contains(selectedMode) { return selectedMode }
        return light.currentControlMode ?? modes[0]
    }

    private func brightnessBinding(_ light: Light) -> Binding<Double> {
        Binding(
            get: { model.lightsByID[lightID]?.state.brightness ?? 1 },
            set: { send(LightCommand(on: true, brightness: $0), to: light) }
        )
    }

    private func send(_ command: LightCommand, to light: Light) {
        var command = command
        if light.capabilities.supportsTransition, let duration = transition.duration {
            command.transition = duration
        }
        model.send(command, to: light.id)
    }
}

#if DEBUG
#Preview("Colour bulb") {
    NavigationStack {
        LightDetailView(lightID: PreviewData.hueColor.id)
    }
    .environment(PreviewRegistry.model())
}

#Preview("White ambiance") {
    NavigationStack {
        LightDetailView(lightID: PreviewData.wizTunable.id)
    }
    .environment(PreviewRegistry.model())
}

#Preview("Plug") {
    NavigationStack {
        LightDetailView(lightID: PreviewData.homePlug.id)
    }
    .environment(PreviewRegistry.model())
}
#endif
