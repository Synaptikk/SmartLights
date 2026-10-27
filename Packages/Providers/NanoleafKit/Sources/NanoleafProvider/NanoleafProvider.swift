import Foundation
import LightCore
import NanoleafCodec
import NetKit
import Synchronization

/// Supplies Bonjour `_nanoleafapi._tcp` services for `timeout`, then finishes.
public typealias NanoleafServiceBrowser = @Sendable (Duration) -> AsyncStream<NanoleafServiceRecord>

/// Thread-safe "seen ids" set for de-duplicating discovery results.
private final class SeenIDs: Sendable {
    private let ids = Mutex<Set<String>>([])

    func insert(_ id: String) -> Bool { ids.withLock { $0.insert(id).inserted } }
}

/// A touch gesture from a Canvas/Shapes/Elements/Lines controller (SSE event class 4).
public struct NanoleafTouchEvent: Sendable, Hashable {
    public var light: LightID
    public var touch: NanoleafTouch

    public init(light: LightID, touch: NanoleafTouch) {
        self.light = light
        self.touch = touch
    }
}

/// Nanoleaf Wi-Fi controllers (Light Panels, Canvas, Shapes, Elements, Lines) over the local Open API
/// (HTTP on port 16021). One `Light` per controller; stored effects are exposed both as light effects
/// and as vendor scenes.
///
/// - Discovery: Bonjour `_nanoleafapi._tcp` (Apple platforms), manual and cached hosts (IPv4 or host
///   name; IPv6 is not used, see `NanoleafMapper.isUsableHost`).
/// - Pairing: the user holds the power button 5-7 s, then `POST /api/v1/new` is retried for up to
///   30 s; the token goes to `SecretStore` (`SecretKey(brand: .nanoleaf, owner: <stable id>, item: "authToken")`).
/// - Events: while `start()`ed, one SSE connection per controller (`/events?id=1,2,3,4`) with
///   reconnect + backoff and a full re-read after every (re)connect.
public actor NanoleafProvider: LightProvider {
    public static let brand: Brand = .nanoleaf

    /// Copy for the pairing confirm prompt (docs/ONBOARDING-WALKTHROUGHS.md §7).
    public static let pairingMessage =
        "Hold the power button on the controller for 5-7 seconds until the LEDs flash, then tap Continue"
    /// Shown when the pairing window ends without a token.
    public static let notInPairingModeMessage =
        "The Nanoleaf controller is not allowing new connections. Hold the power button for 5-7 seconds until the LEDs flash, then try again."
    public static let tokenItem = "authToken"

    public struct Configuration: Sendable {
        /// How long `POST /api/v1/new` is retried after the user confirmed (Nanoleaf: 30 s window).
        public var pairingWindow: Duration
        public var pairingRetryInterval: Duration
        public var requestTimeout: Duration
        /// Timeout for probing a manually entered host.
        public var probeTimeout: Duration
        /// Reconnect the SSE stream when nothing arrives for this long.
        public var eventIdleTimeout: Duration
        public var eventBackoff: ExponentialBackoff
        /// Send on/brightness/colour in one `PUT /state` (true) or one request per attribute.
        public var combineStateWrites: Bool
        public var eventTypes: Set<NanoleafEventType>

        public init(
            pairingWindow: Duration = .seconds(30),
            pairingRetryInterval: Duration = .seconds(1),
            requestTimeout: Duration = .seconds(5),
            probeTimeout: Duration = .seconds(2),
            eventIdleTimeout: Duration = .seconds(300),
            eventBackoff: ExponentialBackoff = ExponentialBackoff(
                initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2),
            combineStateWrites: Bool = true,
            eventTypes: Set<NanoleafEventType> = Set(NanoleafEventType.allCases)
        ) {
            self.pairingWindow = pairingWindow
            self.pairingRetryInterval = pairingRetryInterval
            self.requestTimeout = requestTimeout
            self.probeTimeout = probeTimeout
            self.eventIdleTimeout = eventIdleTimeout
            self.eventBackoff = eventBackoff
            self.combineStateWrites = combineStateWrites
            self.eventTypes = eventTypes
        }
    }

    /// One paired controller.
    struct DeviceRecord: Sendable {
        var stableID: String
        var name: String
        var model: String?
        var endpoint: NanoleafEndpoint
        var bonjourID: String?
        var info: NanoleafInfo?
        var reachable: Bool
        var pairedAt: Date
        var lastSeen: Date?
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    /// Touch gestures (single consumer).
    public nonisolated let touchEvents: AsyncStream<NanoleafTouchEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let touchContinuation: AsyncStream<NanoleafTouchEvent>.Continuation

    private let transport: any NanoleafTransport
    private let secrets: any SecretStore
    private let serviceBrowser: NanoleafServiceBrowser?
    public let configuration: Configuration
    private let log = Log(package: "nanoleafkit", category: "provider")

    private var devices: [String: DeviceRecord] = [:]
    private var streamTasks: [String: Task<Void, Never>] = [:]
    private var started = false

    /// - Parameters:
    ///   - transport: HTTP/SSE transport (default URLSession).
    ///   - secrets: `KeychainSecretStore` in the app.
    ///   - devices: previously paired controllers (from `DeviceStore`), see `restore(_:)`.
    ///   - serviceBrowser: Bonjour browser; defaults to `NanoleafBonjour` on Apple platforms, none on Linux.
    public init(
        transport: any NanoleafTransport = URLSessionNanoleafTransport(),
        secrets: any SecretStore,
        devices: [PairedDevice] = [],
        serviceBrowser: NanoleafServiceBrowser? = NanoleafProvider.defaultServiceBrowser,
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.secrets = secrets
        self.serviceBrowser = serviceBrowser
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
        (touchEvents, touchContinuation) = AsyncStream.makeStream(
            of: NanoleafTouchEvent.self, bufferingPolicy: .bufferingNewest(64))
        for device in devices {
            if let record = Self.record(from: device) { self.devices[record.stableID] = record }
        }
    }

    deinit {
        for task in streamTasks.values { task.cancel() }
        continuation.finish()
        touchContinuation.finish()
    }

    /// The Open API has no account; each controller has its own token.
    public var account: ProviderAccount? { nil }

    /// Default Bonjour browser for this platform.
    public static var defaultServiceBrowser: NanoleafServiceBrowser? {
        #if canImport(Network)
        return { timeout in NanoleafBonjour.browse(timeout: timeout) }
        #else
        return nil
        #endif
    }

    // MARK: - Persistence

    /// Adds previously paired controllers (call at launch with `DeviceStore` contents).
    public func restore(_ paired: [PairedDevice]) {
        for device in paired {
            guard let record = Self.record(from: device) else { continue }
            if devices[record.stableID] == nil {
                devices[record.stableID] = record
                if started { startStream(record.stableID) }
            }
        }
    }

    /// Current paired controllers, for persisting in `DeviceStore`.
    public var pairedDevices: [PairedDevice] {
        devices.values.sorted { $0.stableID < $1.stableID }.map(Self.pairedDevice(from:))
    }

    static func record(from device: PairedDevice) -> DeviceRecord? {
        guard device.brand == .nanoleaf, let host = device.hostHint, NanoleafMapper.isUsableHost(host) else {
            return nil
        }
        return DeviceRecord(
            stableID: device.id,
            name: device.name,
            model: device.model,
            endpoint: NanoleafEndpoint(host: host, port: device.port ?? NanoleafAPI.port),
            bonjourID: device.metadata["bonjourID"],
            info: nil,
            reachable: true,
            pairedAt: device.pairedAt,
            lastSeen: device.lastSeen
        )
    }

    static func pairedDevice(from record: DeviceRecord) -> PairedDevice {
        var metadata: [String: String] = [:]
        if let bonjourID = record.bonjourID { metadata["bonjourID"] = bonjourID }
        if let fw = record.info?.firmwareVersion { metadata["firmware"] = fw }
        if let count = record.info?.panelCount { metadata["panels"] = String(count) }
        return PairedDevice(
            id: record.stableID,
            brand: .nanoleaf,
            name: record.name,
            model: record.model,
            hostHint: record.endpoint.host,
            port: record.endpoint.port,
            lightIDs: NanoleafMapper.lightID(stableID: record.stableID).map { [$0] } ?? [],
            metadata: metadata,
            pairedAt: record.pairedAt,
            lastSeen: record.lastSeen
        )
    }

    static func secretKey(_ stableID: String) -> SecretKey {
        SecretKey(brand: .nanoleaf, owner: stableID, item: tokenItem)
    }

    // MARK: - Lifecycle

    /// Opens the SSE event stream of every paired controller. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        for id in devices.keys.sorted() { startStream(id) }
    }

    /// Closes all event streams.
    public func stop() {
        started = false
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
    }

    // MARK: - Discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        let task = Task { await self.runDiscovery(options: options, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(options: DiscoveryOptions, into output: AsyncStream<DiscoveredDevice>.Continuation) async {
        let seen = SeenIDs()
        let emit: @Sendable (DiscoveredDevice) -> Void = { device in
            if seen.insert(device.id) { output.yield(device) }
        }
        let browser = options.methods.contains(.bonjour) ? serviceBrowser : nil
        var probes: [(String, DiscoveryMethod)] = []
        if options.methods.contains(.manual) { probes += options.manualHosts.map { ($0, .manual) } }
        if options.methods.contains(.cached) { probes += options.cachedHosts.map { ($0, .cached) } }
        let knownByHost = Dictionary(devices.values.map { ($0.endpoint.host, $0) }, uniquingKeysWith: { a, _ in a })
            .mapValues { (stableID: $0.stableID, name: $0.name, model: $0.model) }

        // Child tasks return true for the timeout, false for finished work; discovery ends at the
        // timeout or when all work finished, whichever comes first.
        await withTaskGroup(of: Bool.self) { group in
            var pending = 0
            if let browser {
                pending += 1
                group.addTask {
                    for await record in browser(options.timeout) {
                        guard let device = NanoleafMapper.discoveredDevice(from: record) else { continue }
                        emit(await self.noteDiscovered(device))
                    }
                    return false
                }
            }
            for (input, method) in probes {
                pending += 1
                group.addTask {
                    guard let parsed = NanoleafMapper.parseManualHost(input) else {
                        await self.report("Ignoring host '\(input)': use an IPv4 address or host name")
                        return false
                    }
                    let endpoint = NanoleafEndpoint(host: parsed.host, port: parsed.port)
                    guard await self.probe(endpoint) else { return false }
                    let known = knownByHost[parsed.host]
                    emit(DiscoveredDevice(
                        id: known?.stableID ?? "ip:\(parsed.host)",
                        brand: .nanoleaf,
                        name: known?.name ?? "Nanoleaf (\(parsed.host))",
                        model: known?.model,
                        host: parsed.host,
                        port: parsed.port,
                        method: method
                    ))
                    return false
                }
            }
            guard pending > 0 else { return }
            group.addTask {
                try? await Task.sleep(for: options.timeout)
                return true
            }
            while let isTimeout = await group.next() {
                if isTimeout { break }
                pending -= 1
                if pending == 0 { break }
            }
            group.cancelAll()
        }
        output.finish()
    }

    /// Any HTTP answer on the Open API port counts (a controller answers 401 without a token).
    private func probe(_ endpoint: NanoleafEndpoint) async -> Bool {
        do {
            let response = try await transport.send(NanoleafAPI.probe(), to: endpoint, timeout: configuration.probeTimeout)
            return response.status > 0
        } catch {
            return false
        }
    }

    /// Refreshes the IP hint of a known controller seen via Bonjour; returns the device with the
    /// stable id when it is already paired.
    private func noteDiscovered(_ device: DiscoveredDevice) -> DiscoveredDevice {
        guard let bonjourID = device.metadata["id"], let host = device.host else { return device }
        guard let key = devices.values.first(where: { $0.bonjourID == bonjourID || $0.stableID == bonjourID })?.stableID,
              var record = devices[key] else { return device }
        let endpoint = NanoleafEndpoint(host: host, port: device.port ?? NanoleafAPI.port)
        if record.endpoint != endpoint {
            log.info("Nanoleaf \(key) moved to \(endpoint)")
            record.endpoint = endpoint
            devices[key] = record
            if started { restartStream(key) }
        }
        var out = device
        out.id = key
        return out
    }

    private func report(_ message: String) {
        log.notice(message)
        continuation.yield(.error(message))
    }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .nanoleaf else {
            throw LightCoreError.unsupported("\(device.name) is not a Nanoleaf controller")
        }
        guard let host = device.host, NanoleafMapper.isUsableHost(host) else {
            throw LightCoreError.unsupported("\(device.name) has no IPv4 address; enter it manually")
        }
        let endpoint = NanoleafEndpoint(host: host, port: device.port ?? NanoleafAPI.port)
        guard try await ui.confirm(Self.pairingMessage) else { throw LightCoreError.userCancelled }

        let token = try await requestToken(endpoint: endpoint, ui: ui)
        let info: NanoleafInfo
        do {
            let response = try await transport.send(
                try NanoleafAPI.info(token: token), to: endpoint, timeout: configuration.requestTimeout)
            guard response.isSuccess else {
                throw LightCoreError.protocolError("Nanoleaf info returned HTTP \(response.status)")
            }
            info = try NanoleafAPI.decodeInfo(response.body)
        } catch let error as NanoleafTransportError {
            throw Self.lightCoreError(error, endpoint: endpoint)
        } catch let error as NanoleafCodecError {
            throw LightCoreError.protocolError("Nanoleaf info: \(error)")
        }

        let bonjourID = device.metadata["id"]
        guard let stableID = NanoleafMapper.stableID(serialNo: info.serialNo, bonjourID: bonjourID) else {
            throw LightCoreError.protocolError("Nanoleaf controller reported no serial number")
        }
        try await secrets.set(token, for: Self.secretKey(stableID))

        let now = Date()
        let record = DeviceRecord(
            stableID: stableID,
            name: info.name ?? device.name,
            model: info.model ?? device.model,
            endpoint: endpoint,
            bonjourID: bonjourID,
            info: info,
            reachable: true,
            pairedAt: now,
            lastSeen: now
        )
        let existed = devices[stableID] != nil
        devices[stableID] = record
        log.info("Paired Nanoleaf \(stableID) (\(info.model ?? "?"), fw \(info.firmwareVersion ?? "?")) token \(Log.redact(token))")
        if let light = makeLight(record) {
            continuation.yield(existed ? .lightUpdated(light) : .lightAdded(light))
        }
        continuation.yield(.scenesChanged)
        if started { restartStream(stableID) }
        return Self.pairedDevice(from: record)
    }

    /// `POST /api/v1/new` until it returns a token or the pairing window ends.
    private func requestToken(endpoint: NanoleafEndpoint, ui: any PairingInteraction) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.pairingWindow)
        var attempts = 0
        var lastProblem = "not in pairing mode"
        while true {
            try Task.checkCancellation()
            attempts += 1
            do {
                let response = try await transport.send(
                    NanoleafAPI.addUser(), to: endpoint, timeout: configuration.requestTimeout)
                if response.isSuccess {
                    do {
                        return try NanoleafAPI.decodeAuthToken(response.body)
                    } catch {
                        throw LightCoreError.protocolError("Nanoleaf returned an unreadable token")
                    }
                }
                lastProblem = response.status == 403 || response.status == 401
                    ? "not in pairing mode" : "HTTP \(response.status)"
            } catch let error as NanoleafTransportError {
                lastProblem = "\(error)"
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > configuration.pairingRetryInterval else { break }
            let secondsLeft = Int(remaining.components.seconds)
            await ui.status("Waiting for the Nanoleaf controller (\(lastProblem))... \(secondsLeft) s")
            try await Task.sleep(for: configuration.pairingRetryInterval)
        }
        log.notice("Nanoleaf pairing at \(endpoint) failed after \(attempts) attempts: \(lastProblem)")
        await ui.status(Self.notInPairingModeMessage)
        throw LightCoreError.timeout
    }

    /// Revokes the token on the controller (best effort), deletes it from the secret store and forgets
    /// the controller.
    public func removeDevice(_ stableID: String) async throws {
        guard let record = devices[stableID] else { return }
        if let token = try? await secrets.string(for: Self.secretKey(stableID)),
           let request = try? NanoleafAPI.deleteUser(token: token) {
            _ = try? await transport.send(request, to: record.endpoint, timeout: configuration.requestTimeout)
        }
        try await secrets.remove(Self.secretKey(stableID))
        streamTasks.removeValue(forKey: stableID)?.cancel()
        devices[stableID] = nil
        if let id = NanoleafMapper.lightID(stableID: stableID) { continuation.yield(.lightRemoved(id)) }
        continuation.yield(.scenesChanged)
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        for id in devices.keys.sorted() {
            await refresh(id)
        }
        return devices.keys.sorted().compactMap { devices[$0].flatMap(makeLight) }
    }

    /// Re-reads full info; returns false when the controller could not be read.
    @discardableResult
    private func refresh(_ stableID: String) async -> Bool {
        do {
            let response = try await perform({ try NanoleafAPI.info(token: $0) }, stableID: stableID)
            let info = try NanoleafAPI.decodeInfo(response.body)
            guard var record = devices[stableID] else { return false }
            record.info = info
            if let name = info.name, !name.isEmpty { record.name = name }
            if let model = info.model { record.model = model }
            devices[stableID] = record
            return true
        } catch {
            log.notice("Nanoleaf \(stableID) refresh failed: \(error)")
            return false
        }
    }

    private func makeLight(_ record: DeviceRecord) -> Light? {
        NanoleafMapper.light(
            info: record.info,
            stableID: record.stableID,
            fallbackName: record.name,
            host: record.endpoint.host,
            port: record.endpoint.port,
            reachable: record.reachable,
            updatedAt: record.lastSeen ?? Date()
        )
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .nanoleaf, let record = devices[light.stableId] else {
            throw LightCoreError.lightNotFound(light)
        }
        let capabilities = NanoleafMapper.capabilities(for: record.info)
        let normalized = command.normalized(for: capabilities)
        let plan = NanoleafMapper.plan(
            for: normalized, capabilities: capabilities,
            brightnessRange: NanoleafMapper.brightnessRange(record.info?.state))
        guard !plan.isEmpty else { return }

        if let update = plan.stateUpdate, !update.isEmpty {
            let bodies = configuration.combineStateWrites ? [update] : update.split()
            for body in bodies {
                try await perform({ try NanoleafAPI.setState(token: $0, body) }, stableID: light.stableId)
            }
            applyLocally(light.stableId) { info in
                info.state = (info.state ?? NanoleafState()).applying(update)
            }
        }
        if let effect = plan.effect {
            try await perform({ try NanoleafAPI.selectEffect(token: $0, name: effect) }, stableID: light.stableId)
            applyLocally(light.stableId) { info in
                info.effects = NanoleafEffects(select: effect, effectsList: info.effects?.effectsList)
                info.state = (info.state ?? NanoleafState()).applying([.colorMode(NanoleafColorMode.effect.rawValue)])
            }
        }
    }

    /// Flashes the panels so the user can tell which controller this is.
    public func identify(_ light: LightID) async throws {
        guard light.brand == .nanoleaf, devices[light.stableId] != nil else { throw LightCoreError.lightNotFound(light) }
        try await perform({ try NanoleafAPI.identify(token: $0) }, stableID: light.stableId)
    }

    // MARK: - Scenes (effects)

    public func scenes() async throws -> [LightScene] {
        var out: [LightScene] = []
        for id in devices.keys.sorted() {
            if devices[id]?.info == nil { await refresh(id) }
            guard let record = devices[id] else { continue }
            out += NanoleafMapper.scenes(info: record.info, stableID: id)
        }
        return out
    }

    public func recall(_ scene: LightScene.ID) async throws {
        guard let parsed = NanoleafMapper.parseSceneID(scene), let light = NanoleafMapper.lightID(stableID: parsed.stableID)
        else {
            throw LightCoreError.unsupported("Unknown Nanoleaf scene '\(scene)'")
        }
        try await send(LightCommand(effect: parsed.effect), to: light)
    }

    // MARK: - HTTP

    /// Performs an authenticated request; maps auth failures and reachability.
    @discardableResult
    private func perform(_ build: (String) throws -> NanoleafRequest, stableID: String) async throws
        -> NanoleafHTTPResponse
    {
        guard let record = devices[stableID] else {
            throw LightCoreError.unsupported("Unknown Nanoleaf controller \(stableID)")
        }
        guard let token = try await secrets.string(for: Self.secretKey(stableID)), !token.isEmpty else {
            continuation.yield(.needsReauthentication(accountID: stableID))
            throw LightCoreError.authenticationRequired(.nanoleaf)
        }
        let request: NanoleafRequest
        do { request = try build(token) } catch {
            continuation.yield(.needsReauthentication(accountID: stableID))
            throw LightCoreError.authenticationRequired(.nanoleaf)
        }
        let response: NanoleafHTTPResponse
        do {
            response = try await transport.send(request, to: record.endpoint, timeout: configuration.requestTimeout)
        } catch let error as NanoleafTransportError {
            setReachable(stableID, false)
            throw Self.lightCoreError(error, endpoint: record.endpoint)
        }
        setReachable(stableID, true)
        switch response.status {
        case 200..<300:
            return response
        case 401, 403:
            log.error("Nanoleaf \(stableID) rejected the token (HTTP \(response.status)) for \(request.redactedPath)")
            continuation.yield(.needsReauthentication(accountID: stableID))
            throw LightCoreError.authenticationRequired(.nanoleaf)
        default:
            throw LightCoreError.protocolError("Nanoleaf \(request.method.rawValue) \(request.redactedPath) returned HTTP \(response.status)")
        }
    }

    static func lightCoreError(_ error: NanoleafTransportError, endpoint: NanoleafEndpoint) -> LightCoreError {
        switch error {
        case .timedOut: .unreachable("Nanoleaf at \(endpoint) timed out")
        case .invalidURL: .unreachable("Invalid Nanoleaf address \(endpoint)")
        case .unreachable(let detail): .unreachable("Nanoleaf at \(endpoint): \(detail)")
        }
    }

    private func setReachable(_ stableID: String, _ reachable: Bool) {
        guard var record = devices[stableID] else { return }
        if reachable { record.lastSeen = Date() }
        let changed = record.reachable != reachable
        record.reachable = reachable
        devices[stableID] = record
        if changed, let id = NanoleafMapper.lightID(stableID: stableID) {
            continuation.yield(.reachabilityChanged(id, reachable: reachable))
        }
    }

    /// Mutates the cached info and emits the resulting state.
    private func applyLocally(_ stableID: String, _ change: (inout NanoleafInfo) -> Void) {
        guard var record = devices[stableID] else { return }
        var info = record.info ?? NanoleafInfo()
        change(&info)
        record.info = info
        devices[stableID] = record
        emitState(record)
    }

    private func emitState(_ record: DeviceRecord) {
        guard let id = NanoleafMapper.lightID(stableID: record.stableID) else { return }
        continuation.yield(.stateChanged(id, NanoleafMapper.lightState(from: record.info, reachable: record.reachable)))
    }

    // MARK: - Events (SSE)

    private func startStream(_ stableID: String) {
        guard streamTasks[stableID] == nil else { return }
        streamTasks[stableID] = Task { await self.runEventStream(stableID) }
    }

    private func restartStream(_ stableID: String) {
        streamTasks.removeValue(forKey: stableID)?.cancel()
        startStream(stableID)
    }

    private func runEventStream(_ stableID: String) async {
        var backoff = configuration.eventBackoff
        while !Task.isCancelled {
            guard let record = devices[stableID] else { return }
            guard let token = try? await secrets.string(for: Self.secretKey(stableID)),
                  let request = try? NanoleafAPI.events(token: token, types: configuration.eventTypes) else {
                continuation.yield(.needsReauthentication(accountID: stableID))
                streamTasks[stableID] = nil
                return
            }
            var parser = SSEParser()
            var opened = false
            var fatal = false
            var reason = "stream ended"
            do {
                let stream = transport.stream(request, to: record.endpoint, idleTimeout: configuration.eventIdleTimeout)
                for try await part in stream {
                    switch part {
                    case .opened(let status):
                        if (200..<300).contains(status) {
                            opened = true
                            backoff.reset()
                            setReachable(stableID, true)
                            continuation.yield(.connectionChanged(connected: true, detail: "Nanoleaf \(record.name)"))
                            await resync(stableID)
                        } else if status == 401 || status == 403 {
                            fatal = true
                            log.error("Nanoleaf \(stableID) event stream rejected the token (HTTP \(status))")
                            continuation.yield(.needsReauthentication(accountID: stableID))
                        } else {
                            reason = "HTTP \(status)"
                        }
                    case .bytes(let bytes):
                        for event in NanoleafEventDecoder.feed(bytes, into: &parser) {
                            await handle(event, stableID: stableID)
                        }
                    }
                    if fatal || !opened { break }
                }
            } catch is CancellationError {
                return
            } catch {
                reason = "\(error)"
            }
            if Task.isCancelled { return }
            if !opened, !fatal { setReachable(stableID, false) }
            continuation.yield(.connectionChanged(connected: false, detail: "Nanoleaf \(record.name): \(reason)"))
            if fatal {
                streamTasks[stableID] = nil
                return
            }
            let delay = backoff.nextDelay()
            log.info("Nanoleaf \(stableID) events disconnected (\(reason)); retry in \(delay)")
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    /// Full re-read after (re)connecting so changes during a gap are not missed.
    private func resync(_ stableID: String) async {
        let before = devices[stableID]?.info
        guard await refresh(stableID), let record = devices[stableID] else { return }
        if before?.effects?.effectsList != record.info?.effects?.effectsList || before?.name != record.info?.name {
            if let light = makeLight(record) { continuation.yield(.lightUpdated(light)) }
            if before != nil { continuation.yield(.scenesChanged) }
        }
        emitState(record)
    }

    private func handle(_ event: NanoleafEvent, stableID: String) async {
        guard devices[stableID] != nil, let lightID = NanoleafMapper.lightID(stableID: stableID) else { return }
        setReachable(stableID, true)
        switch event {
        case .state(let changes):
            guard !changes.isEmpty else { return }
            applyLocally(stableID) { info in
                info.state = (info.state ?? NanoleafState()).applying(changes)
            }
        case .effects(let selected):
            guard let selected else { return }
            let known = devices[stableID]?.info?.effects?.effectsList ?? []
            applyLocally(stableID) { info in
                info.effects = NanoleafEffects(select: selected, effectsList: info.effects?.effectsList)
            }
            if !NanoleafMapper.isSpecialEffect(selected), !known.contains(selected) {
                // A new effect was added in the Nanoleaf app.
                await refresh(stableID)
                if let record = devices[stableID], let light = makeLight(record) {
                    continuation.yield(.lightUpdated(light))
                }
                continuation.yield(.scenesChanged)
            }
        case .layout:
            await refresh(stableID)
            if let record = devices[stableID], let light = makeLight(record) {
                continuation.yield(.lightUpdated(light))
            }
        case .touch(let touches):
            for touch in touches { touchContinuation.yield(NanoleafTouchEvent(light: lightID, touch: touch)) }
        case .unknown:
            break
        }
    }
}
