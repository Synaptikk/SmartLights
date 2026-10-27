import Foundation
import HomeKitProvider
import HueKit
import LightCore
import NetKit
import WiZKit
import AiDotKit

/// Creates the brand providers, restores what the user paired earlier and hooks them into the
/// app lifecycle (T1.6).
///
/// - Launch (`registerAll`): Hue and WiZ are always registered (they cost nothing until a bridge
///   or bulb exists). Apple Home and AiDot are registered only once the user has set them up
///   (HomeKit would otherwise show its permission prompt at launch; AiDot needs an account).
///   The Add flow registers them on demand through `ensureRegistered(_:in:)`.
/// - Restore: Hue bridges via `addBridge`, WiZ bulbs via `restore`, the AiDot account via the
///   provider's initialiser. Secrets stay in `model.secretStore`; providers read them on use.
/// - Foreground/background: `ProviderLifecycle` (driven by `AppModel.scenePhaseChanged`)
///   reconnects Hue SSE, re-registers WiZ push, reopens AiDot TCP sessions, and stops them again.
///
/// Brands that already have a provider in the registry are left alone, so previews and tests
/// that register `FakeLightProvider`s before `AppModel.start()` keep their fakes.
enum ProviderWiring {
    /// Marker account saved once the user allowed Apple Home in the Add flow.
    static let appleHomeAccountID = "applehome"

    private static let log = Log(package: "app", category: "wiring")

    @MainActor
    static func registerAll(in model: AppModel) async {
        let store = model.deviceStore
        var devices: [PairedDevice] = []
        var accounts: [ProviderAccount] = []
        do {
            devices = try await store.pairedDevices()
            accounts = try await store.accounts()
        } catch {
            model.record(error: "Could not read paired devices: \(error.localizedDescription)")
        }

        if await model.registry.provider(for: .hue) == nil {
            let hue = makeHue(model: model)
            let bridges = devices.filter { $0.brand == .hue }
            for bridge in bridges { await hue.addBridge(bridge) }
            await install(hue, in: model)
            note("Hue: restored \(bridges.count) bridge(s)")
        }

        if await model.registry.provider(for: .wiz) == nil {
            let wiz = makeWiZ(model: model)
            let bulbs = devices.filter { $0.brand == .wiz }
            await wiz.restore(bulbs)
            await install(wiz, in: model)
            note("WiZ: restored \(bulbs.count) bulb(s)")
        }

        if accounts.contains(where: { $0.brand == .appleHome }), await model.registry.provider(for: .appleHome) == nil {
            await install(HomeKitProvider.live(), in: model)
            note("Apple Home: registered")
        }

        if let account = accounts.first(where: { $0.brand == .aidot }), await model.registry.provider(for: .aidot) == nil {
            let aidot = AiDotProvider(account: account, secretStore: model.secretStore)
            await install(aidot, in: model)
            // Users with an AiDot account already granted Local Network access, so this probe is
            // silent; it runs off the launch path.
            Task { await aidot.setBroadcastAvailable(await BroadcastCapability.detect() == .entitled) }
            note("AiDot: restored account")
        }
    }

    /// The provider for `brand`, creating and registering it if the brand is supported but not
    /// registered yet (Add flow). nil for brands this build cannot control.
    @MainActor
    @discardableResult
    static func ensureRegistered(_ brand: Brand, in model: AppModel, refresh: Bool = true) async -> (any LightProvider)? {
        if let existing = await model.registry.provider(for: brand) { return existing }
        let provider: (any LightProvider)?
        switch brand {
        case .hue:
            provider = makeHue(model: model)
        case .wiz:
            provider = makeWiZ(model: model)
        case .appleHome:
            provider = HomeKitProvider.live()
        case .aidot:
            // No account yet: the Add flow's login step signs in through `pair`.
            provider = AiDotProvider(secretStore: model.secretStore)
        default:
            provider = nil
        }
        guard let provider else { return nil }
        await install(provider, in: model)
        if refresh { await model.refresh() }
        return provider
    }

    /// Discovery hints for `brand`: previously known hosts of paired devices (ids stay authoritative).
    static func cachedHosts(for brand: Brand, in store: any DeviceStore) async -> [String] {
        let devices = (try? await store.pairedDevices()) ?? []
        return Array(Set(devices.filter { $0.brand == brand }.compactMap(\.hostHint))).sorted()
    }

