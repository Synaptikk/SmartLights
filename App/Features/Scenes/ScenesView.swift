import SwiftUI
import LightCore

/// Scenes tab: app scenes (snapshots across brands) and vendor scenes.
struct ScenesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewScene = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.appScenes.isEmpty {
                        Text("No scenes yet. Tap + to save how your lights look right now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.appScenes) { scene in
                        SceneRow(scene: scene, subtitle: "\(scene.lightIDs.count) lights") {
                            model.recall(scene)
                            model.showToast("\(scene.name) recalled")
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.appScenes[$0].id }
                        for id in ids { model.deleteScene(id) }
                    }
                    .onMove { model.moveScenes(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("My Scenes")
                }

                ForEach(vendorBrands, id: \.self) { brand in
                    Section("From \(brand.displayName)") {
                        ForEach(model.vendorScenes.filter { $0.brand == brand }) { scene in
                            SceneRow(scene: scene, subtitle: scene.roomHint) {
                                model.recall(scene)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewScene = true
                    } label: {
                        Label("New Scene", systemImage: "plus")
                    }
                    .disabled(model.lightsByID.isEmpty)
                }
            }
            .sheet(isPresented: $showingNewScene) {
                NewSceneView()
            }
        }
    }

    private var vendorBrands: [Brand] {
        Array(Set(model.vendorScenes.compactMap(\.brand))).sorted()
    }
}

/// A tappable scene row.
struct SceneRow: View {
    let scene: LightScene
    let subtitle: String?
    var onRecall: () -> Void

    var body: some View {
        Button(action: onRecall) {
            HStack {
                Image(systemName: scene.kind == .app ? "square.stack.3d.up.fill" : "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(scene.name)
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(scene.name))
        .accessibilityHint(Text("Recalls this scene"))
    }
}

#if DEBUG
#Preview {
    ScenesView()
        .environment(PreviewRegistry.model())
}
#endif
