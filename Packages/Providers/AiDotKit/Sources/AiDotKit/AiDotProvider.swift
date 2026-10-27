import AiDotCodec
import Foundation
import LightCore
import NetKit
import Synchronization

/// AiDot / Linkind Wi-Fi lights: one-time cloud sign-in for the device list (`aesKey`, `password`,
/// `devId`), then LAN-only control over TCP 10000 with UDP 6666 discovery. See README.md.
public actor AiDotProvider: LightProvider {
    public static let brand: Brand = .aidot

    public struct Configuration: Sendable {
        /// Replaces `https://prod-{region}-api.arnoo.com/v35` (tests: `FakeAiDotCloud.baseURL`).
        public var baseURLOverride: URL?
        public var discoveryPort: UInt16 = AiDotConstants.discoveryPort
        public var tcpPort: UInt16 = AiDotConstants.tcpPort
        /// Whether UDP broadcast may be used (multicast entitlement detected by the app).
        public var broadcastAvailable = false
        public var deviceListTTL: Duration = AiDotConstants.deviceListRefreshInterval
        /// How often the background task re-runs discovery for offline lights and checks the list age.
        public var maintenanceInterval: Duration = AiDotConstants.discoverySlowInterval
        public var httpTimeout: Duration = .seconds(15)
        public var connectTimeout: Duration = .seconds(5)
        public var loginTimeout: Duration = .seconds(5)
        public var pingInterval: Duration = AiDotConstants.pingInterval
        public var firstGenerationPingInterval: Duration = AiDotConstants.firstGenerationPingInterval
        public var maxMissedPings = AiDotConstants.maxMissedPings
        public var reconnectBackoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2)
        /// Per-host timeout for unicast discovery probes.
        public var unicastProbeTimeout: Duration = .seconds(1)
        public var sweepConcurrency = 32
        public var http: any AiDotHTTPTransport = URLSessionAiDotHTTPTransport()
        public var tcp: any AiDotTCPConnector = AiDotTransports.tcp
        public var udp: any AiDotDatagramTransport = AiDotTransports.udp

        public init() {}
    }

    /// Secret item names (`SecretKey(brand: .aidot, owner: <username>, item: ...)`). The password is never stored.
    public enum SecretItem {
        public static let accessToken = "accessToken"
        public static let refreshToken = "refreshToken"
        public static let userId = "userId"
        /// Cached cloud device list (contains device `aesKey`/`password`), so control works offline.
        public static let deviceCache = "deviceCache"
        public static let terminalId = "terminalId"
        public static let all = [accessToken, refreshToken, userId, deviceCache, terminalId]
    }

    public private(set) var account: ProviderAccount?
    public nonisolated let events: AsyncStream<ProviderEvent>

    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    private let secretStore: any SecretStore
    private var configuration: Configuration
    private let log = Log(package: "aidotkit", category: "provider")

    private var userId: String?
    private var accessToken: String?
    private var refreshToken: String?
    private var credentialsLoaded = false
    private var refreshTask: Task<Void, any Error>?

    private var records: [String: AiDotDeviceRecord] = [:]
    private var recordOrder: [String] = []
    private var recordsFetchedAt: Date?
    private var models: [String: AiDotLightModel] = [:]
    private var hosts: [String: String] = [:]
    private var reachable: [String: Bool] = [:]
    private var sessions: [String: AiDotDeviceSession] = [:]

    private let sessionEvents: AsyncStream<AiDotSessionEvent>
    private let sessionContinuation: AsyncStream<AiDotSessionEvent>.Continuation
    private var pumpTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    /// `stop()` was called (background); sessions stay closed until `start()`.
    private var suspended = false

    public init(account: ProviderAccount? = nil, secretStore: any SecretStore, configuration: Configuration = Configuration()) {
        self.account = account
        self.secretStore = secretStore
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (sessionEvents, sessionContinuation) = AsyncStream<AiDotSessionEvent>.makeStream()
    }

    deinit {
        pumpTask?.cancel()
        maintenanceTask?.cancel()
        eventContinuation.finish()
        sessionContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Foreground: (re)open one TCP session per light and start background maintenance.
    public func start() async {
        suspended = false
        ensurePump()
        try? await ensureCredentials()
        startSessions()
        if maintenanceTask == nil {
            maintenanceTask = Task { [weak self] in await self?.maintenanceLoop() }
        }
    }

    /// Background: close all sessions and stop timers.
    public func stop() async {
        suspended = true
        maintenanceTask?.cancel()
        maintenanceTask = nil
        for session in sessions.values { await session.stop() }
    }

    public func setBroadcastAvailable(_ available: Bool) {
        configuration.broadcastAvailable = available
    }

    /// Signs out: removes stored secrets and closes sessions.
    public func signOut() async {
        await stop()
        sessions = [:]
        if let owner = account?.id {
            for item in SecretItem.all where item != SecretItem.terminalId {
                try? await secretStore.remove(SecretKey(brand: .aidot, owner: owner, item: item))
            }
        }
        account = nil
        userId = nil; accessToken = nil; refreshToken = nil
        records = [:]; recordOrder = []; recordsFetchedAt = nil; models = [:]
    }

    // MARK: - Pairing

    /// A placeholder `DiscoveredDevice` for "Sign in to AiDot" in the Add flow.
    public nonisolated static func accountPlaceholder() -> DiscoveredDevice {
        DiscoveredDevice(id: "account", brand: .aidot, name: "AiDot account", method: .cloud)
    }

    /// Signs in (if needed) and returns the paired device. For a discovered light known to the
    /// account the result is that light; otherwise (e.g. ``accountPlaceholder()``) an account-level
    /// `PairedDevice` listing every LAN light of the account.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        try? await ensureCredentials()
        if account == nil || accessToken == nil || userId == nil {
            _ = try await signIn(using: ui)
        }
        await ui.status("Loading your AiDot devices…")
        try await refreshDeviceList()
        let accountID = account?.id
        if let record = records[device.id], record.isLANLight, let lightID = LightID(brand: .aidot, stableId: record.id) {
            return PairedDevice(
                id: record.id, brand: .aidot, name: record.name, model: record.modelId,
                hostHint: hosts[record.id] ?? device.host ?? record.cloudIPAddress, port: Int(configuration.tcpPort),
                accountID: accountID, lightIDs: [lightID], metadata: metadata(for: record))
        }
        let lights = lanRecords.compactMap { LightID(brand: .aidot, stableId: $0.id) }
        return PairedDevice(id: "account:\(accountID ?? "")", brand: .aidot, name: "AiDot account", accountID: accountID,
                            lightIDs: lights, metadata: ["lights": String(lights.count)])
    }

    /// Collects Country, Username and Password, signs in and stores tokens (never the password).
    @discardableResult
    public func signIn(using ui: any PairingInteraction) async throws -> ProviderAccount {
        let countries = AiDotCountry.sortedByName
        let index = try await ui.choose("Country or region of your AiDot account", options: countries.map(\.name))
        guard countries.indices.contains(index) else { throw LightCoreError.userCancelled }
        let country = countries[index]
        let username = try await ui.text("AiDot e-mail address").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw LightCoreError.userCancelled }
        let password = try await ui.secureText("AiDot password")
        await ui.status("Signing in to AiDot…")
        return try await signIn(country: country, username: username, password: password)
    }

    /// Programmatic sign-in (used by `signIn(using:)`).
    @discardableResult
    public func signIn(country: AiDotCountry, username: String, password: String) async throws -> ProviderAccount {
        let owner = username
        let terminalKey = SecretKey(brand: .aidot, owner: owner, item: SecretItem.terminalId)
        var rawTerminal = try? await secretStore.string(for: terminalKey)
        if rawTerminal == nil {
            let fresh = UUID().uuidString.lowercased()
            try? await secretStore.set(fresh, for: terminalKey)
            rawTerminal = fresh
        }
        let encrypted = try AiDotCrypto.encryptPassword(password)
        let request = AiDotAPI.login(country: country, username: username, encryptedPassword: encrypted,
                                     terminalId: AiDotAPI.terminalId(rawId: rawTerminal ?? AiDotConstants.fallbackTerminalRawId))
        let base = configuration.baseURLOverride ?? country.region.baseURL
        let (status, body) = try await http(request, baseURL: base)
        let login = try AiDotAPI.decodeLogin(status: status, body: body)

        let newAccount = ProviderAccount(
            id: owner, brand: .aidot, displayName: Self.mask(username), region: country.code,
            secretKeys: SecretItem.all.map { SecretKey(brand: .aidot, owner: owner, item: $0) },
            metadata: ["countryCode": country.code, "countryName": country.name, "cloudRegion": country.region.rawValue])
        if let old = account, old.id != owner { await signOut() }
        account = newAccount
        userId = login.userId
        accessToken = login.accessToken
        refreshToken = login.refreshToken
        credentialsLoaded = true
        try await storeSecret(login.userId, SecretItem.userId)
        try await storeSecret(login.accessToken, SecretItem.accessToken)
        try await storeSecret(login.refreshToken, SecretItem.refreshToken)
        log.notice("signed in to AiDot (\(country.region.rawValue)) as \(Self.mask(username))")
        return newAccount
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        ensurePump()
        try await ensureCredentials()
        guard account != nil else { throw LightCoreError.authenticationRequired(.aidot) }
        if records.isEmpty || isDeviceListStale {
            do {
                try await refreshDeviceList()
            } catch where !records.isEmpty && !(error is CancellationError) {
                // Local-first: the cached keys keep LAN control working while the cloud is down or
                // the sign-in expired (needsReauthentication has been emitted in that case).
                log.notice("AiDot device list refresh failed (\(error)); using the cached list")
            }
        }
        if !suspended { startSessions() }
        return lanRecords.compactMap(light(for:))
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .aidot, let record = records[light.stableId], var model = models[light.stableId] else {
            throw LightCoreError.lightNotFound(light)
        }
        let attributes = AiDotCommandMapper.attributes(for: command, features: model.features, currentlyOn: model.isOn)
        guard !attributes.isEmpty else {
            if command.effect != nil { throw LightCoreError.unsupported("AiDot effects need the cloud (not implemented)") }
            return
        }
        guard let session = sessions[record.id] else { throw LightCoreError.unreachable("AiDot light \(record.name) is not connected") }
        try await session.send(attributes)
        model.apply(attributes)
        models[record.id] = model
        eventContinuation.yield(.stateChanged(light, model.lightState(reachable: true)))
    }

    // MARK: - Discovery

    public nonisolated func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        AsyncStream { continuation in
            let task = Task {
                await self.runDiscovery(options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runDiscovery(_ options: DiscoveryOptions, report: @escaping @Sendable (DiscoveredDevice) -> Void) async {
        try? await ensureCredentials()
        guard let payload = try? AiDotDiscovery.datagram(userId: userId) else { return }
        let udp = configuration.udp
        let port = configuration.discoveryPort
        let probeTimeout = configuration.unicastProbeTimeout
        let useBroadcast = (options.broadcastAvailable || configuration.broadcastAvailable) && options.methods.contains(.broadcast)

        var cached: [String] = []
        if options.methods.contains(.cached) {
            cached = options.cachedHosts + Array(hosts.values) + lanRecords.compactMap(\.cloudIPAddress)
        }
        let manual = options.methods.contains(.manual) ? options.manualHosts : []
        let sweepHosts = (!useBroadcast && options.methods.contains(.sweep)) ? udp.sweepHosts().compactMap(IPv4Addr.init) : []
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)
        let found = FoundSet()

        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                if useBroadcast {
                    group.addTask {
                        for await reply in udp.broadcast(payload, port: port, listen: options.timeout) {
                            await self.handleDiscoveryReply(reply, method: .broadcast, found: found, report: report)
                        }
                    }
                }
                var seenHosts = Set<String>()
                for (host, method) in manual.map({ ($0, DiscoveryMethod.manual) }) + cached.map({ ($0, DiscoveryMethod.cached) })
                where seenHosts.insert(host).inserted {
                    group.addTask {
                        if let reply = await udp.request(payload, host: host, port: port, timeout: probeTimeout) {
                            await self.handleDiscoveryReply(reply, method: method, found: found, report: report)
                        }
                    }
                }
                if !sweepHosts.isEmpty {
                    group.addTask {
                        let stream = sweeper.stream(sweepHosts) { ip in
                            await udp.request(payload, host: ip.description, port: port, timeout: probeTimeout)
                        }
                        for await reply in stream {
                            await self.handleDiscoveryReply(reply, method: .sweep, found: found, report: report)
                        }
                    }
                }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: options.timeout)
            work.cancel()
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()

        // Lights known from the account but silent on the LAN.
        if options.methods.contains(.cloud), !Task.isCancelled {
            for record in lanRecords where !found.contains(record.id) {
                report(DiscoveredDevice(id: record.id, brand: .aidot, name: record.name, model: record.modelId,
                                        host: hosts[record.id] ?? record.cloudIPAddress, port: Int(configuration.tcpPort),
                                        macAddress: record.mac, method: .cloud, metadata: metadata(for: record)))
            }
        }
    }

    private func handleDiscoveryReply(_ reply: AiDotDatagramReply, method: DiscoveryMethod, found: FoundSet,
                                      report: @Sendable (DiscoveredDevice) -> Void) async {
        guard let parsed = AiDotDiscovery.parseReply(reply.data), found.insert(parsed.devId) else { return }
        let host = reply.host
        hosts[parsed.devId] = host
        if let session = sessions[parsed.devId] { await session.updateHost(host) }
        let record = records[parsed.devId]
        var metadata = parsed.metadata
        if let ip = parsed.ip { metadata["reportedIP"] = ip }
        report(DiscoveredDevice(
            id: parsed.devId, brand: .aidot, name: record?.name ?? "AiDot \(parsed.productModel ?? "light")",
            model: parsed.productModel ?? record?.modelId, host: host, port: Int(configuration.tcpPort),
            macAddress: parsed.mac ?? record?.mac, method: method, metadata: metadata))
    }

    // MARK: - Cloud

    private var isDeviceListStale: Bool {
        guard let at = recordsFetchedAt else { return true }
        return Date().timeIntervalSince(at) > configuration.deviceListTTL.seconds
    }

    private var baseURL: URL {
        if let o = configuration.baseURLOverride { return o }
        let region = account?.metadata["cloudRegion"].flatMap(AiDotRegion.init(rawValue:))
            ?? account?.region.flatMap(AiDotCountry.region(forCountryCode:)) ?? .us
        return region.baseURL
    }

    /// `GET /houses` (owner houses only) -> `/devices?houseId=` -> `/products/<ids>`; cached in the Keychain.
    public func refreshDeviceList() async throws {
        let houses = try await authorized({ AiDotAPI.houses(token: $0) }) { try AiDotAPI.decodeHouses(status: $0, body: $1) }
        var devices: [AiDotDeviceRecord] = []
        for house in AiDotAPI.ownedHouses(houses) {
            devices += try await authorized({ AiDotAPI.devices(houseId: house.id, token: $0) }) {
                try AiDotAPI.decodeDevices(status: $0, body: $1)
            }
        }
        let productIds = devices.compactMap(\.productId)
        if !productIds.isEmpty {
            let products = try await authorized({ AiDotAPI.products(ids: productIds, token: $0) }) {
                try AiDotAPI.decodeProducts(status: $0, body: $1)
            }
            devices = AiDotAPI.attachProducts(products, to: devices)
        }
        let now = Date()
        applyDeviceList(devices, fetchedAt: now)
        let cache = AiDotJSON.obj([
            "fetchedAt": .double(now.timeIntervalSince1970),
            "devices": .array(devices.map(\.json)),
        ])
        try? await storeSecret(cache.compactString(), SecretItem.deviceCache)
    }

    private func applyDeviceList(_ devices: [AiDotDeviceRecord], fetchedAt: Date) {
        let old = records
        records = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        recordOrder = devices.map(\.id)
        recordsFetchedAt = fetchedAt
        for record in devices where record.isLANLight {
            if var model = models[record.id] {
                model.features = AiDotFeatures(record: record)
                models[record.id] = model
            } else {
                models[record.id] = AiDotLightModel(record: record)
            }
            if old.isEmpty { continue }
            if let previous = old[record.id] {
                guard previous != record, let l = light(for: record) else { continue }
                eventContinuation.yield(.lightUpdated(l))
                // Key or device password changed: rebuild the session.
                if previous.sessionKey != record.sessionKey || previous.password != record.password,
                   let s = sessions.removeValue(forKey: record.id) {
                    Task { await s.stop() }
                }
            } else if let l = light(for: record) {
                eventContinuation.yield(.lightAdded(l))
            }
        }
        for id in old.keys where records[id] == nil || records[id]?.isLANLight == false {
            if let s = sessions.removeValue(forKey: id) { Task { await s.stop() } }
            models[id] = nil
            if old[id]?.isLANLight == true, let lid = LightID(brand: .aidot, stableId: id) {
                eventContinuation.yield(.lightRemoved(lid))
            }
        }
    }

    /// Authenticated request with one token refresh on 21026; emits `needsReauthentication` when the
    /// session cannot be recovered (refresh answered 21025, or 21025/21027/21041 directly).
    private func authorized<T>(_ build: (String) -> AiDotHTTPRequest,
                               decode: (Int, Data) throws -> T) async throws -> T {
        try await ensureCredentials()
        guard let token = accessToken else { throw await reauthenticationRequired() }
        var (status, body) = try await http(build(token), baseURL: baseURL)
        if AiDotCloudError.classify(status: status, body: body) == .tokenExpired {
            try await refreshTokens()
            guard let fresh = accessToken else { throw await reauthenticationRequired() }
            (status, body) = try await http(build(fresh), baseURL: baseURL)
        }
        do {
            return try decode(status, body)
        } catch let error as AiDotCloudError where error.requiresReauthentication || error == .tokenExpired {
            throw await reauthenticationRequired()
        }
    }

    /// `POST /users/refreshToken`; concurrent callers share one refresh.
    private func refreshTokens() async throws {
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refresh = refreshToken, !refresh.isEmpty else { throw await reauthenticationRequired() }
        let (status, body) = try await http(AiDotAPI.refreshToken(refresh), baseURL: baseURL)
        let pair: AiDotTokenPair
        do {
            pair = try AiDotAPI.decodeRefresh(status: status, body: body)
        } catch let error as AiDotCloudError {
            log.notice("AiDot token refresh failed: \(error.errorDescription ?? "")")
            throw await reauthenticationRequired()
        }
        accessToken = pair.accessToken
        try await storeSecret(pair.accessToken, SecretItem.accessToken)
        if let r = pair.refreshToken {
            refreshToken = r
            try await storeSecret(r, SecretItem.refreshToken)
        }
    }

    /// Drops the dead access token, tells the UI to re-run sign-in and returns the error to throw.
    /// LAN sessions keep working with the cached device keys.
    private func reauthenticationRequired() async -> LightCoreError {
        accessToken = nil
        if let owner = account?.id {
            try? await secretStore.remove(SecretKey(brand: .aidot, owner: owner, item: SecretItem.accessToken))
        }
        eventContinuation.yield(.needsReauthentication(accountID: account?.id))
        return .authenticationRequired(.aidot)
    }

    private func ensureCredentials() async throws {
        guard !credentialsLoaded, let owner = account?.id else { return }
        let store = secretStore
        func load(_ item: String) async throws -> String? {
            try await store.string(for: SecretKey(brand: .aidot, owner: owner, item: item))
        }
        userId = try await load(SecretItem.userId)
        accessToken = try await load(SecretItem.accessToken)
        refreshToken = try await load(SecretItem.refreshToken)
        if records.isEmpty, let cache = try await load(SecretItem.deviceCache), let json = try? AiDotJSON.parse(cache) {
            let devices = (json["devices"]?.arrayValue ?? []).compactMap(AiDotDeviceRecord.init(json:))
            var fetchedAt = Date.distantPast
            if case .double(let d)? = json["fetchedAt"] { fetchedAt = Date(timeIntervalSince1970: d) }
            applyDeviceList(devices, fetchedAt: fetchedAt)
        }
        credentialsLoaded = true
    }

    private func storeSecret(_ value: String, _ item: String) async throws {
        guard let owner = account?.id else { return }
        try await secretStore.set(value, for: SecretKey(brand: .aidot, owner: owner, item: item))
    }

    // MARK: - Sessions

    private var lanRecords: [AiDotDeviceRecord] {
        recordOrder.compactMap { records[$0] }.filter(\.isLANLight)
    }

    private func startSessions() {
        guard let userId else { return }
        ensurePump()
        let settings = AiDotDeviceSession.Settings(
            port: configuration.tcpPort, connectTimeout: configuration.connectTimeout, loginTimeout: configuration.loginTimeout,
            pingInterval: configuration.pingInterval, firstGenerationPingInterval: configuration.firstGenerationPingInterval,
            maxMissedPings: configuration.maxMissedPings, backoff: configuration.reconnectBackoff)
        for record in lanRecords {
            guard let key = record.sessionKey else { continue }
            let session: AiDotDeviceSession
            if let existing = sessions[record.id] {
                session = existing
            } else {
                // python-aidot ignores the cloud IP for the first-generation model and waits for discovery.
                let host = hosts[record.id] ?? (record.isFirstGeneration ? nil : record.cloudIPAddress)
                session = AiDotDeviceSession(record: record, aesKey: key, userId: userId, host: host,
                                             connector: configuration.tcp, settings: settings, events: sessionContinuation)
                sessions[record.id] = session
            }
            Task { await session.start() }
        }
    }

    private func ensurePump() {
        guard pumpTask == nil else { return }
        let stream = sessionEvents
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AiDotSessionEvent) {
        switch event {
        case .online(let deviceId, let online):
            reachable[deviceId] = online
            guard let id = LightID(brand: .aidot, stableId: deviceId) else { return }
            eventContinuation.yield(.reachabilityChanged(id, reachable: online))
        case .message(let deviceId, let message):
            guard let attributes = message.attributes, var model = models[deviceId],
                  let id = LightID(brand: .aidot, stableId: deviceId) else { return }
            model.apply(attributes)
            models[deviceId] = model
            eventContinuation.yield(.stateChanged(id, model.lightState(reachable: reachable[deviceId] ?? true)))
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.maintenanceInterval)
            } catch {
                return
            }
            if isDeviceListStale, accessToken != nil {
                do {
                    try await refreshDeviceList()
                    if !suspended { startSessions() }
                } catch {
                    log.notice("periodic AiDot device list refresh failed: \(error)")
                }
            }
            if lanRecords.contains(where: { reachable[$0.id] != true }) {
                let options = DiscoveryOptions(timeout: .seconds(4), methods: [.broadcast, .cached],
                                               broadcastAvailable: configuration.broadcastAvailable)
                await runDiscovery(options) { _ in }
            }
        }
    }

    // MARK: - Helpers

    private func light(for record: AiDotDeviceRecord) -> Light? {
        guard let id = LightID(brand: .aidot, stableId: record.id) else { return nil }
        let model = models[record.id] ?? AiDotLightModel(record: record)
        return Light(id: id, name: record.name, capabilities: model.features.capabilities,
                     state: model.lightState(reachable: reachable[record.id] ?? false), providerRef: record.id,
                     model: record.modelId)
    }

    private func metadata(for record: AiDotDeviceRecord) -> [String: String] {
        var m: [String: String] = [:]
        if let v = record.modelId { m["modelId"] = v }
        if let v = record.productId { m["productId"] = v }
        if let v = record.mac { m["mac"] = v }
        if let v = record.firmwareVersion { m["firmwareVersion"] = v }
        if let v = record.houseId { m["houseId"] = v }
        return m
    }

    /// `jo***@example.com`.
    static func mask(_ username: String) -> String {
        guard let at = username.firstIndex(of: "@") else { return String(username.prefix(2)) + "***" }
        return String(username[..<at].prefix(2)) + "***" + String(username[at...])
    }

    private func http(_ request: AiDotHTTPRequest, baseURL: URL) async throws -> (Int, Data) {
        do {
            let r = try await configuration.http.perform(request, baseURL: baseURL, timeout: configuration.httpTimeout)
            return (r.status, r.body)
        } catch let error as LightCoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LightCoreError.transport(error.localizedDescription)
        }
    }
}

/// Thread-safe set of devIds seen during one discovery run.
final class FoundSet: Sendable {
    private let ids = Mutex<Set<String>>([])
    func insert(_ id: String) -> Bool { ids.withLock { $0.insert(id).inserted } }
    func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}
