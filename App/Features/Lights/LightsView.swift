import SwiftUI
import LightCore

/// Lights tab: cross-brand groups, then one section per room (all brands mixed), then "Unassigned".
struct LightsView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var creatingGroup = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Lights")
                .navigationDestination(for: LightID.self) { id in
                    LightDetailView(lightID: id)
                }
                .navigationDestination(for: LightGroup.ID.self) { id in
                    GroupDetailView(groupID: id) { path.append($0) }
                }
                .toolbar {
                    if !model.lightsByID.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                creatingGroup = true
                            } label: {
                                Label("New Group", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    }
                }
                .sheet(isPresented: $creatingGroup) {
                    NavigationStack {
                        GroupEditorView { path.append($0) }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.lightsByID.isEmpty {
            if model.isLoading {
                ProgressView("Loading lights")
            } else {
                ContentUnavailableView(
                    "No Lights Yet",
                    systemImage: "lightbulb.2",
                    description: Text("Use the Add tab to connect a brand. Lights from every brand show up here, grouped by room.")
                )
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !model.groups.isEmpty {
                Section {
                    ForEach(model.groups) { group in
                        GroupControlRow(group: group) { path.append(group.id) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.groups[$0].id }
                        for id in ids { model.deleteGroup(id) }
                    }
                    .onMove { model.moveGroups(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Groups")
                } footer: {
                    Text("Groups mix lights from any brands; every light gets the same change at the same time.")
                }
            }
            ForEach(model.rooms) { room in
                let members = model.lights(inRoom: room.id)
                if !members.isEmpty {
                    Section {
                        RoomControlRow(room: room, lights: members)
                        ForEach(members) { light in
                            LightRow(light: light) { path.append(light.id) }
                        }
                    } header: {
                        Text(room.name)
                    }
                }
            }
            let unassigned = model.unassignedLights
            if !unassigned.isEmpty {
                Section("Unassigned") {
                    ForEach(unassigned) { light in
                        LightRow(light: light) { path.append(light.id) }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }
}

#if DEBUG
#Preview("Lights") {
    LightsView()
        .environment(PreviewRegistry.model())
}

#Preview("Empty") {
    LightsView()
        .environment(PreviewRegistry.emptyModel())
}
#endif