    /// Reconciles discovery results with stored devices: a known id at a new address updates the
    /// stored host hint (and the Hue provider's endpoint). Returns the ids already paired.
    @MainActor
    @discardableResult
    static func reconcile(_ found: [DiscoveredDevice], in model: AppModel) async -> Set<String> {
        let paired = (try? await model.deviceStore.pairedDevices()) ?? []
        var known: Set<String> = []
        for device in found {
            guard var stored = paired.first(where: { $0.brand == device.brand && matches($0.id, device) }) else { continue }
            known.insert(device.id)
            guard let host = device.host, host != stored.hostHint else { continue }
            stored.hostHint = host
            stored.lastSeen = Date()
            try? await model.deviceStore.save(stored)
            if device.brand == .hue, let hue = await model.registry.provider(for: .hue) as? HueProvider {
                await hue.updateHost(bridgeID: stored.id, host: host, port: device.port)
            }
            note("\(device.brand.displayName): \(stored.name) moved to a new address")
        }
        return known
    }

    private static func matches(_ storedID: String, _ device: DiscoveredDevice) -> Bool {
        let normalize = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let id = normalize(storedID)
        return id == normalize(device.id) || device.macAddress.map(normalize) == id
    }

    // MARK: Construction

    @MainActor
    private static func makeHue(model: AppModel) -> HueProvider {
        HueProvider(secrets: model.secretStore, pinStore: KeychainTOFUPinStore())
    }

    @MainActor
    private static func makeWiZ(model: AppModel) -> WiZProvider {
        WiZProvider(secrets: model.secretStore)
    }

    /// Registers `provider` with the registry (without a refresh) and installs its lifecycle hooks.
    @MainActor
    private static func install(_ provider: any LightProvider, in model: AppModel) async {
        await model.registry.register(provider)
        if let hooks = hooks(for: provider) {
            model.providerLifecycle.install(hooks)
        }
    }

    private static func hooks(for provider: any LightProvider) -> ProviderLifecycle.Hooks? {
        if let hue = provider as? HueProvider {
            return .init(
                brand: .hue,
                activate: { await hue.connectEventStreams() },
                deactivate: { await hue.disconnectEventStreams() })
        }
        if let wiz = provider as? WiZProvider {
            return .init(brand: .wiz, activate: { await wiz.start() }, deactivate: { await wiz.stop() })
        }
        if let aidot = provider as? AiDotProvider {
            return .init(brand: .aidot, activate: { await aidot.start() }, deactivate: { await aidot.stop() })
        }
        // HomeKit keeps its own connection; nothing to do on scene changes.
        return nil
    }

    @MainActor
    private static func note(_ message: String) {
        log.info(message)
        DiagnosticsCollector.shared.note(message, category: "wiring")
    }
}

/// Starts providers' live connections while the app is in the foreground and stops them in the
/// background. Owned by `AppModel` (`providerLifecycle`), driven by `scenePhaseChanged`.
@MainActor
final class ProviderLifecycle {
    struct Hooks: Sendable {
        let brand: Brand
        let activate: @Sendable () async -> Void
        let deactivate: @Sendable () async -> Void
    }

    /// Short `.inactive` phases (Control Center, app switcher peeks) do not tear connections down.
    static let backgroundGrace: Duration = .seconds(2)

    private var hooks: [Brand: Hooks] = [:]
    private var transition: Task<Void, Never>?
    /// The app launches in the foreground.
    private(set) var isActive = true

    nonisolated init() {}

    /// Adds (or replaces) a provider's hooks; activates it right away while in the foreground.
    func install(_ hooks: Hooks) {
        self.hooks[hooks.brand] = hooks
        if isActive {
            Task { await hooks.activate() }
        }
    }

    func setActive(_ active: Bool) {
        let all = Array(hooks.values)
        transition?.cancel()
        if active {
            isActive = true
            // Activation is idempotent for every provider; re-running it lets dropped sockets recover.
            transition = Task {
                await withTaskGroup(of: Void.self) { group in
                    for hook in all { group.addTask { await hook.activate() } }
                }
            }
        } else {
            isActive = false
            transition = Task {
                try? await Task.sleep(for: Self.backgroundGrace)
                guard !Task.isCancelled else { return }
                for hook in all { await hook.deactivate() }
            }
        }
    }
}
