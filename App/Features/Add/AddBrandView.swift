import SwiftUI
import LightCore

// Adapter between the app and `Packages/Onboarding`. All assumptions about the Onboarding
// package's SwiftUI API live in this file so a signature change only breaks here:
//   - `BrandListView(catalog: GuideCatalog, onSelect: (BrandGuide) -> Void)`
//   - `GuideFlowView(guide: BrandGuide, runner: GuideRunner, onOpenGuide:, onFinish:)`
// Checked against the package source: `GuideCatalog.standard`, `BrandGuide` (Identifiable,
// Hashable), `GuideRunner(guide:actionHandler:)`, `GuideActionContext`, `GuideCallback`, `StepAnswer`.
// Provider callbacks live in `AddBrandActions`; the scan result picker in `DeviceSelectionView`.

#if canImport(Onboarding)
import Onboarding

struct AddBrandView: View {
    @Environment(AppModel.self) private var model
    @State private var session: GuideSession?

    var body: some View {
        BrandListView(catalog: GuideCatalog.standard) { guide in
            open(guide)
        }
        .sheet(item: $session) { active in
            GuideSessionView(
                session: active,
                actions: active.actions,
                onOpenGuide: { other in open(other) },
                onClose: { finished in
                    if !finished { active.runner.cancelAction() }
                    session = nil
                    Task { await model.refresh() }
                }
            )
            .interactiveDismissDisabled(active.runner.isBusy)
        }
    }

    /// Starts (or switches to) a wizard run for `guide`.
    private func open(_ guide: BrandGuide) {
        session?.runner.cancelAction()
        let actions = AddBrandActions(model: model)
        session = GuideSession(
            guide: guide,
            runner: GuideRunner(guide: guide) { context in
                try await actions.handle(context)
            },
            actions: actions
        )
    }
}

/// One wizard run: the guide, the runner that holds its progress and the provider callbacks.
private struct GuideSession: Identifiable {
    let id = UUID()
    let guide: BrandGuide
    let runner: GuideRunner
    let actions: AddBrandActions
}

/// The wizard sheet plus the device picker that `AddBrandActions` raises after a scan.
private struct GuideSessionView: View {
    let session: GuideSession
    let actions: AddBrandActions
    let onOpenGuide: @MainActor (BrandGuide) -> Void
    /// `true` when the guide finished, `false` when closed early.
    let onClose: @MainActor (Bool) -> Void

    var body: some View {
        NavigationStack {
            GuideFlowView(
                guide: session.guide,
                runner: session.runner,
                onOpenGuide: onOpenGuide,
                onFinish: { onClose(true) }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose(false) }
                }
            }
        }
        .sheet(item: selectionBinding) { selection in
            DeviceSelectionView(selection: selection)
        }
    }

    /// Dismissing the picker any other way than its buttons counts as cancel, so the waiting
    /// step never hangs.
    private var selectionBinding: Binding<DeviceSelection?> {
        Binding(
            get: { actions.selection },
            set: { newValue in
                if newValue == nil { actions.selection?.cancel() }
            }
        )
    }
}

#else

/// Fallback while the Onboarding package is not linked: lists the phase-1 brands.
struct AddBrandView: View {
    var body: some View {
        List {
            Section {
                ForEach([Brand.hue, .wiz, .aidot, .appleHome], id: \.self) { brand in
                    Label(brand.displayName, systemImage: "lightbulb")
                }
            } footer: {
                Text("Step-by-step setup guides are coming in a later build.")
            }
        }
    }
}

#endif

#if DEBUG
#Preview {
    NavigationStack {
        AddBrandView()
    }
    .environment(PreviewRegistry.model())
}
#endif
