#if canImport(Onboarding)
import AiDotKit
import Foundation
import HomeKitProvider
import LightCore
import NetKit
import Observation
import Onboarding
import WiZCodec
import WiZKit

/// A user-facing failure of an Add-flow step (shown under the step by `GuideFlowView`).
struct AddFlowError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Provider callbacks for one wizard run (T1.7). One instance per `GuideRunner`; it remembers
/// what was found, chosen and paired so later steps (pair, key import, verify) build on earlier ones.
///
/// Callbacks (`GuideCallback`):
/// - `discover`: provider discovery (broadcast only when `BroadcastCapability` says it works,
///   cached hosts of paired devices, manual IPs), reconciliation with stored ids, then a
///   multi-select list (`DeviceSelection`) with an "Add by IP address" field. Brands without a
///   separate pair step (WiZ, AiDot) pair the chosen devices right away.
/// - `pair` (Hue): pairs every chosen bridge plus a manual IP from the guide; the provider asks for
///   the link button through `ctx.ui`.
/// - `login` (AiDot): pairs the account placeholder; the provider asks for country/user/password.
/// - `importKey` (WiZ): imports the home signing key from a file or pasted text into the Keychain.
/// - `permission.homeKit`: registers Apple Home and waits for the permission answer.
/// - `permission.localNetwork`: triggers and checks the Local Network prompt.
/// - `verify`: pairs anything still pending, blinks one light, asks the user to confirm.
@MainActor
@Observable
final class AddBrandActions {
    /// The multi-select list currently shown over the wizard (nil when none).
    var selection: DeviceSelection?

