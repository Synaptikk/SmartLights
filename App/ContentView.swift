import SwiftUI

/// Root tab container: Lights, Scenes, Add, Settings. Shows the model's toast on top.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Lights", systemImage: "lightbulb.2") {
                LightsView()
            }
            Tab("Scenes", systemImage: "square.stack.3d.up") {
                ScenesView()
            }
            Tab("Add", systemImage: "plus.circle") {
                AddView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
            // Brands whose credentials were rejected (ProviderEvent.needsReauthentication).
            .badge(model.reauthenticationNeeded.count)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.dismissToast(id: toast.id) }
            }
        }
        .animation(.snappy, value: model.toast)
        .task(id: model.toast?.id) {
            guard let toast = model.toast else { return }
            AccessibilityNotification.Announcement(toast.message).post()
            try? await Task.sleep(for: .seconds(toast.isError ? 5 : 3))
            model.dismissToast(id: toast.id)
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environment(PreviewRegistry.model())
}
#endif
