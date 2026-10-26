import SwiftUI
import LightCore

/// Vendor effects (from capabilities) and vendor scenes that include this light.
struct LightEffectsSection: View {
    let light: Light
    var onSelectEffect: (EffectDescriptor) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        if !light.capabilities.effects.isEmpty {
            Section {
                ForEach(light.capabilities.effects) { effect in
                    Button {
                        onSelectEffect(effect)
                    } label: {
                        HStack {
                            Text(effect.name)
                                .foregroundStyle(.primary)
                            if effect.isFast {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(Text("Fast, flashing"))
                            }
                            Spacer()
                            if light.state.effect == effect.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(light.state.effect == effect.id ? .isSelected : [])
                }
            } header: {
                Text("Effects")
            } footer: {
                Text("Choosing a colour or temperature stops the effect.")
            }
        }

        let scenes = model.vendorScenes(for: light.id)
        if !scenes.isEmpty {
            Section("Scenes from \(light.brand.displayName)") {
                ForEach(scenes) { scene in
                    Button {
                        model.recall(scene)
                    } label: {
                        Label(scene.name, systemImage: "sparkles")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityHint(Text("Recalls this scene"))
                }
            }
        }
    }
}

/// Read-only details: brand, maker, model, last seen.
struct LightInfoSection: View {
    let light: Light
    let lastSeen: Date?

    var body: some View {
        Section("About This Light") {
            LabeledContent("Brand", value: light.brand.displayName)
            if let manufacturer = light.manufacturer, !manufacturer.isEmpty {
                LabeledContent("Maker", value: manufacturer)
            }
            if let model = light.model, !model.isEmpty {
                LabeledContent("Model", value: model)
            }
            if let lastSeen {
                LabeledContent("Last Update") {
                    Text(lastSeen, style: .relative)
                }
            }
        }
    }
}
