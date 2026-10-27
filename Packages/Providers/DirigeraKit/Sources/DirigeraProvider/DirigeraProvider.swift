import DirigeraCodec
import Foundation
import LightCore
import NetKit

/// IKEA DIRIGERA hub provider (unofficial local REST API, ported from Leggin/dirigera).
///
/// - Discovery: Bonjour (`gw2-<id>` hosts), manual and cached hosts, and an HTTPS sweep of the
///   Wi-Fi /24. A candidate is any host whose `:8443/v1/hub/status` answers (401 without token).
/// - Pairing: PKCE `GET /v1/oauth/authorize` -> code; the user presses the action button on the
///   bottom of the hub; `POST /v1/oauth/token` -> bearer token (polled until the button press
///   registers). The hub id comes from `GET /v1/hub/status`. Pairing requests accept the hub's
///   self-signed certificate, check every response came with the same one and pin its SHA-256
///   under the hub id (TOFU); later requests go through NetKit `TrustEvaluator` with that pin.
/// - Control: `PATCH /v1/devices/{id}` with `[{"attributes": {...}}]`; on/level/colour go in
///   one PATCH, falling back to one PATCH per attribute group if the hub answers 400.
/// - State: `GET /v1/devices` (type `light`), then `wss://<hub>:8443/v1` events
///   (`deviceStateChanged`, `deviceAdded`, `deviceRemoved`, `scene*`) with reconnect + resync.
///
/// Light ids are `dirigera:<hubID>/<deviceID>`; scene ids `dirigera:<hubID>/<sceneID>`.
public actor DirigeraProvider: LightProvider {
    public static let brand: Brand = .dirigera

    /// Shown before the token request (PairingInteraction.confirm).
    public static let buttonPrompt = "Press the action button on the bottom of the IKEA DIRIGERA hub, then tap Continue"

    public struct Configuration: Sendable {
        /// `https` in production; tests use `http` against a loopback fake.
        public var scheme = "https"
        public var webSocketScheme = "wss"
        /// nil = 8443.
        public var port: Int?
        /// Client name registered with the token (shown by the hub).
        public var clientName = "SmartLights"
        public var requestTimeout: Duration = .seconds(10)
        public var probeTimeout: Duration = .seconds(2)
        /// How long to keep asking for the token after the user confirmed the button press.
        public var pairingTimeout: Duration = .seconds(30)
        public var pairingPollInterval: Duration = .seconds(1)
        public var maxConcurrentRequests = 3
        /// Undocumented; Zigbee behind the hub cannot take much more than this per bulb.
        public var lightRateLimit = RateLimiter<String>.Limit(10, per: .seconds(1))
        public var sweepConcurrency = 32
        public var eventBackoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2)
        public var pingInterval: Duration = .seconds(60)
        /// Open the event streams after `loadLights()` / `pair`.
        public var autoConnectEvents = true
        public var now: @Sendable () -> Date = { Date() }

        public init() {}
    }

    struct HubState {
        var id: String
        var host: String
        var port: Int?
        var name: String
        var model: String?
        var devices: [String: DirigeraDevice] = [:]
        var scenes: [DirigeraScene] = []
        var loaded = false
        /// Set after the hub rejected a combined PATCH with 400.
        var splitPatches = false
        var eventTask: Task<Void, Never>?
        var connected = false
        let semaphore: AsyncSemaphore
    }

    public let configuration: Configuration
    private let secrets: any SecretStore
    private let pinStore: any TOFUPinStore
    private let transport: any DirigeraTransport
    private let limiter: RateLimiter<String>
    private var hubs: [String: HubState] = [:]
    private var tokens: [String: String] = [:]
    private let log = Log(package: "dirigerakit", category: "provider")

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation

    public init(secrets: any SecretStore, pinStore: any TOFUPinStore, transport: any DirigeraTransport,
                configuration: Configuration = Configuration()) {
        self.secrets = secrets
        self.pinStore = pinStore
        self.transport = transport
        self.configuration = configuration
        self.limiter = RateLimiter(configuration.lightRateLimit)
        let (stream, continuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        for hub in hubs.values { hub.eventTask?.cancel() }
        continuation.finish()
    }

    // MARK: - Accounts and registry

    public static func tokenSecret(hubID: String) -> SecretKey {
        SecretKey(brand: .dirigera, owner: hubID, item: "token")
    }

    public var account: ProviderAccount? { accounts.first }

    public var accounts: [ProviderAccount] {
        hubs.keys.sorted().compactMap { id in
            hubs[id].map {
                ProviderAccount(id: $0.id, brand: .dirigera, displayName: $0.name, secretKeys: [Self.tokenSecret(hubID: $0.id)],
                                metadata: ["host": $0.host, "model": $0.model ?? ""])
            }
        }
    }

    public var hubIDs: [String] { hubs.keys.sorted() }

    /// Restores a paired hub (call on launch).
    public func addHub(_ device: PairedDevice) {
        let parsed = DirigeraEndpoint.parse(device.hostHint ?? "")
        register(id: device.id, host: parsed.host, port: parsed.port ?? device.port, name: device.name, model: device.model)
    }

    /// Updates the cached address (hub ids are stable, IPs are hints).
    public func updateHost(hubID: String, host: String, port: Int? = nil) {
        let parsed = DirigeraEndpoint.parse(host)
        hubs[hubID]?.host = parsed.host
        hubs[hubID]?.port = parsed.port ?? port
    }

    /// Forgets a hub; optionally deletes its token and certificate pin.
    public func removeHub(id: String, deleteCredentials: Bool = true) async {
        if let hub = hubs.removeValue(forKey: id) {
            hub.eventTask?.cancel()
            for device in hub.devices.values where device.isLight {
                if let lightID = DirigeraIdentifiers.lightID(hubID: id, deviceID: device.id) {
                    continuation.yield(.lightRemoved(lightID))
                }
            }
        }
        tokens[id] = nil
        if deleteCredentials {
            try? await secrets.remove(Self.tokenSecret(hubID: id))
            await pinStore.removePin(for: id)
        }
    }

    public func isEventStreamConnected(hubID: String) -> Bool { hubs[hubID]?.connected ?? false }

    private func register(id: String, host: String, port: Int?, name: String, model: String?) {
        if hubs[id] != nil {
            hubs[id]?.host = host
            hubs[id]?.port = port ?? hubs[id]?.port
            hubs[id]?.name = name
            hubs[id]?.model = model ?? hubs[id]?.model
        } else {
            hubs[id] = HubState(id: id, host: host, port: port, name: name, model: model,
                                semaphore: AsyncSemaphore(configuration.maxConcurrentRequests))
        }
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
        let methods = options.methods
        let manual = methods.contains(.manual) ? options.manualHosts : []
        let cached = methods.contains(.cached) ? options.cachedHosts : []
        let sweep = methods.contains(.sweep) ? transport.sweepHosts() : []
        let useBonjour = methods.contains(.bonjour)
        let transport = self.transport
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)
        let timeout = options.timeout

        await withTaskGroup(of: Void.self) { outer in
            outer.addTask {
                await withTaskGroup(of: Void.self) { group in
                    for host in manual {
                        group.addTask { if let d = await self.probe(host, method: .manual) { await sink.emit(d) } }
                    }
                    for host in cached {
                        group.addTask { if let d = await self.probe(host, method: .cached) { await sink.emit(d) } }
                    }
                    if useBonjour {
                        group.addTask {
                            for await record in transport.browseBonjour() {
                                let host = record.host ?? "\(record.name).local"
                                guard DirigeraEndpoint.isHubHostname(record.name) || DirigeraEndpoint.isHubHostname(host) else { continue }
                                if let d = await self.probe(host, method: .bonjour, name: record.name) { await sink.emit(d) }
                            }
                        }
                    }
                    if !sweep.isEmpty {
                        group.addTask {
                            let hosts = sweep.compactMap { IPv4Addr(DirigeraEndpoint.parse($0).host) }
                            for await d in sweeper.stream(hosts, probe: { await self.probe($0.description, method: .sweep) }) {
                                await sink.emit(d)
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

    /// A hub answers `GET /v1/hub/status` without a token with 401.
    private func probe(_ input: String, method: DiscoveryMethod, name: String? = nil) async -> DiscoveredDevice? {
        let parsed = DirigeraEndpoint.parse(input)
        let port = parsed.port ?? configuration.port
        guard let response = try? await rawSend(DirigeraAPI.hubStatusProbe, host: parsed.host, port: port, token: nil,
                                                 trust: .pairing, timeout: configuration.probeTimeout),
              [200, 401, 403].contains(response.status) else { return nil }
        var metadata = ["probeStatus": String(response.status)]
        if let fp = response.peerCertificateSHA256 { metadata["certificateSHA256"] = fp.hexString() }
        let known = hubs.values.first { $0.host == parsed.host }
        return DiscoveredDevice(
            id: known?.id ?? "ip:\(parsed.host)", brand: .dirigera, name: known?.name ?? name ?? "IKEA DIRIGERA hub",
            model: "DIRIGERA", host: parsed.host, port: port ?? DirigeraAPI.defaultPort, method: method, metadata: metadata)
    }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        do {
            return try await runPairing(device, ui: ui)
        } catch {
            throw Self.map(error)
        }
    }

    private func runPairing(_ device: DiscoveredDevice, ui: any PairingInteraction) async throws -> PairedDevice {
        let input = device.host ?? (device.id.hasPrefix("ip:") ? String(device.id.dropFirst(3)) : "")
        guard !input.isEmpty else { throw LightCoreError.unsupported("DIRIGERA pairing needs the hub's IP address") }
        let parsed = DirigeraEndpoint.parse(input)
        let host = parsed.host
        let port = parsed.port ?? device.port ?? configuration.port
        var fingerprint = FingerprintCheck()

        let verifier = DirigeraPKCE.makeVerifier()
        let authorize = try await pairingCall(DirigeraAPI.authorize(challenge: DirigeraPKCE.challenge(for: verifier)),
                                              host: host, port: port, token: nil, fingerprint: &fingerprint)
        let code = try Self.decode(DirigeraAuthorizeResponse.self, from: authorize).code

        guard try await ui.confirm(Self.buttonPrompt) else { throw LightCoreError.userCancelled }

        let tokenRequest = DirigeraAPI.token(code: code, verifier: verifier, name: configuration.clientName)
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.pairingTimeout
        var token: String?
        while token == nil {
            let response = try await rawSend(tokenRequest, host: host, port: port, token: nil, trust: .pairing,
                                             timeout: configuration.requestTimeout)
            try fingerprint.check(response.peerCertificateSHA256)
            if (200..<300).contains(response.status) {
                token = try Self.decode(DirigeraTokenResponse.self, from: response.body).accessToken
            } else if [400, 401, 403].contains(response.status), clock.now < deadline {
                let left = max(0, Int((deadline - clock.now).timeInterval.rounded()))
                await ui.status("Waiting for the hub's action button... \(left) s")
                try await Task.sleep(for: configuration.pairingPollInterval)
            } else if [400, 401, 403].contains(response.status) {
                throw DirigeraError.buttonNotPressed
            } else {
                throw DirigeraError.httpStatus(response.status, Self.snippet(response.body))
            }
        }
        guard let token else { throw DirigeraError.buttonNotPressed }

        let statusData = try await pairingCall(DirigeraAPI.hubStatus, host: host, port: port, token: token, fingerprint: &fingerprint)
        let status = try Self.decode(DirigeraHubStatus.self, from: statusData)
        let hubID = status.id
        guard !hubID.isEmpty, !hubID.contains(where: { $0.isWhitespace || $0 == "/" }) else { throw DirigeraError.missingHubIdentity }

        if let sha = fingerprint.value {
            if let existing = await pinStore.pin(for: hubID), existing.sha256 != sha { throw DirigeraError.certificateChanged }
            if let pin = CertificatePin(sha256: sha) { await pinStore.setPin(pin, for: hubID) }
        }
        try await secrets.set(token, for: Self.tokenSecret(hubID: hubID))
        tokens[hubID] = token
        let name = status.attributes?.customName ?? device.name
        register(id: hubID, host: host, port: port, name: name, model: status.attributes?.model)
        log.info("Paired DIRIGERA hub \(hubID) at \(host) (token \(Log.redact(token)))")

        try await refreshHub(hubID, emitDiff: true)
        if configuration.autoConnectEvents { connectEventStreams() }
        let lightIDs = lightIDs(hubID)
        var metadata: [String: String] = [:]
        metadata["firmware"] = status.attributes?.firmwareVersion
        metadata["serialNumber"] = status.attributes?.serialNumber
        if let sha = fingerprint.value { metadata["certificateSHA256"] = sha.hexString() }
        return PairedDevice(id: hubID, brand: .dirigera, name: name, model: status.attributes?.model, hostHint: host,
                            port: port, accountID: hubID, lightIDs: lightIDs, metadata: metadata, lastSeen: configuration.now())
    }

    /// Every pairing response must come with the same certificate.
    struct FingerprintCheck {
        var value: Data?
        var seen = false

        mutating func check(_ sha: Data?) throws {
            if !seen {
                value = sha
                seen = true
            } else if sha != value {
                throw DirigeraError.certificateChanged
            }
        }
    }

    private func pairingCall(_ request: DirigeraRequest, host: String, port: Int?, token: String?,
                             fingerprint: inout FingerprintCheck) async throws -> Data {
        let response = try await rawSend(request, host: host, port: port, token: token, trust: .pairing,
                                         timeout: configuration.requestTimeout)
        try fingerprint.check(response.peerCertificateSHA256)
        guard (200..<300).contains(response.status) else {
            throw DirigeraError.httpStatus(response.status, Self.snippet(response.body))
        }
        return response.body
    }

    // MARK: - Lights and scenes

    public func loadLights() async throws -> [Light] {
        var lights: [Light] = []
        for hubID in hubs.keys.sorted() {
            do {
                try await refreshHub(hubID, emitDiff: hubs[hubID]?.loaded == true)
            } catch DirigeraError.unauthorized {
                throw LightCoreError.authenticationRequired(.dirigera)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.notice("DIRIGERA hub \(hubID) not reachable: \(error)")
                markHubReachable(hubID, false)
            }
            lights += currentLights(hubID)
        }
        if configuration.autoConnectEvents { connectEventStreams() }
        return lights
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        do {
            try await execute(command, on: light)
        } catch {
            throw Self.map(error)
        }
    }

    private func execute(_ command: LightCommand, on light: LightID) async throws {
        guard light.brand == .dirigera, let (hubID, deviceID) = DirigeraIdentifiers.split(light.stableId), hubs[hubID] != nil else {
            throw LightCoreError.lightNotFound(light)
        }
        if hubs[hubID]?.devices[deviceID] == nil { try await refreshHub(hubID, emitDiff: true) }
        guard let device = hubs[hubID]?.devices[deviceID], device.isLight else { throw LightCoreError.lightNotFound(light) }

        try await limiter.acquire(light.rawValue)
        var split = hubs[hubID]?.splitPatches ?? false
        var groups = DirigeraMapping.plan(command, device: device, split: split)
        var index = 0
        while index < groups.count {
            do {
                _ = try await call(DirigeraAPI.patch(deviceID: deviceID, attributes: groups[index]), hubID: hubID)
                index += 1
            } catch DirigeraError.httpStatus(400, let body) where !split && groups[index].count > 1 {
                log.notice("DIRIGERA hub \(hubID) rejected a combined PATCH (\(body)); sending attributes separately")
                split = true
                hubs[hubID]?.splitPatches = true
                groups = DirigeraMapping.plan(command, device: device, split: true)
                index = 0
            }
        }
        guard var updated = hubs[hubID]?.devices[deviceID] else { return }
        for attributes in groups { updated.attributes.merge(attributes) }
        if let color = command.normalized(for: DirigeraMapping.capabilities(device)).color {
            updated.attributes.colorMode = color.colorMode == .colorTemp ? "temperature" : "color"
        }
        hubs[hubID]?.devices[deviceID] = updated
        continuation.yield(.stateChanged(light, DirigeraMapping.state(updated, at: configuration.now())))
    }

    public func scenes() async throws -> [LightScene] {
        hubs.keys.sorted().flatMap { hubID in
            (hubs[hubID]?.scenes ?? []).map {
                LightScene(id: DirigeraIdentifiers.sceneID(hubID: hubID, sceneID: $0.id), name: $0.info.name, kind: .vendor,
                           brand: .dirigera)
            }
        }
    }

    public func recall(_ scene: LightScene.ID) async throws {
        guard let (hubID, sceneID) = DirigeraIdentifiers.split(scene), hubs[hubID] != nil else {
            throw LightCoreError.unsupported("Unknown DIRIGERA scene \(scene)")
        }
        do {
            _ = try await call(DirigeraAPI.triggerScene(sceneID), hubID: hubID)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Event stream

    /// Opens one WebSocket per hub (no-op for hubs already connected or connecting).
    public func connectEventStreams() {
        for id in hubs.keys where hubs[id]?.eventTask == nil {
            hubs[id]?.eventTask = Task { [weak self] in await self?.runEvents(hubID: id) }
        }
    }

    /// Closes the WebSockets (call when the app goes to the background).
    public func disconnectEventStreams() {
        for id in hubs.keys {
            hubs[id]?.eventTask?.cancel()
            hubs[id]?.eventTask = nil
            setConnected(id, false, detail: "disconnected")
        }
    }

    private func runEvents(hubID: String) async {
        var backoff = configuration.eventBackoff
        var first = true
        while !Task.isCancelled {
            guard let hub = hubs[hubID] else { return }
            guard let token = try? await token(for: hubID),
                  let url = DirigeraEndpoint.url(scheme: configuration.webSocketScheme, host: hub.host, port: hub.port ?? configuration.port,
                                                 path: DirigeraAPI.eventsPath) else {
                continuation.yield(.needsReauthentication(accountID: hubID))
                hubs[hubID]?.eventTask = nil
                return
            }
            let request = DirigeraEventStreamRequest(url: url, hubID: hubID, token: token, pingInterval: configuration.pingInterval)
            do {
                for try await event in transport.eventStream(request) {
                    switch event {
                    case .connected:
                        setConnected(hubID, true, detail: nil)
                        backoff.reset()
                        // State may have changed while we were away.
                        if !first { try? await refreshHub(hubID, emitDiff: true) }
                        first = false
                    case .message(let text):
                        await handleEvent(text, hubID: hubID)
                    }
                }
            } catch DirigeraTransportError.unauthorized {
                setConnected(hubID, false, detail: "token rejected")
                continuation.yield(.needsReauthentication(accountID: hubID))
                hubs[hubID]?.eventTask = nil
                return
            } catch is CancellationError {
                return
            } catch {
                log.notice("DIRIGERA \(hubID) event stream: \(error)")
            }
            if Task.isCancelled { return }
            setConnected(hubID, false, detail: "reconnecting")
            first = false
            try? await Task.sleep(for: backoff.nextDelay())
        }
    }

    func handleEvent(_ text: String, hubID: String) async {
        guard let event = DirigeraEvent.parse(text) else { return }
        switch event.type {
        case "deviceStateChanged":
            guard let update = event.deviceUpdate else { return }
            guard var device = hubs[hubID]?.devices[update.id] else {
                if update.type == "light" { try? await refreshHub(hubID, emitDiff: true) }
                return
            }
            let before = device
            device.apply(update)
            hubs[hubID]?.devices[update.id] = device
            emitChanges(hubID: hubID, before: before, after: device)
        case "deviceAdded":
            try? await refreshHub(hubID, emitDiff: true)
        case "deviceRemoved":
            guard let id = event.deviceUpdate?.id, let removed = hubs[hubID]?.devices.removeValue(forKey: id) else { return }
            if removed.isLight, let lightID = DirigeraIdentifiers.lightID(hubID: hubID, deviceID: id) {
                continuation.yield(.lightRemoved(lightID))
            }
        case let type where type.hasPrefix("scene"):
            if let scenes = try? await fetchScenes(hubID) {
                hubs[hubID]?.scenes = scenes
                continuation.yield(.scenesChanged)
            }
        default:
            break
        }
    }

    // MARK: - Internals

    /// Fetches devices (+ scenes) and, if `emitDiff`, emits added/removed/updated/state events.
    private func refreshHub(_ hubID: String, emitDiff: Bool) async throws {
        let data = try await call(DirigeraAPI.devices, hubID: hubID)
        let devices = try Self.decode([DirigeraDevice].self, from: data)
        let scenes = try? await fetchScenes(hubID)
        guard hubs[hubID] != nil else { return }
        let old = hubs[hubID]?.devices ?? [:]
        let new = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hubs[hubID]?.devices = new
        if let scenes {
            if emitDiff, scenes != hubs[hubID]?.scenes { continuation.yield(.scenesChanged) }
            hubs[hubID]?.scenes = scenes
        }
        hubs[hubID]?.loaded = true
        markHubReachable(hubID, true)
        guard emitDiff else { return }
        for (id, device) in new where device.isLight {
            if let previous = old[id] {
                emitChanges(hubID: hubID, before: previous, after: device)
            } else if let light = DirigeraMapping.light(device, hubID: hubID, at: configuration.now()) {
                continuation.yield(.lightAdded(light))
            }
        }
        for (id, device) in old where device.isLight && new[id] == nil {
            if let lightID = DirigeraIdentifiers.lightID(hubID: hubID, deviceID: id) { continuation.yield(.lightRemoved(lightID)) }
        }
    }

    private func fetchScenes(_ hubID: String) async throws -> [DirigeraScene] {
        try Self.decode([DirigeraScene].self, from: try await call(DirigeraAPI.scenes, hubID: hubID))
    }

    private func emitChanges(hubID: String, before: DirigeraDevice, after: DirigeraDevice) {
        guard after.isLight, let lightID = DirigeraIdentifiers.lightID(hubID: hubID, deviceID: after.id) else { return }
        let now = configuration.now()
        if before.isReachable != after.isReachable {
            continuation.yield(.reachabilityChanged(lightID, reachable: after.isReachable))
        }
        if before.attributes.customName != after.attributes.customName || before.room != after.room
            || before.capabilities != after.capabilities, let light = DirigeraMapping.light(after, hubID: hubID, at: now) {
            continuation.yield(.lightUpdated(light))
        }
        let oldState = DirigeraMapping.state(before, at: now)
        let newState = DirigeraMapping.state(after, at: now)
        if oldState != newState { continuation.yield(.stateChanged(lightID, newState)) }
    }

    private func currentLights(_ hubID: String) -> [Light] {
        guard let hub = hubs[hubID] else { return [] }
        let now = configuration.now()
        return hub.devices.values.filter(\.isLight).sorted { $0.id < $1.id }.compactMap { device in
            guard var light = DirigeraMapping.light(device, hubID: hubID, at: now) else { return nil }
            if !hub.loaded { light.state.reachable = false }
            return light
        }
    }

    private func lightIDs(_ hubID: String) -> [LightID] { currentLights(hubID).map(\.id) }

    private func markHubReachable(_ hubID: String, _ reachable: Bool) {
        guard !reachable, let hub = hubs[hubID] else { return }
        for device in hub.devices.values where device.isLight {
            if let lightID = DirigeraIdentifiers.lightID(hubID: hubID, deviceID: device.id) {
                continuation.yield(.reachabilityChanged(lightID, reachable: false))
            }
        }
    }

    private func setConnected(_ hubID: String, _ connected: Bool, detail: String?) {
        guard hubs[hubID] != nil, hubs[hubID]?.connected != connected else { return }
        hubs[hubID]?.connected = connected
        continuation.yield(.connectionChanged(connected: connected, detail: "DIRIGERA \(hubID): \(detail ?? "connected")"))
    }

    private func token(for hubID: String) async throws -> String {
        if let token = tokens[hubID] { return token }
        guard let token = try await secrets.string(for: Self.tokenSecret(hubID: hubID)), !token.isEmpty else {
            throw DirigeraError.unauthorized
        }
        tokens[hubID] = token
        return token
    }

    /// Authenticated call to a paired hub (pinned trust, concurrency-limited).
    private func call(_ request: DirigeraRequest, hubID: String) async throws -> Data {
        guard let hub = hubs[hubID] else { throw LightCoreError.unreachable("DIRIGERA hub \(hubID) is not set up") }
        let token: String
        do {
            token = try await self.token(for: hubID)
        } catch {
            continuation.yield(.needsReauthentication(accountID: hubID))
            throw error
        }
        await hub.semaphore.wait()
        let response: DirigeraHTTPResponse
        do {
            response = try await rawSend(request, host: hub.host, port: hub.port ?? configuration.port, token: token,
                                         trust: .hub(id: hubID), timeout: configuration.requestTimeout)
            await hub.semaphore.signal()
        } catch {
            await hub.semaphore.signal()
            throw error
        }
        switch response.status {
        case 200..<300:
            return response.body
        case 401, 403:
            tokens[hubID] = nil
            continuation.yield(.needsReauthentication(accountID: hubID))
            throw DirigeraError.unauthorized
        default:
            throw DirigeraError.httpStatus(response.status, Self.snippet(response.body))
        }
    }

    private func rawSend(_ request: DirigeraRequest, host: String, port: Int?, token: String?, trust: DirigeraTrust,
                         timeout: Duration) async throws -> DirigeraHTTPResponse {
        guard let url = DirigeraEndpoint.url(scheme: configuration.scheme, host: host, port: port, path: request.path,
                                             query: request.query) else {
            throw LightCoreError.unreachable("invalid host \(host)")
        }
        var headers: [String: String] = ["Accept": "application/json"]
        if let contentType = request.contentType { headers["Content-Type"] = contentType }
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return try await transport.send(DirigeraHTTPRequest(method: request.method, url: url, headers: headers, body: request.body,
                                                            trust: trust, timeout: timeout))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DirigeraError.malformedResponse(String(describing: error))
        }
    }

    static func snippet(_ data: Data) -> String { String(decoding: data.prefix(200), as: UTF8.self) }

    /// Maps internal errors to `LightCoreError` (never includes tokens).
    static func map(_ error: any Error) -> any Error {
        switch error {
        case let e as DirigeraError: return e.lightCoreError
        case let e as DirigeraTransportError:
            switch e {
            case .timedOut: return LightCoreError.timeout
            case .connectionFailed(let message): return LightCoreError.unreachable(message)
            case .trustRejected(let message): return LightCoreError.transport("certificate rejected: \(message)")
            case .unauthorized: return LightCoreError.authenticationRequired(.dirigera)
            }
        default: return error
        }
    }
}

/// Counting semaphore for the per-hub request limit.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = max(1, count) }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Deduplicates discovery results by id.
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
