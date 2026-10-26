import SwiftUI
import LightCore

/// Settings > Rooms: create, rename, reorder and delete rooms.
struct RoomsView: View {
    @Environment(AppModel.self) private var model
    @State private var addingRoom = false
    @State private var newRoomName = ""

    var body: some View {
        List {
            ForEach(model.rooms) { room in
                NavigationLink {
                    RoomEditorView(roomID: room.id)
                } label: {
                    LabeledContent(room.name, value: "\(room.lightIDs.count) lights")
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { model.rooms[$0].id }
                for id in ids { model.deleteRoom(id) }
            }
            .onMove { model.moveRooms(fromOffsets: $0, toOffset: $1) }
        }
        .overlay {
            if model.rooms.isEmpty {
                ContentUnavailableView(
                    "No Rooms",
                    systemImage: "square.split.2x2",
                    description: Text("Rooms group lights from any brand. Tap + to add one.")
                )
            }
        }
        .navigationTitle("Rooms")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newRoomName = ""
                    addingRoom = true
                } label: {
                    Label("Add Room", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .alert("New Room", isPresented: $addingRoom) {
            TextField("Name", text: $newRoomName)
            Button("Add") {
                let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { model.addRoom(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Rename a room and choose its lights.
struct RoomEditorView: View {
    let roomID: Room.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var room: Room? { model.rooms.first { $0.id == roomID } }

    var body: some View {
        if let room {
            Form {
                Section("Name") {
                    TextField("Room name", text: $name)
                        .onSubmit { model.renameRoom(roomID, to: name) }
                }
                Section {
                    ForEach(model.sortedLights) { light in
                        Toggle(isOn: Binding(
                            get: { model.rooms.first { $0.id == roomID }?.lightIDs.contains(light.id) ?? false },
                            set: { model.assign(light.id, toRoom: $0 ? roomID : nil) }
                        )) {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(light.name)
                                    BrandBadge(light: light)
                                }
                                if let other = model.room(containing: light.id), other.id != roomID {
                                    Text("In \(other.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Lights")
                } footer: {
                    Text("A light can be in one room. Adding it here moves it from its current room.")
                }
                Section {
                    Button("Delete Room", role: .destructive) {
                        model.deleteRoom(roomID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = room.name }
            .onDisappear { model.renameRoom(roomID, to: name) }
        } else {
            ContentUnavailableView("Room Deleted", systemImage: "square.split.2x2")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RoomsView()
    }
    .environment(PreviewRegistry.model())
}
#endif
