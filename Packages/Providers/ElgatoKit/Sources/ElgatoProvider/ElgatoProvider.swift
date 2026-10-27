import ElgatoCodec
import Foundation
import LightCore
import NetKit

/// Elgato Key Light / Key Light Air / Mini / Ring Light / Light Strip over the local HTTP API
/// (port 9123, no authentication).
///
/// - Devices are keyed by serial number (`elgato:<serial>`); host and port are cached hints,
///   refreshed by discovery.
/// - Requests are serialised per light with a short gap (`minRequestInterval`), carry
///   `Connection: close` and are retried `retries` (1) times on a transport error: the firmware
///   resets reused connections and does not like being hammered.
/// - Discovery: Bonjour `_elg._tcp` plus cached and manual hosts (there is no broadcast protocol).
/// - No push protocol: `start()` polls every paired light every `pollInterval` (10 s).
public actor ElgatoProvider: LightProvider {
    public static let brand: Brand = .elgato
    public static let bonjourType = "_elg._tcp"
    public static let defaultPort: UInt16 = ElgatoAPI.defaultPort

    public struct Configuration: Sendable {
        /// Port for hosts given without one.
        public var port: UInt16
        /// Per-attempt HTTP timeout.
        public var requestTimeout: Duration
        /// Extra attempts after a transport error or timeout.
        public var retries: Int
        /// Polling period while `start()`ed.
        public var pollInterval: Duration
        /// Pause between two requests to the same light.
        public var minRequestInterval: Duration

        public init(
            port: UInt16 = ElgatoProvider.defaultPort,
            requestTimeout: Duration = .seconds(5),
            retries: Int = 1,
            pollInterval: Duration = .seconds(10),
            minRequestInterval: Duration = .milliseconds(100)
        ) {
            self.port = port
            self.requestTimeout = requestTimeout
            self.retries = retries
            self.pollInterval = pollInterval
            self.minRequestInterval = minRequestInterval
        }
    }

    struct Device {
        var serial: String
        var host: String
        var port: UInt16
        var info: ElgatoAccessoryInfo?
        var settings: ElgatoSettings?
        var light: ElgatoLightState?
        var macAddress: String?
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?

        var supportsColor: Bool {
            ElgatoMapping.supportsColor(info: info, settings: settings, state: light) || paired?.metadata["color"] == "1"
        }
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: ElgatoNetworkEnvironment
    private let log = Log(package: "elgatokit", category: "provider")

    private var devices: [String: Device] = [:]
    private var pollTask: Task<Void, Never>?
    /// Tail of the request chain per `host:port` (one request at a time per light).
    private var gates: [String: Task<Void, Never>] = [:]

    public init(configuration: Configuration = Configuration(), environment: ElgatoNetworkEnvironment) {
        self.configuration = configuration
        self.environment = environment
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    /// Elgato needs no account.
    public var account: ProviderAccount? { nil }

    // MARK: - Lifecycle

    /// Starts polling paired lights every `configuration.pollInterval`. Idempotent.
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
        for p in paired where p.brand == .elgato {
            guard let host = p.hostHint, !host.isEmpty else { continue }
            let serial = ElgatoMapping.stableID(serial: p.id)
            var d = devices[serial] ?? Device(serial: serial, host: host, port: UInt16(clamping: p.port ?? Int(configuration.port)))
            d.host = host
            if let port = p.port { d.port = UInt16(clamping: port) }
            d.macAddress = d.macAddress ?? p.metadata["mac"]
            d.paired = p
            devices[serial] = d
        }
    }

    /// Serial numbers of paired devices (diagnostics/tests).
    public var pairedSerials: [String] { devices.values.filter { $0.paired != nil }.map(\.serial).sorted() }

    /// Cached `host:port` for a light (diagnostics/tests).
    public func endpoint(of id: LightID) -> String? {
        guard let d = device(for: id) else { return nil }
        return "\(d.host):\(d.port)"
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

    /// Reads accessory info (identity), settings and state from a host.
    private func identify(host: String, port: UInt16, method: DiscoveryMethod, bonjour: ElgatoBonjourHit?, retries: Int? = 0) async -> DiscoveredDevice? {
        guard let info = try? await fetchInfo(host: host, port: port, retries: retries) else { return nil }
        let serial = ElgatoMapping.stableID(serial: info.serialNumber)
        guard !serial.isEmpty else { return nil }
        noteEndpoint(serial, host: host, port: port)
        devices[serial]?.info = info
        if let mac = info.macAddress ?? bonjour?.macAddress { devices[serial]?.macAddress = mac }
        if let settings = try? await fetchSettings(host: host, port: port, retries: retries) { devices[serial]?.settings = settings }
        if let light = try? await fetchLight(host: host, port: port, retries: retries) { devices[serial]?.light = light }
        guard let d = devices[serial] else { return nil }
        return DiscoveredDevice(
            id: serial,
            brand: .elgato,
            name: info.name,
            model: info.productName,
            host: host,
            port: Int(port),
            macAddress: d.macAddress,
            method: method,
            metadata: metadata(of: d)
        )
    }

    private func metadata(of d: Device) -> [String: String] {
        var m: [String: String] = ["color": d.supportsColor ? "1" : "0"]
        if let info = d.info {
            m["product"] = info.productName
            if let fw = info.firmwareVersion { m["firmware"] = fw }
            if let build = info.firmwareBuildNumber { m["firmwareBuild"] = String(build) }
            if let board = info.hardwareBoardType { m["boardType"] = String(board) }
        }
        if let mac = d.macAddress { m["mac"] = mac }
        return m
    }

    // MARK: - LightProvider: pairing

    /// Elgato needs no credentials: pairing confirms the light answers and records it.
    /// Devices without a host (manual add) ask for an IP address.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .elgato else { throw LightCoreError.unsupported("\(device.name) is not an Elgato light") }
        var hostSpec = device.host
        if hostSpec == nil || hostSpec?.isEmpty == true {
            hostSpec = try await ui.text("IP address of the Elgato light (Elgato Control Center > light settings)")
        }
        guard let spec = hostSpec, let (host, specPort) = Self.parseHost(spec, defaultPort: configuration.port) else {
            throw LightCoreError.unreachable("no address for \(device.name)")
        }
        let port = device.port.map { UInt16(clamping: $0) } ?? specPort
        await ui.status("Contacting \(host)...")
        guard let found = await identify(host: host, port: port, method: .manual, bonjour: nil, retries: nil),
              var d = devices[found.id] else {
            throw LightCoreError.unreachable("No Elgato light answered at \(host):\(port)")
        }
        if d.light == nil { d.light = try? await fetchLight(host: host, port: port) }
        let paired = PairedDevice(
            id: d.serial,
            brand: .elgato,
            name: d.info?.name ?? device.name,
            model: d.info?.productName,
            hostHint: host,
            port: Int(port),
            lightIDs: ElgatoMapping.lightID(serial: d.serial).map { [$0] } ?? [],
            metadata: metadata(of: d),
            lastSeen: d.lastSeen
        )
        d.paired = paired
        devices[d.serial] = d
        if let light = light(for: d.serial) { emit(.lightAdded(light)) }
        return paired
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        let serials = pairedSerials
        await withTaskGroup(of: Void.self) { group in
            for serial in serials {
                group.addTask { await self.refresh(serial, emitChanges: false) }
            }
        }
        return serials.compactMap(light(for:))
    }

    /// One polling round over every paired light; emits changes.
    public func pollOnce() async {
        let serials = pairedSerials
        await withTaskGroup(of: Void.self) { group in
            for serial in serials {
                group.addTask { await self.refresh(serial, emitChanges: true) }
            }
        }
    }

    private func refresh(_ serial: String, emitChanges: Bool) async {
        guard let d = devices[serial] else { return }
        let old = light(for: serial)
        do {
            if d.info == nil, let info = try? await fetchInfo(host: d.host, port: d.port) { devices[serial]?.info = info }
            let state = try await fetchLight(host: d.host, port: d.port)
            devices[serial]?.light = state
            devices[serial]?.lastSeen = Date()
            markReachable(serial, true, emit: emitChanges)
        } catch {
            log.debug("poll \(serial) failed: \(error)")
            markReachable(serial, false, emit: emitChanges)
            return
        }
        guard emitChanges, let new = light(for: serial), let old else { return }
        if old.name != new.name {
            emit(.lightUpdated(new))
        } else if !Self.sameState(old.state, new.state) {
            emit(.stateChanged(new.id, new.state))
        }
    }

    private func light(for serial: String) -> Light? {
        guard let d = devices[serial], let id = ElgatoMapping.lightID(serial: serial) else { return nil }
        var state: LightState
        if let l = d.light {
            state = ElgatoMapping.state(from: l, supportsColor: d.supportsColor, at: d.lastSeen ?? Date())
        } else {
            state = LightState(reachable: false)
        }
        state.reachable = d.reachable && d.light != nil
        return Light(
            id: id,
            name: d.info?.name ?? d.paired?.name ?? "Elgato \(serial.suffix(6))",
            capabilities: ElgatoMapping.capabilities(supportsColor: d.supportsColor),
            state: state,
            providerRef: "\(Self.hostSpec(d.host)):\(d.port)",
            manufacturer: "Elgato",
            model: d.info?.productName ?? d.paired?.model
        )
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to id: LightID) async throws {
        guard let serial = devices[ElgatoMapping.stableID(serial: id.stableId)]?.serial, id.brand == .elgato else {
            throw LightCoreError.lightNotFound(id)
        }
        if command.isEmpty { return }
        do {
            if devices[serial]?.light == nil, let d = devices[serial] {
                devices[serial]?.light = try await fetchLight(host: d.host, port: d.port)
            }
            guard let d = devices[serial] else { throw LightCoreError.lightNotFound(id) }
            guard let change = ElgatoMapping.plan(command, current: d.light, supportsColor: d.supportsColor) else { return }
            let body = ElgatoMapping.putDocument(change).encoded()
            let data = try await perform(.put, ElgatoAPI.lights, host: d.host, port: d.port, body: body)
            let merged = (d.light ?? ElgatoLightState()).merging(change)
            // The light answers with its new state; fall back to the merged request if it does not parse.
            devices[serial]?.light = (try? ElgatoLightsDocument.decode(data))?.lights.first ?? merged
            devices[serial]?.lastSeen = Date()
            markReachable(serial, true, emit: true)
            if let light = light(for: serial) { emit(.stateChanged(light.id, light.state)) }
        } catch let error as LightCoreError {
            switch error {
            case .timeout, .transport:
                markReachable(serial, false, emit: true)
                throw LightCoreError.unreachable("Elgato light \(devices[serial]?.info?.name ?? serial) did not answer")
            default:
                throw error
            }
        }
    }

    /// Concurrent fan-out (each light has its own request chain).
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

    /// Makes the light blink (onboarding "Verify" step).
    public func identify(_ id: LightID) async throws {
        guard let d = device(for: id) else { throw LightCoreError.lightNotFound(id) }
        _ = try await perform(.post, ElgatoAPI.identify, host: d.host, port: d.port, body: Data())
    }

    // MARK: - HTTP

    private func fetchInfo(host: String, port: UInt16, retries: Int? = nil) async throws -> ElgatoAccessoryInfo {
        let data = try await perform(.get, ElgatoAPI.accessoryInfo, host: host, port: port, retries: retries)
        do { return try ElgatoAccessoryInfo.decode(data) } catch {
            throw LightCoreError.protocolError("Elgato accessory-info: \(error)")
        }
    }

    private func fetchSettings(host: String, port: UInt16, retries: Int? = nil) async throws -> ElgatoSettings {
        let data = try await perform(.get, ElgatoAPI.settings, host: host, port: port, retries: retries)
        do { return try ElgatoSettings.decode(data) } catch {
            throw LightCoreError.protocolError("Elgato settings: \(error)")
        }
    }

    private func fetchLight(host: String, port: UInt16, retries: Int? = nil) async throws -> ElgatoLightState {
        let data = try await perform(.get, ElgatoAPI.lights, host: host, port: port, retries: retries)
        guard let light = (try? ElgatoLightsDocument.decode(data))?.lights.first else {
            throw LightCoreError.protocolError("Elgato lights: no light in response")
        }
        return light
    }

    /// One request with retries on transport errors/timeouts; non-2xx statuses throw
    /// `.unsupported` (404) or `.protocolError`.
    private func perform(_ method: HTTPMethod, _ path: String, host: String, port: UInt16, body: Data? = nil, retries: Int? = nil) async throws -> Data {
        let request = ElgatoHTTPRequest(method: method, host: host, port: port, path: path, body: body, timeout: configuration.requestTimeout)
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
    /// `minRequestInterval` so a light never sees two requests back to back.
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
        guard id.brand == .elgato else { return nil }
        return devices[ElgatoMapping.stableID(serial: id.stableId)]
    }

    private func noteEndpoint(_ serial: String, host: String, port: UInt16) {
        if devices[serial] == nil {
            devices[serial] = Device(serial: serial, host: host, port: port)
        } else {
            if devices[serial]?.host != host { log.info("Elgato \(serial) at \(host):\(port)") }
            devices[serial]?.host = host
            devices[serial]?.port = port
            if var p = devices[serial]?.paired {
                p.hostHint = host
                p.port = Int(port)
                devices[serial]?.paired = p
            }
        }
        devices[serial]?.lastSeen = Date()
    }

    private func markReachable(_ serial: String, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[serial], d.reachable != reachable else { return }
        devices[serial]?.reachable = reachable
        if shouldEmit, d.paired != nil, let id = ElgatoMapping.lightID(serial: serial) {
            emit(.reachabilityChanged(id, reachable: reachable))
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

    /// `"192.168.1.20"`, `"192.168.1.20:9123"`, `"elgato-key-light.local"`, `"[fe80::1]:9123"`
    /// or a bare IPv6 literal -> host + port.
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
