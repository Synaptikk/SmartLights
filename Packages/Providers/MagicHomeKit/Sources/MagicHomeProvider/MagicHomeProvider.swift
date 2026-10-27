import Foundation
import LightCore
import MagicHomeCodec
import NetKit

/// Magic Home / Zengge / LEDENET over the LAN (binary TCP 5577, UDP 48899 discovery, no auth).
///
/// - Devices are keyed by MAC (`magichome:b4e842e10588`, from the UDP discovery reply); IPs are
///   cached hints refreshed by every discovery.
/// - One persistent TCP connection per device (the firmware accepts very few concurrent clients).
///   Replies are framed by `MagicHomeFramer`; devices with push firmware report external changes
///   on the same connection, which become `.stateChanged` events.
/// - State: `81 8a 8b` query, `requestTimeout` (2 s) per attempt, `retries` (2) with a fresh
///   connection each. Commands are not acknowledged by the protocol: the predicted state is applied
///   and the next poll/push reconciles.
/// - Discovery: UDP broadcast `HF-A11ASSISTHREAD` when allowed (multicast entitlement), else a
///   unicast sweep of the Wi-Fi /24 with the same datagram, plus cached and manual hosts.
public actor MagicHomeProvider: LightProvider {
    public static let brand: Brand = .magicHome

    public struct Configuration: Sendable {
        public var tcpPort: UInt16
        public var discoveryPort: UInt16
        public var connectTimeout: Duration
        public var requestTimeout: Duration
        /// Extra state-query attempts (each on a fresh connection).
        public var retries: Int
        /// How long broadcast discovery listens for replies.
        public var broadcastListen: Duration
        /// Per-host timeout during the unicast sweep and manual probes.
        public var probeTimeout: Duration
        public var sweepConcurrency: Int
        /// Polling period while `start()`ed (also refreshes reachability).
        public var pollInterval: Duration
        /// Use `0x31` (persisted) levels; `false` sends `0x41`, which the device does not store.
        public var persistLevels: Bool

        public init(
            tcpPort: UInt16 = MagicHomeMessage.port,
            discoveryPort: UInt16 = MagicHomeDiscovery.port,
            connectTimeout: Duration = .seconds(3),
            requestTimeout: Duration = .seconds(2),
            retries: Int = 2,
            broadcastListen: Duration = .seconds(3),
            probeTimeout: Duration = .milliseconds(600),
            sweepConcurrency: Int = 32,
            pollInterval: Duration = .seconds(10),
            persistLevels: Bool = true
        ) {
            self.tcpPort = tcpPort
            self.discoveryPort = discoveryPort
            self.connectTimeout = connectTimeout
            self.requestTimeout = requestTimeout
            self.retries = retries
            self.broadcastListen = broadcastListen
            self.probeTimeout = probeTimeout
            self.sweepConcurrency = sweepConcurrency
            self.pollInterval = pollInterval
            self.persistLevels = persistLevels
        }
    }

    struct Device {
        var mac: String
        var host: String
        /// Hardware string from discovery ("AK001-ZJ2145").
        var hardware: String?
        var name: String?
        var raw: MagicHomeRawState?
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?

        var profile: MagicHomeProfile? { raw.map(MagicHomeProfile.init(state:)) }
    }

    private struct Session {
        var connection: any MagicHomeConnection
        var reader: Task<Void, Never>
        var framer = MagicHomeFramer()
        var generation: Int
    }

    private struct StateWaiter {
        var token: Int
        var continuation: CheckedContinuation<MagicHomeRawState, any Error>
        var timer: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: MagicHomeNetworkEnvironment
    private let log = Log(package: "magichomekit", category: "provider")

    private var devices: [String: Device] = [:]
    private var sessions: [String: Session] = [:]
    private var connecting: [String: Task<any MagicHomeConnection, any Error>] = [:]
    private var waiters: [String: [StateWaiter]] = [:]
    private var nextToken = 0
    private var nextGeneration = 0
    private var counter: UInt8 = 0
    private var pollTask: Task<Void, Never>?

    public init(configuration: Configuration = Configuration(), environment: MagicHomeNetworkEnvironment) {
        self.configuration = configuration
        self.environment = environment
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        for (_, s) in sessions {
            s.reader.cancel()
            s.connection.close()
        }
        eventContinuation.finish()
    }

    /// No account: Magic Home LAN control is unauthenticated.
    public var account: ProviderAccount? { nil }

    // MARK: - Lifecycle

    /// Starts polling paired devices every `configuration.pollInterval`. Idempotent.
    public func start() {
        guard pollTask == nil else { return }
        let interval = configuration.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
            }
        }
    }

    /// Stops polling (e.g. app in background). Open connections stay until `shutdown()`.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Stops polling and closes every connection. Pending queries fail.
    public func shutdown() {
        stop()
        for mac in Array(sessions.keys) { dropSession(mac, error: LightCoreError.transport("Magic Home provider shut down")) }
    }

    /// Re-registers devices persisted by the app without touching the network.
    public func restore(_ paired: [PairedDevice]) {
        for p in paired where p.brand == .magicHome {
            guard let mac = MagicHomeDiscovery.normalizeMAC(p.id), let host = p.hostHint else { continue }
            var d = devices[mac] ?? Device(mac: mac, host: host)
            d.host = host
            d.name = d.name ?? p.name
            d.hardware = d.hardware ?? p.metadata["hardware"]
            d.paired = p
            devices[mac] = d
        }
    }

    /// MACs of paired devices (diagnostics/tests).
    public var pairedMACs: [String] { devices.values.filter { $0.paired != nil }.map(\.mac).sorted() }

    /// Cached host for a light (diagnostics/tests).
    public func host(of id: LightID) -> String? {
        MagicHomeMapping.mac(of: id).flatMap { devices[$0]?.host }
    }

    /// Whether a TCP connection to the device is open (diagnostics/tests).
    public func isConnected(_ id: LightID) -> Bool {
        MagicHomeMapping.mac(of: id).map { sessions[$0] != nil } ?? false
    }

    // MARK: - LightProvider: discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        let work = Task { await self.runDiscovery(options: options, into: continuation) }
        let timer = Task {
            try? await Task.sleep(for: options.timeout)
            work.cancel()
        }
        let finisher = Task {
            await work.value
            timer.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            work.cancel()
            timer.cancel()
            _ = finisher
        }
        return stream
    }

    private func runDiscovery(options: DiscoveryOptions, into continuation: AsyncStream<DiscoveredDevice>.Continuation) async {
        let seen = SeenSet()
        let methods = options.methods
        let report: @Sendable (DiscoveredDevice?) async -> Void = { device in
            guard let device, await seen.insert(device.id) else { return }
            continuation.yield(device)
        }
        let config = configuration
        let env = environment
        let broadcast = options.broadcastAvailable && methods.contains(.broadcast) ? env.broadcast : nil
        let sweepHosts = broadcast == nil && methods.contains(.sweep) ? env.sweepHosts() : []
        var direct: [(String, DiscoveryMethod)] = []
        if methods.contains(.cached) {
            direct += options.cachedHosts.map { ($0, .cached) }
            direct += devices.values.map { ($0.host, .cached) }
        }
        if methods.contains(.manual) { direct += options.manualHosts.map { ($0, .manual) } }
        let directProbes = direct.compactMap { spec, method in Self.parseHost(spec).map { ($0, method) } }

        await withTaskGroup(of: Void.self) { group in
            if let broadcast {
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        var hosts: Set<String> = []
                        for await datagram in broadcast(MagicHomeDiscovery.request, config.discoveryPort, config.broadcastListen) {
                            guard let reply = MagicHomeDiscovery.parseReply(datagram.data), hosts.insert(reply.mac).inserted else { continue }
                            inner.addTask { await report(await self.describe(reply, host: datagram.host, method: .broadcast)) }
                        }
                    }
                }
            } else if !sweepHosts.isEmpty {
                group.addTask {
                    let sweeper = SubnetSweeper(maxConcurrent: config.sweepConcurrency)
                    let hosts = sweepHosts.compactMap(IPv4Addr.init)
                    let results = sweeper.stream(hosts) { host -> (MagicHomeDiscovery.Reply, String)? in
                        guard let d = await env.unicast(MagicHomeDiscovery.request, host.description, config.discoveryPort, config.probeTimeout),
                              let reply = MagicHomeDiscovery.parseReply(d.data) else { return nil }
                        return (reply, host.description)
                    }
                    await withTaskGroup(of: Void.self) { inner in
                        for await (reply, host) in results {
                            inner.addTask { await report(await self.describe(reply, host: host, method: .sweep)) }
                        }
                    }
                }
            }
            for (host, method) in directProbes {
                group.addTask { await report(await self.probe(host: host, method: method)) }
            }
        }
        // Discovery opened connections to identify devices; keep only those of paired devices.
        for (mac, d) in devices where d.paired == nil && sessions[mac] != nil {
            dropSession(mac, error: LightCoreError.transport("discovery finished"))
        }
    }

    /// UDP discovery datagram to one host; falls back to a TCP state query (no MAC then: the
    /// device gets a provisional `ip:` id and pairing asks UDP again).
    private func probe(host: String, method: DiscoveryMethod) async -> DiscoveredDevice? {
        if let d = await environment.unicast(MagicHomeDiscovery.request, host, configuration.discoveryPort, configuration.probeTimeout),
           let reply = MagicHomeDiscovery.parseReply(d.data) {
            return await describe(reply, host: host, method: method)
        }
        guard let raw = try? await queryOnce(host: host) else { return nil }
        let profile = MagicHomeProfile(state: raw)
        return DiscoveredDevice(
            id: "ip:\(host)", brand: .magicHome, name: "Magic Home \(profile.model.name)", model: profile.modelDescription,
            host: host, port: Int(configuration.tcpPort), method: method, metadata: Self.metadata(profile: profile, hardware: nil)
        )
    }

    /// Records the endpoint and reads the state once (model id, firmware) to describe the device.
    private func describe(_ reply: MagicHomeDiscovery.Reply, host replyHost: String, method: DiscoveryMethod) async -> DiscoveredDevice? {
        let host = IPv4Addr(reply.ip) != nil ? reply.ip : replyHost
        noteEndpoint(reply.mac, host: host, hardware: reply.model)
        if devices[reply.mac]?.raw == nil { _ = try? await queryState(reply.mac, retries: 0) }
        let d = devices[reply.mac]!
        let profile = d.profile
        return DiscoveredDevice(
            id: reply.mac,
            brand: .magicHome,
            name: d.name ?? Self.defaultName(profile: profile, mac: reply.mac),
            model: profile?.modelDescription ?? reply.model,
            host: host,
            port: Int(configuration.tcpPort),
            macAddress: reply.mac,
            method: method,
            metadata: Self.metadata(profile: profile, hardware: reply.model)
        )
    }

    // MARK: - LightProvider: pairing

    /// No credentials: pairing confirms the device answers, learns its MAC (UDP 48899) and model
    /// (state query), and records it. Devices without a host (Add by IP) ask for an IP address.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .magicHome else { throw LightCoreError.unsupported("\(device.name) is not a Magic Home device") }
        var hostSpec = device.host
        if hostSpec == nil || hostSpec?.isEmpty == true {
            hostSpec = try await ui.text("IP address of the Magic Home light (shown in your router's device list)")
        }
        guard let host = hostSpec.flatMap(Self.parseHost) else { throw LightCoreError.unreachable("no address for \(device.name)") }

        var mac = MagicHomeDiscovery.normalizeMAC(device.id) ?? device.macAddress.flatMap(MagicHomeDiscovery.normalizeMAC)
        var hardware = device.metadata["hardware"]
        if mac == nil {
            await ui.status("Contacting \(host)...")
            if let d = await environment.unicast(MagicHomeDiscovery.request, host, configuration.discoveryPort, configuration.requestTimeout),
               let reply = MagicHomeDiscovery.parseReply(d.data) {
                mac = reply.mac
                hardware = reply.model
            }
        }
        guard let mac else {
            throw LightCoreError.unreachable("The light at \(host) did not report its MAC address (UDP 48899)")
        }
        noteEndpoint(mac, host: host, hardware: hardware)
        let raw: MagicHomeRawState
        do {
            raw = try await queryState(mac)
        } catch {
            throw LightCoreError.unreachable("Magic Home light \(mac) did not answer at \(host):\(configuration.tcpPort)")
        }
        let profile = MagicHomeProfile(state: raw)
        guard profile.isSupported else {
            throw LightCoreError.unsupported("\(profile.modelDescription) firmware \(profile.version) uses a protocol SmartLights does not speak yet")
        }
        let d = devices[mac]!
        let paired = PairedDevice(
            id: mac,
            brand: .magicHome,
            name: d.name ?? Self.defaultName(profile: profile, mac: mac),
            model: profile.modelDescription,
            hostHint: d.host,
            port: Int(configuration.tcpPort),
            lightIDs: [MagicHomeMapping.lightID(mac: mac)],
            metadata: Self.metadata(profile: profile, hardware: d.hardware),
            lastSeen: d.lastSeen
        )
        devices[mac]?.paired = paired
        if let light = light(for: mac) { emit(.lightAdded(light)) }
        return paired
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        let macs = pairedMACs
        await withTaskGroup(of: Void.self) { group in
            for mac in macs { group.addTask { await self.refresh(mac, emitChanges: false) } }
        }
        return macs.compactMap(light(for:))
    }

    /// One polling round over every paired device; emits changes.
    public func pollOnce() async {
        let macs = pairedMACs
        await withTaskGroup(of: Void.self) { group in
            for mac in macs { group.addTask { await self.refresh(mac, emitChanges: true) } }
        }
    }

    private func refresh(_ mac: String, emitChanges: Bool) async {
        do {
            _ = try await queryState(mac)
        } catch {
            markReachable(mac, false, emit: emitChanges)
        }
    }

    private func light(for mac: String) -> Light? {
        guard let d = devices[mac] else { return nil }
        let id = MagicHomeMapping.lightID(mac: mac)
        guard let raw = d.raw else {
            return Light(id: id, name: d.name ?? d.paired?.name ?? "Magic Home \(mac.suffix(4))", capabilities: .onOff,
                         state: LightState(reachable: false), providerRef: d.host, manufacturer: "Magic Home", model: d.hardware)
        }
        let profile = MagicHomeProfile(state: raw)
        var state = MagicHomeMapping.state(raw, profile: profile, at: d.lastSeen ?? Date())
        state.reachable = d.reachable
        return Light(
            id: id,
            name: d.name ?? d.paired?.name ?? Self.defaultName(profile: profile, mac: mac),
            capabilities: MagicHomeMapping.capabilities(for: profile),
            state: state,
            providerRef: d.host,
            manufacturer: "Magic Home",
            model: profile.modelDescription
        )
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to id: LightID) async throws {
        guard let mac = MagicHomeMapping.mac(of: id), devices[mac] != nil else { throw LightCoreError.lightNotFound(id) }
        if command.isEmpty { return }
        do {
            if devices[mac]?.raw == nil { _ = try await queryState(mac) }
            guard let raw = devices[mac]?.raw else { throw LightCoreError.unreachable(id.rawValue) }
            let profile = MagicHomeProfile(state: raw)
            guard profile.isSupported else { throw LightCoreError.unsupported("\(profile.modelDescription) cannot be controlled yet") }
            counter &+= 1
            let plan = MagicHomeMapping.plan(command, current: raw, profile: profile, persist: configuration.persistLevels, counter: counter)
            if plan.isEmpty { return }
            try await write(plan.messages, to: mac)
            devices[mac]?.raw = plan.predicted
            devices[mac]?.lastSeen = Date()
            markReachable(mac, true, emit: true)
            if let light = light(for: mac) { emit(.stateChanged(light.id, light.state)) }
        } catch let error as LightCoreError {
            if case .unsupported = error { throw error }
            markReachable(mac, false, emit: true)
            throw LightCoreError.unreachable("Magic Home light \(devices[mac]?.name ?? mac) did not answer")
        }
    }

    /// Concurrent fan-out (one connection per device).
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        let failures = await withTaskGroup(of: (LightID, String?).self) { group in
            for id in lights {
                group.addTask {
                    do {
                        try await self.send(command, to: id)
                        return (id, nil)
                    } catch {
                        return (id, String(describing: error))
                    }
                }
            }
            var out: [LightID: String] = [:]
            for await (id, failure) in group { if let failure { out[id] = failure } }
            return out
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    /// Sends messages in order; on a broken connection reconnects once and resends all of them.
    private func write(_ messages: [Data], to mac: String) async throws {
        for attempt in 0...1 {
            do {
                let connection = try await connection(for: mac)
                for m in messages { try await connection.send(m) }
                return
            } catch {
                dropSession(mac, error: error)
                if attempt == 1 { throw LightCoreError.transport(String(describing: error)) }
            }
        }
    }

    // MARK: - State query

    /// Queries the state (`81 8a 8b`), retrying on fresh connections. Throws `LightCoreError.timeout`.
    @discardableResult
    func queryState(_ mac: String, retries: Int? = nil) async throws -> MagicHomeRawState {
        let attempts = 1 + max(0, retries ?? configuration.retries)
        var lastError: any Error = LightCoreError.timeout
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let connection = try await connection(for: mac)
                let proto = devices[mac]?.profile?.protocol ?? .ledenet8Byte
                counter &+= 1
                let query = MagicHomeMessage.stateQuery(proto, counter: counter)
                return try await awaitState(mac, timeout: configuration.requestTimeout) {
                    try await connection.send(query)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                log.debug("state query \(mac) attempt \(attempt)/\(attempts) failed: \(error)")
                dropSession(mac, error: error)
            }
        }
        throw (lastError as? LightCoreError) ?? LightCoreError.timeout
    }

    /// Registers a waiter for the next state from `mac`, runs `send`, waits up to `timeout`.
    private func awaitState(_ mac: String, timeout: Duration, send: @escaping @Sendable () async throws -> Void) async throws -> MagicHomeRawState {
        nextToken += 1
        let token = nextToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MagicHomeRawState, any Error>) in
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.failWaiter(mac, token: token, LightCoreError.timeout)
                }
                waiters[mac, default: []].append(StateWaiter(token: token, continuation: continuation, timer: timer))
                Task { [weak self] in
                    do { try await send() } catch { await self?.failWaiter(mac, token: token, error) }
                }
            }
        } onCancel: {
            Task { await self.failWaiter(mac, token: token, CancellationError()) }
        }
    }

    private func failWaiter(_ mac: String, token: Int, _ error: any Error) {
        guard var list = waiters[mac], let i = list.firstIndex(where: { $0.token == token }) else { return }
        let w = list.remove(at: i)
        waiters[mac] = list.isEmpty ? nil : list
        w.timer.cancel()
        w.continuation.resume(throwing: error)
    }

    /// Probe without a known MAC (manual host that ignores UDP): own short-lived connection.
    private func queryOnce(host: String) async throws -> MagicHomeRawState {
        let connection = try await environment.connect(host, configuration.tcpPort, configuration.connectTimeout)
        defer { connection.close() }
        let incoming = connection.incoming
        let timeout = configuration.requestTimeout
        return try await withThrowingTaskGroup(of: MagicHomeRawState?.self) { group in
            group.addTask {
                var framer = MagicHomeFramer()
                for try await chunk in incoming {
                    for case .state(let s) in framer.push(chunk) { return s }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            try await connection.send(MagicHomeMessage.stateQuery())
            let first = try await group.next() ?? nil
            group.cancelAll()
            connection.close()
            guard let state = first else { throw LightCoreError.timeout }
            return state
        }
    }

    // MARK: - Connections

    private func connection(for mac: String) async throws -> any MagicHomeConnection {
        if let s = sessions[mac] { return s.connection }
        if let pending = connecting[mac] { return try await pending.value }
        guard let host = devices[mac]?.host else { throw LightCoreError.lightNotFound(MagicHomeMapping.lightID(mac: mac)) }
        let env = environment
        let port = configuration.tcpPort
        let timeout = configuration.connectTimeout
        let task = Task { try await env.connect(host, port, timeout) }
        connecting[mac] = task
        defer { connecting[mac] = nil }
        let connection = try await task.value
        nextGeneration += 1
        let generation = nextGeneration
        let stream = connection.incoming
        let reader = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self else { return }
                    await self.received(chunk, from: mac, generation: generation)
                }
                await self?.sessionEnded(mac, generation: generation, error: nil)
            } catch {
                await self?.sessionEnded(mac, generation: generation, error: error)
            }
        }
        sessions[mac] = Session(connection: connection, reader: reader, generation: generation)
        if devices[mac]?.paired != nil { emit(.connectionChanged(connected: true, detail: "magichome \(mac)")) }
        return connection
    }

    private func received(_ chunk: Data, from mac: String, generation: Int) {
        guard var session = sessions[mac], session.generation == generation else { return }
        let responses = session.framer.push(chunk)
        sessions[mac] = session
        for response in responses { handle(response, from: mac) }
    }

    private func handle(_ response: MagicHomeResponse, from mac: String) {
        guard devices[mac] != nil else { return }
        let before = light(for: mac)
        switch response {
        case .state(let raw):
            devices[mac]?.raw = raw
            devices[mac]?.lastSeen = Date()
            if let list = waiters.removeValue(forKey: mac) {
                for w in list {
                    w.timer.cancel()
                    w.continuation.resume(returning: raw)
                }
            }
        case .power(let on):
            guard var raw = devices[mac]?.raw else { return }
            raw.power = on ? MagicHomeRawState.onByte : MagicHomeRawState.offByte
            devices[mac]?.raw = raw
            devices[mac]?.lastSeen = Date()
        case .other(let data):
            log.debug("ignored \(data.count)-byte message from \(mac)")
            return
        }
        markReachable(mac, true, emit: true)
        guard devices[mac]?.paired != nil, let after = light(for: mac) else { return }
        if let before, before.capabilities != after.capabilities || before.model != after.model {
            emit(.lightUpdated(after))
        } else if before.map({ !Self.sameState($0.state, after.state) }) ?? true {
            emit(.stateChanged(after.id, after.state))
        }
    }

    private func sessionEnded(_ mac: String, generation: Int, error: (any Error)?) {
        guard let s = sessions[mac], s.generation == generation else { return }
        dropSession(mac, error: error ?? LightCoreError.transport("connection closed by the device"))
    }

    private func dropSession(_ mac: String, error: any Error) {
        if let s = sessions.removeValue(forKey: mac) {
            s.reader.cancel()
            s.connection.close()
            if devices[mac]?.paired != nil { emit(.connectionChanged(connected: false, detail: "magichome \(mac)")) }
        }
        if let list = waiters.removeValue(forKey: mac) {
            for w in list {
                w.timer.cancel()
                w.continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func noteEndpoint(_ mac: String, host: String, hardware: String?) {
        if devices[mac] == nil {
            devices[mac] = Device(mac: mac, host: host, hardware: hardware)
        } else {
            if devices[mac]?.host != host {
                log.info("Magic Home \(mac) moved to \(host)")
                dropSession(mac, error: LightCoreError.transport("device moved"))
                devices[mac]?.host = host
                if var p = devices[mac]?.paired { p.hostHint = host; devices[mac]?.paired = p }
            }
            if let hardware { devices[mac]?.hardware = hardware }
        }
        devices[mac]?.lastSeen = Date()
    }

    private func markReachable(_ mac: String, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[mac], d.reachable != reachable else { return }
        devices[mac]?.reachable = reachable
        if shouldEmit, d.paired != nil { emit(.reachabilityChanged(MagicHomeMapping.lightID(mac: mac), reachable: reachable)) }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    private static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    private static func defaultName(profile: MagicHomeProfile?, mac: String) -> String {
        "\(profile?.model.name ?? "Magic Home") \(mac.suffix(4).uppercased())"
    }

    private static func metadata(profile: MagicHomeProfile?, hardware: String?) -> [String: String] {
        var m: [String: String] = [:]
        if let hardware { m["hardware"] = hardware }
        if let profile {
            m["modelNumber"] = String(format: "0x%02X", profile.model.number)
            m["version"] = String(profile.version)
            m["protocol"] = profile.protocol?.rawValue ?? "unsupported"
            m["layout"] = profile.layout.rawValue
        }
        return m
    }

    /// `"192.168.1.20"` (a port suffix is ignored: control is always TCP 5577).
    static func parseHost(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.split(separator: ":", maxSplits: 1).first ?? Substring(trimmed))
    }
}

/// Thread-safe "first time seen" set for discovery de-duplication.
private actor SeenSet {
    private var ids: Set<String> = []
    func insert(_ id: String) -> Bool { ids.insert(id).inserted }
}
