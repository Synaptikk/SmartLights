import Foundation
import LightCore
import NetKit
import TwinklyCodec

/// Twinkly provider (unofficial local xled REST API on HTTP :80, no cloud).
///
/// - Discovery: UDP 5555 `\x01discover` broadcast when the multicast entitlement works, else the
///   same datagram unicast to every host of the Wi-Fi /24; manual and cached hosts. Every hit is
///   confirmed with `GET /xled/v1/gestalt`, which needs no token and carries the MAC (stable id).
/// - Auth: `POST /login` with a random challenge, then `POST /verify` with the returned token in
///   `X-Auth-Token`. Tokens live ~4 h; the provider logs in again before expiry and on any 401.
///   A successful verify invalidates the previous token, so another controller (the Twinkly app)
///   logging in makes our next call 401 and triggers one re-login.
/// - Control: `/led/mode` (off/color/effect/movie), `/led/color` (HSV), `/led/out/brightness`,
///   `/led/effects` + `/led/effects/current`. Requests to one device are serialised.
/// - State: no push on the LAN; `loadLights()` reads the state and an optional poll loop
///   (`Configuration.pollInterval`) emits `stateChanged` when something changed elsewhere.
///
/// Light ids are `twinkly:<mac>` (lower-case hex, no separators). IPs are hints.
public actor TwinklyProvider: LightProvider {
    public static let brand: Brand = .twinkly

    public struct Configuration: Sendable {
        /// HTTP port; nil = 80. Tests point this at a loopback fake.
        public var httpPort: Int?
        public var discoveryPort: UInt16 = TwinklyDiscovery.port
        public var requestTimeout: Duration = .seconds(5)
        /// Timeout of the unauthenticated `/gestalt` probe during discovery.
        public var probeTimeout: Duration = .seconds(2)
        /// Log in again this long before the token expires.
        public var tokenRefreshMargin: Duration = .seconds(60)
        /// Used when `/login` omits `authentication_token_expires_in` (xled-docs: always 14400).
        public var defaultTokenLifetime: Duration = .seconds(14_400)
        /// Poll period after `loadLights()`; nil disables polling.
        public var pollInterval: Duration? = .seconds(30)
        /// Wall clock for token expiry (injectable for tests).
        public var now: @Sendable () -> Date = { Date() }

        public init() {}
    }

    struct Token: Codable, Sendable {
        var value: String
        var expiresAt: Date
    }

    struct DeviceState {
        var id: String
        var host: String
        var port: Int?
        var name: String
        var model: String?
        var info: TwinklyDeviceInfo?
        var live: TwinklyLiveState?
        var state: LightState?
        var token: Token?
        var tokenLoaded = false
        var reachable = true
        var lastSeen: Date?
        let gate = AsyncGate()
    }

    public let configuration: Configuration
    private let secrets: any SecretStore
    private let transport: any TwinklyTransport
    private var devices: [String: DeviceState] = [:]
    private var pollTask: Task<Void, Never>?
    private let log = Log(package: "twinklykit", category: "provider")

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation

    public init(secrets: any SecretStore, transport: any TwinklyTransport, configuration: Configuration = Configuration()) {
        self.secrets = secrets
        self.transport = transport
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        pollTask?.cancel()
        continuation.finish()
    }

    /// Twinkly has no account; the per-device token is internal.
    public var account: ProviderAccount? { nil }

    public static func tokenSecret(deviceID: String) -> SecretKey {
        SecretKey(brand: .twinkly, owner: deviceID, item: "token")
    }

    // MARK: - Device registry

    /// Restores a paired device (call on launch).
    public func addDevice(_ device: PairedDevice) {
        let id = TwinklyIdentifiers.normalizeMAC(device.id) ?? device.id.lowercased()
        let parsed = TwinklyEndpoint.parse(device.hostHint ?? "")
        register(id: id, host: parsed.host, port: parsed.port ?? device.port, name: device.name, model: device.model)
    }

    /// Updates the cached address (ids are stable, IPs are hints).
    public func updateHost(deviceID: String, host: String, port: Int? = nil) {
        guard let id = TwinklyIdentifiers.normalizeMAC(deviceID) else { return }
        let parsed = TwinklyEndpoint.parse(host)
        devices[id]?.host = parsed.host
        devices[id]?.port = parsed.port ?? port
    }

    /// Forgets a device and its token.
    public func removeDevice(id: String) async {
        let key = TwinklyIdentifiers.normalizeMAC(id) ?? id
        devices[key] = nil
        try? await secrets.remove(Self.tokenSecret(deviceID: key))
        if let lightID = LightID(brand: .twinkly, stableId: key) { continuation.yield(.lightRemoved(lightID)) }
    }

    public var deviceIDs: [String] { devices.keys.sorted() }

    /// Cached host of a device (diagnostics).
    public func host(of deviceID: String) -> String? { devices[deviceID]?.host }

    private func register(id: String, host: String, port: Int?, name: String, model: String?) {
        if devices[id] != nil {
            devices[id]?.host = host
            devices[id]?.port = port ?? devices[id]?.port
            devices[id]?.name = name
            devices[id]?.model = model ?? devices[id]?.model
        } else {
            devices[id] = DeviceState(id: id, host: host, port: port, name: name, model: model)
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
        let useBroadcast = options.broadcastAvailable && methods.contains(.broadcast)
        let broadcast = useBroadcast ? transport.broadcastAddresses() : []
        // Unicast sweep only when broadcast is unavailable (it reaches the same devices).
        let sweep = !useBroadcast && methods.contains(.sweep) ? transport.sweepHosts() : []
        let transport = self.transport
        let port = configuration.discoveryPort
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
                    for (destinations, method) in [(broadcast, DiscoveryMethod.broadcast), (sweep, .sweep)] where !destinations.isEmpty {
                        group.addTask {
                            await withTaskGroup(of: Void.self) { probes in
                                var seen: Set<String> = []
                                for await datagram in transport.probeUDP(TwinklyDiscovery.request, destinations: destinations,
                                                                         port: port, window: timeout) {
                                    guard let reply = TwinklyDiscovery.parseReply(datagram.data),
                                          seen.insert(datagram.host).inserted else { continue }
                                    probes.addTask {
                                        if let d = await self.probe(datagram.host, method: method, discoveryID: reply.deviceID) {
                                            await sink.emit(d)
                                        }
                                    }
                                }
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

    /// Confirms a candidate with `GET /gestalt` (+ `/fw/version`); nil if it is not a Twinkly.
    private func probe(_ input: String, method: DiscoveryMethod, discoveryID: String? = nil) async -> DiscoveredDevice? {
        let parsed = TwinklyEndpoint.parse(input)
        let port = parsed.port ?? configuration.httpPort
        guard let gestalt = try? await fetchGestalt(host: parsed.host, port: port, timeout: configuration.probeTimeout),
              let id = gestalt.stableID else { return nil }
        let firmware = try? await fetchFirmware(host: parsed.host, port: port, timeout: configuration.probeTimeout)
        if devices[id] != nil, devices[id]?.host != parsed.host {
            log.info("Twinkly \(id) moved to \(parsed.host)")
            devices[id]?.host = parsed.host
            devices[id]?.port = port
        }
        var metadata: [String: String] = [:]
        metadata["hw_id"] = gestalt.hardwareID
        metadata["fw_family"] = gestalt.firmwareFamily
        metadata["led_profile"] = gestalt.ledProfile
        metadata["number_of_led"] = gestalt.numberOfLED.map(String.init)
        metadata["uuid"] = gestalt.uuid
        metadata["firmware"] = firmware
        metadata["discovery_id"] = discoveryID
        return DiscoveredDevice(
            id: id, brand: .twinkly, name: gestalt.deviceName ?? discoveryID ?? "Twinkly", model: gestalt.productCode,
            host: parsed.host, port: port, macAddress: gestalt.mac, method: method, metadata: metadata)
    }

    // MARK: - Pairing

    /// No button press is needed: the xled login works for any client on the LAN. Pairing
    /// confirms the identity, performs one login and reads capabilities and state.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        let input = device.host ?? (device.id.hasPrefix("ip:") ? String(device.id.dropFirst(3)) : "")
        guard !input.isEmpty else { throw LightCoreError.unsupported("Twinkly pairing needs an IP address") }
        let parsed = TwinklyEndpoint.parse(input)
        let port = parsed.port ?? device.port ?? configuration.httpPort
        await ui.status("Connecting to \(device.name)...")

        let gestalt: TwinklyGestalt
        do {
            gestalt = try await fetchGestalt(host: parsed.host, port: port, timeout: configuration.requestTimeout)
        } catch {
            throw Self.map(error)
        }
        guard let id = gestalt.stableID else { throw TwinklyError.missingIdentity.lightCoreError }
        if let expected = TwinklyIdentifiers.normalizeMAC(device.id), expected != id {
            throw TwinklyError.identityMismatch(expected: expected, found: id).lightCoreError
        }
        let name = gestalt.deviceName ?? device.name
        register(id: id, host: parsed.host, port: port, name: name, model: gestalt.productCode)

        let lightID = try Self.lightID(id)
        do {
            try await withDevice(id) {
                _ = try await self.login(id)
                _ = try await self.loadInfo(id)
                try await self.readState(id, emit: false)
            }
        } catch {
            throw Self.map(error)
        }
        if let light = makeLight(id) { continuation.yield(.lightAdded(light)) }
        let info = devices[id]?.info
        var metadata: [String: String] = [:]
        metadata["firmware"] = info?.firmware
        metadata["hw_id"] = gestalt.hardwareID
        metadata["fw_family"] = gestalt.firmwareFamily
        metadata["led_profile"] = gestalt.ledProfile
        metadata["number_of_led"] = gestalt.numberOfLED.map(String.init)
        log.info("Paired Twinkly \(id) at \(parsed.host)")
        return PairedDevice(
            id: id, brand: .twinkly, name: name, model: gestalt.productCode, hostHint: parsed.host, port: port,
            lightIDs: [lightID], metadata: metadata, lastSeen: configuration.now())
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        var lights: [Light] = []
        for id in devices.keys.sorted() {
            do {
                try await withDevice(id) {
                    if self.devices[id]?.info == nil { _ = try await self.loadInfo(id) }
                    try await self.readState(id, emit: false)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.notice("Twinkly \(id) not reachable: \(error)")
            }
            if let light = makeLight(id) { lights.append(light) }
        }
        if configuration.pollInterval != nil, pollTask == nil, !devices.isEmpty { startPolling() }
        return lights
    }

    /// Re-reads one device and emits `stateChanged` if anything differs.
    public func refresh(_ light: LightID) async throws {
        let id = try deviceID(for: light)
        do {
            try await withDevice(id) { try await self.readState(id, emit: true) }
        } catch {
            throw Self.map(error)
        }
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        let id = try deviceID(for: light)
        do {
            try await withDevice(id) { try await self.execute(command, on: id) }
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Polling

    /// Starts the poll loop (no-op if `pollInterval` is nil or already running).
    public func startPolling() {
        guard let interval = configuration.pollInterval, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
            }
        }
    }

    /// Stops polling (call when the app goes to the background).
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var isPolling: Bool { pollTask != nil }

    func pollOnce() async {
        for id in devices.keys.sorted() {
            try? await withDevice(id) { try await self.readState(id, emit: true) }
        }
    }

    // MARK: - Internals (device gate held)

    private func execute(_ command: LightCommand, on id: String) async throws {
        if devices[id]?.info == nil { _ = try await loadInfo(id) }
        if devices[id]?.live == nil { try await readState(id, emit: false) }
        guard let info = devices[id]?.info, let live = devices[id]?.live else {
            throw LightCoreError.unreachable("Twinkly \(id)")
        }
        let capabilities = TwinklyMapping.capabilities(info)
        let plan = TwinklyMapping.plan(command, current: live, capabilities: capabilities)
        for request in plan.requests {
            _ = try await call(request, on: id)
        }
        var newLive = live
        newLive.apply(mode: plan.resultingMode, effectID: plan.resultingEffectID)
        devices[id]?.live = newLive

        var state = (devices[id]?.state ?? LightState()).applying(command.normalized(for: capabilities), at: configuration.now())
        state.isOn = plan.resultingMode != .off
        state.reachable = true
        switch plan.resultingMode {
        case .movie: state.effect = TwinklyEffects.movie
        case .playlist: state.effect = TwinklyEffects.playlist
        case .effect: state.effect = plan.resultingEffectID.map(TwinklyEffects.effectID)
        case .color: state.effect = nil
        default: break
        }
        if plan.resultingMode != .color, state.colorMode == .hs, command.color == nil { state.colorMode = nil }
        devices[id]?.state = state
        if let lightID = LightID(brand: .twinkly, stableId: id) { continuation.yield(.stateChanged(lightID, state)) }
    }

    @discardableResult
    private func loadInfo(_ id: String) async throws -> TwinklyDeviceInfo {
        guard let device = devices[id] else { throw LightCoreError.lightNotFound(try Self.lightID(id)) }
        let gestalt = try await fetchGestalt(host: device.host, port: device.port, timeout: configuration.requestTimeout)
        if let found = gestalt.stableID, found != id {
            throw TwinklyError.identityMismatch(expected: id, found: found)
        }
        let firmware = try? await fetchFirmware(host: device.host, port: device.port, timeout: configuration.requestTimeout)
        var effectCount = 0
        if let data = try? await call(TwinklyAPI.getEffects, on: id),
           let effects = try? TwinklyAPI.decode(TwinklyEffectsResponse.self, from: data) {
            effectCount = effects.count
        }
        let info = TwinklyDeviceInfo(gestalt: gestalt, firmware: firmware, effectCount: effectCount)
        devices[id]?.info = info
        if let name = gestalt.deviceName, !name.isEmpty { devices[id]?.name = name }
        devices[id]?.model = gestalt.productCode ?? devices[id]?.model
        return info
    }

    private func readState(_ id: String, emit: Bool) async throws {
        guard let info = devices[id]?.info else { throw LightCoreError.unreachable("Twinkly \(id)") }
        let mode = try TwinklyAPI.decode(TwinklyModeResponse.self, from: try await call(TwinklyAPI.getMode, on: id)).mode
        var brightness: TwinklyBrightnessResponse?
        if info.supportsBrightness {
            brightness = try? TwinklyAPI.decode(TwinklyBrightnessResponse.self, from: try await call(TwinklyAPI.getBrightness, on: id))
        }
        var color: TwinklyColorResponse?
        if mode == .color, info.supportsColor {
            color = try? TwinklyAPI.decode(TwinklyColorResponse.self, from: try await call(TwinklyAPI.getColor, on: id))
        }
        var effectID: Int?
        if mode == .effect {
            effectID = (try? TwinklyAPI.decode(TwinklyEffectCurrent.self, from: try await call(TwinklyAPI.getCurrentEffect, on: id)))?.effectID
        }
        let state = TwinklyMapping.state(mode: mode, color: color, brightness: brightness, effectID: effectID,
                                         at: configuration.now())
        var live = devices[id]?.live ?? TwinklyLiveState(mode: mode)
        live.apply(mode: mode, effectID: effectID)
        devices[id]?.live = live
        let previous = devices[id]?.state
        devices[id]?.state = state
        if emit, let lightID = LightID(brand: .twinkly, stableId: id), !Self.sameState(previous, state) {
            continuation.yield(.stateChanged(lightID, state))
        }
    }

    /// One authenticated (or anonymous) call; logs in when needed and retries once after a 401.
    private func call(_ request: TwinklyRequest, on id: String) async throws -> Data {
        var token: Token?
        if request.authenticated { token = try await validToken(id) }
        var response = try await rawSend(request, on: id, token: token?.value)
        if response.status == 401, request.authenticated {
            log.info("Twinkly \(id): token rejected, logging in again")
            token = try await login(id)
            response = try await rawSend(request, on: id, token: token?.value)
            if response.status == 401 { throw TwinklyError.unauthorized }
        }
        switch response.status {
        case 200..<300: break
        case 404: throw TwinklyError.endpointUnavailable(request.path)
        default: throw TwinklyError.httpStatus(response.status)
        }
        try TwinklyAPI.checkCode(response.body)
        return response.body
    }

    private func rawSend(_ request: TwinklyRequest, on id: String, token: String?) async throws -> TwinklyHTTPResponse {
        guard let device = devices[id] else { throw LightCoreError.lightNotFound(try Self.lightID(id)) }
        guard let url = TwinklyEndpoint.url(host: device.host, port: device.port ?? configuration.httpPort, path: request.path) else {
            throw LightCoreError.unreachable("invalid host \(device.host)")
        }
        var headers: [String: String] = [:]
        if request.body != nil { headers["Content-Type"] = "application/json" }
        if let token { headers[TwinklyAPI.tokenHeader] = token }
        do {
            let response = try await transport.send(TwinklyHTTPRequest(
                method: request.method, url: url, headers: headers, body: request.body, timeout: configuration.requestTimeout))
            markReachable(id, true)
            return response
        } catch let error as TwinklyTransportError {
            markReachable(id, false)
            throw error
        }
    }

    private func validToken(_ id: String) async throws -> Token {
        if devices[id]?.tokenLoaded == false {
            devices[id]?.tokenLoaded = true
            if let data = try? await secrets.data(for: Self.tokenSecret(deviceID: id)),
               let stored = try? JSONDecoder().decode(Token.self, from: data) {
                devices[id]?.token = stored
            }
        }
        if let token = devices[id]?.token,
           token.expiresAt.timeIntervalSince(configuration.now()) > configuration.tokenRefreshMargin.timeInterval {
            return token
        }
        return try await login(id)
    }

    /// `POST /login` + `POST /verify`. Invalidates the previous token on the device.
    @discardableResult
    private func login(_ id: String) async throws -> Token {
        let loginData = try await call(TwinklyAPI.login(challenge: TwinklyAPI.makeChallenge()), on: id)
        let login = try TwinklyAPI.decode(TwinklyLoginResponse.self, from: loginData)
        let verify = try await rawSend(TwinklyAPI.verify(challengeResponse: login.challengeResponse), on: id,
                                       token: login.authenticationToken)
        guard verify.status != 401 else { throw TwinklyError.unauthorized }
        guard (200..<300).contains(verify.status) else { throw TwinklyError.httpStatus(verify.status) }
        try TwinklyAPI.checkCode(verify.body)

        let lifetime = login.expiresIn.map { Double($0) } ?? configuration.defaultTokenLifetime.timeInterval
        let token = Token(value: login.authenticationToken, expiresAt: configuration.now().addingTimeInterval(lifetime))
        devices[id]?.token = token
        devices[id]?.tokenLoaded = true
        if let data = try? JSONEncoder().encode(token) {
            do {
                try await secrets.set(data, for: Self.tokenSecret(deviceID: id))
            } catch {
                log.error("Could not store Twinkly token for \(id): \(error)")
            }
        }
        log.info("Logged in to Twinkly \(id) (token \(Log.redact(token.value)))")
        return token
    }

    private func fetchGestalt(host: String, port: Int?, timeout: Duration) async throws -> TwinklyGestalt {
        try TwinklyAPI.decode(TwinklyGestalt.self, from: try await anonymousGet(TwinklyAPI.gestalt, host: host, port: port, timeout: timeout))
    }

    private func fetchFirmware(host: String, port: Int?, timeout: Duration) async throws -> String {
        try TwinklyAPI.decode(TwinklyFirmwareResponse.self,
                              from: try await anonymousGet(TwinklyAPI.firmwareVersion, host: host, port: port, timeout: timeout)).version
    }

    private func anonymousGet(_ request: TwinklyRequest, host: String, port: Int?, timeout: Duration) async throws -> Data {
        guard let url = TwinklyEndpoint.url(host: host, port: port ?? configuration.httpPort, path: request.path) else {
            throw LightCoreError.unreachable("invalid host \(host)")
        }
        let response = try await transport.send(TwinklyHTTPRequest(method: request.method, url: url, timeout: timeout))
        guard (200..<300).contains(response.status) else {
            throw response.status == 404 ? TwinklyError.endpointUnavailable(request.path) : TwinklyError.httpStatus(response.status)
        }
        return response.body
    }

    private func withDevice<T: Sendable>(_ id: String, _ body: () async throws -> T) async throws -> T {
        guard let gate = devices[id]?.gate else { throw LightCoreError.lightNotFound(try Self.lightID(id)) }
        await gate.lock()
        do {
            let result = try await body()
            await gate.unlock()
            return result
        } catch {
            await gate.unlock()
            throw error
        }
    }

    private func markReachable(_ id: String, _ reachable: Bool) {
        guard devices[id] != nil else { return }
        if reachable { devices[id]?.lastSeen = configuration.now() }
        guard devices[id]?.reachable != reachable else { return }
        devices[id]?.reachable = reachable
        devices[id]?.state?.reachable = reachable
        if let lightID = LightID(brand: .twinkly, stableId: id) {
            continuation.yield(.reachabilityChanged(lightID, reachable: reachable))
        }
    }

    private func makeLight(_ id: String) -> Light? {
        guard let device = devices[id], let lightID = LightID(brand: .twinkly, stableId: id) else { return nil }
        let capabilities = device.info.map(TwinklyMapping.capabilities)
            ?? LightCapabilities(supportedColorModes: [.hs], supportsEffects: true, effects: TwinklyEffects.descriptors(effectCount: 0))
        var state = device.state ?? LightState(reachable: false)
        state.reachable = device.reachable && device.state != nil
        return Light(id: lightID, name: device.name, capabilities: capabilities, state: state, providerRef: id,
                     model: device.model)
    }

    private func deviceID(for light: LightID) throws -> String {
        guard light.brand == .twinkly, devices[light.stableId] != nil else { throw LightCoreError.lightNotFound(light) }
        return light.stableId
    }

    private static func lightID(_ id: String) throws -> LightID {
        guard let lightID = LightID(brand: .twinkly, stableId: id) else { throw LightCoreError.invalidLightID("twinkly:\(id)") }
        return lightID
    }

    private static func sameState(_ a: LightState?, _ b: LightState) -> Bool {
        guard var a else { return false }
        a.updatedAt = b.updatedAt
        return a == b
    }

    /// Maps internal errors to `LightCoreError` (never includes tokens).
    static func map(_ error: any Error) -> any Error {
        switch error {
        case let e as TwinklyError: return e.lightCoreError
        case let e as TwinklyTransportError:
            switch e {
            case .timedOut: return LightCoreError.timeout
            case .connectionFailed(let message): return LightCoreError.unreachable(message)
            }
        default: return error
        }
    }
}

/// Serialises requests to one device (the ESP-based controllers handle one connection at a time).
actor AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Deduplicates discovery results by stable id.
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