    @ObservationIgnored private let model: AppModel
    /// Chosen in the scan step or entered by IP; paired by the next pairing step.
    @ObservationIgnored private var chosen: [DiscoveredDevice] = []
    /// `DiscoveredDevice.id`s paired during this run.
    @ObservationIgnored private var pairedIDs: Set<String> = []
    @ObservationIgnored private(set) var paired: [PairedDevice] = []
    @ObservationIgnored private var consumedManualHosts: Set<String> = []
    @ObservationIgnored private var broadcastAvailable: Bool?

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ context: GuideActionContext) async throws -> StepAnswer {
        guard let brand = context.brand else { return .done }
        switch context.callback ?? Self.defaultCallback(for: context.action) {
        case GuideCallback.localNetworkPermission:
            try await requestLocalNetwork()
            return .done
        case GuideCallback.discover:
            return try await discover(brand, context: context)
        case GuideCallback.pair:
            return try await pairStep(brand, context: context)
        case GuideCallback.login:
            return try await login(brand, context: context)
        case GuideCallback.importKey:
            return try await importKey(brand, context: context)
        case GuideCallback.homeKitPermission:
            try await requestHomeKit()
            return .done
        case GuideCallback.verify:
            return try await verify(brand, context: context)
        default:
            // Bluetooth permission is requested by the providers that need it (phase 3).
            return .done
        }
    }

    private static func defaultCallback(for action: ActionKind) -> String {
        switch action {
        case .scan: GuideCallback.discover
        case .verifyBlink: GuideCallback.verify
        default: ""
        }
    }

    // MARK: Discover + select

    private func discover(_ brand: Brand, context: GuideActionContext) async throws -> StepAnswer {
        let provider = try await provider(for: brand)
        await context.ui.status("Searching for \(brand.displayName) devices…")
        let found = try await runDiscovery(provider, brand: brand, manualHosts: manualHosts(in: context))
        for device in found where device.method == .manual {
            if let host = device.host { consumedManualHosts.insert(host) }
        }
        let known = await ProviderWiring.reconcile(found, in: model)
        let selected = try await select(brand, from: found, alreadyAdded: known, provider: provider)
        for device in selected where !chosen.contains(where: { $0.id == device.id }) {
            chosen.append(device)
        }
        // Brands whose guide has a dedicated pair step (Hue link button) pair there.
        let hasPairStep = context.guide.steps.contains { $0.callback == GuideCallback.pair }
        if !hasPairStep {
            try await pairPending(brand, context: context)
        }
        return .discovered(selected)
    }

    private func runDiscovery(
        _ provider: any LightProvider, brand: Brand, manualHosts: [String], timeout: Duration? = nil
    ) async throws -> [DiscoveredDevice] {
        let options = DiscoveryOptions(
            timeout: timeout ?? Self.discoveryTimeout(brand),
            broadcastAvailable: try await isBroadcastAvailable(brand),
            manualHosts: manualHosts,
            cachedHosts: await ProviderWiring.cachedHosts(for: brand, in: model.deviceStore)
        )
        var found: [DiscoveredDevice] = []
        for await device in await provider.discover(options: options) where !found.contains(where: { $0.id == device.id }) {
            found.append(device)
        }
        try Task.checkCancellation()
        DiagnosticsCollector.shared.note("\(brand.displayName): discovery found \(found.count) device(s)", category: "add")
        return found
    }

    private static func discoveryTimeout(_ brand: Brand) -> Duration {
        switch brand {
        case .wiz: .seconds(20) // subnet sweep without the multicast entitlement
        case .aidot: .seconds(12)
        case .appleHome: .seconds(5)
        default: .seconds(10)
        }
    }

    /// Probes one typed address (manual IP path), nil if no device of `brand` answers.
    private func probe(_ host: String, brand: Brand, provider: any LightProvider) async -> DiscoveredDevice? {
        let options = DiscoveryOptions(timeout: .seconds(8), methods: [.manual], manualHosts: [host])
        for await device in await provider.discover(options: options) {
            return device
        }
        return nil
    }

    private func select(
        _ brand: Brand, from found: [DiscoveredDevice], alreadyAdded: Set<String>, provider: any LightProvider
    ) async throws -> [DiscoveredDevice] {
        guard brand != .appleHome else { return found }
        let request = DeviceSelection(
            brand: brand, devices: found, alreadyAdded: alreadyAdded,
            allowsManualHost: true,
            probe: { [weak self] host in await self?.probe(host, brand: brand, provider: provider) }
        )
        selection = request
        defer { if selection === request { selection = nil } }
        return try await withTaskCancellationHandler {
            try await request.wait()
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    // MARK: Pairing

    private func pairStep(_ brand: Brand, context: GuideActionContext) async throws -> StepAnswer {
        let new = try await pairPending(brand, context: context)
        if let last = new.last { return .paired(last) }
        if let last = paired.last(where: { $0.brand == brand }) { return .paired(last) }
        throw AddFlowError("Nothing to add yet. Run Scan and pick a device, or enter its IP address.")
    }

    /// Pairs every chosen device not paired yet, plus manual IPs typed into the guide.
    /// Failures of single devices are recorded; throws only if every attempt failed.
    @discardableResult
    private func pairPending(_ brand: Brand, context: GuideActionContext) async throws -> [PairedDevice] {
        let provider = try await provider(for: brand)
        for host in manualHosts(in: context) where !consumedManualHosts.contains(host) {
            consumedManualHosts.insert(host)
            await context.ui.status("Checking \(host)…")
            let device = await probe(host, brand: brand, provider: provider)
                ?? DiscoveredDevice(id: "ip:\(host)", brand: brand, name: host, host: host, method: .manual)
            if !chosen.contains(where: { $0.id == device.id }) { chosen.append(device) }
        }

        var added: [PairedDevice] = []
        var firstError: (any Error)?
        for device in chosen where device.brand == brand && !pairedIDs.contains(device.id) {
            await context.ui.status("Adding \(device.name)…")
            do {
                let result = try await model.pair(device, using: context.ui)
                pairedIDs.insert(device.id)
                paired.append(result)
                added.append(result)
                DiagnosticsCollector.shared.note("\(brand.displayName): added \(result.name)", category: "add")
            } catch {
                if Self.isCancellation(error) { throw error }
                firstError = firstError ?? error
                model.record(error: "\(brand.displayName) \(device.name): \(AppModel.message(for: error))")
            }
        }
        if added.isEmpty, let firstError { throw firstError }
        return added
    }

    private func login(_ brand: Brand, context: GuideActionContext) async throws -> StepAnswer {
        let provider = try await provider(for: brand)
        // Cloud brands pair the account; the provider asks for credentials through `ctx.ui`
        // (AiDot: country, e-mail, password) and returns an account-level PairedDevice.
        var account = DiscoveredDevice(id: "account", brand: brand, name: "\(brand.displayName) account", method: .cloud)
        if provider is AiDotProvider { account = AiDotProvider.accountPlaceholder() }
        let result = try await model.pair(account, using: context.ui)
        pairedIDs.insert(account.id)
        paired.append(result)
        return .paired(result)
    }

    // MARK: WiZ key

    private func importKey(_ brand: Brand, context: GuideActionContext) async throws -> StepAnswer {
        guard brand == .wiz, let wiz = try await provider(for: brand) as? WiZProvider else { return .done }
        let ui = context.ui
        let options = ["Import the key file exported from the WiZ app", "Paste the key"]
        let key: WiZSigningKey
        do {
            if try await ui.choose("How do you want to add your WiZ key?", options: options) == 0 {
                key = try WiZSigningKey.parseImport(
                    try await ui.importFile(WiZPairingText.importFile, allowedTypes: WiZPairingText.importTypes))
            } else {
                key = try WiZSigningKey.parseImport(try await ui.secureText(WiZPairingText.pasteKey))
            }
        } catch let error as WiZSigningKey.ImportError {
            throw AddFlowError(error.description)
        }
        try await wiz.setSigningKey(key)
        if let account = await wiz.account {
            try? await model.deviceStore.save(account)
        }
        model.reauthenticationNeeded.remove(.wiz)
        DiagnosticsCollector.shared.note("WiZ: signing key stored", category: "add")
        // Bulbs added after the key is stored negotiate signing without prompting.
        let new = try await pairPending(brand, context: context)
        return new.last.map(StepAnswer.paired) ?? .done
    }

    // MARK: Permissions

    private func requestHomeKit() async throws {
        guard let homeKit = await ProviderWiring.ensureRegistered(.appleHome, in: model, refresh: false) as? HomeKitProvider else {
            throw AddFlowError("Apple Home is not available on this device.")
        }
        switch await homeKit.requestAccess() {
        case .authorized:
            let marker = ProviderAccount(id: ProviderWiring.appleHomeAccountID, brand: .appleHome, displayName: "Apple Home")
            try? await model.deviceStore.save(marker)
            await model.refresh()
        case .notDetermined:
            throw AddFlowError("Apple Home has not answered yet. Allow access when iOS asks, then tap the button again.")
        default: // denied, restricted, unavailable
            await model.registry.unregister(.appleHome)
            throw AddFlowError(HomeKitProvider.accessDeniedMessage)
        }
    }

    private func requestLocalNetwork() async throws {
        LocalNetworkPermissionProbe.triggerPrompt()
        if await LocalNetworkPermissionProbe.check(timeout: .seconds(10)) == .denied {
            throw Self.localNetworkDenied
        }
    }

    private static let localNetworkDenied = AddFlowError(
        "Local Network access is off. Turn on Settings > Privacy & Security > Local Network > SmartLights.")

    private func isBroadcastAvailable(_ brand: Brand) async throws -> Bool {
        guard brand != .appleHome else { return false }
        if let broadcastAvailable { return broadcastAvailable }
        let status = await BroadcastCapability.detect()
        DiagnosticsCollector.shared.note("Broadcast capability: \(status.rawValue)", category: "add")
        if status == .localNetworkDenied { throw Self.localNetworkDenied }
        let available = status == .entitled
        broadcastAvailable = available
        if let aidot = await model.registry.provider(for: .aidot) as? AiDotProvider {
            await aidot.setBroadcastAvailable(available)
        }
        return available
    }

    // MARK: Verify

    private func verify(_ brand: Brand, context: GuideActionContext) async throws -> StepAnswer {
        try await pairPending(brand, context: context)
        var ids = paired.filter { $0.brand == brand }.flatMap(\.lightIDs).filter { model.lightsByID[$0] != nil }
        if ids.isEmpty {
            await model.refresh()
            let bridgeIDs = Set(paired.filter { $0.brand == brand }.map { $0.id.lowercased() })
            let lights = model.lights.filter { $0.brand == brand }
            // Hue bridges list no light ids; prefer lights of the bridges added in this run.
            let ofBridges = lights.filter { light in bridgeIDs.contains { light.id.stableId.lowercased().contains($0) } }
            ids = (ofBridges.isEmpty ? lights : ofBridges).map(\.id)
        }
        guard !ids.isEmpty else {
            throw AddFlowError("No \(brand.displayName) light is loaded yet. Add a device first, then try again.")
        }
        let target: LightID
        if ids.count == 1 {
            target = ids[0]
        } else {
            let names = ids.map { model.lightsByID[$0]?.name ?? $0.description }
            target = ids[try await context.ui.choose("Which light should blink?", options: names)]
        }
        let name = model.lightsByID[target]?.name ?? target.description
        await context.ui.status("Blinking \(name)…")
        try await blink(target, brand: brand)
        guard try await context.ui.confirm("Did \(name) blink?") else {
            throw AddFlowError("\(name) did not respond. Check that it is powered and on the same Wi-Fi, then try again (see Troubleshooting).")
        }
        return .confirmed(true)
    }

    private func blink(_ id: LightID, brand: Brand) async throws {
        if brand == .wiz, let wiz = await model.registry.provider(for: .wiz) as? WiZProvider {
            try await wiz.identify(id)
            return
        }
        let wasOn = model.lightsByID[id]?.state.isOn ?? true
        for _ in 0..<2 {
            _ = try await model.sendNow(wasOn ? .turnOff : .turnOn, to: id)
            try await Task.sleep(for: .milliseconds(600))
            _ = try await model.sendNow(wasOn ? .turnOn : .turnOff, to: id)
            try await Task.sleep(for: .milliseconds(600))
        }
    }

    // MARK: Helpers

    private func provider(for brand: Brand) async throws -> any LightProvider {
        guard let provider = await ProviderWiring.ensureRegistered(brand, in: model) else {
            throw AddFlowError("\(brand.displayName) is not available in this build yet.")
        }
        return provider
    }

    /// IP addresses typed into the guide's "Add by IP" steps.
    private func manualHosts(in context: GuideActionContext) -> [String] {
        context.guide.steps.compactMap { step -> String? in
            guard case .action(.text(let field), _) = step.kind, field.contentType == .ipAddress,
                  case .text(let value)? = context.answers[step.id] else { return nil }
            let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? nil : host
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? LightCoreError) == .userCancelled
    }
}
#endif
