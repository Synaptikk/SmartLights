import Foundation
import LightCore
import NetKit
import YeelightCodec

/// Yeelight Wi-Fi lights over the LAN protocol (TCP 55443 JSON-RPC, SSDP-style discovery on
/// 239.255.255.250:1982). No account, no auth; the user must enable "LAN Control" in the Yeelight
/// app.
///
/// - Lights are keyed by the device `id` from SSDP (`yeelight:0x000000000015243f`), never by IP.
///   Hosts are hints that discovery refreshes.
/// - One persistent TCP session per bulb (`YeelightSession`): replies matched by id, `props`
///   notifications become `ProviderEvent.stateChanged`, reconnect with exponential backoff.
/// - Every call goes through a per-bulb `RateLimiter` (60 commands/min, the documented quota).
/// - `send` uses the fewest calls (`YeelightMapper.calls`): `set_scene` folds power + colour +
///   brightness into one call where that saves round trips.
public actor YeelightProvider: LightProvider {
    public static let brand: Brand = .yeelight

    /// Shown (via `PairingInteraction.confirm`) when a light refuses the TCP connection.
    public static let lanControlGuidance = """
        The light answered but refused the connection, so LAN Control is off. In the Yeelight app open \
        the light, tap the more icon, choose LAN Control and turn it on (older firmware calls it \
        Developer Mode; update the firmware if the toggle is missing). Try again now?
        """

    public struct Configuration: Sendable {
        public var session: YeelightSession.Options
        /// Per-bulb command quota.
        public var rateLimit: RateLimiter<String>.Limit
        /// Deadline for unicast SSDP and TCP probes during discovery.
        public var probeTimeout: Duration
        /// Parallel TCP probes during the /24 sweep.
        public var sweepConcurrency: Int
        /// Connection attempts in `pair` before giving up on a refused connection.
        public var pairAttempts: Int
        /// Effect/duration used when a command carries no transition.
        public var defaultTiming: YeelightTiming

        public init(
            session: YeelightSession.Options = YeelightSession.Options(),
            rateLimit: RateLimiter<String>.Limit = RateLimiter<String>.Limit(YeelightProtocol.commandsPerMinute, per: .seconds(60)),
            probeTimeout: Duration = .seconds(1),
            sweepConcurrency: Int = 32,
            pairAttempts: Int = 3,
            defaultTiming: YeelightTiming = .default
        ) {
            self.session = session
            self.rateLimit = rateLimit
            self.probeTimeout = probeTimeout
            self.sweepConcurrency = sweepConcurrency
            self.pairAttempts = max(1, pairAttempts)
            self.defaultTiming = defaultTiming
        }
    }

    struct Bulb: Sendable {
        var id: String
        var host: String
        var port: UInt16
        var model: String?
        var firmware: String?
        var support: Set<String>
        var name: String
        var kind: YeelightLightKind
        var state: LightState
        var pairedAt: Date

        var lightID: LightID { LightID(brand: .yeelight, stableId: id) ?? LightID(brand: .yeelight, stableId: "invalid")! }
        var capabilities: LightCapabilities { YeelightCapabilities.capabilities(model: model, kind: kind) }
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let connector: any YeelightConnector
    private let backend: any YeelightDiscoveryBackend
    private let configuration: Configuration
    private let limiter: RateLimiter<String>
    private let log = Log(package: "yeelightkit", category: "provider")

    private var bulbs: [String: Bulb] = [:]
    private var sessions: [String: YeelightSession] = [:]
    private var disconnected: Set<String> = []
    private var advertisements: [String: YeelightAdvertisement] = [:]

    public init(
        connector: any YeelightConnector,
        discovery: any YeelightDiscoveryBackend = NoYeelightDiscoveryBackend(),
        configuration: Configuration = Configuration()
    ) {
        self.connector = connector
        self.backend = discovery
        self.configuration = configuration
        self.limiter = RateLimiter(configuration.rateLimit)
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        continuation.finish()
    }

    /// Yeelight needs no account.
    public var account: ProviderAccount? { nil }

    // MARK: - Persistence

    /// Re-creates paired bulbs from `DeviceStore` records (call once at launch, before `loadLights`).
    public func restore(_ devices: [PairedDevice]) {
        for device in devices where device.brand == .yeelight {
            guard let host = device.hostHint, LightID(brand: .yeelight, stableId: device.id) != nil else { continue }
            let support = Set((device.metadata["support"] ?? "").split(separator: " ").map(String.init))
            let kind = device.metadata["kind"].flatMap(YeelightLightKind.init(rawValue:))
                ?? YeelightCapabilities.kind(model: device.model, support: support)
            bulbs[device.id] = Bulb(
                id: device.id, host: host, port: UInt16(clamping: device.port ?? Int(YeelightProtocol.controlPort)),
                model: device.model, firmware: device.metadata["fw_ver"], support: support, name: device.name,
                kind: kind, state: LightState(reachable: false), pairedAt: device.pairedAt
            )
        }
    }

    /// Records for `DeviceStore` (refreshed host hints, names, support lists).
    public func pairedDevices() -> [PairedDevice] {
        bulbs.values.sorted { $0.id < $1.id }.map(pairedDevice(for:))
    }

    /// Forgets a light and closes its connection.
    public func remove(_ light: LightID) async {
        guard light.brand == .yeelight else { return }
        bulbs[light.stableId] = nil
        disconnected.remove(light.stableId)
        if let session = sessions.removeValue(forKey: light.stableId) { await session.close() }
        continuation.yield(.lightRemoved(light))
    }

    /// Closes every connection (app backgrounding). Sessions reopen on the next command.
    public func disconnectAll() async {
        let all = sessions
        sessions.removeAll()
        for session in all.values { await session.close() }
    }

    // MARK: - Discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        let sink = DiscoverySink(continuation)
        let task = Task { [weak self] in
            await self?.runDiscovery(options, sink: sink)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(_ options: DiscoveryOptions, sink: DiscoverySink) async {
        let backend = self.backend
        let timeout = options.timeout
        let methods = options.methods
        let concurrency = configuration.sweepConcurrency
        var direct: [(String, DiscoveryMethod)] = []
        if methods.contains(.manual) { direct += options.manualHosts.map { ($0, .manual) } }
        if methods.contains(.cached) {
            let cached = options.cachedHosts + bulbs.values.map(\.host)
            direct += cached.map { ($0, .cached) }
        }
        var seenHosts: Set<String> = []
        direct = direct.filter { seenHosts.insert($0.0.trimmingCharacters(in: .whitespaces)).inserted && !$0.0.isEmpty }

        await withTaskGroup(of: Bool.self) { group in
            var work = 0
            group.addTask {
                try? await Task.sleep(for: timeout)
                return true
            }
            for (host, method) in direct {
                work += 1
                group.addTask {
                    if let d = await self.probe(host: host.trimmingCharacters(in: .whitespaces), method: method) { await sink.yield(d) }
                    return false
                }
            }
            if options.broadcastAvailable && methods.contains(.broadcast) {
                work += 1
                group.addTask {
                    for await adv in backend.multicastSearch(timeout: timeout) {
                        await self.note(adv)
                        await sink.yield(Self.discovered(adv, method: .broadcast))
                    }
                    return false
                }
            }
            if methods.contains(.bonjour) {
                work += 1
                group.addTask {
                    for await hit in backend.bonjour(timeout: timeout) {
                        guard let host = hit.host else { continue }
                        if let d = await self.probe(host: host, method: .bonjour) {
                            await sink.yield(d)
                        } else if let parsed = hit.parsedName, let id = parsed.derivedID {
                            await sink.yield(DiscoveredDevice(
                                id: id, brand: .yeelight, name: Self.defaultName(model: parsed.model), model: parsed.model,
                                host: host, port: Int(YeelightProtocol.controlPort), method: .bonjour,
                                metadata: ["bonjourName": hit.serviceName, "idSource": "bonjour"]
                            ))
                        }
                    }
                    return false
                }
            }
            if methods.contains(.sweep) && !options.broadcastAvailable {
                work += 1
                group.addTask {
                    let hosts = backend.sweepHosts()
                    let sweeper = SubnetSweeper(maxConcurrent: concurrency)
                    let stream = sweeper.stream(hosts) { ip -> DiscoveredDevice? in
                        await self.probe(host: ip.description, method: .sweep)
                    }
                    for await d in stream { await sink.yield(d) }
                    return false
                }
            }
            guard work > 0 else {
                group.cancelAll()
                return
            }
            while let isDeadline = await group.next() {
                if isDeadline { break }
                work -= 1
                if work == 0 { break }
            }
            group.cancelAll()
        }
    }

    /// TCP probe (`get_prop` on 55443) plus unicast SSDP for the stable id.
    /// Manual hosts that refuse the TCP connection are still reported (`metadata["lanControl"] = "off"`)
    /// so the wizard can explain the LAN Control toggle; refused sweep hosts are skipped.
    func probe(host: String, method: DiscoveryMethod) async -> DiscoveredDevice? {
        let session = YeelightSession(
            host: host, connector: connector,
            options: YeelightSession.Options(connectTimeout: configuration.probeTimeout,
                                             requestTimeout: configuration.probeTimeout, keepAlive: false)
        )
        var props: [String: YeelightValue] = [:]
        var refused = false
        do {
            let names = YeelightCommands.stateProperties
            let values = try await session.perform(YeelightCommands.getProp(names))
            props = YeelightMapper.properties(names: names, values: values)
        } catch YeelightTransportError.connectionRefused {
            refused = true
        } catch {
            await session.close()
            return nil
        }
        await session.close()
        if refused && method == .sweep { return nil }

        if let adv = await backend.unicastSearch(host: host, timeout: configuration.probeTimeout) {
            note(adv)
            var d = Self.discovered(adv, method: method)
            if refused { d.metadata["lanControl"] = "off" }
            return d
        }
        let known = bulbs.values.first { $0.host == host }
        let name = props["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? known?.name ?? "Yeelight (\(host))"
        var metadata: [String: String] = ["idSource": known == nil ? "provisional" : "cached"]
        if refused { metadata["lanControl"] = "off" }
        return DiscoveredDevice(
            id: known?.id ?? "ip:\(host)", brand: .yeelight, name: name, model: known?.model, host: host,
            port: Int(YeelightProtocol.controlPort), method: method, metadata: metadata
        )
    }

    /// Remembers an advertisement; moves a paired bulb to its new address if the IP changed.
    func note(_ adv: YeelightAdvertisement) {
        advertisements[adv.id] = adv
        guard var bulb = bulbs[adv.id] else { return }
        if bulb.host != adv.host || bulb.port != adv.port {
            log.info("\(adv.id) moved \(bulb.host) -> \(adv.host)")
            bulb.host = adv.host
            bulb.port = adv.port
            if let old = sessions.removeValue(forKey: adv.id) { Task { await old.close() } }
        }
        if !adv.support.isEmpty { bulb.support = adv.support }
        if let fw = adv.firmwareVersion { bulb.firmware = fw }
        bulbs[adv.id] = bulb
    }

    static func defaultName(model: String?) -> String {
        model.map { "Yeelight \($0)" } ?? "Yeelight"
    }

    static func discovered(_ adv: YeelightAdvertisement, method: DiscoveryMethod) -> DiscoveredDevice {
        var metadata: [String: String] = ["idSource": "ssdp"]
        if let fw = adv.firmwareVersion { metadata["fw_ver"] = fw }
        if !adv.support.isEmpty { metadata["support"] = adv.support.sorted().joined(separator: " ") }
        return DiscoveredDevice(
            id: adv.id, brand: .yeelight, name: adv.name ?? defaultName(model: adv.model), model: adv.model,
            host: adv.host, port: Int(adv.port), method: method, metadata: metadata
        )
    }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .yeelight else { throw LightCoreError.unsupported("\(device.brand.displayName) device") }
        guard let host = device.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            throw LightCoreError.unreachable("\(device.name) has no IP address")
        }
        var id = device.id
        var port = UInt16(clamping: device.port ?? Int(YeelightProtocol.controlPort))
        var adv = advertisements[id]
        if adv == nil || id.hasPrefix("ip:") {
            if let found = await backend.unicastSearch(host: host, timeout: configuration.probeTimeout) {
                note(found)
                adv = found
                id = found.id
                port = found.port
            }
        }
        guard LightID(brand: .yeelight, stableId: id) != nil else { throw LightCoreError.invalidLightID("yeelight:\(id)") }
        if id.hasPrefix("ip:") {
            log.notice("pairing \(host) without an SSDP id; using provisional id \(id)")
        }

        let support = adv?.support ?? Set((device.metadata["support"] ?? "").split(separator: " ").map(String.init))
        let model = adv?.model ?? device.model
        let session = makeSession(id: id, host: host, port: port)

        let names = YeelightCommands.stateProperties
        var props: [String: YeelightValue] = [:]
        var attempt = 0
        while true {
            attempt += 1
            do {
                await ui.status("Connecting to \(device.name) at \(host)")
                try await limiter.acquire(id)
                let values = try await session.perform(YeelightCommands.getProp(names))
                props = YeelightMapper.properties(names: names, values: values)
                break
            } catch YeelightTransportError.connectionRefused {
                guard attempt < configuration.pairAttempts else {
                    await discardSession(id)
                    throw LightCoreError.unreachable("\(device.name) refused the connection. Turn on LAN Control in the Yeelight app.")
                }
                let retry: Bool
                do {
                    retry = try await ui.confirm(Self.lanControlGuidance)
                } catch {
                    await discardSession(id)
                    throw error
                }
                guard retry else {
                    await discardSession(id)
                    throw LightCoreError.userCancelled
                }
            } catch {
                await discardSession(id)
                throw Self.mapError(error, name: device.name)
            }
        }

        let kind = YeelightCapabilities.kind(model: model, support: support, properties: props)
        let name = props["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? adv?.name ?? device.name
        let state = YeelightMapper.state(merging: (adv?.properties ?? [:]).merging(props) { $1 }, into: LightState(), kind: kind)
        let bulb = Bulb(
            id: id, host: host, port: port, model: model, firmware: adv?.firmwareVersion ?? device.metadata["fw_ver"],
            support: support, name: name, kind: kind, state: state, pairedAt: Date()
        )
        let isNew = bulbs[id] == nil
        bulbs[id] = bulb
        disconnected.remove(id)
        continuation.yield(isNew ? .lightAdded(light(for: bulb)) : .lightUpdated(light(for: bulb)))
        return pairedDevice(for: bulb)
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        let ids = Array(bulbs.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    _ = try? await self?.refreshBulb(id)
                }
            }
        }
        return bulbs.values.sorted { $0.id < $1.id }.map(light(for:))
    }

    /// Reads the bulb's state with `get_prop` and returns it.
    @discardableResult
    public func refresh(_ light: LightID) async throws -> LightState {
        guard light.brand == .yeelight, bulbs[light.stableId] != nil else { throw LightCoreError.lightNotFound(light) }
        return try await refreshBulb(light.stableId)
    }

    private func refreshBulb(_ id: String) async throws -> LightState {
        guard let bulb = bulbs[id] else { throw LightCoreError.lightNotFound(LightID(brand: .yeelight, stableId: id) ?? LightID("yeelight:unknown")!) }
        let names = YeelightCommands.stateProperties
        do {
            let values = try await perform(YeelightCommands.getProp(names), on: bulb)
            let props = YeelightMapper.properties(names: names, values: values)
            guard var current = bulbs[id] else { throw LightCoreError.lightNotFound(bulb.lightID) }
            current.state = YeelightMapper.state(merging: props, into: current.state, kind: current.kind)
            if let name = props["name"]?.stringValue, !name.isEmpty { current.name = name }
            bulbs[id] = current
            return current.state
        } catch {
            if var current = bulbs[id], current.state.reachable {
                current.state.reachable = false
                bulbs[id] = current
                continuation.yield(.reachabilityChanged(current.lightID, reachable: false))
            }
            throw error
        }
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .yeelight, let bulb = bulbs[light.stableId] else { throw LightCoreError.lightNotFound(light) }
        let capabilities = bulb.capabilities
        let calls = YeelightMapper.calls(
            for: command, capabilities: capabilities, current: bulb.state, support: bulb.support,
            defaultTiming: configuration.defaultTiming
        )
        guard !calls.isEmpty else { return }
        for call in calls {
            try await perform(call, on: bulb)
        }
        guard var updated = bulbs[bulb.id] else { return }
        updated.state = updated.state.applying(command.normalized(for: capabilities))
        updated.state.reachable = true
        bulbs[bulb.id] = updated
        continuation.yield(.stateChanged(light, updated.state))
    }

    /// Concurrent fan-out (each bulb has its own connection and quota).
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        let failures = await withTaskGroup(of: (LightID, String?).self) { group in
            for id in lights {
                group.addTask { [weak self] in
                    guard let self else { return (id, "provider released") }
                    do {
                        try await self.send(command, to: id)
                        return (id, nil)
                    } catch {
                        return (id, String(describing: error))
                    }
                }
            }
            var out: [LightID: String] = [:]
            for await (id, failure) in group {
                if let failure { out[id] = failure }
            }
            return out
        }
        try Task.checkCancellation()
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    /// Stores a name on the device (`set_name`) and updates the light.
    public func setName(_ name: String, for light: LightID) async throws {
        guard light.brand == .yeelight, let bulb = bulbs[light.stableId] else { throw LightCoreError.lightNotFound(light) }
        try await perform(YeelightCommands.setName(name), on: bulb)
        guard var updated = bulbs[bulb.id] else { return }
        updated.name = name
        bulbs[bulb.id] = updated
        continuation.yield(.lightUpdated(self.light(for: updated)))
    }

    /// Toggles power with the device's `toggle` method.
    public func toggle(_ light: LightID) async throws {
        guard light.brand == .yeelight, let bulb = bulbs[light.stableId] else { throw LightCoreError.lightNotFound(light) }
        try await perform(YeelightCommands.toggle(), on: bulb)
        guard var updated = bulbs[bulb.id] else { return }
        updated.state.isOn.toggle()
        updated.state.updatedAt = Date()
        bulbs[bulb.id] = updated
        continuation.yield(.stateChanged(light, updated.state))
    }

    // MARK: - Sessions

    @discardableResult
    private func perform(_ call: YeelightCall, on bulb: Bulb) async throws -> [YeelightValue] {
        let session = makeSession(id: bulb.id, host: bulb.host, port: bulb.port)
        do {
            try await limiter.acquire(bulb.id)
            return try await session.perform(call)
        } catch {
            throw Self.mapError(error, name: bulb.name)
        }
    }

    private func makeSession(id: String, host: String, port: UInt16) -> YeelightSession {
        if let existing = sessions[id], existing.host == host, existing.port == port { return existing }
        if let old = sessions.removeValue(forKey: id) { Task { await old.close() } }
        let session = YeelightSession(host: host, port: port, connector: connector, options: configuration.session) { [weak self] event in
            await self?.handleSessionEvent(id, event)
        }
        sessions[id] = session
        return session
    }

    private func discardSession(_ id: String) async {
        guard bulbs[id] == nil, let session = sessions.removeValue(forKey: id) else { return }
        await session.close()
    }

    private func handleSessionEvent(_ id: String, _ event: YeelightSession.Event) {
        guard var bulb = bulbs[id] else { return }
        switch event {
        case .properties(let props):
            bulb.state = YeelightMapper.state(merging: props, into: bulb.state, kind: bulb.kind)
            if let name = props["name"]?.stringValue, !name.isEmpty { bulb.name = name }
            bulbs[id] = bulb
            disconnected.remove(id)
            continuation.yield(.stateChanged(bulb.lightID, bulb.state))
        case .disconnected:
            guard disconnected.insert(id).inserted else { return }
            bulb.state.reachable = false
            bulbs[id] = bulb
            continuation.yield(.reachabilityChanged(bulb.lightID, reachable: false))
        case .connected:
            guard disconnected.remove(id) != nil else { return }
            bulb.state.reachable = true
            bulbs[id] = bulb
            continuation.yield(.reachabilityChanged(bulb.lightID, reachable: true))
            Task { [weak self] in
                guard let self, let state = try? await self.refreshBulb(id) else { return }
                await self.emitState(id, state)
            }
        }
    }

    private func emitState(_ id: String, _ state: LightState) {
        guard let bulb = bulbs[id] else { return }
        continuation.yield(.stateChanged(bulb.lightID, state))
    }

    // MARK: - Mapping

    func light(for bulb: Bulb) -> Light {
        Light(
            id: bulb.lightID, name: bulb.name, capabilities: bulb.capabilities, state: bulb.state,
            providerRef: "\(bulb.host):\(bulb.port)", manufacturer: nil, model: bulb.model
        )
    }

    func pairedDevice(for bulb: Bulb) -> PairedDevice {
        var metadata: [String: String] = ["kind": bulb.kind.rawValue]
        if !bulb.support.isEmpty { metadata["support"] = bulb.support.sorted().joined(separator: " ") }
        if let fw = bulb.firmware { metadata["fw_ver"] = fw }
        if bulb.id.hasPrefix("ip:") { metadata["idSource"] = "provisional" }
        return PairedDevice(
            id: bulb.id, brand: .yeelight, name: bulb.name, model: bulb.model, hostHint: bulb.host,
            port: Int(bulb.port), lightIDs: [bulb.lightID], metadata: metadata, pairedAt: bulb.pairedAt,
            lastSeen: bulb.state.reachable ? bulb.state.updatedAt : nil
        )
    }

    static func mapError(_ error: any Error, name: String) -> any Error {
        switch error {
        case let e as LightCoreError: return e
        case is CancellationError: return error
        case let e as YeelightRPCError:
            return LightCoreError.protocolError(e.isQuotaExceeded ? "\(name): command quota exceeded (60/min)" : "\(name): \(e)")
        case let e as YeelightTransportError:
            switch e {
            case .connectionRefused:
                return LightCoreError.unreachable("\(name) refused the connection. Turn on LAN Control in the Yeelight app.")
            case .timedOut: return LightCoreError.timeout
            case .unreachable(let s): return LightCoreError.unreachable("\(name): \(s)")
            case .localNetworkDenied:
                return LightCoreError.unreachable("Local Network access is off. Settings > Privacy & Security > Local Network.")
            case .connectionLost, .closed, .other: return LightCoreError.transport("\(name): \(e)")
            }
        default:
            return LightCoreError.transport("\(name): \(error)")
        }
    }
}

/// Deduplicates discovery results across methods.
private actor DiscoverySink {
    private let continuation: AsyncStream<DiscoveredDevice>.Continuation
    private var ids: Set<String> = []
    private var hostsWithStableID: Set<String> = []

    init(_ continuation: AsyncStream<DiscoveredDevice>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ device: DiscoveredDevice) {
        let provisional = device.id.hasPrefix("ip:")
        if provisional, let host = device.host, hostsWithStableID.contains(host) { return }
        guard ids.insert(device.id).inserted else { return }
        if !provisional, let host = device.host { hostsWithStableID.insert(host) }
        continuation.yield(device)
    }
}

#if canImport(Network) && canImport(Darwin)
extension YeelightProvider {
    /// Provider wired to Network.framework TCP and the live discovery backend.
    public static func live(configuration: Configuration = Configuration()) -> YeelightProvider {
        YeelightProvider(connector: NWYeelightConnector(), discovery: LiveYeelightDiscovery(), configuration: configuration)
    }
}
#endif
