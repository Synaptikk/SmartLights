import Foundation
import Observation
import LightCore

/// The app's single state store (main actor). Views read it via `@Environment(AppModel.self)`.
///
/// Owns the provider registry, device store, secret store and the app library (rooms, app
/// scenes). Mirrors provider events into `lightsByID` (`lights` is the sorted array). State properties are settable only so the
/// `AppModel+*.swift` extensions can mutate them; views must go through the methods.
///
/// Extension points for other tasks:
/// - T1.6 provider wiring: `register(_:)`, `refresh()`, `scenePhaseChanged(isActive:)`,
///   `pair(_:using:)`, `discover(brand:options:)`, `ProviderWiring.registerAll(in:)`.
/// - T1.8 scenes: `createSnapshotScene(name:lightIDs:)`, `recall(_:)`, `saveScene(_:)`.
/// - T1.10 intents: `send(_:to:)`, `send(_:toRoom:)`, `send(_:toLights:groupKey:)`, `lookup` helpers.
/// - T0.7 diagnostics: `registry`, `lights`, `providerHealth`, `lastSeen`, `recentErrors`, `sendNow(_:to:)`;
///   every registry event is forwarded to `DiagnosticsCollector.shared.ingest(_:)` and every
///   dispatched command reports latency/errors to it.
@MainActor
@Observable
final class AppModel {
    // MARK: Services

    let registry: ProviderRegistry
    let deviceStore: any DeviceStore
    let secretStore: any SecretStore
    let libraryStore: LibraryStore
    let coalescer: CommandCoalescer

    // MARK: Observable state

    /// Every known light, keyed by stable id (never IP). Includes cached lights before providers load.
    var lightsByID: [LightID: Light] = [:]
    /// User-defined rooms, in display order.
    var rooms: [Room] = []
    /// App scenes (`kind == .app`).
    var appScenes: [LightScene] = []
    /// Vendor scenes from all providers (`kind == .vendor`).
    var vendorScenes: [LightScene] = []
    var providerHealth: [Brand: ProviderHealth] = [:]
    /// Last time each light reported state or reachability.
    var lastSeen: [LightID: Date] = [:]
    /// Most recent provider/command errors, newest last (max 100). Never contains secrets.
    var recentErrors: [String] = []
    /// Brands whose account needs signing in again.
    var reauthenticationNeeded: Set<Brand> = []
    var toast: Toast?
    /// True until `start()` has loaded cached lights and the library.
    var isLoading = true

    // MARK: Internal bookkeeping (not observed)

    @ObservationIgnored var seenLightIDs: Set<LightID> = []
    /// State before the first optimistic change of the current burst (for revert on failure).
    @ObservationIgnored var baselines: [LightID: LightState] = [:]
    /// Provider state received while a command was in flight; applied when the burst settles.
    @ObservationIgnored var deferredStates: [LightID: LightState] = [:]
    @ObservationIgnored var dispatchStartedAt: [LightID: Date] = [:]
    @ObservationIgnored var librarySaveTask: Task<Void, Never>?
    @ObservationIgnored var lightCacheTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Foreground/background hooks of the real providers (installed by `ProviderWiring`).
    @ObservationIgnored let providerLifecycle = ProviderLifecycle()

    init(
        registry: ProviderRegistry = ProviderRegistry(),
        deviceStore: any DeviceStore,
        secretStore: any SecretStore,
        libraryStore: LibraryStore,
        commandInterval: Duration = .milliseconds(100)
    ) {
        self.registry = registry
        self.deviceStore = deviceStore
        self.secretStore = secretStore
        self.libraryStore = libraryStore
        self.coalescer = CommandCoalescer(minimumInterval: commandInterval) { command, targets in
            if targets.count == 1 {
                try await registry.send(command, to: targets[0])
            } else {
                try await registry.sendGroup(command, to: targets)
            }
        }
        coalescer.onEvent = { [weak self] event in
            self?.handleCoalescer(event)
        }
    }

    /// Production model: JSON device store + library in Application Support, Keychain secrets.
    static func live() -> AppModel {
        let folder = URL.applicationSupportDirectory.appending(path: "SmartLights", directoryHint: .isDirectory)
        // D10: SwiftData replaces the JSON files in T1.6; LightCore's SwiftDataDeviceStore is the hook.
        return AppModel(
            deviceStore: JSONFileDeviceStore(fileURL: folder.appending(path: "devices.json")),
            secretStore: KeychainSecretStore(),
            libraryStore: LibraryStore(fileURL: folder.appending(path: "library.json"))
        )
    }

    // MARK: Lifecycle

    /// Loads cached lights and the library, starts consuming registry events, registers providers.
    /// Safe to call more than once; only the first call does work.
    func start() async {
        guard !started else { return }
        started = true
        startEventLoop()

        if let cached = try? await deviceStore.cachedLights() {
            for light in cached where lightsByID[light.id] == nil {
                lightsByID[light.id] = light
            }
        }
        do {
            let library = try await libraryStore.load()
            rooms = library.rooms
            appScenes = library.scenes
            seenLightIDs = library.seenLightIDs.union(lightsByID.keys)
        } catch {
            record(error: "Could not read rooms and scenes: \(error.localizedDescription)")
        }
        isLoading = false

        await ProviderWiring.registerAll(in: self)
        await refresh()
    }

    /// Registers (or replaces) a provider and loads its lights and scenes.
    func register(_ provider: any LightProvider) async {
        await registry.register(provider)
        await refresh()
    }

