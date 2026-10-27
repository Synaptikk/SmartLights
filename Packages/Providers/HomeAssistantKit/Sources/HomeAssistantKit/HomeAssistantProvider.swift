import Foundation
import HomeAssistantCodec
import LightCore
import NetKit

/// Home Assistant provider (WebSocket API, `/api/websocket`).
///
/// - Discovery: Bonjour `_home-assistant._tcp` (via the transport) plus manual/cached URLs, each
///   confirmed by reading `auth_required`.
/// - Pairing: base URL (+ optional remote URL, e.g. Nabu Casa) and a long-lived access token,
///   stored in `SecretStore` under `SecretKey(brand: .homeAssistant, owner: <instanceID>, item: "accessToken")`.
/// - Lights: `light.*` entities from `get_states`; names, rooms (areas) and stable keys from the
///   entity/device/area registries.
/// - Control: `call_service` `light.turn_on`/`light.turn_off` (one call per distinct payload for
///   groups), `scene.turn_on` for `scene.*` entities.
/// - State: `subscribe_events` `state_changed` (+ registry update events), ping every 30 s,
///   reconnect with exponential backoff and a full resync after every reconnect.
///
/// The logic is portable; the network comes from an injected `HAWebSocketTransport`
/// (`URLSessionHATransport` on Apple platforms).
public actor HomeAssistantProvider: LightProvider {
    public static let brand: Brand = .homeAssistant

    public static let urlPrompt = "Home Assistant URL (for example http://homeassistant.local:8123)"
    public static let remoteURLPrompt =
        "Remote URL for when you are away from home (Nabu Casa https://….ui.nabu.casa or your own). Leave empty to skip."
    public static let tokenPrompt =
        "Long-lived access token (Home Assistant > your profile > Security > Long-lived access tokens > Create token)"

    public struct Configuration: Sendable {
        public var connectTimeout: Duration = .seconds(10)
        public var commandTimeout: Duration = .seconds(10)
        /// Heartbeat: `ping` every `pingInterval`; no `pong` within `pongTimeout` closes the socket.
        public var pingInterval: Duration = .seconds(30)
        public var pongTimeout: Duration = .seconds(10)
        public var reconnectBackoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2)
        /// Coalesces bursts of registry events / unknown entities into one resync.
        public var resyncDelay: Duration = .milliseconds(500)
        /// Open the live connections automatically after `loadLights()` / `pair`.
        public var autoConnectEvents = true
        /// Token prompts before pairing gives up.
        public var maxTokenAttempts = 3

        public init() {}
    }

    struct Instance {
        var id: String
        var name: String
        var baseURL: URL
        var externalURL: URL?
        var version: String?
        var client: HAClient?
        var connecting: Task<HAClient, any Error>?
        var liveTask: Task<Void, Never>?
        var resyncTask: Task<Void, Never>?
        var connected = false
        var loaded = false
        var registry = HARegistry.empty
        /// `light.*` and `scene.*` states by entity_id.
        var states: [String: HAEntityState] = [:]
        var lights: [LightID: Light] = [:]
        var entityForLight: [LightID: String] = [:]
        var lightForEntity: [String: LightID] = [:]
        var sceneEntities: Set<String> = []

        var urls: [URL] { [baseURL] + (externalURL.map { [$0] } ?? []) }
    }

    public let configuration: Configuration
    private let secrets: any SecretStore
    private let transport: any HAWebSocketTransport
    private var instances: [String: Instance] = [:]
    private let log = Log(package: "homeassistantkit", category: "provider")

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation

    public init(secrets: any SecretStore, transport: any HAWebSocketTransport, configuration: Configuration = Configuration()) {
        self.secrets = secrets
        self.transport = transport
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        for instance in instances.values {
            instance.liveTask?.cancel()
            instance.resyncTask?.cancel()
            instance.connecting?.cancel()
        }
        continuation.finish()
    }

    // MARK: - Secrets and accounts

    public static func tokenSecret(instanceID: String) -> SecretKey {
        SecretKey(brand: .homeAssistant, owner: instanceID, item: "accessToken")
    }

    /// The first paired instance's account (one account per HA instance; see `accounts`).
    public var account: ProviderAccount? { accounts.first }

    public var accounts: [ProviderAccount] {
        instances.keys.sorted().compactMap { id in instances[id].map(Self.makeAccount) }
    }

    private static func makeAccount(_ instance: Instance) -> ProviderAccount {
        var metadata = ["url": instance.baseURL.absoluteString]
        if let external = instance.externalURL { metadata["external_url"] = external.absoluteString }
        if let version = instance.version { metadata["version"] = version }
        return ProviderAccount(
            id: instance.id, brand: .homeAssistant, displayName: "\(instance.name) (\(instance.baseURL.host ?? ""))",
            secretKeys: [tokenSecret(instanceID: instance.id)], metadata: metadata)
    }

    /// Replaces the stored token (re-authentication) and reconnects.
    public func setAccessToken(_ token: String, instanceID: String) async throws {
        try await secrets.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenSecret(instanceID: instanceID))
        guard instances[instanceID] != nil else { return }
        await dropClient(instanceID)
        if configuration.autoConnectEvents { startLive(instanceID) }
    }

    // MARK: - Instance registry

    /// Restores a previously paired instance (the token is read from `SecretStore` on use).
    public func addInstance(_ device: PairedDevice) {
        let base = (device.metadata["url"] ?? device.hostHint).flatMap(HAURL.normalize)
        guard let base else {
            log.error("Instance \(device.id) has no usable URL")
            return
        }
        register(
            id: device.id, name: device.name, baseURL: base,
            externalURL: device.metadata["external_url"].flatMap(HAURL.normalize), version: device.metadata["version"])
    }

    /// Updates the URLs of an instance (ids are stable, URLs are hints).
    public func updateURLs(instanceID: String, baseURL: URL, externalURL: URL?) async {
        guard instances[instanceID] != nil else { return }
        instances[instanceID]?.baseURL = HAURL.normalize(baseURL.absoluteString) ?? baseURL
        instances[instanceID]?.externalURL = externalURL.flatMap { HAURL.normalize($0.absoluteString) }
        await dropClient(instanceID)
        if configuration.autoConnectEvents, instances[instanceID]?.loaded == true { startLive(instanceID) }
    }

    /// Forgets an instance; optionally deletes its token.
    public func removeInstance(id: String, deleteCredentials: Bool = true) async {
        if let instance = instances.removeValue(forKey: id) {
            instance.liveTask?.cancel()
            instance.resyncTask?.cancel()
            instance.connecting?.cancel()
            await instance.client?.close()
            for lightID in instance.lights.keys { continuation.yield(.lightRemoved(lightID)) }
        }
        if deleteCredentials { try? await secrets.remove(Self.tokenSecret(instanceID: id)) }
    }

    public var instanceIDs: [String] { instances.keys.sorted() }

    /// Whether the live connection of `instanceID` is authenticated and subscribed.
    public func isConnected(instanceID: String) -> Bool { instances[instanceID]?.connected ?? false }

    private func register(id: String, name: String, baseURL: URL, externalURL: URL?, version: String?) {
        if var existing = instances[id] {
            existing.name = name
            existing.baseURL = baseURL
            existing.externalURL = externalURL
            existing.version = version ?? existing.version
            instances[id] = existing
        } else {
            instances[id] = Instance(id: id, name: name, baseURL: baseURL, externalURL: externalURL, version: version)
        }
    }

    // MARK: - Discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream<DiscoveredDevice>.makeStream()
        let task = Task {
            await self.runDiscovery(options, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(_ options: DiscoveryOptions, continuation: AsyncStream<DiscoveredDevice>.Continuation) async {
        let transport = transport
        let probeTimeout = min(configuration.connectTimeout, options.timeout)
        let hosts: [(String, DiscoveryMethod)] =
            (options.methods.contains(.manual) ? options.manualHosts.map { ($0, .manual) } : [])
            + (options.methods.contains(.cached) ? options.cachedHosts.map { ($0, .cached) } : [])
        let browse = options.methods.contains(.bonjour)
        let seen = SeenSet()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: options.timeout) }
            group.addTask {
                await withTaskGroup(of: Void.self) { work in
                    for (host, method) in hosts {
                        guard let base = HAURL.normalize(host) else { continue }
                        work.addTask {
                            guard await seen.insert(base.absoluteString) else { return }
                            var metadata = ["url": base.absoluteString]
                            metadata["confirmed"] = "false"
                            if let ws = HAURL.websocketURL(for: base) {
                                do {
                                    let version = try await HAClient.probe(transport: transport, url: ws, timeout: probeTimeout)
                                    metadata["confirmed"] = "true"
                                    if let version { metadata["version"] = version }
                                } catch {}
                            }
                            continuation.yield(DiscoveredDevice(
                                id: "url:\(base.absoluteString)", brand: .homeAssistant, name: "Home Assistant",
                                model: metadata["version"].map { "Home Assistant \($0)" }, host: base.absoluteString,
                                port: base.port, method: method, metadata: metadata))
                        }
                    }
                    if browse {
                        work.addTask {
                            for await instance in transport.browse(timeout: options.timeout) {
                                guard await seen.insert(instance.baseURL.absoluteString) else { continue }
                                var metadata = ["url": instance.baseURL.absoluteString, "confirmed": "true"]
                                if let uuid = instance.uuid { metadata["uuid"] = uuid }
                                if let external = instance.externalURL { metadata["external_url"] = external.absoluteString }
                                if let version = instance.version { metadata["version"] = version }
                                continuation.yield(DiscoveredDevice(
                                    id: instance.uuid ?? "url:\(instance.baseURL.absoluteString)", brand: .homeAssistant,
                                    name: instance.name, model: instance.version.map { "Home Assistant \($0)" },
                                    host: instance.baseURL.absoluteString, port: instance.baseURL.port,
                                    method: .bonjour, metadata: metadata))
                            }
                        }
                    }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Pairing

    /// Asks for (or takes from discovery) the base URL, checks it answers `auth_required`, asks
    /// for an optional remote URL and a long-lived access token, authenticates, and stores the
    /// token. Up to `maxTokenAttempts` token prompts; then `authenticationRequired`.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        // 1. Base URL.
        var base = (device.metadata["url"] ?? device.host).flatMap(HAURL.normalize)
        var version: String?
        while true {
            if base == nil {
                let text = try await ui.text(Self.urlPrompt)
                base = HAURL.normalize(text)
                if base == nil {
                    await ui.status("That does not look like a URL. Try http://homeassistant.local:8123")
                    continue
                }
            }
            guard let ws = HAURL.websocketURL(for: base!) else { base = nil; continue }
            await ui.status("Connecting to \(base!.absoluteString)…")
            do {
                version = try await HAClient.probe(transport: transport, url: ws, timeout: configuration.connectTimeout)
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.notice("Probe of \(base!.absoluteString) failed: \(error)")
                await ui.status("Could not reach Home Assistant at \(base!.absoluteString).")
                base = nil
                guard try await ui.confirm("Home Assistant did not answer. Enter a different URL?") else {
                    throw LightCoreError.unreachable("Home Assistant")
                }
            }
        }
        let baseURL = base!

        // 2. Optional remote URL (skipped when the base URL already is the remote one).
        var externalURL = device.metadata["external_url"].flatMap(HAURL.normalize)
        if externalURL == nil, !HAURL.isNabuCasa(baseURL) {
            let text = try await ui.text(Self.remoteURLPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                externalURL = HAURL.normalize(text)
                if externalURL == nil { await ui.status("Ignoring the remote URL: it is not a valid URL.") }
            }
        }
        if externalURL == baseURL { externalURL = nil }

        // 3. Token.
        var client: HAClient?
        var token = ""
        for attempt in 1...max(1, configuration.maxTokenAttempts) {
            token = try await ui.secureText(Self.tokenPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            do {
                client = try await HAClient.connect(
                    transport: transport, url: HAURL.websocketURL(for: baseURL)!, accessToken: token,
                    timeout: configuration.connectTimeout)
                break
            } catch HAClientError.authInvalid {
                log.notice("Token rejected (attempt \(attempt), \(Log.redact(token)))")
                await ui.status("Home Assistant rejected the token. Check that it was copied completely.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.map(error, context: "Home Assistant")
            }
        }
        guard let client else { throw LightCoreError.authenticationRequired(.homeAssistant) }

        // 4. Instance identity and name.
        let config = (try? await client.command(.getConfig, timeout: configuration.commandTimeout)).map(HAConfig.init(json:))
        version = client.haVersion ?? config?.version ?? version
        let instanceID = device.metadata["uuid"]
            ?? instances.values.first { $0.baseURL == baseURL }?.id
            ?? UUID().uuidString.lowercased()
        let name = config?.locationName ?? (device.name.isEmpty ? "Home Assistant" : device.name)
        try await secrets.set(token, for: Self.tokenSecret(instanceID: instanceID))
        if let old = instances[instanceID]?.client { await old.close() }
        register(id: instanceID, name: name, baseURL: baseURL, externalURL: externalURL, version: version)
        instances[instanceID]?.client = client

        var lightIDs: [LightID] = []
        if let lights = try? await refresh(instanceID, emitChanges: false) { lightIDs = lights.map(\.id) }
        if configuration.autoConnectEvents { startLive(instanceID) }

        var metadata = ["url": baseURL.absoluteString]
        if let externalURL { metadata["external_url"] = externalURL.absoluteString }
        if let version { metadata["version"] = version }
        return PairedDevice(
            id: instanceID, brand: .homeAssistant, name: name, model: version.map { "Home Assistant \($0)" },
            hostHint: baseURL.absoluteString, port: baseURL.port, accountID: instanceID, lightIDs: lightIDs,
            metadata: metadata, lastSeen: Date())
    }

    // MARK: - Lights and scenes

    public func loadLights() async throws -> [Light] {
        var all: [Light] = []
        var failures: [String] = []
        for id in instances.keys.sorted() {
            do {
                all += try await refresh(id, emitChanges: true)
                if configuration.autoConnectEvents { startLive(id) }
            } catch let error as LightCoreError {
                // The live loop keeps retrying with backoff and resyncs once HA is reachable.
                if configuration.autoConnectEvents { startLive(id) }
                if instances.count == 1 { throw error }
                failures.append("\(id): \(error.localizedDescription)")
                // Keep the last known lights of an unreachable instance, marked unreachable.
                all += (instances[id]?.lights.values.map { var l = $0; l.state.reachable = false; return l } ?? [])
            }
        }
        for failure in failures { continuation.yield(.error(failure)) }
        return all.sorted { $0.id < $1.id }
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        let (instanceID, entityID, light) = try await resolve(light)
        guard let call = HALightMapping.serviceCall(for: command, entityID: entityID, capabilities: light.capabilities) else { return }
        try await callService(call, instanceID: instanceID)
    }

    /// One `call_service` per instance and distinct payload, targeting all its entities
    /// (HA fans out to the integrations, which use native groups where they have them).
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        var failures: [LightID: String] = [:]
        // (instance, call without target) -> (entities, lights)
        var batches: [BatchKey: (entities: [String], lights: [LightID])] = [:]
        var order: [BatchKey] = []
        for id in lights {
            do {
                let (instanceID, entityID, light) = try await resolve(id)
                guard let call = HALightMapping.serviceCall(for: command, entityID: entityID, capabilities: light.capabilities)
                else { continue }
                var untargeted = call
                untargeted.target = nil
                let key = BatchKey(instanceID: instanceID, call: untargeted)
                if batches[key] == nil { order.append(key) }
                batches[key, default: ([], [])].entities.append(entityID)
                batches[key, default: ([], [])].lights.append(id)
            } catch {
                failures[id] = String(describing: error)
            }
        }
        for key in order {
            guard let batch = batches[key] else { continue }
            do {
                try await callService(key.call.targeting(batch.entities), instanceID: key.instanceID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for id in batch.lights { failures[id] = String(describing: error) }
            }
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    private struct BatchKey: Hashable {
        var instanceID: String
        var call: HAServiceCall
    }

    /// `scene.*` entities of every instance.
    public func scenes() async throws -> [Scene] {
        var out: [Scene] = []
        for id in instances.keys.sorted() {
            if instances[id]?.loaded != true { _ = try? await refresh(id, emitChanges: true) }
            guard let instance = instances[id] else { continue }
            out += instance.sceneEntities.sorted().compactMap { entityID in
                instance.states[entityID].flatMap {
                    HALightMapping.scene(for: $0, instanceID: id, registry: instance.registry)
                }
            }
        }
        return out
    }

    public func recall(_ scene: Scene.ID) async throws {
        guard let (instanceID, entityID) = HAIdentifiers.split(scene), instances[instanceID] != nil,
            HAEntityID.domain(of: entityID) == "scene"
        else { throw LightCoreError.unsupported("Unknown Home Assistant scene \(scene)") }
        try await callService(HALightMapping.sceneCall(entityID: entityID), instanceID: instanceID)
    }

    /// Calls any HA service on an instance (escape hatch for scripts/automations).
    public func callService(_ call: HAServiceCall, instanceID: String) async throws {
        let client = try await client(for: instanceID)
        do {
            _ = try await client.command(.callService(call), timeout: configuration.commandTimeout)
        } catch {
            throw Self.map(error, context: "\(call.domain).\(call.service)")
        }
    }

    private func resolve(_ light: LightID) async throws -> (instanceID: String, entityID: String, light: Light) {
        guard light.brand == .homeAssistant, let (instanceID, _) = HAIdentifiers.split(light.stableId),
            instances[instanceID] != nil
        else { throw LightCoreError.lightNotFound(light) }
        if instances[instanceID]?.lights[light] == nil { _ = try await refresh(instanceID, emitChanges: true) }
        guard let instance = instances[instanceID], let entityID = instance.entityForLight[light],
            let current = instance.lights[light]
        else { throw LightCoreError.lightNotFound(light) }
        return (instanceID, entityID, current)
    }

    // MARK: - Connection

    /// An authenticated client for the instance, connecting (internal URL first, then the
    /// remote one) if needed. Concurrent callers share one connection attempt.
    private func client(for instanceID: String) async throws -> HAClient {
        guard let instance = instances[instanceID] else { throw LightCoreError.providerNotRegistered(.homeAssistant) }
        if let client = instance.client {
            let closed = await client.isClosed
            if !closed { return client }
        }
        if let connecting = instance.connecting { return try await Self.awaitConnect(connecting) }

        let transport = transport
        let urls = instance.urls.compactMap(HAURL.websocketURL(for:))
        let timeout = configuration.connectTimeout
        let secrets = secrets
        let task = Task<HAClient, any Error> {
            guard let token = try await secrets.string(for: Self.tokenSecret(instanceID: instanceID)), !token.isEmpty else {
                throw HAClientError.authInvalid("no stored token")
            }
            var lastError: any Error = HAClientError.connectionClosed
            for url in urls {
                do {
                    return try await HAClient.connect(transport: transport, url: url, accessToken: token, timeout: timeout)
                } catch let error as HAClientError {
                    if case .authInvalid = error { throw error }
                    lastError = error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
        instances[instanceID]?.connecting = task
        defer { instances[instanceID]?.connecting = nil }
        do {
            let client = try await Self.awaitConnect(task)
            instances[instanceID]?.client = client
            return client
        } catch let error as LightCoreError {
            if case .authenticationRequired = error { continuation.yield(.needsReauthentication(accountID: instanceID)) }
            throw error
        }
    }

    private static func awaitConnect(_ task: Task<HAClient, any Error>) async throws -> HAClient {
        do {
            return try await task.value
        } catch {
            throw map(error, context: "Home Assistant")
        }
    }

    private func dropClient(_ instanceID: String) async {
        instances[instanceID]?.liveTask?.cancel()
        instances[instanceID]?.liveTask = nil
        if let client = instances[instanceID]?.client { await client.close() }
        instances[instanceID]?.client = nil
        setConnected(instanceID, false, detail: nil)
    }

    /// Opens the live connections (state subscriptions + heartbeat) of every instance.
    /// Call when the app returns to the foreground.
    public func connectEventStreams() {
        for id in instances.keys { startLive(id) }
    }

    /// Closes all connections. Call when the app goes to the background.
    public func disconnectEventStreams() async {
        for id in instances.keys { await dropClient(id) }
    }

    private func startLive(_ instanceID: String) {
        guard let instance = instances[instanceID], instance.liveTask == nil else { return }
        instances[instanceID]?.liveTask = Task { [weak self] in
            await self?.runLive(instanceID)
        }
    }

    /// Connect -> subscribe -> resync -> heartbeat until closed -> backoff -> repeat.
    /// Stops on cancellation, removal of the instance, or a rejected token.
    private func runLive(_ instanceID: String) async {
        var backoff = configuration.reconnectBackoff
        while !Task.isCancelled, instances[instanceID] != nil {
            do {
                let client = try await client(for: instanceID)
                let stateEvents = try await client.subscribe(eventType: "state_changed", timeout: configuration.commandTimeout)
                // Registry changes (renames, room moves, new lights). Allowed for non-admin
                // users too; ignored if the server refuses.
                var registryStreams: [AsyncStream<HAEvent>] = []
                for type in ["entity_registry_updated", "device_registry_updated", "area_registry_updated"] {
                    if let stream = try? await client.subscribe(eventType: type, timeout: configuration.commandTimeout) {
                        registryStreams.append(stream)
                    }
                }
                _ = try await refresh(instanceID, emitChanges: true)
                backoff.reset()
                setConnected(instanceID, true, detail: client.haVersion.map { "Home Assistant \($0)" })

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for await event in stateEvents { await self?.handle(event, instanceID: instanceID) }
                    }
                    for stream in registryStreams {
                        group.addTask { [weak self] in
                            for await _ in stream { await self?.scheduleResync(instanceID) }
                        }
                    }
                    group.addTask { [weak self] in await self?.heartbeat(client) }
                    group.addTask { await client.waitUntilClosed() }
                    await group.next()
                    group.cancelAll()
                    await client.close()
                }
                if Task.isCancelled { break }
                setConnected(instanceID, false, detail: "connection closed")
            } catch let error as LightCoreError where error == .authenticationRequired(.homeAssistant) {
                setConnected(instanceID, false, detail: "access token rejected")
                break
            } catch {
                if Task.isCancelled { break }
                setConnected(instanceID, false, detail: error.localizedDescription)
                log.notice("Connection to \(instanceID) failed: \(error.localizedDescription)")
            }
            if let client = instances[instanceID]?.client { await client.close() }
            instances[instanceID]?.client = nil
            do { try await Task.sleep(for: backoff.nextDelay()) } catch { break }
        }
        if instances[instanceID] != nil, !Task.isCancelled { instances[instanceID]?.liveTask = nil }
    }

    private func heartbeat(_ client: HAClient) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.pingInterval)
                try await client.ping(timeout: configuration.pongTimeout)
            } catch is CancellationError {
                return
            } catch {
                log.notice("Heartbeat failed: \(error.localizedDescription)")
                await client.close()
                return
            }
        }
    }

    private func setConnected(_ instanceID: String, _ connected: Bool, detail: String?) {
        guard let instance = instances[instanceID], instance.connected != connected else { return }
        instances[instanceID]?.connected = connected
        continuation.yield(.connectionChanged(connected: connected, detail: detail.map { "\(instance.name): \($0)" } ?? instance.name))
        if !connected {
            for (id, light) in instance.lights where light.state.reachable {
                continuation.yield(.reachabilityChanged(id, reachable: false))
            }
        }
    }

    // MARK: - State

    /// Fetches states + registries and rebuilds the instance's lights. With `emitChanges`,
    /// differences to the previous snapshot become provider events.
    @discardableResult
    private func refresh(_ instanceID: String, emitChanges: Bool) async throws -> [Light] {
        let client = try await client(for: instanceID)
        let timeout = configuration.commandTimeout
        let statesJSON: HAJSONValue
        do {
            statesJSON = try await client.command(.getStates, timeout: timeout)
        } catch {
            throw Self.map(error, context: "get_states")
        }
        var registry = instances[instanceID]?.registry ?? .empty
        // Registries are best effort: on failure keep the previous snapshot so keys stay stable.
        if let entities = try? await client.command(.entityRegistryList, timeout: timeout) {
            let devices = (try? await client.command(.deviceRegistryList, timeout: timeout)).map(HADeviceRegistryEntry.list(from:))
            let areas = (try? await client.command(.areaRegistryList, timeout: timeout)).map(HAAreaRegistryEntry.list(from:))
            registry = HARegistry(
                entities: HAEntityRegistryEntry.list(from: entities),
                devices: devices ?? Array(registry.devices.values),
                areas: areas ?? Array(registry.areas.values))
        }
        guard instances[instanceID] != nil else { return [] }
        let states = HAEntityState.list(from: statesJSON).filter { ["light", "scene"].contains($0.domain) }
        apply(states: states, registry: registry, instanceID: instanceID, emitChanges: emitChanges)
        return instances[instanceID].map { Array($0.lights.values).sorted { $0.id < $1.id } } ?? []
    }

    private func apply(states: [HAEntityState], registry: HARegistry, instanceID: String, emitChanges: Bool) {
        guard var instance = instances[instanceID] else { return }
        let previous = instance.lights
        let previousScenes = instance.sceneEntities
        instance.registry = registry
        instance.states = Dictionary(states.map { ($0.entityID, $0) }, uniquingKeysWith: { _, last in last })
        instance.lights = [:]
        instance.entityForLight = [:]
        instance.lightForEntity = [:]
        instance.sceneEntities = []
        for state in states {
            if state.domain == "scene" {
                if !registry.isHidden(state.entityID) { instance.sceneEntities.insert(state.entityID) }
            } else if let light = HALightMapping.light(for: state, instanceID: instanceID, registry: registry) {
                instance.lights[light.id] = light
                instance.entityForLight[light.id] = state.entityID
                instance.lightForEntity[state.entityID] = light.id
            }
        }
        instance.loaded = true
        instances[instanceID] = instance

        guard emitChanges else { return }
        for (id, light) in instance.lights.sorted(by: { $0.key < $1.key }) {
            guard let old = previous[id] else {
                continuation.yield(.lightAdded(light))
                continue
            }
            emitDifference(old: old, new: light)
        }
        for id in previous.keys.sorted() where instance.lights[id] == nil {
            continuation.yield(.lightRemoved(id))
        }
        if previousScenes != instance.sceneEntities, !previous.isEmpty || !previousScenes.isEmpty {
            continuation.yield(.scenesChanged)
        }
    }

    private func emitDifference(old: Light, new: Light) {
        var oldMeta = old
        oldMeta.state = new.state
        if oldMeta != new {
            continuation.yield(.lightUpdated(new))
        } else if Self.stateDiffers(old.state, new.state) {
            if old.state.reachable != new.state.reachable {
                continuation.yield(.reachabilityChanged(new.id, reachable: new.state.reachable))
            }
            continuation.yield(.stateChanged(new.id, new.state))
        }
    }

    private static func stateDiffers(_ a: LightState, _ b: LightState) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        return a != b
    }

    private func handle(_ event: HAEvent, instanceID: String) {
        guard let change = event.stateChanged, var instance = instances[instanceID] else { return }
        let domain = HAEntityID.domain(of: change.entityID)
        if domain == "scene" {
            let known = instance.sceneEntities.contains(change.entityID)
            if let state = change.newState { instance.states[change.entityID] = state }
            instances[instanceID] = instance
            if !known || change.newState == nil { scheduleResync(instanceID) }
            return
        }
        guard domain == "light" else { return }
        guard let newState = change.newState, let lightID = instance.lightForEntity[change.entityID],
            let old = instance.lights[lightID],
            let light = HALightMapping.light(for: newState, instanceID: instanceID, registry: instance.registry),
            light.id == lightID
        else {
            // New, removed or renamed entity: rebuild from a full snapshot.
            if !instance.registry.isHidden(change.entityID) { scheduleResync(instanceID) }
            return
        }
        instance.states[change.entityID] = newState
        instance.lights[lightID] = light
        instances[instanceID] = instance
        emitDifference(old: old, new: light)
    }

    private func scheduleResync(_ instanceID: String) {
        guard instances[instanceID]?.resyncTask == nil else { return }
        let delay = configuration.resyncDelay
        instances[instanceID]?.resyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.runResync(instanceID)
        }
    }

    private func runResync(_ instanceID: String) async {
        instances[instanceID]?.resyncTask = nil
        do {
            try await refresh(instanceID, emitChanges: true)
        } catch {
            continuation.yield(.error("Home Assistant resync failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Errors

    static func map(_ error: any Error, context: String) -> any Error {
        switch error {
        case let e as LightCoreError: return e
        case is CancellationError: return error
        case let e as HAClientError:
            switch e {
            case .authInvalid: return LightCoreError.authenticationRequired(.homeAssistant)
            case .commandFailed(let info):
                if info.code == HAErrorInfo.unauthorized { return LightCoreError.authenticationRequired(.homeAssistant) }
                return LightCoreError.protocolError("\(context): \(info.code) \(info.message)")
            case .timeout: return LightCoreError.timeout
            case .connectionClosed: return LightCoreError.unreachable(context)
            case .unexpected(let s): return LightCoreError.protocolError("\(context): \(s)")
            }
        default:
            return LightCoreError.transport("\(context): \(error.localizedDescription)")
        }
    }
}

/// Dedupe helper for concurrent discovery sources.
private actor SeenSet {
    private var values: Set<String> = []

    /// Returns true when `value` was not seen before.
    func insert(_ value: String) -> Bool { values.insert(value).inserted }
}
