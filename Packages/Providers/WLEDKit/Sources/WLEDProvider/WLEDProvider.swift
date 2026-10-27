import Foundation
import LightCore
import NetKit
import WLEDCodec

/// WLED controllers (DIY ESP8266/ESP32 LED strips) over the JSON HTTP API (port 80, no
/// authentication). Each controller is one light driven through segment 0.
///
/// - Devices are keyed by their mDNS name (`wled:wled-kitchen`), with the MAC from `/json/info`
///   recorded alongside: a controller that is renamed later is recognised by its MAC and keeps
///   its original id. Host and port are cached hints, refreshed by discovery.
/// - Requests are serialised per controller with a short gap (`minRequestInterval`) and retried
///   `retries` (1) times on a transport error (ESP8266 builds have few connection slots).
/// - Discovery: Bonjour `_wled._tcp` plus cached and manual hosts.
/// - Effects come from `/json/effects` (the index is the id) and are exposed as `EffectDescriptor`s.
/// - No push over HTTP: `start()` polls every paired controller every `pollInterval` (10 s).
public actor WLEDProvider: LightProvider {
    public static let brand: Brand = .wled
    public static let bonjourType = "_wled._tcp"
    public static let defaultPort: UInt16 = WLEDAPI.defaultPort

    public struct Configuration: Sendable {
        /// Port for hosts given without one.
        public var port: UInt16
        /// Per-attempt HTTP timeout.
        public var requestTimeout: Duration
        /// Extra attempts after a transport error or timeout.
        public var retries: Int
        /// Polling period while `start()`ed.
        public var pollInterval: Duration
        /// Pause between two requests to the same controller.
        public var minRequestInterval: Duration

        public init(
            port: UInt16 = WLEDProvider.defaultPort,
            requestTimeout: Duration = .seconds(5),
            retries: Int = 1,
            pollInterval: Duration = .seconds(10),
            minRequestInterval: Duration = .milliseconds(50)
        ) {
            self.port = port
            self.requestTimeout = requestTimeout
            self.retries = retries
            self.pollInterval = pollInterval
            self.minRequestInterval = minRequestInterval
        }
    }

    struct Device {
        /// Stable id (the mDNS name when first paired).
        var id: String
        var host: String
        var port: UInt16
        /// Current mDNS name (may differ from `id` after a rename).
        var mdns: String?
        /// 12 lower-case hex digits.
        var mac: String?
        var info: WLEDInfo?
        var effects: [EffectDescriptor] = []
        var state: WLEDState?
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?

        /// `info`, or the LED capability bits persisted in the paired metadata.
        var ledInfo: WLEDInfo? {
            if let info { return info }
            guard let p = paired else { return nil }
            let lc = p.metadata["lc"].flatMap { Int($0) }
            let rgbw = p.metadata["rgbw"].map { $0 == "1" }
            return lc == nil && rgbw == nil ? nil : WLEDInfo(leds: WLEDInfo.LEDs(rgbw: rgbw, lc: lc))
        }

        var capabilities: LightCapabilities { WLEDMapping.capabilities(info: ledInfo, effects: effects) }
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: WLEDNetworkEnvironment
    private let log = Log(package: "wledkit", category: "provider")

    private var devices: [String: Device] = [:]
    private var pollTask: Task<Void, Never>?
    /// Tail of the request chain per `host:port` (one request at a time per controller).
    private var gates: [String: Task<Void, Never>] = [:]

    public init(configuration: Configuration = Configuration(), environment: WLEDNetworkEnvironment) {
        self.configuration = configuration
        self.environment = environment
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    /// WLED needs no account.
    public var account: ProviderAccount? { nil }

    // MARK: - Lifecycle

    /// Starts polling paired controllers every `configuration.pollInterval`. Idempotent.
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

    /// Stops polling (e.g. when the app goes to the background).
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-registers devices persisted by the app (`DeviceStore`) without touching the network.
    public func restore(_ paired: [PairedDevice]) {
        for p in paired where p.brand == .wled {
            guard let host = p.hostHint, !host.isEmpty, let id = WLEDMapping.stableID(mdns: p.id) else { continue }
            var d = devices[id] ?? Device(id: id, host: host, port: UInt16(clamping: p.port ?? Int(configuration.port)))
            d.host = host
            if let port = p.port { d.port = UInt16(clamping: port) }
            d.mdns = d.mdns ?? p.metadata["mdns"] ?? id
            d.mac = d.mac ?? p.metadata["mac"].flatMap(WLEDMapping.normalizedMAC)
            d.paired = p
            devices[id] = d
        }
    }

    /// Stable ids of paired controllers (diagnostics/tests).
    public var pairedIDs: [String] { devices.values.filter { $0.paired != nil }.map(\.id).sorted() }

    /// Cached `host:port` for a light (diagnostics/tests).
    public func endpoint(of id: LightID) -> String? {
        guard let d = device(for: id) else { return nil }
        return "\(Self.hostSpec(d.host)):\(d.port)"
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
        let defaultPort = configuration.port
        let methods = options.methods
        let report: @Sendable (DiscoveredDevice?) async -> Void = { device in
            guard let device, await seen.insert(device.id) else { return }
            continuation.yield(device)
        }

        let browse = methods.contains(.bonjour) ? environment.browseBonjour : nil
        var specs: [(String, DiscoveryMethod)] = []
        if methods.contains(.cached) {
            specs += options.cachedHosts.map { ($0, .cached) }
            specs += devices.values.map { ("\(Self.hostSpec($0.host)):\($0.port)", .cached) }
        }
        if methods.contains(.manual) { specs += options.manualHosts.map { ($0, .manual) } }
        let direct = specs.compactMap { spec, method in
            Self.parseHost(spec, defaultPort: defaultPort).map { ($0.0, $0.1, method) }
        }

        await withTaskGroup(of: Void.self) { group in
            if let browse {
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        for await hit in browse() {
                            guard let host = hit.host, !host.isEmpty else { continue }
                            let port = hit.port ?? defaultPort
                            inner.addTask { await report(await self.identify(host: host, port: port, method: .bonjour, bonjour: hit)) }
                        }
                    }
                }
            }
            for (host, port, method) in direct {
                group.addTask { await report(await self.identify(host: host, port: port, method: method, bonjour: nil)) }
            }
        }
    }

    /// Reads `/json/info`, works out the mDNS name (Bonjour instance name, else `/json/cfg`
    /// `id.mdns`, else WLED's default `wled-<mac suffix>`), then effects and state.
    private func identify(host: String, port: UInt16, method: DiscoveryMethod, bonjour: WLEDBonjourHit?, retries: Int? = 0) async -> DiscoveredDevice? {
        guard let info = try? await fetchInfo(host: host, port: port, retries: retries) else { return nil }
        let mac = (info.mac ?? bonjour?.macAddress).flatMap(WLEDMapping.normalizedMAC)
        var mdns = bonjour.flatMap { WLEDMapping.stableID(mdns: $0.name) }
        if mdns == nil, let cfg = try? await fetchConfig(host: host, port: port, retries: retries) {
            mdns = cfg.id?.mdns.flatMap(WLEDMapping.stableID(mdns:))
        }
        if mdns == nil { mdns = mac.flatMap(WLEDMapping.defaultMDNSName(mac:)) }
        guard let mdns else {
            log.notice("WLED at \(host) reports neither an mDNS name nor a MAC; skipped")
            return nil
        }
        // A controller renamed since pairing keeps its id: match by MAC first.
        let id = devices.values.first { mac != nil && $0.mac == mac }?.id ?? mdns
        noteEndpoint(id, host: host, port: port)
        devices[id]?.info = info
        devices[id]?.mdns = mdns
        if let mac { devices[id]?.mac = mac }
        if devices[id]?.effects.isEmpty ?? true, let fx = try? await fetchEffects(host: host, port: port, retries: retries) {
            devices[id]?.effects = fx
        }
        if let state = try? await fetchState(host: host, port: port, retries: retries) { devices[id]?.state = state }
        guard let d = devices[id] else { return nil }
        return DiscoveredDevice(
            id: id,
            brand: .wled,
            name: Self.displayName(info: info, mdns: mdns),
            model: Self.model(info),
            host: host,
            port: Int(port),
            macAddress: mac.flatMap(WLEDMapping.formattedMAC),
            method: method,
            metadata: metadata(of: d)
        )
    }

    private func metadata(of d: Device) -> [String: String] {
        var m: [String: String] = [:]
        if let mdns = d.mdns { m["mdns"] = mdns }
        if let mac = d.mac { m["mac"] = mac }
        if let info = d.info {
            if let v = info.ver { m["version"] = v }
            if let a = info.arch { m["arch"] = a }
            if let n = info.leds?.count { m["leds"] = String(n) }
            if let lc = info.leds?.lc { m["lc"] = String(lc) }
            if let rgbw = info.leds?.rgbw { m["rgbw"] = rgbw ? "1" : "0" }
        }
        if !d.effects.isEmpty { m["effects"] = String(d.effects.count) }
        return m
    }

    private static func displayName(info: WLEDInfo?, mdns: String?) -> String {
        let name = info?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "WLED" is the factory default; the mDNS name is more telling then.
        if !name.isEmpty, name != "WLED" { return name }
        return mdns ?? (name.isEmpty ? "WLED" : name)
    }

    private static func model(_ info: WLEDInfo?) -> String {
        guard let arch = info?.arch, !arch.isEmpty else { return "WLED" }
        return "WLED (\(arch))"
    }

    // MARK: - LightProvider: pairing

    /// WLED needs no credentials: pairing confirms the controller answers and records it.
    /// Devices without a host (manual add) ask for an IP address or `.local` name.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .wled else { throw LightCoreError.unsupported("\(device.name) is not a WLED controller") }
        var hostSpec = device.host
        if hostSpec == nil || hostSpec?.isEmpty == true {
            hostSpec = try await ui.text("IP address or mDNS name of the WLED controller (e.g. 192.168.1.50 or wled-kitchen.local)")
        }
        guard let spec = hostSpec, let (host, specPort) = Self.parseHost(spec, defaultPort: configuration.port) else {
            throw LightCoreError.unreachable("no address for \(device.name)")
        }
        let port = device.port.map { UInt16(clamping: $0) } ?? specPort
        // Keep the Bonjour instance name the device was discovered with.
        let bonjour = device.metadata["mdns"].map { WLEDBonjourHit(name: $0, host: host, port: port, txt: [:]) }
        await ui.status("Contacting \(host)...")
        guard let found = await identify(host: host, port: port, method: .manual, bonjour: bonjour, retries: nil),
              var d = devices[found.id] else {
            throw LightCoreError.unreachable("No WLED controller answered at \(host):\(port)")
        }
        if d.state == nil { d.state = try? await fetchState(host: host, port: port) }
        let paired = PairedDevice(
            id: d.id,
            brand: .wled,
            name: found.name,
            model: found.model,
            hostHint: host,
            port: Int(port),
            lightIDs: WLEDMapping.lightID(mdns: d.id).map { [$0] } ?? [],
            metadata: metadata(of: d),
            lastSeen: d.lastSeen
        )
        d.paired = paired
        devices[d.id] = d
        if let light = light(for: d.id) { emit(.lightAdded(light)) }
        return paired
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        let ids = pairedIDs
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id, emitChanges: false) }
            }
        }
        return ids.compactMap(light(for:))
    }

    /// One polling round over every paired controller; emits changes.
    public func pollOnce() async {
        let ids = pairedIDs
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id, emitChanges: true) }
            }
        }
    }

    private func refresh(_ id: String, emitChanges: Bool) async {
        guard let d = devices[id] else { return }
        let old = light(for: id)
        do {
            if d.info == nil, let info = try? await fetchInfo(host: d.host, port: d.port) { devices[id]?.info = info }
            if d.effects.isEmpty, let fx = try? await fetchEffects(host: d.host, port: d.port) { devices[id]?.effects = fx }
            let state = try await fetchState(host: d.host, port: d.port)
            devices[id]?.state = state
            devices[id]?.lastSeen = Date()
            markReachable(id, true, emit: emitChanges)
        } catch {
            log.debug("poll \(id) failed: \(error)")
            markReachable(id, false, emit: emitChanges)
            return
        }
        guard emitChanges, let new = light(for: id), let old else { return }
        if old.name != new.name || old.capabilities != new.capabilities {
            emit(.lightUpdated(new))
        } else if !Self.sameState(old.state, new.state) {
            emit(.stateChanged(new.id, new.state))
        }
    }

    private func light(for id: String) -> Light? {
        guard let d = devices[id], let lightID = WLEDMapping.lightID(mdns: id) else { return nil }
        let caps = d.capabilities
        var state: LightState
        if let s = d.state {
            state = WLEDMapping.state(from: s, capabilities: caps, at: d.lastSeen ?? Date())
        } else {
            state = LightState(reachable: false)
        }
        state.reachable = d.reachable && d.state != nil
        return Light(
            id: lightID,
            name: d.info != nil ? Self.displayName(info: d.info, mdns: d.mdns) : (d.paired?.name ?? id),
            capabilities: caps,
            state: state,
            providerRef: "\(Self.hostSpec(d.host)):\(d.port)",
            manufacturer: d.info?.brand ?? "WLED",
            model: d.info.map(Self.model) ?? d.paired?.model
        )
    }

    /// Effects of a light (from `/json/effects`), fetched on first use.
    public func effects(of id: LightID) async throws -> [EffectDescriptor] {
        guard let d = device(for: id) else { throw LightCoreError.lightNotFound(id) }
        if !d.effects.isEmpty { return d.effects }
        let fx = try await fetchEffects(host: d.host, port: d.port)
        devices[d.id]?.effects = fx
        return fx
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to lightID: LightID) async throws {
        guard let id = device(for: lightID)?.id else { throw LightCoreError.lightNotFound(lightID) }
        if command.isEmpty { return }
        do {
            if let d = devices[id], d.state == nil {
                devices[id]?.state = try await fetchState(host: d.host, port: d.port)
            }
            if command.effect != nil, let d = devices[id], d.effects.isEmpty {
                devices[id]?.effects = (try? await fetchEffects(host: d.host, port: d.port)) ?? []
            }
            guard let d = devices[id] else { throw LightCoreError.lightNotFound(lightID) }
            guard let update = WLEDMapping.plan(command, current: d.state, capabilities: d.capabilities) else { return }
            let data = try await perform(.post, WLEDAPI.state, host: d.host, port: d.port, body: update.encoded())
            let merged = (d.state ?? WLEDState()).merging(update)
            // With `v: true` WLED answers with the new state; older builds answer {"success":true}.
            if let echoed = try? WLEDState.decode(data), echoed.on != nil {
                devices[id]?.state = echoed
            } else {
                devices[id]?.state = merged
            }
            devices[id]?.lastSeen = Date()
            markReachable(id, true, emit: true)
            if let light = light(for: id) { emit(.stateChanged(light.id, light.state)) }
        } catch let error as LightCoreError {
            switch error {
            case .timeout, .transport:
                markReachable(id, false, emit: true)
                throw LightCoreError.unreachable("WLED \(devices[id]?.mdns ?? id) did not answer")
            default:
                throw error
            }
        }
    }

    /// Concurrent fan-out (each controller has its own request chain).
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

    // MARK: - HTTP

    private func fetchInfo(host: String, port: UInt16, retries: Int? = nil) async throws -> WLEDInfo {
        let data = try await perform(.get, WLEDAPI.info, host: host, port: port, retries: retries)
        do { return try WLEDInfo.decode(data) } catch {
            throw LightCoreError.protocolError("WLED info: \(error)")
        }
    }

    private func fetchConfig(host: String, port: UInt16, retries: Int? = nil) async throws -> WLEDConfig {
        let data = try await perform(.get, WLEDAPI.config, host: host, port: port, retries: retries)
        do { return try WLEDConfig.decode(data) } catch {
            throw LightCoreError.protocolError("WLED cfg: \(error)")
        }
    }

    private func fetchEffects(host: String, port: UInt16, retries: Int? = nil) async throws -> [EffectDescriptor] {
        let data = try await perform(.get, WLEDAPI.effects, host: host, port: port, retries: retries)
        do { return try WLEDMapping.decodeEffects(data) } catch {
            throw LightCoreError.protocolError("WLED effects: \(error)")
        }
    }

    private func fetchState(host: String, port: UInt16, retries: Int? = nil) async throws -> WLEDState {
        let data = try await perform(.get, WLEDAPI.state, host: host, port: port, retries: retries)
        do { return try WLEDState.decode(data) } catch {
            throw LightCoreError.protocolError("WLED state: \(error)")
        }
    }

    /// One request with retries on transport errors/timeouts; non-2xx statuses throw
    /// `.unsupported` (404) or `.protocolError`.
    private func perform(_ method: HTTPMethod, _ path: String, host: String, port: UInt16, body: Data? = nil, retries: Int? = nil) async throws -> Data {
        let request = WLEDHTTPRequest(method: method, host: host, port: port, path: path, body: body, timeout: configuration.requestTimeout)
        let attempts = 1 + max(0, retries ?? configuration.retries)
        let http = environment.http
        var lastError: LightCoreError = .timeout
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let response = try await exclusive("\(host):\(port)") { try await http.send(request) }
                if let error = HTTPError.check(status: response.status, body: response.body) {
                    if case .notFound = error { throw LightCoreError.unsupported("\(path) not found on \(host)") }
                    throw LightCoreError.protocolError("\(method.rawValue) \(path) -> HTTP \(response.status)")
                }
                return response.body
            } catch let error as LightCoreError {
                switch error {
                case .timeout, .transport:
                    log.debug("\(method.rawValue) \(path) -> \(host):\(port) attempt \(attempt)/\(attempts): \(error)")
                    lastError = error
                    continue
                default:
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Runs `operation` after every earlier request to `key` finished, then holds the slot for
    /// `minRequestInterval`.
    private func exclusive<T: Sendable>(_ key: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = gates[key]
        let gap = configuration.minRequestInterval
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        gates[key] = Task {
            _ = try? await task.value
            try? await Task.sleep(for: gap)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Helpers

    private func device(for id: LightID) -> Device? {
        guard id.brand == .wled, let key = WLEDMapping.stableID(mdns: id.stableId) else { return nil }
        return devices[key]
    }

    private func noteEndpoint(_ id: String, host: String, port: UInt16) {
        if devices[id] == nil {
            devices[id] = Device(id: id, host: host, port: port)
        } else {
            if devices[id]?.host != host { log.info("WLED \(id) at \(host):\(port)") }
            devices[id]?.host = host
            devices[id]?.port = port
            if var p = devices[id]?.paired {
                p.hostHint = host
                p.port = Int(port)
                devices[id]?.paired = p
            }
        }
        devices[id]?.lastSeen = Date()
    }

    private func markReachable(_ id: String, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[id], d.reachable != reachable else { return }
        devices[id]?.reachable = reachable
        if shouldEmit, d.paired != nil, let lightID = WLEDMapping.lightID(mdns: id) {
            emit(.reachabilityChanged(lightID, reachable: reachable))
        }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    private static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    /// Host as written in a `host:port` spec (IPv6 literals bracketed).
    static func hostSpec(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// `"192.168.1.50"`, `"192.168.1.50:8080"`, `"wled-kitchen.local"`, `"[fe80::1]:80"` or a bare
    /// IPv6 literal -> host + port.
    static func parseHost(_ spec: String, defaultPort: UInt16) -> (String, UInt16)? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return host.isEmpty ? nil : (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), !host.isEmpty else { return nil }
            return (host, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return (trimmed, defaultPort) }
        if parts.count == 2 {
            guard let port = UInt16(parts[1]), !parts[0].isEmpty else { return nil }
            return (String(parts[0]), port)
        }
        return (trimmed, defaultPort)   // bare IPv6 literal
    }
}

/// Thread-safe "first time seen" set for discovery de-duplication.
private actor SeenSet {
    private var ids: Set<String> = []
    func insert(_ id: String) -> Bool { ids.insert(id).inserted }
}
