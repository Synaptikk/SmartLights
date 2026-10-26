import Foundation
import LightCore

/// Apple Home (HomeKit) as a SmartLights provider. Every lightbulb service of every home the user
/// has in Apple Home (HAP and Matter accessories alike) becomes a `Light` with `brand: .appleHome`
/// and the accessory maker in `Light.manufacturer`.
///
/// - There is no scanning or pairing: `discover` lists the lightbulb services Apple Home already
///   knows, `pair` only records the choice.
/// - HomeKit work happens on the main actor inside the `HomeKitSession`; this actor owns the cache,
///   diffing, write serialisation (one write chain per accessory) and the event stream.
public actor HomeKitProvider: LightProvider {
    public static let brand: Brand = .appleHome

    /// Message used when HomeKit access is denied or restricted.
    public static let accessDeniedMessage =
        "SmartLights is not allowed to use Apple Home. Turn it on in Settings > Privacy & Security > HomeKit."

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let session: any HomeKitSession
    private let readyTimeout: Duration
    private let log = Log(package: "homekitprovider", category: "provider")

    /// Last known HomeKit permission state (updated from session events and every load).
    public private(set) var authorizationState: HomeKitAuthorizationState = .notDetermined
    /// Devices the user "added" via `pair` (bookkeeping only; all Apple Home lights are loaded).
    public private(set) var pairedDevices: [String: PairedDevice] = [:]

    private var started = false
    private var eventTask: Task<Void, Never>?
    private var known: [LightID: HomeKitLightbulb] = [:]
    private var colorModeHints: [LightID: ColorMode] = [:]
    private var notificationsRequested: Set<LightID> = []
    private var writeTails: [UUID: Task<Void, any Error>] = [:]

    /// - Parameters:
    ///   - session: `HMHomeKitSession()` in the app (see `HomeKitProvider.live()`), a fake in tests.
    ///   - readyTimeout: how long `loadLights` waits for HomeKit to deliver the home list.
    public init(session: any HomeKitSession, readyTimeout: Duration = .seconds(8)) {
        self.session = session
        self.readyTimeout = readyTimeout
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        eventTask?.cancel()
        continuation.finish()
    }

    /// HomeKit needs no credentials.
    public var account: ProviderAccount? { nil }

    // MARK: - Lifecycle

    /// Creates the HomeKit home manager (permission prompt on first use) and starts observing.
    /// Called implicitly by every other entry point; idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        let stream = session.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await session.start()
        noteAuthorization(await session.authorizationState)
    }

    /// Starts the session and waits until the user has answered the permission prompt and the
    /// home list arrived (or `timeout` elapsed). For the onboarding "Allow Apple Home" step.
    @discardableResult
    public func requestAccess(timeout: Duration = .seconds(60)) async -> HomeKitAuthorizationState {
        await start()
        await waitUntilReady(timeout: timeout)
        noteAuthorization(await session.authorizationState)
        return authorizationState
    }

    // MARK: - LightProvider

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        guard options.methods.contains(.homeKit) else {
            continuation.finish()
            return stream
        }
        let task = Task { await self.runDiscovery(options: options, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .appleHome,
              let ids = HomeKitMapper.identifiers(stableID: device.id),
              let lightID = HomeKitMapper.lightID(accessoryID: ids.accessoryID, serviceID: ids.serviceID) else {
            throw LightCoreError.unsupported("\(device.name) is not an Apple Home light")
        }
        let paired = PairedDevice(
            id: device.id,
            brand: .appleHome,
            name: device.name,
            model: device.model,
            lightIDs: [lightID],
            metadata: device.metadata,
            lastSeen: Date()
        )
        pairedDevices[device.id] = paired
        return paired
    }

    public func loadLights() async throws -> [Light] {
        await start()
        await waitUntilReady(timeout: readyTimeout)
        try await checkAuthorization()
        let bulbs = await session.lightbulbs()
        reconcile(bulbs, emit: false)
        return known.keys.sorted().compactMap(light(for:))
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard let ids = HomeKitMapper.identifiers(of: light) else { throw LightCoreError.lightNotFound(light) }
        await start()
        if command.isEmpty { return }
        let accessoryID = ids.accessoryID
        let previous = writeTails[accessoryID]
        let task = Task<Void, any Error> {
            _ = await previous?.result
            try await self.perform(command, on: light)
        }
        writeTails[accessoryID] = task
        defer { if writeTails[accessoryID] == task { writeTails[accessoryID] = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Concurrent across accessories, sequential (and serialised with other sends) per accessory.
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        var byAccessory: [String: [LightID]] = [:]
        for id in lights {
            let key = HomeKitMapper.identifiers(of: id)?.accessoryID.uuidString ?? id.rawValue
            byAccessory[key, default: []].append(id)
        }
        let failures = await withTaskGroup(of: [LightID: String].self) { group in
            for ids in byAccessory.values {
                group.addTask {
                    var failed: [LightID: String] = [:]
                    for id in ids {
                        do { try await self.send(command, to: id) } catch { failed[id] = String(describing: error) }
                    }
                    return failed
                }
            }
            var merged: [LightID: String] = [:]
            for await partial in group { merged.merge(partial) { a, _ in a } }
            return merged
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    // MARK: - Internals

    private func runDiscovery(options: DiscoveryOptions, into continuation: AsyncStream<DiscoveredDevice>.Continuation) async {
        await start()
        await waitUntilReady(timeout: options.timeout)
        if Task.isCancelled { continuation.finish(); return }
        noteAuthorization(await session.authorizationState)
        if !authorizationState.isAuthorized && authorizationState != .notDetermined {
            log.notice("discover: HomeKit not authorized (\(authorizationState.rawValue))")
        }
        let bulbs = await session.lightbulbs()
        reconcile(bulbs, emit: true)
        var seen: Set<String> = []
        for bulb in bulbs {
            let device = HomeKitMapper.discoveredDevice(for: bulb)
            if seen.insert(device.id).inserted { continuation.yield(device) }
        }
        continuation.finish()
    }

    private func waitUntilReady(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if await session.isReady { return }
            switch await session.authorizationState {
            case .denied, .restricted, .unavailable: return
            case .notDetermined, .authorized: break
            }
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func checkAuthorization() async throws {
        noteAuthorization(await session.authorizationState)
        switch authorizationState {
        case .denied, .restricted:
            throw LightCoreError.unsupported(Self.accessDeniedMessage)
        case .unavailable:
            throw LightCoreError.unsupported("HomeKit is not available on this device")
        case .authorized, .notDetermined:
            break
        }
    }

    private func perform(_ command: LightCommand, on id: LightID) async throws {
        guard var bulb = await bulb(for: id) else { throw LightCoreError.lightNotFound(id) }
        guard bulb.isReachable else {
            throw LightCoreError.unreachable("\(bulb.displayName) is not responding in Apple Home")
        }
        let writes = HomeKitMapper.writes(for: command, to: bulb, colorModeHint: colorModeHints[id])
        guard !writes.isEmpty else { return }
        log.debug("write \(id): \(writes.map(\.description).joined(separator: ", "))")
        try await session.write(writes, accessoryID: bulb.accessoryID, serviceID: bulb.serviceID)
        // HomeKit does not call the delegate for this app's own writes: update cache and publish.
        bulb = HomeKitMapper.applying(writes, to: known[id] ?? bulb)
        known[id] = bulb
        if let mode = HomeKitMapper.colorMode(of: writes) { colorModeHints[id] = mode }
        continuation.yield(.stateChanged(id, state(of: bulb, id: id)))
    }

    private func bulb(for id: LightID) async -> HomeKitLightbulb? {
        if let cached = known[id] { return cached }
        await waitUntilReady(timeout: readyTimeout)
        reconcile(await session.lightbulbs(), emit: true)
        return known[id]
    }

    private func light(for id: LightID) -> Light? {
        guard let bulb = known[id] else { return nil }
        return HomeKitMapper.light(from: bulb, colorModeHint: colorModeHints[id])
    }

    private func state(of bulb: HomeKitLightbulb, id: LightID) -> LightState {
        HomeKitMapper.state(for: bulb, colorModeHint: colorModeHints[id])
    }

    func handle(_ event: HomeKitSessionEvent) async {
        switch event {
        case .authorizationChanged(let status):
            noteAuthorization(status)
        case .homesChanged:
            reconcile(await session.lightbulbs(), emit: true)
        case .lightbulbUpdated(let bulb, let changed):
            guard let id = HomeKitMapper.lightID(for: bulb) else { return }
            switch changed {
            case .colorTemperature?: colorModeHints[id] = .colorTemp
            case .hue?, .saturation?: colorModeHints[id] = .hs
            default: break
            }
            update(id: id, to: bulb, emit: true)
            requestNotificationsIfNeeded()
        case .reachabilityChanged(let accessoryID, let reachable):
            for (id, bulb) in known where bulb.accessoryID == accessoryID && bulb.isReachable != reachable {
                var next = bulb
                next.isReachable = reachable
                known[id] = next
                continuation.yield(.reachabilityChanged(id, reachable: reachable))
            }
            if reachable {
                // Notifications enabled while unreachable may have failed; retry.
                requestNotificationsIfNeeded()
            }
        }
    }

    /// Records the permission state; on change publishes `.error` / `.connectionChanged`.
    private func noteAuthorization(_ status: HomeKitAuthorizationState) {
        guard status != authorizationState else { return }
        authorizationState = status
        switch status {
        case .denied, .restricted:
            continuation.yield(.error(Self.accessDeniedMessage))
            continuation.yield(.connectionChanged(connected: false, detail: Self.accessDeniedMessage))
        case .unavailable:
            continuation.yield(.connectionChanged(connected: false, detail: "HomeKit is not available on this device"))
        case .authorized:
            continuation.yield(.connectionChanged(connected: true, detail: nil))
        case .notDetermined:
            break
        }
    }

    /// Replaces the cache with `bulbs`; emits added/removed/updated/state events when `emit`.
    private func reconcile(_ bulbs: [HomeKitLightbulb], emit: Bool) {
        var fresh: [LightID: HomeKitLightbulb] = [:]
        for bulb in bulbs {
            if let id = HomeKitMapper.lightID(for: bulb) { fresh[id] = bulb }
        }
        for id in known.keys.sorted() where fresh[id] == nil {
            known[id] = nil
            colorModeHints[id] = nil
            notificationsRequested.remove(id)
            if emit { continuation.yield(.lightRemoved(id)) }
        }
        for id in fresh.keys.sorted() {
            if let bulb = fresh[id] { update(id: id, to: bulb, emit: emit) }
        }
        requestNotificationsIfNeeded()
    }

    private func update(id: LightID, to bulb: HomeKitLightbulb, emit: Bool) {
        let old = known[id]
        known[id] = bulb
        guard emit, let new = light(for: id) else { return }
        guard let old, let previous = HomeKitMapper.light(from: old, colorModeHint: colorModeHints[id]) else {
            continuation.yield(.lightAdded(new))
            return
        }
        if previous.name != new.name || previous.roomHint != new.roomHint || previous.capabilities != new.capabilities
            || previous.manufacturer != new.manufacturer || previous.model != new.model {
            continuation.yield(.lightUpdated(new))
            return
        }
        if previous.state.reachable != new.state.reachable {
            continuation.yield(.reachabilityChanged(id, reachable: new.state.reachable))
        }
        if !Self.sameState(previous.state, new.state) {
            continuation.yield(.stateChanged(id, new.state))
        }
    }

    /// Enables characteristic notifications once per light (fire-and-forget; HomeKit can take
    /// seconds for unreachable accessories). Failures are logged and retried on the next refresh.
    private func requestNotificationsIfNeeded() {
        let pending = known.filter { !notificationsRequested.contains($0.key) && $0.value.isReachable }
        guard !pending.isEmpty else { return }
        for (id, bulb) in pending {
            notificationsRequested.insert(id)
            let session = self.session
            let accessoryID = bulb.accessoryID
            let serviceID = bulb.serviceID
            Task { [weak self] in
                do {
                    try await session.enableNotifications(accessoryID: accessoryID, serviceID: serviceID)
                } catch {
                    await self?.notificationsFailed(id, error: error)
                }
            }
        }
    }

    private func notificationsFailed(_ id: LightID, error: any Error) {
        notificationsRequested.remove(id)
        log.notice("enableNotification failed for \(id): \(error)")
    }

    /// State equality ignoring `updatedAt` and `reachable` (reported separately).
    static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        a.reachable = b.reachable
        return a == b
    }
}