    /// Reloads every provider's lights and vendor scenes. Failing providers are recorded, not fatal.
    func refresh() async {
        let (loaded, failures) = await registry.loadAllLights()
        for light in loaded { upsert(light) }
        for (brand, message) in failures {
            providerHealth[brand, default: ProviderHealth()].lastError = message
            record(error: "\(brand.displayName): \(message)")
        }
        await reloadVendorScenes()
    }

    /// Foreground/background hook: reconnects Hue SSE, re-registers WiZ push and reopens AiDot TCP
    /// in the foreground (`ProviderLifecycle`), stops them in the background, refreshes on return.
    func scenePhaseChanged(isActive: Bool) {
        providerLifecycle.setActive(isActive)
        guard isActive, started else { return }
        Task { await refresh() }
    }

    /// Starts discovery for one brand; nil if the brand has no registered provider.
    func discover(brand: Brand, options: DiscoveryOptions = .default) async -> AsyncStream<DiscoveredDevice>? {
        guard let provider = await registry.provider(for: brand) else { return nil }
        return await provider.discover(options: options)
    }

    /// Pairs a discovered device, persists it and loads its lights.
    @discardableResult
    func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard let provider = await registry.provider(for: device.brand) else {
            throw LightCoreError.providerNotRegistered(device.brand)
        }
        let paired = try await provider.pair(device, using: ui)
        try await deviceStore.save(paired)
        if let account = await provider.account {
            try await deviceStore.save(account)
        }
        reauthenticationNeeded.remove(device.brand)
        await refresh()
        return paired
    }

    // MARK: Events

    private func startEventLoop() {
        let stream = registry.events
        eventTask = Task { [weak self] in
            for await event in stream {
                DiagnosticsCollector.shared.ingest(event)
                self?.handle(event)
            }
        }
    }

    func handle(_ registryEvent: RegistryEvent) {
        let brand = registryEvent.brand
        var health = providerHealth[brand] ?? ProviderHealth()
        health.lastEventAt = Date()

        switch registryEvent.event {
        case .stateChanged(let id, let state):
            receive(state, for: id)
        case .lightAdded(let light), .lightUpdated(let light):
            upsert(light)
        case .lightRemoved(let id):
            lightsByID[id] = nil
            lastSeen[id] = nil
        case .reachabilityChanged(let id, let reachable):
            lightsByID[id]?.state.reachable = reachable
            if reachable { lastSeen[id] = Date() }
        case .scenesChanged:
            Task { await reloadVendorScenes() }
        case .needsReauthentication:
            // Toast once per brand until it is paired again; Settings shows a badge meanwhile.
            if reauthenticationNeeded.insert(brand).inserted {
                showToast("\(brand.displayName) needs you to sign in again. Open Add > \(brand.displayName).", isError: true)
            }
        case .connectionChanged(let connected, let detail):
            health.connected = connected
            health.detail = detail
        case .error(let message):
            health.lastError = message
            record(error: "\(brand.displayName): \(message)")
        }
        providerHealth[brand] = health
    }

    /// Applies authoritative state unless a local command for the light is in flight
    /// (then it is deferred and reconciled when the burst settles).
    func receive(_ state: LightState, for id: LightID) {
        lastSeen[id] = Date()
        guard lightsByID[id] != nil else { return }
        if coalescer.isBusy(id) {
            // Only states reported after our send started can reflect it.
            if let started = dispatchStartedAt[id], Date() >= started {
                deferredStates[id] = state
            }
            return
        }
        lightsByID[id]?.state = state
        scheduleLightCacheSave()
    }

    /// Inserts or replaces a light's metadata, keeping optimistic state while commands are in flight.
    func upsert(_ light: Light) {
        var incoming = light
        if coalescer.isBusy(light.id), let current = lightsByID[light.id] {
            incoming.state = current.state
        }
        lightsByID[light.id] = incoming
        if !seenLightIDs.contains(light.id) {
            seenLightIDs.insert(light.id)
            autoAssignRoom(for: incoming)
            scheduleLibrarySave()
        }
        scheduleLightCacheSave()
    }

    func reloadVendorScenes() async {
        var scenes: [LightScene] = []
        for brand in await registry.registeredBrands {
            guard let provider = await registry.provider(for: brand) else { continue }
            do {
                scenes += try await provider.scenes()
            } catch {
                record(error: "\(brand.displayName) scenes: \(error.localizedDescription)")
            }
        }
        vendorScenes = scenes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Toasts and errors

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
    }

    func dismissToast(id: Toast.ID) {
        if toast?.id == id { toast = nil }
    }

    func showError(_ error: any Error) {
        if error is CancellationError { return }
        let message = Self.message(for: error)
        record(error: message)
        showToast(message, isError: true)
    }

    func record(error message: String) {
        recentErrors.append(message)
        if recentErrors.count > 100 { recentErrors.removeFirst(recentErrors.count - 100) }
    }

    static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Persistence

    func scheduleLibrarySave() {
        let library = AppLibrary(rooms: rooms, scenes: appScenes, seenLightIDs: seenLightIDs)
        let store = libraryStore
        librarySaveTask?.cancel()
        librarySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await store.save(library)
            } catch {
                self?.record(error: "Could not save rooms and scenes: \(error.localizedDescription)")
            }
        }
    }

    func scheduleLightCacheSave() {
        lightCacheTask?.cancel()
        lightCacheTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let snapshot = Array(self.lightsByID.values)
            try? await self.deviceStore.cacheLights(snapshot)
        }
    }
}
