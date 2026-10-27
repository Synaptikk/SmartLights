import Foundation
import HueCodec
import LightCore
import NetKit

/// Philips Hue bridge provider (CLIP v2, local only).
///
/// - Discovery: Bonjour `_hue._tcp`, `discovery.meethue.com` (at most once per minute), manual
///   and cached hosts; each candidate is confirmed with `GET /api/config`.
/// - Pairing: link button + `POST /api`; app key and client key go to `SecretStore`.
/// - Control: `PUT /clip/v2/resource/light|grouped_light|scene/{id}`, at most
///   `maxConcurrentRequests` in flight per bridge, 10/s per light and 1/s per grouped_light.
/// - State: `/eventstream/clip/v2` with a `geofence_client` rename keep-alive every 60 s and a
///   full resync after a gap of more than 60 s.
///
/// Light ids are `hue:<BRIDGEID>/<light uuid>`; scene ids `hue:<BRIDGEID>/<scene uuid>`.
/// The logic is portable; the network comes from an injected `HueTransport`
/// (`URLSessionHueTransport` on Apple platforms).
public actor HueProvider: LightProvider {
    public static let brand: Brand = .hue

    /// Prompt shown before pairing (PairingInteraction.confirm).
    public static let linkButtonPrompt = "Press the round button on the Hue Bridge, then tap Continue"

    public struct Configuration: Sendable {
        /// `devicetype` sent when pairing (`<app>#<device>`).
        public var deviceType = "SmartLights#iphone"
        public var pairingTimeout: Duration = .seconds(30)
        public var pairingPollInterval: Duration = .seconds(1)
        /// aiohue: "the bridge denies more than 3 concurrent requests".
        public var maxConcurrentRequests = 3
        public var lightRateLimit = RateLimiter<String>.Limit(10, per: .seconds(1))
        public var groupRateLimit = RateLimiter<String>.Limit(1, per: .seconds(1))
        /// Retries on HTTP 429/503 with `busyRetryBase * attempt` backoff (aiohue: 0.25 s * n).
        public var maxBusyRetries = 10
        public var busyRetryBase: Duration = .milliseconds(250)
        public var requestTimeout: Duration = .seconds(10)
        public var probeTimeout: Duration = .seconds(4)
        public var cloudDiscoveryURL = URL(string: "https://discovery.meethue.com/")!
        public var cloudDiscoveryMinInterval: Duration = .seconds(60)
        public var keepaliveInterval: Duration = .seconds(60)
        public var eventReadTimeout: Duration = .seconds(90)
        public var resyncGap: Duration = .seconds(60)
        public var eventStreamBackoff: ExponentialBackoff = .hueEventStream
        /// Open the event streams automatically after `loadLights()` / `pair`.
        public var autoConnectEvents = true

        public init() {}
    }

    struct BridgeState {
        var id: String
        var host: String
        var port: Int?
        var scheme: String
        var name: String
        var model: String?
        var store = HueResourceStore()
        var loaded = false
        let semaphore: AsyncSemaphore
        var eventTask: Task<Void, Never>?
        var keepaliveTask: Task<Void, Never>?
        var geofenceID: String?
        var connected = false
        var disconnectedAt: ContinuousClock.Instant?
        var lastSync: ContinuousClock.Instant?
    }

    public let configuration: Configuration
    private let secrets: any SecretStore
    private let transport: any HueTransport
    private let lightLimiter: RateLimiter<String>
    private let groupLimiter: RateLimiter<String>
    private var bridgeStates: [String: BridgeState] = [:]
    private var lastCloudFetch: ContinuousClock.Instant?
    private var cloudCache: [HueDiscoveryEntry] = []
    private let clock = ContinuousClock()
    private let log = Log(package: "huekit", category: "provider")

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation

    public init(secrets: any SecretStore, transport: any HueTransport, configuration: Configuration = Configuration()) {
        self.secrets = secrets
        self.transport = transport
        self.configuration = configuration
        self.lightLimiter = RateLimiter(configuration.lightRateLimit)
        self.groupLimiter = RateLimiter(configuration.groupRateLimit)
        let (stream, continuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        for bridge in bridgeStates.values {
            bridge.eventTask?.cancel()
            bridge.keepaliveTask?.cancel()
        }
        continuation.finish()
    }

    // MARK: - Secrets and accounts

    public static func appKeySecret(bridgeID: String) -> SecretKey {
        SecretKey(brand: .hue, owner: bridgeID, item: "appkey")
    }

    public static func clientKeySecret(bridgeID: String) -> SecretKey {
        SecretKey(brand: .hue, owner: bridgeID, item: "clientkey")
    }

    /// The first paired bridge's account (Hue has one account per bridge; see `accounts`).
    public var account: ProviderAccount? { accounts.first }

    public var accounts: [ProviderAccount] {
        bridgeStates.keys.sorted().compactMap { id in bridgeStates[id].map(Self.makeAccount) }
    }

    private static func makeAccount(_ bridge: BridgeState) -> ProviderAccount {
        ProviderAccount(
            id: bridge.id,
            brand: .hue,
            displayName: "\(bridge.name) (\(bridge.id.suffix(6)))",
            secretKeys: [appKeySecret(bridgeID: bridge.id), clientKeySecret(bridgeID: bridge.id)],
            metadata: ["host": bridge.host, "model": bridge.model ?? ""]
        )
    }

    // MARK: - Bridge registry

    /// Restores a previously paired bridge (credentials are read from `SecretStore` on use).
    public func addBridge(_ device: PairedDevice) {
        let id = HueBridgeID.normalize(device.id) ?? device.id.uppercased()
        let parsed = HueEndpoint.parseHost(device.hostHint ?? "")
        register(
            id: id, host: parsed.host, port: parsed.port ?? Self.explicitPort(device.port),
            scheme: device.metadata["scheme"] ?? "https", name: device.name, model: device.model)
    }

    /// Updates the cached address of a bridge (ids are stable, IPs are hints).
    public func updateHost(bridgeID: String, host: String, port: Int? = nil) {
        let parsed = HueEndpoint.parseHost(host)
        bridgeStates[bridgeID.uppercased()]?.host = parsed.host
        bridgeStates[bridgeID.uppercased()]?.port = parsed.port ?? Self.explicitPort(port)
    }

    /// Forgets a bridge; optionally deletes its keys.
    public func removeBridge(id: String, deleteCredentials: Bool = true) async {
        let key = id.uppercased()
        if let bridge = bridgeStates.removeValue(forKey: key) {
            bridge.eventTask?.cancel()
            bridge.keepaliveTask?.cancel()
        }
        if deleteCredentials {
            try? await secrets.remove(Self.appKeySecret(bridgeID: key))
            try? await secrets.remove(Self.clientKeySecret(bridgeID: key))
        }
    }

    public var bridgeIDs: [String] { bridgeStates.keys.sorted() }

    /// Whether the event stream of `bridgeID` is currently connected.
    public func isEventStreamConnected(bridgeID: String) -> Bool {
        bridgeStates[bridgeID.uppercased()]?.connected ?? false
    }

    private func register(id: String, host: String, port: Int?, scheme: String, name: String, model: String?) {
        if var existing = bridgeStates[id] {
            existing.host = host
            existing.port = port
            existing.scheme = scheme
            existing.name = name
            existing.model = model ?? existing.model
            bridgeStates[id] = existing
        } else {
            bridgeStates[id] = BridgeState(
                id: id, host: host, port: port, scheme: scheme, name: name, model: model,
                semaphore: AsyncSemaphore(configuration.maxConcurrentRequests))
        }
    }

    private static func explicitPort(_ port: Int?) -> Int? {
        guard let port, port != 443, port != 80 else { return nil }
        return port
    }

    // MARK: - Discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream<DiscoveredDevice>.makeStream()
        let task = Task {
            await self.runDiscovery(options, sink: DiscoverySink(continuation))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(_ options: DiscoveryOptions, sink: DiscoverySink) async {
        let manual = options.methods.contains(.manual) ? options.manualHosts : []
        let cached = options.methods.contains(.cached) ? options.cachedHosts : []
        let useBonjour = options.methods.contains(.bonjour)
        let useCloud = options.methods.contains(.cloud)
        let transport = self.transport
        let timeout = options.timeout

        await withTaskGroup(of: Void.self) { outer in
            outer.addTask {
                await withTaskGroup(of: Void.self) { group in
                    for host in manual {
                        group.addTask {
                            if let d = await self.probeDevice(host, method: .manual) { await sink.emit(d) }
                        }
                    }
                    for host in cached {
                        group.addTask {
                            if let d = await self.probeDevice(host, method: .cached) { await sink.emit(d) }
                        }
                    }
                    if useBonjour {
                        group.addTask {
                            for await record in transport.browseBonjour() {
                                if let d = await self.device(from: record) { await sink.emit(d) }
                            }
                        }
                    }
                    if useCloud {
                        group.addTask {
                            for entry in await self.cloudEntries() {
                                if let d = await self.device(from: entry) { await sink.emit(d) }
                            }
                        }
                    }
                }
            }
            outer.addTask { try? await Task.sleep(for: timeout) }
            _ = await outer.next()
            outer.cancelAll()
        }
    }

    private func probeDevice(_ input: String, method: DiscoveryMethod) async -> DiscoveredDevice? {
        let parsed = HueEndpoint.parseHost(input)
        guard !parsed.host.isEmpty else { return nil }
        do {
            let result = try await probe(host: parsed.host, port: parsed.port)
            return Self.discovered(config: result.config, host: parsed.host, port: parsed.port, scheme: result.scheme, method: method)
        } catch {
            log.info("Hue probe of \(input) failed: \(error)")
            return nil
        }
    }

    private func device(from record: HueBonjourRecord) async -> DiscoveredDevice? {
        guard let host = record.host else { return nil }
        let port = Self.explicitPort(record.port)
        if let id = record.txt["bridgeid"].flatMap(HueBridgeID.normalize) {
            var metadata: [String: String] = ["scheme": "https"]
            if let model = record.txt["modelid"] { metadata["modelid"] = model }
            return DiscoveredDevice(
                id: id, brand: .hue, name: record.name, model: record.txt["modelid"], host: host, port: port,
                method: .bonjour, metadata: metadata)
        }
        return await probeDevice(HueEndpoint.authority(host: host, port: port), method: .bonjour)
    }

    private func device(from entry: HueDiscoveryEntry) async -> DiscoveredDevice? {
        guard let ip = entry.internalipaddress else { return nil }
        let port = Self.explicitPort(entry.port)
        if let result = try? await probe(host: ip, port: port) {
            return Self.discovered(config: result.config, host: ip, port: port, scheme: result.scheme, method: .cloud)
        }
        guard let id = entry.bridgeID else { return nil }
        // Broker says it exists but we could not confirm it (yet): still offer it.
        return DiscoveredDevice(
            id: id, brand: .hue, name: "Hue Bridge", host: ip, port: port, method: .cloud,
            metadata: ["confirmed": "false"])
    }

    /// `GET https://discovery.meethue.com/`, at most once per `cloudDiscoveryMinInterval`.
    private func cloudEntries() async -> [HueDiscoveryEntry] {
        if let last = lastCloudFetch, clock.now - last < configuration.cloudDiscoveryMinInterval {
            return cloudCache
        }
        lastCloudFetch = clock.now
        do {
            let response = try await transport.send(HueHTTPRequest(
                method: "GET", url: configuration.cloudDiscoveryURL, headers: ["Accept": "application/json"],
                trust: .publicInternet, timeout: configuration.requestTimeout))
            guard (200..<300).contains(response.status) else {
                log.notice("discovery.meethue.com returned \(response.status)")
                return cloudCache
            }
            cloudCache = try HueDiscoveryEntry.parseList(response.body)
        } catch {
            log.notice("discovery.meethue.com failed: \(error)")
        }
        return cloudCache
    }

    private static func discovered(
        config: HueBridgeConfig, host: String, port: Int?, scheme: String, method: DiscoveryMethod
    ) -> DiscoveredDevice? {
        guard let id = config.bridgeID else { return nil }
        var metadata: [String: String] = ["scheme": scheme, "model": config.modelName]
        if let v = config.modelid { metadata["modelid"] = v }
        if let v = config.swversion { metadata["swversion"] = v }
        if let v = config.apiversion { metadata["apiversion"] = v }
        return DiscoveredDevice(
            id: id, brand: .hue, name: config.name ?? config.modelName, model: config.modelid, host: host, port: port,
            macAddress: config.mac, method: method, metadata: metadata)
    }

    /// `GET /api/config` (https first, http fallback on transport failure). Over https the
    /// certificate CN must equal the returned bridge id.
    public func probe(host: String, port: Int? = nil) async throws -> (config: HueBridgeConfig, scheme: String) {
        var lastError: any Error = HueTransportError.connectionFailed("no response from \(host)")
        for scheme in ["https", "http"] {
            guard let url = HueEndpoint.url(scheme: scheme, host: host, port: port, path: "/api/config") else { continue }
            let response: HueHTTPResponse
            do {
                response = try await transport.send(HueHTTPRequest(
                    method: "GET", url: url, headers: ["Accept": "application/json"], trust: .probe,
                    timeout: configuration.probeTimeout))
            } catch let error as HueTransportError {
                lastError = error
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw HueError.from(status: response.status, body: response.body, path: "/api/config")
                    ?? HueError.invalidResponse("status \(response.status)")
            }
            guard let config = try? JSONDecoder().decode(HueBridgeConfig.self, from: response.body),
                  let id = config.bridgeID
            else { throw HueError.invalidResponse("\(host) is not a Hue Bridge") }
            if scheme == "https", let cn = response.peerCommonName, cn.caseInsensitiveCompare(id) != .orderedSame {
                throw HueError.bridgeIdentityMismatch(expected: id, found: cn)
            }
            return (config, scheme)
        }
        throw lastError
    }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        do {
            return try await performPairing(device, ui: ui)
        } catch {
            throw Self.toLightCore(error)
        }
    }

    private func performPairing(_ device: DiscoveredDevice, ui: any PairingInteraction) async throws -> PairedDevice {
        guard let hostInput = device.host, !hostInput.isEmpty else {
            throw LightCoreError.unsupported("No address for this Hue Bridge; enter its IP address")
        }
        let parsed = HueEndpoint.parseHost(hostInput)
        let host = parsed.host
        let port = parsed.port ?? Self.explicitPort(device.port)
        let expected = HueBridgeID.normalize(device.id)

        var config: HueBridgeConfig?
        var scheme = device.metadata["scheme"] ?? "https"
        do {
            let result = try await probe(host: host, port: port)
            config = result.config
            scheme = result.scheme
        } catch let error as HueError {
            throw error
        } catch {
            guard expected != nil else { throw error }
            log.notice("Hue probe before pairing failed (\(error)); continuing with \(expected ?? "")")
        }
        guard let bridgeID = config?.bridgeID ?? expected else {
            throw HueError.invalidResponse("could not read the bridge id")
        }
        if let expected, expected != bridgeID {
            throw HueError.bridgeIdentityMismatch(expected: expected, found: bridgeID)
        }

        guard try await ui.confirm(Self.linkButtonPrompt) else { throw LightCoreError.userCancelled }

        let body = try JSONEncoder().encode(HuePairingRequest(devicetype: configuration.deviceType, generateclientkey: true))
        guard let url = HueEndpoint.url(scheme: scheme, host: host, port: port, path: "/api") else {
            throw HueError.invalidResponse("invalid host \(host)")
        }
        let request = HueHTTPRequest(
            method: "POST", url: url, headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: body, trust: .bridge(id: bridgeID), timeout: configuration.requestTimeout)
        let deadline = clock.now + configuration.pairingTimeout

        while true {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            if let error = HueError.from(status: response.status, body: response.body, path: "/api") { throw error }
            switch try HuePairing.parse(response.body) {
            case .success(let username, let clientKey):
                try await secrets.set(username, for: Self.appKeySecret(bridgeID: bridgeID))
                if let clientKey, !clientKey.isEmpty {
                    try await secrets.set(clientKey, for: Self.clientKeySecret(bridgeID: bridgeID))
                }
                log.notice("Paired with Hue Bridge \(bridgeID); app key \(Log.redact(username))")
                let name = config?.name ?? device.name
                register(id: bridgeID, host: host, port: port, scheme: scheme, name: name, model: config?.modelid ?? device.model)
                var metadata: [String: String] = ["scheme": scheme]
                if let v = config?.modelid ?? device.model { metadata["modelid"] = v }
                if let v = config?.swversion { metadata["swversion"] = v }
                if let v = config?.apiversion { metadata["apiversion"] = v }
                if config?.isBridgePro == true { metadata["bridgePro"] = "true" }
                return PairedDevice(
                    id: bridgeID, brand: .hue, name: name, model: config?.modelid ?? device.model, hostHint: host,
                    port: port, accountID: bridgeID, metadata: metadata, lastSeen: Date())
            case .linkButtonNotPressed:
                let remaining = deadline - clock.now
                guard remaining > .zero else { throw HueError.linkButtonNotPressed }
                await ui.status("Waiting for the link button... \(remaining.components.seconds) s")
                try await Task.sleep(for: min(configuration.pairingPollInterval, remaining))
            case .error(let type, let description):
                throw type == 1 ? HueError.unauthorized : HueError.v1Error(type: type, description: description)
            }
        }
    }

    // MARK: - CLIP v2 requests

    /// Performs one CLIP v2 request with the concurrency cap and 429/503 retries.
    @discardableResult
    func clip(_ bridgeID: String, method: String, path: String, body: Data? = nil, collection: Bool = false)
        async throws -> Data
    {
        guard let bridge = bridgeStates[bridgeID] else { throw HueError.unknownBridge(bridgeID) }
        guard let key = try await secrets.string(for: Self.appKeySecret(bridgeID: bridgeID)), !key.isEmpty else {
            throw HueError.notPaired(bridgeID: bridgeID)
        }
        guard let url = HueEndpoint.url(scheme: bridge.scheme, host: bridge.host, port: bridge.port, path: path) else {
            throw HueError.invalidResponse("invalid URL for \(path)")
        }
        var headers = ["hue-application-key": key, "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let request = HueHTTPRequest(
            method: method, url: url, headers: headers, body: body, trust: .bridge(id: bridgeID),
            timeout: configuration.requestTimeout)
        let semaphore = bridge.semaphore
        var attempt = 0
        while true {
            await semaphore.wait()
            let response: HueHTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                await semaphore.signal()
                throw error
            }
            await semaphore.signal()
            if HueError.isBusyStatus(response.status), attempt < configuration.maxBusyRetries {
                attempt += 1
                try await Task.sleep(for: configuration.busyRetryBase * attempt)
                continue
            }
            if let error = HueError.from(status: response.status, body: response.body, path: path, isCollectionRequest: collection) {
                if error == .unauthorized { continuation.yield(.needsReauthentication(accountID: bridgeID)) }
                throw error
            }
            return response.body
        }
    }

    /// Refetches every resource; returns the diff events (none on the first load).
    @discardableResult
    private func sync(_ bridgeID: String) async throws -> [ProviderEvent] {
        let data = try await clip(bridgeID, method: "GET", path: "/clip/v2/resource", collection: true)
        let fresh = try HueResourceStore(envelopeData: data)
        guard var bridge = bridgeStates[bridgeID] else { return [] }
        let events = bridge.loaded ? HueResourceStore.diff(from: bridge.store, to: fresh, bridgeID: bridgeID) : []
        if let reported = fresh.bridgeID, reported != bridgeID {
            log.error("Bridge resource reports id \(reported), expected \(bridgeID)")
        }
        bridge.store = fresh
        bridge.loaded = true
        bridge.lastSync = clock.now
        bridgeStates[bridgeID] = bridge
        return events
    }

    private func ensureLoaded(_ bridgeID: String) async throws {
        guard let bridge = bridgeStates[bridgeID] else { throw HueError.unknownBridge(bridgeID) }
        if !bridge.loaded { try await sync(bridgeID) }
    }

    // MARK: - LightProvider

    public func loadLights() async throws -> [Light] {
        var lights: [Light] = []
        var firstError: (any Error)?
        for id in bridgeStates.keys.sorted() {
            do {
                try await sync(id)
                lights += bridgeStates[id]?.store.makeLights(bridgeID: id) ?? []
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Loading Hue Bridge \(id) failed: \(error)")
                if firstError == nil { firstError = error }
            }
        }
        if lights.isEmpty, let firstError { throw Self.toLightCore(firstError) }
        if configuration.autoConnectEvents { connectEventStreams() }
        return lights
    }

    /// Cached lights of one bridge (no network).
    public func cachedLights(bridgeID: String) -> [Light] {
        bridgeStates[bridgeID.uppercased()]?.store.makeLights(bridgeID: bridgeID.uppercased()) ?? []
    }

    /// Cached resource mirror (diagnostics, tests).
    public func resourceStore(bridgeID: String) -> HueResourceStore? {
        bridgeStates[bridgeID.uppercased()]?.store
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        do {
            guard let parts = HueIdentifiers.split(light) else { throw LightCoreError.invalidLightID(light.rawValue) }
            try await ensureLoaded(parts.bridgeID)
            guard let hueLight = bridgeStates[parts.bridgeID]?.store.lights[parts.resourceID] else {
                throw LightCoreError.lightNotFound(light)
            }
            let update = HueMapping.lightUpdate(
                for: command, capabilities: HueMapping.capabilities(for: hueLight),
                mirekSchema: hueLight.colorTemperature?.mirekSchema)
            guard !update.isEmpty else { return }
            try await lightLimiter.acquire(light.stableId)
            try await clip(
                parts.bridgeID, method: "PUT", path: "/clip/v2/resource/light/\(parts.resourceID)",
                body: try update.jsonData())
        } catch {
            throw Self.toLightCore(error)
        }
    }

    /// Uses a room/zone `grouped_light` for every room/zone whose lights are all targeted
    /// (one request instead of N); the remaining lights are sent individually in parallel.
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        var failures: [LightID: String] = [:]
        var byBridge: [String: Set<String>] = [:]
        for id in lights {
            guard let parts = HueIdentifiers.split(id) else {
                failures[id] = "invalid Hue light id"
                continue
            }
            byBridge[parts.bridgeID, default: []].insert(parts.resourceID)
        }
        for (bridgeID, targets) in byBridge.sorted(by: { $0.key < $1.key }) {
            func lightID(_ rid: String) -> LightID? { HueIdentifiers.lightID(bridgeID: bridgeID, resourceID: rid) }
            do {
                try await ensureLoaded(bridgeID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for rid in targets { if let id = lightID(rid) { failures[id] = String(describing: Self.toLightCore(error)) } }
                continue
            }
            let store = bridgeStates[bridgeID]?.store ?? HueResourceStore()
            let plan = command.effect == nil
                ? HueGroupPlan.make(targets: targets, store: store)
                : HueGroupPlan(grouped: [], individual: targets.sorted())

            for target in plan.grouped {
                let members = target.lightIDs.compactMap { store.lights[$0] }.map(HueMapping.capabilities(for:))
                let update = HueMapping.groupUpdate(for: command, members: members)
                guard !update.isEmpty else { continue }
                do {
                    try await groupLimiter.acquire("\(bridgeID)/\(target.groupedLightID)")
                    try await clip(
                        bridgeID, method: "PUT", path: "/clip/v2/resource/grouped_light/\(target.groupedLightID)",
                        body: try update.jsonData())
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = String(describing: Self.toLightCore(error))
                    for rid in target.lightIDs { if let id = lightID(rid) { failures[id] = message } }
                }
            }

            let individual = plan.individual.compactMap(lightID)
            let results = await withTaskGroup(of: (LightID, String?).self) { group -> [(LightID, String?)] in
                for id in individual {
                    group.addTask {
                        do {
                            try await self.send(command, to: id)
                            return (id, nil)
                        } catch {
                            return (id, String(describing: error))
                        }
                    }
                }
                var out: [(LightID, String?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, message) in results { if let message { failures[id] = message } }
        }
        try Task.checkCancellation()
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    public func scenes() async throws -> [LightScene] {
        var out: [LightScene] = []
        for id in bridgeStates.keys.sorted() {
            do {
                try await ensureLoaded(id)
            } catch {
                throw Self.toLightCore(error)
            }
            out += bridgeStates[id]?.store.makeScenes(bridgeID: id) ?? []
        }
        return out
    }

    public func recall(_ scene: LightScene.ID) async throws {
        try await recall(scene, action: .active)
    }

    /// Recalls a Hue scene (`recall.action` = `active` | `dynamic_palette` | `static`).
    public func recall(
        _ scene: LightScene.ID, action: HueSceneRecallAction, transition: Duration? = nil, brightness: Double? = nil
    ) async throws {
        do {
            guard let parts = HueIdentifiers.split(stableID: scene) else {
                throw LightCoreError.protocolError("invalid Hue scene id \(scene)")
            }
            try await ensureLoaded(parts.bridgeID)
            guard let hueScene = bridgeStates[parts.bridgeID]?.store.scenes[parts.resourceID] else {
                throw LightCoreError.protocolError("Hue scene \(scene) not found")
            }
            let ms = LightCommand(transition: transition).transitionMilliseconds
            let body = HueSceneRecall(
                action: action, durationMilliseconds: ms,
                brightness: brightness.map { (min(max($0, 0), 1) * 10_000).rounded() / 100 })
            try await groupLimiter.acquire("\(parts.bridgeID)/\(hueScene.group?.rid ?? parts.resourceID)")
            try await clip(
                parts.bridgeID, method: "PUT", path: "/clip/v2/resource/scene/\(parts.resourceID)",
                body: try body.jsonData())
        } catch {
            throw Self.toLightCore(error)
        }
    }

    // MARK: - Event stream

    /// Opens `/eventstream/clip/v2` for every paired bridge (idempotent).
    public func connectEventStreams() {
        for id in bridgeStates.keys.sorted() where bridgeStates[id]?.eventTask == nil {
            bridgeStates[id]?.eventTask = Task { await self.runEventStream(id) }
        }
    }

    /// Closes all event streams (app backgrounded).
    public func disconnectEventStreams() {
        for id in bridgeStates.keys {
            bridgeStates[id]?.eventTask?.cancel()
            bridgeStates[id]?.eventTask = nil
            bridgeStates[id]?.keepaliveTask?.cancel()
            bridgeStates[id]?.keepaliveTask = nil
            if bridgeStates[id]?.connected == true {
                bridgeStates[id]?.connected = false
                bridgeStates[id]?.disconnectedAt = clock.now
            }
        }
    }

    private func runEventStream(_ id: String) async {
        var backoff = configuration.eventStreamBackoff
        var lastEventID: String?
        while !Task.isCancelled {
            guard let bridge = bridgeStates[id],
                  let url = HueEndpoint.url(scheme: bridge.scheme, host: bridge.host, port: bridge.port, path: "/eventstream/clip/v2"),
                  let key = try? await secrets.string(for: Self.appKeySecret(bridgeID: id)), !key.isEmpty
            else { break }
            let stream = transport.eventStream(HueEventStreamRequest(
                url: url, bridgeID: id, applicationKey: key, lastEventID: lastEventID,
                readTimeout: configuration.eventReadTimeout, backoff: configuration.eventStreamBackoff))
            do {
                for try await event in stream {
                    switch event {
                    case .connected:
                        backoff.reset()
                        await handleConnected(id)
                    case .message(let eventID, let data):
                        if let eventID, !eventID.isEmpty { lastEventID = eventID }
                        handleMessage(id, data: data)
                    case .disconnected(let reason, _):
                        handleDisconnected(id, reason: reason)
                    }
                }
                if Task.isCancelled { break }
                handleDisconnected(id, reason: "stream ended")
            } catch is CancellationError {
                break
            } catch HueError.unauthorized {
                handleDisconnected(id, reason: "unauthorized")
                continuation.yield(.needsReauthentication(accountID: id))
                break
            } catch HueError.v2Unsupported {
                handleDisconnected(id, reason: "no CLIP v2")
                continuation.yield(.error(HueError.v2Unsupported.errorDescription ?? "CLIP v2 unsupported"))
                break
            } catch {
                handleDisconnected(id, reason: String(describing: error))
            }
            do { try await Task.sleep(for: backoff.nextDelay()) } catch { break }
        }
        if !Task.isCancelled { bridgeStates[id]?.eventTask = nil }
    }

    private func handleConnected(_ id: String) async {
        guard let bridge = bridgeStates[id] else { return }
        let since = bridge.disconnectedAt ?? bridge.lastSync
        let gapExceeded = since.map { clock.now - $0 > configuration.resyncGap } ?? true
        bridgeStates[id]?.connected = true
        bridgeStates[id]?.disconnectedAt = nil
        continuation.yield(.connectionChanged(connected: true, detail: nil))
        if !bridge.loaded || gapExceeded {
            do {
                for event in try await sync(id) { continuation.yield(event) }
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.error("Hue resync failed: \(Self.toLightCore(error))"))
            }
        }
        if bridgeStates[id]?.keepaliveTask == nil {
            bridgeStates[id]?.keepaliveTask = Task { await self.runKeepalive(id) }
        }
    }

    private func handleDisconnected(_ id: String, reason: String) {
        bridgeStates[id]?.keepaliveTask?.cancel()
        bridgeStates[id]?.keepaliveTask = nil
        guard bridgeStates[id]?.connected == true else { return }
        bridgeStates[id]?.connected = false
        bridgeStates[id]?.disconnectedAt = clock.now
        log.info("Hue event stream \(id) disconnected: \(reason)")
        continuation.yield(.connectionChanged(connected: false, detail: reason))
    }

    private func handleMessage(_ id: String, data: String) {
        guard let messages = try? HueEventMessage.decodeList(data), !messages.isEmpty else { return }
        guard var store = bridgeStates[id]?.store, bridgeStates[id]?.loaded == true else { return }
        let events = store.apply(messages, bridgeID: id)
        bridgeStates[id]?.store = store
        for event in events { continuation.yield(event) }
    }

    /// aiohue keep-alive: rename our `geofence_client` every 60 s so the bridge sends an event
    /// and a dead socket is noticed (the read timeout then triggers a reconnect).
    private func runKeepalive(_ id: String) async {
        guard let geofenceID = await ensureGeofenceClient(id) else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: configuration.keepaliveInterval) } catch { return }
            do {
                let body = try JSONEncoder().encode(HueGeofenceClientBody.rename(name: HueGeofenceClientBody.randomName()))
                try await clip(id, method: "PUT", path: "/clip/v2/resource/geofence_client/\(geofenceID)", body: body)
            } catch is CancellationError {
                return
            } catch {
                log.notice("Hue keep-alive failed: \(error)")
                if case HueError.resourceNotFound = error { bridgeStates[id]?.geofenceID = nil }
                return
            }
        }
    }

    private func ensureGeofenceClient(_ id: String) async -> String? {
        if let existing = bridgeStates[id]?.geofenceID { return existing }
        do {
            let list = try await clip(id, method: "GET", path: "/clip/v2/resource/geofence_client")
            let clients = try JSONDecoder().decode(ResourceEnvelope<LossyArray<HueGeofenceClient>>.self, from: list)
            if let mine = clients.data?.elements.first(where: { $0.name?.hasPrefix(HueGeofenceClientBody.namePrefix) == true }) {
                bridgeStates[id]?.geofenceID = mine.id
                return mine.id
            }
            let body = try JSONEncoder().encode(HueGeofenceClientBody.create(name: HueGeofenceClientBody.randomName()))
            let created = try await clip(id, method: "POST", path: "/clip/v2/resource/geofence_client", body: body)
            let refs = try JSONDecoder().decode(ResourceEnvelope<[HueResourceIdentifier]>.self, from: created)
            guard let rid = refs.data?.first?.rid else { return nil }
            bridgeStates[id]?.geofenceID = rid
            return rid
        } catch {
            log.notice("Hue keep-alive unavailable on \(id): \(error)")
            return nil
        }
    }

    // MARK: - Errors

    static func toLightCore(_ error: any Error) -> any Error {
        switch error {
        case let e as HueError:
            return e.lightCoreError
        case let e as HueTransportError:
            switch e {
            case .timedOut: return LightCoreError.timeout
            case .connectionFailed(let s): return LightCoreError.unreachable(s)
            case .trustRejected(let s): return LightCoreError.transport("TLS certificate rejected: \(s)")
            }
        default:
            return error
        }
    }
}

/// Deduplicates discovery results by bridge id within one `discover` run.
actor DiscoverySink {
    private let continuation: AsyncStream<DiscoveredDevice>.Continuation
    private var seen: Set<String> = []

    init(_ continuation: AsyncStream<DiscoveredDevice>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ device: DiscoveredDevice) {
        guard seen.insert(device.id).inserted else { return }
        continuation.yield(device)
    }
}
