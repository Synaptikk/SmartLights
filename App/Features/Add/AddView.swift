import SwiftUI

/// Add tab: hosts the onboarding wizard (see `AddBrandView`, the only file that touches the
/// Onboarding package's views).
struct AddView: View {
    var body: some View {
        NavigationStack {
            AddBrandView()
        }
    }
}

#if DEBUG
#Preview {
    AddView()
        .environment(PreviewRegistry.model())
}
#endif
