import AiDotKit
import DirigeraProvider
import ElgatoProvider
import Foundation
import GoveeProvider
import HomeAssistantKit
import HomeKitProvider
import HueKit
import LIFXProvider
import LightCore
import MagicHomeProvider
import MerossProvider
import NanoleafProvider
import NetKit
import ShellyProvider
import SwitchBotProvider
import TPLinkProvider
import TuyaKit
import TwinklyProvider
import WiZKit
import WLEDProvider
import YeelightProvider

/// Creates the brand providers, restores what the user paired earlier and hooks them into the
/// app lifecycle (T1.6, P11).
///
/// - Launch (`registerAll`): Hue, WiZ and LIFX are always registered (they cost nothing until a
///   bridge or bulb exists). Every other brand is registered only once the user has set it up (a
///   paired device or a stored account): Apple Home would otherwise show its permission prompt at
///   launch, cloud brands need an account, and idle LAN providers would poll for nothing. The Add
///   flow registers them on demand through `ensureRegistered(_:in:)`.
/// - Restore: every provider receives its paired devices (cached IPs are hints) before the first
///   refresh: Hue bridges via `addBridge`, Twinkly via `addDevice`, Dirigera via `addHub`, Home
///   Assistant via `addInstance`, the LAN brands via `restore`; TP-Link also loads its account, Tuya
///   reads its records (with the local keys) from the Keychain, and the cloud brands (AiDot, Govee,
///   Meross, SwitchBot) get their stored `ProviderAccount`. Secrets stay in `model.secretStore`.
/// - Foreground/background: `ProviderLifecycle` (driven by `AppModel.scenePhaseChanged`) starts push
///   channels and polling (Hue SSE, Dirigera and Home Assistant WebSockets, Nanoleaf SSE, Shelly
///   sockets, WiZ push, AiDot and Tuya TCP sessions, LAN/cloud polling) and stops them again.
/// - `needsReauthentication` from any provider is surfaced by `AppModel.handle(_:)` (toast, Settings
///   badge, Diagnostics); running the brand's Add guide again asks for new credentials.
///
/// Brands that already have a provider in the registry are left alone, so previews and tests
/// that register `FakeLightProvider`s before `AppModel.start()` keep their fakes.
enum ProviderWiring {
    /// Marker account saved once the user allowed Apple Home in the Add flow.
    static let appleHomeAccountID = "applehome"

    /// Registered at every launch, even before anything is paired.
    static let alwaysRegistered: [Brand] = [.hue, .wiz, .lifx]
    /// Registered at launch only once set up; otherwise by the Add flow.
    static let registeredWhenSetUp: [Brand] = [
        .appleHome, .aidot, .nanoleaf, .yeelight, .govee, .elgato, .wled, .shelly, .magicHome, .tplink,
        .tuya, .meross, .switchbot, .twinkly, .dirigera, .homeAssistant,
    ]
    /// Every brand this build can control.
    static var supportedBrands: [Brand] { alwaysRegistered + registeredWhenSetUp }
    /// Providers that take a broadcast flag from the app (others read `DiscoveryOptions.broadcastAvailable`).
    static let broadcastAware: Set<Brand> = [.aidot, .govee, .tuya]

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

        var needsBroadcastCheck = false
        for brand in supportedBrands {
            guard await model.registry.provider(for: brand) == nil else { continue }
            let own = devices.filter { $0.brand == brand }
            let account = accounts.first { $0.brand == brand }
            if !alwaysRegistered.contains(brand), !isSetUp(brand, devices: own, account: account) { continue }
            guard let provider = await makeProvider(brand, model: model, devices: own, account: account) else { continue }
            await install(provider, in: model)
            if broadcastAware.contains(brand) { needsBroadcastCheck = true }
            note("\(brand.displayName): restored \(own.count) device(s)\(account == nil ? "" : " and an account")")
        }

