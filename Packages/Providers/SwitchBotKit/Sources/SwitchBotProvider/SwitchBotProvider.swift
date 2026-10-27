import Crypto
import Foundation
import LightCore
import SwitchBotCodec

/// SwitchBot lights (Color Bulb, Strip Light, Ceiling Light and siblings) through the official
/// cloud API v1.1 with the user's token + secret. Every call counts against SwitchBot's
/// 10,000 requests/day, so the provider spends a local budget (`RateLimiter`) and keeps a reserve
/// for user commands when polling. See README.md.
public actor SwitchBotProvider: LightProvider {
    public static let brand: Brand = .switchbot

    public struct Configuration: Sendable {
        public var baseURL: URL = SwitchBotAPI.baseURL
        public var timeout: Duration = .seconds(15)
        /// State polling while started (no push without webhooks). 5 min x 10 lights = 2,880 calls/day.
        public var pollInterval: Duration = .seconds(300)
        /// `loadLights()` reuses a status younger than this instead of spending a request.
        public var statusTTL: Duration = .seconds(30)
        public var deviceListTTL: Duration = .seconds(3600)
        /// Daily budget: a token bucket refilling 10,000 per 24 h.
        public var dailyBudget = RateLimiter<String>.Limit(capacity: SwitchBotAPI.dailyRequestLimit,
                                                           refillPerSecond: Double(SwitchBotAPI.dailyRequestLimit) / 86_400)
        /// Polling stops while fewer than this many requests are left, keeping them for user commands.
        public var pollReserve = 2_000
        /// Short-term pacing of calls.
        public var burstLimit = RateLimiter<String>.Limit(5, per: .seconds(1))
        public var http: any SwitchBotHTTPTransport = URLSessionSwitchBotTransport()

        public init() {}
    }

    /// Secret items (`SecretKey(brand: .switchbot, owner: <account id>, item: ...)`).
    public enum SecretItem {
        public static let token = "token"
        public static let secret = "secret"
        /// Cached device list (no secrets inside, kept with them for simplicity).
        public static let deviceCache = "deviceCache"
        public static let all = [token, secret, deviceCache]
    }

    enum Purpose {
        case user
        case poll
    }

    public private(set) var account: ProviderAccount?
    public nonisolated let events: AsyncStream<ProviderEvent>

    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    private let secretStore: any SecretStore
    private let configuration: Configuration
    private let log = Log(package: "switchbotkit", category: "provider")
    private let budget: RateLimiter<String>
    private let burst: RateLimiter<String>
    private static let budgetKey = "day"

    private var token: String?
    private var secret: String?
    private var credentialsLoaded = false
    /// Last time a request with the current credentials succeeded: a later 401 then most likely
    /// means the daily limit (shared with other SwitchBot API clients) was hit, not bad credentials.
    private var lastSuccess: Date?

    private var devices: [String: SwitchBotDevice] = [:]
    private var deviceOrder: [String] = []
    private var listFetchedAt: Date?
    private var states: [String: LightState] = [:]
    private var statusAt: [String: ContinuousClock.Instant] = [:]
    private var modes: [String: ColorMode] = [:]
    private var reachable: [String: Bool] = [:]
    private var pollTask: Task<Void, Never>?

    public init(account: ProviderAccount? = nil, secretStore: any SecretStore, configuration: Configuration = Configuration()) {
        self.account = account
        self.secretStore = secretStore
        self.configuration = configuration
        budget = RateLimiter(configuration.dailyBudget)
        burst = RateLimiter(configuration.burstLimit)
        (events, eventContinuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Foreground: poll light states every `pollInterval` (budget permitting).
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Requests left in the local daily budget (diagnostics).
    public func remainingBudget() async -> Int {
        Int(await budget.available(Self.budgetKey).rounded(.down))
    }

    /// Removes the token, secret and cached list.
    public func signOut() async {
        stop()
        if let owner = account?.id {
            for item in SecretItem.all { try? await secretStore.remove(SecretKey(brand: .switchbot, owner: owner, item: item)) }
        }
        for id in lightDevices.compactMap({ LightID(brand: .switchbot, stableId: $0.deviceId) }) {
            eventContinuation.yield(.lightRemoved(id))
        }
        account = nil
        token = nil; secret = nil; credentialsLoaded = false; lastSuccess = nil
        devices = [:]; deviceOrder = []; listFetchedAt = nil; states = [:]; statusAt = [:]; modes = [:]; reachable = [:]
    }

    // MARK: - Pairing

    /// "Add SwitchBot" placeholder for the Add flow.
    public nonisolated static func accountPlaceholder() -> DiscoveredDevice {
        DiscoveredDevice(id: "account", brand: .switchbot, name: "SwitchBot account", method: .cloud)
    }

    /// Asks for token + secret (if none stored), verifies them with `GET /devices` and returns the
    /// discovered light, or an account-level `PairedDevice` listing every supported light.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        try? await ensureCredentials()
        if token == nil || secret == nil {
            let token = try await ui.secureText("SwitchBot token (app > Profile > Preferences > About: tap App Version 10 times > Developer Options)")
            let secret = try await ui.secureText("SwitchBot secret key (same screen, below the token)")
            await ui.status("Checking your SwitchBot token…")
            try await connect(token: token, secret: secret)
        } else if devices.isEmpty || isListStale {
            try await refreshDeviceList()
        }
        if let d = devices[device.id], d.lightKind != nil, let id = LightID(brand: .switchbot, stableId: d.deviceId) {
            return PairedDevice(id: d.deviceId, brand: .switchbot, name: d.deviceName, model: d.deviceType,
                                accountID: account?.id, lightIDs: [id], metadata: metadata(for: d))
        }
        let lights = lightDevices.compactMap { LightID(brand: .switchbot, stableId: $0.deviceId) }
        return PairedDevice(id: "account:\(account?.id ?? "")", brand: .switchbot, name: "SwitchBot account",
                            accountID: account?.id, lightIDs: lights, metadata: ["lights": String(lights.count)])
    }

    /// Verifies and stores credentials (programmatic pairing).
    @discardableResult
    public func connect(token rawToken: String, secret rawSecret: String) async throws -> ProviderAccount {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !secret.isEmpty else { throw LightCoreError.userCancelled }
        let list = try await fetchDevices(token: token, secret: secret)
        let owner = Self.accountID(token: token)
        if let old = account, old.id != owner { await signOut() }
        self.token = token
        self.secret = secret
        credentialsLoaded = true
        lastSuccess = Date()
        account = ProviderAccount(id: owner, brand: .switchbot, displayName: "SwitchBot (token …\(token.suffix(4)))",
                                  secretKeys: SecretItem.all.map { SecretKey(brand: .switchbot, owner: owner, item: $0) })
        try await storeSecret(token, SecretItem.token)
        try await storeSecret(secret, SecretItem.secret)
        await apply(list)
        log.notice("SwitchBot connected, \(lightDevices.count) light(s)")
        return account!
    }

    /// Stable, non-secret account id derived from the token.
    static func accountID(token: String) -> String {
        "switchbot-" + SHA256.hash(data: Data(token.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        try await ensureCredentials()
        guard token != nil, secret != nil else { throw LightCoreError.authenticationRequired(.switchbot) }
        if devices.isEmpty || isListStale {
            do {
                try await refreshDeviceList()
            } catch where !devices.isEmpty && !(error is CancellationError) {
                log.notice("SwitchBot device list refresh failed (\(error)); using the cached list")
            }
        }
        for device in lightDevices where device.enableCloudService != false {
            let fresh = statusAt[device.deviceId].map { ContinuousClock.now - $0 < configuration.statusTTL } ?? false
            if !fresh { _ = try? await refreshStatus(device.deviceId, purpose: .user) }
        }
        return lightDevices.compactMap(light(for:))
    }

    public func send(_ command: LightCommand, to lightID: LightID) async throws {
        guard lightID.brand == .switchbot, let device = devices[lightID.stableId], let kind = device.lightKind else {
            throw LightCoreError.lightNotFound(lightID)
        }
        guard device.enableCloudService != false else {
            throw LightCoreError.unreachable("Turn on Cloud Services for \(device.deviceName) in the SwitchBot app")
        }
        let current = states[device.deviceId] ?? LightState(reachable: true)
        let commands = SwitchBotMapping.commands(for: command, kind: kind, currentlyOn: current.isOn)
        guard !commands.isEmpty else {
            if command.effect != nil { throw LightCoreError.unsupported("SwitchBot effects are not implemented") }
            return
        }
        var state = current
        for c in commands {
            try await call(purpose: .user, deviceId: device.deviceId) { tok, sec, t, n in
                SwitchBotAPI.command(c, deviceId: device.deviceId, token: tok, secret: sec, t: t, nonce: n)
            } decode: { try SwitchBotResponse.check(status: $0, body: $1) }
            state = SwitchBotMapping.apply([c], to: state)
        }
        if let mode = state.colorMode, commands.contains(where: { $0.command == "setColor" || $0.command == "setColorTemperature" }) {
            modes[device.deviceId] = mode
        }
        state.reachable = true
        states[device.deviceId] = state
        eventContinuation.yield(.stateChanged(lightID, state))
    }

    // MARK: - Discovery

    /// Cloud only: lights on the account (refreshing the list if stale).
    public nonisolated func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        AsyncStream { continuation in
            let task = Task {
                if options.methods.contains(.cloud) {
                    for d in await self.discoverable() { continuation.yield(d) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func discoverable() async -> [DiscoveredDevice] {
        try? await ensureCredentials()
        guard token != nil else { return [] }
        if devices.isEmpty || isListStale { try? await refreshDeviceList() }
        return lightDevices.map {
            DiscoveredDevice(id: $0.deviceId, brand: .switchbot, name: $0.deviceName, model: $0.deviceType,
                             method: .cloud, metadata: metadata(for: $0))
        }
    }

    // MARK: - Cloud

    private var isListStale: Bool {
        guard let at = listFetchedAt else { return true }
        return Date().timeIntervalSince(at) > configuration.deviceListTTL.seconds
    }

    private var lightDevices: [SwitchBotDevice] {
        deviceOrder.compactMap { devices[$0] }.filter { $0.lightKind != nil }
    }

    public func refreshDeviceList() async throws {
        let list = try await call(purpose: .user, deviceId: nil) { tok, sec, t, n in
            SwitchBotAPI.devices(token: tok, secret: sec, t: t, nonce: n)
        } decode: { try SwitchBotResponse.decodeDevices(status: $0, body: $1) }
        await apply(list)
    }

    /// `GET /devices` with explicit credentials (pairing); spends budget like any call.
    private func fetchDevices(token: String, secret: String) async throws -> [SwitchBotDevice] {
        guard await budget.tryAcquire(Self.budgetKey) else { throw SwitchBotError.budgetExhausted }
        try await burst.acquire("burst")
        let request = SwitchBotAPI.devices(token: token, secret: secret)
        let (status, body) = try await http(request)
        return try SwitchBotResponse.decodeDevices(status: status, body: body)
    }

    private func apply(_ list: [SwitchBotDevice]) async {
        let hadList = !devices.isEmpty
        let old = devices
        devices = Dictionary(list.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
        deviceOrder = list.map(\.deviceId)
        listFetchedAt = Date()
        if hadList {
            for d in list where d.lightKind != nil {
                guard let l = light(for: d) else { continue }
                if old[d.deviceId] == nil { eventContinuation.yield(.lightAdded(l)) } else if old[d.deviceId] != d { eventContinuation.yield(.lightUpdated(l)) }
            }
            for (id, d) in old where d.lightKind != nil && devices[id]?.lightKind == nil {
                if let lid = LightID(brand: .switchbot, stableId: id) { eventContinuation.yield(.lightRemoved(lid)) }
            }
        }
        if let data = try? JSONEncoder().encode(CacheSnapshot(fetchedAt: listFetchedAt, devices: list)) {
            try? await storeSecret(String(decoding: data, as: UTF8.self), SecretItem.deviceCache)
        }
    }

    /// `GET /devices/{id}/status` -> `LightState`; emits `stateChanged` when it differs.
    @discardableResult
    private func refreshStatus(_ deviceId: String, purpose: Purpose) async throws -> LightState? {
        guard let device = devices[deviceId], let kind = device.lightKind, let lid = LightID(brand: .switchbot, stableId: deviceId) else { return nil }
        let status = try await call(purpose: purpose, deviceId: deviceId) { tok, sec, t, n in
            SwitchBotAPI.status(deviceId: deviceId, token: tok, secret: sec, t: t, nonce: n)
        } decode: { try SwitchBotResponse.decodeStatus(status: $0, body: $1) }
        statusAt[deviceId] = ContinuousClock.now
        let state = SwitchBotMapping.state(from: status, kind: kind, previousMode: modes[deviceId], reachable: true)
        if let mode = state.colorMode { modes[deviceId] = mode }
        var old = states[deviceId]
        old?.updatedAt = state.updatedAt
        states[deviceId] = state
        if old != state { eventContinuation.yield(.stateChanged(lid, state)) }
        return state
    }

    /// Budgeted, signed call with error mapping. `deviceId` scopes reachability updates.
    private func call<T>(purpose: Purpose, deviceId: String?,
                         _ build: (String, String, Int64, String) -> SwitchBotRequest,
                         decode: (Int, Data) throws -> T) async throws -> T {
        try await ensureCredentials()
        guard let token, let secret else { throw LightCoreError.authenticationRequired(.switchbot) }
        if purpose == .poll, await budget.available(Self.budgetKey) < Double(configuration.pollReserve + 1) {
            throw SwitchBotError.budgetExhausted
        }
        guard await budget.tryAcquire(Self.budgetKey) else {
            eventContinuation.yield(.error("SwitchBot daily request budget used up"))
            throw SwitchBotError.budgetExhausted
        }
        try await burst.acquire("burst")
        let request = build(token, secret, SwitchBotAPI.nowMillis(), UUID().uuidString)
        let (status, body) = try await http(request)
        do {
            let value = try decode(status, body)
            lastSuccess = Date()
            if let deviceId { setReachable(true, deviceId) }
            return value
        } catch SwitchBotError.unauthorized {
            if let last = lastSuccess, Date().timeIntervalSince(last) < 86_400 {
                // Worked recently: most likely the account-wide 10k/day limit (other apps count too).
                eventContinuation.yield(.error("SwitchBot answered Unauthorized; the daily request limit is probably reached"))
                throw SwitchBotError.unauthorized
            }
            eventContinuation.yield(.needsReauthentication(accountID: account?.id))
            throw LightCoreError.authenticationRequired(.switchbot)
        } catch let error as SwitchBotError where error.isOffline {
            if let deviceId { setReachable(false, deviceId) }
            throw LightCoreError.unreachable(error.localizedDescription)
        }
    }

    private func http(_ request: SwitchBotRequest) async throws -> (Int, Data) {
        do {
            let r = try await configuration.http.perform(request, baseURL: configuration.baseURL, timeout: configuration.timeout)
            return (r.status, r.body)
        } catch let error as LightCoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LightCoreError.transport(error.localizedDescription)
        }
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.pollInterval)
            } catch {
                return
            }
            for device in lightDevices where device.enableCloudService != false {
                if Task.isCancelled { return }
                do {
                    try await refreshStatus(device.deviceId, purpose: .poll)
                } catch SwitchBotError.budgetExhausted {
                    log.notice("SwitchBot polling paused: budget reserve reached")
                    break
                } catch {
                    log.notice("SwitchBot status poll failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func setReachable(_ value: Bool, _ deviceId: String) {
        guard reachable[deviceId] != value else { return }
        reachable[deviceId] = value
        if var s = states[deviceId] { s.reachable = value; states[deviceId] = s }
        if let lid = LightID(brand: .switchbot, stableId: deviceId) {
            eventContinuation.yield(.reachabilityChanged(lid, reachable: value))
        }
    }

    private func light(for device: SwitchBotDevice) -> Light? {
        guard let kind = device.lightKind, let id = LightID(brand: .switchbot, stableId: device.deviceId) else { return nil }
        var state = states[device.deviceId] ?? LightState(reachable: false)
        state.reachable = device.enableCloudService != false && (reachable[device.deviceId] ?? (states[device.deviceId] != nil))
        return Light(id: id, name: device.deviceName, capabilities: kind.capabilities, state: state,
                     providerRef: device.deviceId, manufacturer: "SwitchBot", model: device.deviceType)
    }

    private func metadata(for device: SwitchBotDevice) -> [String: String] {
        var m = ["deviceType": device.deviceType]
        if let hub = device.hubDeviceId { m["hubDeviceId"] = hub }
        if let cloud = device.enableCloudService { m["cloudService"] = cloud ? "on" : "off" }
        return m
    }

    private struct CacheSnapshot: Codable {
        var fetchedAt: Date?
        var devices: [SwitchBotDevice]
    }

    private func ensureCredentials() async throws {
        guard !credentialsLoaded, let owner = account?.id else { return }
        let store = secretStore
        func load(_ item: String) async throws -> String? {
            try await store.string(for: SecretKey(brand: .switchbot, owner: owner, item: item))
        }
        token = try await load(SecretItem.token)
        secret = try await load(SecretItem.secret)
        if devices.isEmpty, let cache = try await load(SecretItem.deviceCache),
           let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: Data(cache.utf8)) {
            devices = Dictionary(snapshot.devices.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
            deviceOrder = snapshot.devices.map(\.deviceId)
            listFetchedAt = snapshot.fetchedAt
        }
        credentialsLoaded = true
    }

    private func storeSecret(_ value: String, _ item: String) async throws {
        guard let owner = account?.id else { return }
        try await secretStore.set(value, for: SecretKey(brand: .switchbot, owner: owner, item: item))
    }
}
