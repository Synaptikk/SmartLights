import SwiftUI

/// Placeholder for Settings > Diagnostics. Task T0.7 replaces the body of this
/// view (keep the type name `DiagnosticsView` so SettingsView keeps compiling).
struct DiagnosticsView: View {
    var body: some View {
        ContentUnavailableView(
            "Diagnostics",
            systemImage: "stethoscope",
            description: Text("Network self-test and log export are coming soon.")
        )
        .navigationTitle("Diagnostics")
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
