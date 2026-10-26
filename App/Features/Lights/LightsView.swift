import SwiftUI
import LightCore

/// Lights tab: one section per room (all brands mixed), then "Unassigned".
struct LightsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LightID] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Lights")
                .navigationDestination(for: LightID.self) { id in
                    LightDetailView(lightID: id)
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
