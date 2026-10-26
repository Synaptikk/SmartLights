import SwiftUI
import LightCore

// Adapter between the app and `Packages/Onboarding`. All assumptions about the Onboarding
// package's SwiftUI API live in this file so a signature change only breaks here:
//   - `BrandListView(catalog: GuideCatalog, onSelect: (BrandGuide) -> Void)`
//   - `GuideFlowView(guide: BrandGuide, runner: GuideRunner, onOpenGuide:, onFinish:)`
// Checked against the package source: `GuideCatalog.standard`, `BrandGuide` (Identifiable,
// Hashable), `GuideRunner(guide:actionHandler:)`, `GuideActionContext`, `GuideCallback`, `StepAnswer`.

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
            NavigationStack {
                GuideFlowView(
                    guide: active.guide,
                    runner: active.runner,
                    onOpenGuide: { other in open(other) },
                    onFinish: {
                        session = nil
                        Task { await model.refresh() }
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            active.runner.cancelAction()
                            session = nil
                        }
                    }
                }
            }
            .interactiveDismissDisabled(active.runner.isBusy)
        }
    }

    /// Starts (or switches to) a wizard run for `guide`.
    private func open(_ guide: BrandGuide) {
        session?.runner.cancelAction()
        let appModel = model
        session = GuideSession(
            guide: guide,
            runner: GuideRunner(guide: guide) { context in
                try await AddBrandActions.handle(context, model: appModel)
            }
        )
    }
}

/// One wizard run: the guide plus the runner that holds its progress.
private struct GuideSession: Identifiable {
    let id = UUID()
    let guide: BrandGuide
    let runner: GuideRunner
}

/// Default provider callbacks for guide steps (T1.7 refines per brand).
@MainActor
enum AddBrandActions {
    static func handle(_ context: GuideActionContext, model: AppModel) async throws -> StepAnswer {
        guard let brand = context.brand else { return .done }
        let callback = context.callback ?? (context.action == .scan ? GuideCallback.discover : "")

        switch callback {
        case GuideCallback.discover, GuideCallback.localNetworkPermission:
            let devices = try await discover(brand, model: model)
            return callback == GuideCallback.discover ? .discovered(devices) : .done

        case GuideCallback.pair, GuideCallback.login, GuideCallback.importKey:
            let device = try await chooseDevice(brand: brand, context: context, isCloudLogin: callback == GuideCallback.login)
            return .paired(try await model.pair(device, using: context.ui))

        case GuideCallback.verify:
            try await blink(context: context, model: model)
            return .done

        default:
            // Permission prompts (HomeKit, Bluetooth) are triggered by the providers themselves (T1.6).
            return .done
        }
    }

    private static func discover(_ brand: Brand, model: AppModel) async throws -> [DiscoveredDevice] {
        guard let stream = await model.discover(brand: brand) else {
            throw LightCoreError.providerNotRegistered(brand)
        }
        var found: [DiscoveredDevice] = []
        for await device in stream where !found.contains(where: { $0.id == device.id }) {
            found.append(device)
        }
        return found
    }

    private static func chooseDevice(brand: Brand, context: GuideActionContext, isCloudLogin: Bool) async throws -> DiscoveredDevice {
        let devices = discoveredDevices(in: context.answers)
        if devices.count == 1 { return devices[0] }
        if devices.count > 1 {
            let index = try await context.ui.choose("Which device do you want to add?", options: devices.map(\.name))
            return devices[index]
        }
        if isCloudLogin {
            // Cloud brands (AiDot) pair the account; the provider prompts for credentials.
            return DiscoveredDevice(id: "account", brand: brand, name: brand.displayName, method: .cloud)
        }
        throw LightCoreError.unsupported("No \(brand.displayName) device found yet. Run the scan step first.")
    }

    private static func discoveredDevices(in answers: [String: StepAnswer]) -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        for answer in answers.values {
            if case .discovered(let found) = answer { devices += found }
        }
        return devices
    }

    /// Off, short pause, on: lets the user see which light was added.
    private static func blink(context: GuideActionContext, model: AppModel) async throws {
        var paired: PairedDevice?
        for answer in context.answers.values {
            if case .paired(let device) = answer { paired = device }
        }
        guard let id = paired?.lightIDs.first else { return }
        _ = try await model.sendNow(.turnOff, to: id)
        try await Task.sleep(for: .milliseconds(700))
        _ = try await model.sendNow(.turnOn, to: id)
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
