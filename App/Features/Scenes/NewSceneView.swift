import SwiftUI
import LightCore

/// Creates an app scene from the current state of the selected lights.
struct NewSceneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: Set<LightID>

    init(preselected: Set<LightID> = []) {
        _selection = State(initialValue: preselected)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Scene name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Saves the current power, brightness and colour of the selected lights.")
                }
                Section {
                    ForEach(model.sortedLights) { light in
                        let isSelected = selection.contains(light.id)
                        Button {
                            toggleSelection(light.id)
                        } label: {
                            HStack {
                                LightSwatch(light: light).frame(width: 24, height: 24)
                                Text(light.name).foregroundStyle(.primary)
                                BrandBadge(light: light)
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(Text(light.name))
                        .accessibilityValue(Text(light.stateSummary))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                } header: {
                    HStack {
                        Text("Lights")
                        Spacer()
                        Button(selection.count == model.lightsByID.count ? "Select None" : "Select All") {
                            selection = selection.count == model.lightsByID.count ? [] : Set(model.lightsByID.keys)
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("New Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let ordered = model.sortedLights.map(\.id).filter(selection.contains)
                        model.createSnapshotScene(name: name, lightIDs: ordered)
                        dismiss()
                    }
                    .disabled(selection.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func toggleSelection(_ id: LightID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

#if DEBUG
#Preview {
    NewSceneView()
        .environment(PreviewRegistry.model())
}
#endif
