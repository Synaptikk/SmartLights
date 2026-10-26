import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Home") {
                    NavigationLink {
                        RoomsView()
                    } label: {
                        LabeledContent {
                            Text("\(model.rooms.count)")
                        } label: {
                            Label("Rooms", systemImage: "square.split.2x2")
                        }
                    }
                }
                Section("Support") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    // Required by the Hue developer terms.
                    Text("SmartLights is not a Signify app and is not affiliated with or endorsed by Signify or Philips Hue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(PreviewRegistry.model())
}
#endif
