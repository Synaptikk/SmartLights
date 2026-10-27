import SwiftUI
import LightCore

/// Creates a group (`groupID == nil`) or edits one: name, lights from any brand, transition.
/// Changes apply on **Save**.
struct GroupEditorView: View {
    var groupID: LightGroup.ID?
    /// Called with the saved group's id.
    var onSave: (LightGroup.ID) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: [LightID] = []
    @State private var transition: TransitionOption = .providerDefault
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Group name", text: $name)
            }
            Section {
                ForEach(lightSections) { section in
                    if !section.title.isEmpty {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.lights) { light in
                        Toggle(isOn: membership(light.id)) {
                            HStack {
                                Text(light.name)
                                BrandBadge(light: light)
                            }
                        }
                    }
                }
            } header: {
                Text("Lights (\(selected.count))")
            } footer: {
                Text("Mix lights from any brands. A light can be in several groups and stays in its room.")
            }
            Section {
                Picker("Transition", selection: $transition) {
                    ForEach(TransitionOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } footer: {
                Text("How quickly every change to this group fades in, on lights that support fades.")
            }
        }
        .navigationTitle(groupID == nil ? "New Group" : "Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private struct LightSection: Identifiable {
        var id: String
        var title: String
        var lights: [Light]
    }

    /// All lights, by room (rooms in display order, then unassigned).
    private var lightSections: [LightSection] {
        var sections = model.rooms.map { LightSection(id: $0.id.uuidString, title: $0.name, lights: model.lights(inRoom: $0.id)) }
        sections.append(LightSection(id: "unassigned", title: model.rooms.isEmpty ? "" : "Other", lights: model.unassignedLights))
        return sections.filter { !$0.lights.isEmpty }
    }

    private func membership(_ id: LightID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                selected.removeAll { $0 == id }
                if isOn { selected.append(id) }
            }
        )
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let groupID, let group = model.group(groupID) else { return }
        name = group.name
        selected = group.lightIDs
        transition = TransitionOption(milliseconds: group.transitionMilliseconds)
    }

    private func save() {
        if let groupID, model.group(groupID) != nil {
            model.renameGroup(groupID, to: trimmedName)
            model.setLights(selected, forGroup: groupID)
            model.setTransition(milliseconds: transition.milliseconds, forGroup: groupID)
            onSave(groupID)
        } else {
            let group = model.addGroup(named: trimmedName, lightIDs: selected, transitionMilliseconds: transition.milliseconds)
            onSave(group.id)
        }
        dismiss()
    }
}

#if DEBUG
#Preview("New") {
    NavigationStack {
        GroupEditorView()
    }
    .environment(PreviewRegistry.model())
}
#endif