        if needsBroadcastCheck {
            // Users who set these brands up already granted Local Network access, so this probe is
            // silent; it runs off the launch path.
            Task { await applyBroadcast(await BroadcastCapability.detect() == .entitled, in: model) }
        }
    }

    /// Whether the user has set `brand` up (launch registration of on-demand brands).
    private static func isSetUp(_ brand: Brand, devices: [PairedDevice], account: ProviderAccount?) -> Bool {
        switch brand {
        case .appleHome, .aidot, .meross, .switchbot: account != nil
        default: !devices.isEmpty || account != nil
        }
    }

    /// Tells the broadcast-aware providers whether UDP broadcast/multicast may be used.
    @MainActor
    static func applyBroadcast(_ available: Bool, in model: AppModel) async {
        if let aidot = await model.registry.provider(for: .aidot) as? AiDotProvider {
            await aidot.setBroadcastAvailable(available)
        }
        if let govee = await model.registry.provider(for: .govee) as? GoveeProvider {
            await govee.setBroadcastAvailable(available)
        }
        if let tuya = await model.registry.provider(for: .tuya) as? TuyaProvider {
            await tuya.setBroadcastAvailable(available)
        }
    }

    /// The provider for `brand`, creating and registering it if the brand is supported but not
    /// registered yet (Add flow). nil for brands this build cannot control.
    @MainActor
    @discardableResult
    static func ensureRegistered(_ brand: Brand, in model: AppModel, refresh: Bool = true) async -> (any LightProvider)? {
        if let existing = await model.registry.provider(for: brand) { return existing }
        let devices = ((try? await model.deviceStore.pairedDevices()) ?? []).filter { $0.brand == brand }
        let account = ((try? await model.deviceStore.accounts()) ?? []).first { $0.brand == brand }
        guard let provider = await makeProvider(brand, model: model, devices: devices, account: account) else { return nil }
        await install(provider, in: model)
        note("\(brand.displayName): registered")
        if refresh { await model.refresh() }
        return provider
    }

    /// Discovery hints for `brand`: previously known hosts of paired devices (ids stay authoritative).
    static func cachedHosts(for brand: Brand, in store: any DeviceStore) async -> [String] {
        let devices = (try? await store.pairedDevices()) ?? []
        return Array(Set(devices.filter { $0.brand == brand }.compactMap(\.hostHint))).sorted()
    }

    /// Reconciles discovery results with stored devices: a known id at a new address updates the
    /// stored host hint (and the Hue/Twinkly provider's endpoint; the other providers update their
    /// own records during discovery). Returns the ids already paired.
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
            switch device.brand {
            case .hue:
                if let hue = await model.registry.provider(for: .hue) as? HueProvider {
                    await hue.updateHost(bridgeID: stored.id, host: host, port: device.port)
                }
            case .twinkly:
                if let twinkly = await model.registry.provider(for: .twinkly) as? TwinklyProvider {
                    await twinkly.updateHost(deviceID: stored.id, host: host, port: device.port)
                }
            default:
                break
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

    /// Builds the provider for `brand` with its restored devices and account. nil if this build has none.
    @MainActor
    private static func makeProvider(
        _ brand: Brand, model: AppModel, devices: [PairedDevice], account: ProviderAccount?
    ) async -> (any LightProvider)? {
        let secrets = model.secretStore
        switch brand {
        case .hue:
            let hue = HueProvider(secrets: secrets, pinStore: KeychainTOFUPinStore())
            for bridge in devices { await hue.addBridge(bridge) }
            return hue
        case .wiz:
            let wiz = WiZProvider(secrets: secrets)
            await wiz.restore(devices)
            return wiz
        case .lifx:
            let lifx = LIFXProvider.live(secretStore: secrets)
            await lifx.restore(devices)
            return lifx
        case .appleHome:
            return HomeKitProvider.live()
        case .aidot:
            // No account yet: the Add flow's login step signs in through `pair`.
            if let account { return AiDotProvider(account: account, secretStore: secrets) }
            return AiDotProvider(secretStore: secrets)
        case .nanoleaf:
            return NanoleafProvider(secrets: secrets, devices: devices)
        case .yeelight:
            let yeelight = YeelightProvider.live()
            await yeelight.restore(devices)
            return yeelight
        case .govee:
            // Multicast is switched on by `applyBroadcast` once the entitlement check ran.
            return GoveeProvider.live(secrets: secrets, account: account, pairedDevices: devices, broadcastAvailable: false)
        case .elgato:
            let elgato = ElgatoProvider.live()
            await elgato.restore(devices)
            return elgato
        case .wled:
            let wled = WLEDProvider.live()
            await wled.restore(devices)
            return wled
        case .shelly:
            let shelly = ShellyProvider.live(secretStore: secrets)
            await shelly.restore(devices)
            return shelly
        case .magicHome:
            let magicHome = MagicHomeProvider.live()
            await magicHome.restore(devices)
            return magicHome
        case .tplink:
            let tplink = TPLinkProvider.live(secretStore: secrets)
            await tplink.loadAccount()
            await tplink.restore(devices)
            return tplink
        case .tuya:
            // Device records (with the local keys) live in the Keychain; the provider loads them.
            return TuyaProvider(secretStore: secrets)
        case .meross:
            // Key, token and the cached device list (IP hints) are read from the Keychain on use.
            return MerossProvider(account: account, secretStore: secrets)
        case .switchbot:
            return SwitchBotProvider(account: account, secretStore: secrets)
        case .twinkly:
            let twinkly = TwinklyProvider.live(secrets: secrets)
            for device in devices { await twinkly.addDevice(device) }
            return twinkly
        case .dirigera:
            let dirigera = DirigeraProvider(secrets: secrets, pinStore: KeychainTOFUPinStore())
            for hub in devices { await dirigera.addHub(hub) }
            return dirigera
        case .homeAssistant:
            let homeAssistant = HomeAssistantProvider(secrets: secrets, transport: URLSessionHATransport())
            for instance in devices { await homeAssistant.addInstance(instance) }
            return homeAssistant
        default:
            return nil
        }
    }

    /// Registers `provider` with the registry (without a refresh) and installs its lifecycle hooks.
    @MainActor
    private static func install(_ provider: any LightProvider, in model: AppModel) async {
        await model.registry.register(provider)
        if let hooks = hooks(for: provider) {
            model.providerLifecycle.install(hooks)
        }
    }

    /// Foreground (`activate`) and background (`deactivate`) work per provider.
    private static func hooks(for provider: any LightProvider) -> ProviderLifecycle.Hooks? {
        switch provider {
        case let hue as HueProvider:
            .init(brand: .hue, activate: { await hue.connectEventStreams() }, deactivate: { await hue.disconnectEventStreams() })
        case let wiz as WiZProvider:
            .init(brand: .wiz, activate: { await wiz.start() }, deactivate: { await wiz.stop() })
        case let lifx as LIFXProvider:
            // LIFX has no push; start/stop toggles its state polling.
            .init(brand: .lifx, activate: { await lifx.start() }, deactivate: { await lifx.stop() })
        case let aidot as AiDotProvider:
            .init(brand: .aidot, activate: { await aidot.start() }, deactivate: { await aidot.stop() })
        case let nanoleaf as NanoleafProvider:
            // SSE event stream per controller.
            .init(brand: .nanoleaf, activate: { await nanoleaf.start() }, deactivate: { await nanoleaf.stop() })
        case let yeelight as YeelightProvider:
            // Sessions reopen on the next command or refresh; close them in the background.
            .init(brand: .yeelight, activate: {}, deactivate: { await yeelight.disconnectAll() })
        case let govee as GoveeProvider:
            .init(brand: .govee, activate: { await govee.start() }, deactivate: { await govee.stop() })
        case let elgato as ElgatoProvider:
            .init(brand: .elgato, activate: { await elgato.start() }, deactivate: { await elgato.stop() })
        case let wled as WLEDProvider:
            .init(brand: .wled, activate: { await wled.start() }, deactivate: { await wled.stop() })
        case let shelly as ShellyProvider:
            .init(brand: .shelly, activate: { await shelly.start() }, deactivate: { await shelly.stop() })
        case let magicHome as MagicHomeProvider:
            .init(brand: .magicHome, activate: { await magicHome.start() }, deactivate: { await magicHome.stop() })
        case let tplink as TPLinkProvider:
            .init(brand: .tplink, activate: { await tplink.start() }, deactivate: { await tplink.stop() })
        case let tuya as TuyaProvider:
            // Closing the TCP sessions frees each light's single local connection for Smart Life.
            .init(brand: .tuya, activate: { await tuya.start() }, deactivate: { await tuya.stop() })
        case let meross as MerossProvider:
            .init(brand: .meross, activate: { await meross.start() }, deactivate: { await meross.stop() })
        case let switchbot as SwitchBotProvider:
            .init(brand: .switchbot, activate: { await switchbot.start() }, deactivate: { await switchbot.stop() })
        case let twinkly as TwinklyProvider:
            .init(brand: .twinkly, activate: { await twinkly.startPolling() }, deactivate: { await twinkly.stopPolling() })
        case let dirigera as DirigeraProvider:
            .init(brand: .dirigera, activate: { await dirigera.connectEventStreams() }, deactivate: { await dirigera.disconnectEventStreams() })
        case let homeAssistant as HomeAssistantProvider:
            .init(brand: .homeAssistant, activate: { await homeAssistant.connectEventStreams() },
                  deactivate: { await homeAssistant.disconnectEventStreams() })
        default:
            // HomeKit keeps its own connection; nothing to do on scene changes.
            nil
        }
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
