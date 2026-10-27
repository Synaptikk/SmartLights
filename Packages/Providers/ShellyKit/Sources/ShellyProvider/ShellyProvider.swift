import Foundation
import LightCore
import NetKit
import ShellyCodec

/// Shelly lights over the local API: Gen1 REST (`/shelly`, `/settings`, `/status`, `/light/N`,
/// `/color/N`, `/white/N`) and Gen2+ JSON-RPC (`POST /rpc`, `Shelly.GetDeviceInfo`,
/// `Shelly.GetConfig`, `Shelly.GetStatus`, `Light/CCT/RGB/RGBW/RGBCCT.Set`).
///
/// - Devices are keyed by MAC (`shelly:a0a3b3c4d5e6`; extra outputs `shelly:<mac>-light1`); IPs are
///   cached hints refreshed by discovery.
/// - Auth: when the device has a password, Gen2+ use HTTP Digest (RFC 7616, SHA-256, user `admin`,
///   realm = device id), Gen1 HTTP Basic. The password is asked once with
///   `PairingInteraction.secureText` and kept in `SecretStore` only.
/// - Discovery: Bonjour `_shelly._tcp` and `_http._tcp` names `shelly*`; if nothing answers within
///   `sweepDelay`, a unicast `GET /shelly` sweep of the Wi-Fi /24; plus cached and manual hosts.
/// - Events: `start()` opens the Gen2+ `/rpc` WebSocket (`NotifyStatus`) where available and polls
///   every `pollInterval` the devices without a live socket (all Gen1 devices).
public actor ShellyProvider: LightProvider {
    public static let brand: Brand = .shelly

    public struct Configuration: Sendable {
        public var port: Int
        public var requestTimeout: Duration
        /// Extra attempts for reads after a transport failure.
        public var retries: Int
        public var sweepTimeout: Duration
        public var sweepConcurrency: Int
        /// The sweep starts only if Bonjour found nothing within this time.
        public var sweepDelay: Duration
        public var pollInterval: Duration
        /// Use the Gen2+ WebSocket notification channel when the environment offers one.
        public var useWebSocket: Bool
        /// RPC `src` (the device addresses replies and notifications to it).
        public var clientID: String

        public init(
            port: Int = 80,
            requestTimeout: Duration = .seconds(3),
            retries: Int = 1,
            sweepTimeout: Duration = .milliseconds(800),
            sweepConcurrency: Int = 24,
            sweepDelay: Duration = .milliseconds(1500),
            pollInterval: Duration = .seconds(10),
            useWebSocket: Bool = true,
            clientID: String = "smartlights-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        ) {
            self.port = port
            self.requestTimeout = requestTimeout
            self.retries = retries
            self.sweepTimeout = sweepTimeout
            self.sweepConcurrency = sweepConcurrency
            self.sweepDelay = sweepDelay
            self.pollInterval = pollInterval
            self.useWebSocket = useWebSocket
            self.clientID = clientID
        }
    }

    struct Device {
        var mac: String
        var host: String
        var port: Int
        var info: ShellyDeviceInfo
        var name: String?
        var channels: [ShellyChannel] = []
        var statuses: [String: ShellyChannelStatus] = [:]
        var username: String?
        var password: String?
        var challenge: ShellyDigestChallenge?
        var nonceCount = 0
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?
    }

    private struct Socket {
        var socket: any ShellyWebSocket
        var task: Task<Void, Never>
        var requestID: Int
        var authSent = false
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: ShellyNetworkEnvironment
    private let secretStore: any SecretStore
    private let log = Log(package: "shellykit", category: "provider")

    private var devices: [String: Device] = [:]
    /// LightID -> (mac, channel key).
    private var lightIndex: [LightID: (mac: String, key: String)] = [:]
    private var sockets: [String: Socket] = [:]
    private var opening: Set<String> = []
    private var rpcID = 0
    private var pollTask: Task<Void, Never>?

    public init(configuration: Configuration = Configuration(), environment: ShellyNetworkEnvironment,
                secretStore: any SecretStore = InMemorySecretStore()) {
        self.configuration = configuration
        self.environment = environment
        self.secretStore = secretStore
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        for (_, s) in sockets {
            s.task.cancel()
            s.socket.close()
        }
        eventContinuation.finish()
    }

    /// Per-device passwords are not an account; nothing to report.
    public var account: ProviderAccount? { nil }

    public static func passwordKey(mac: String) -> SecretKey {
        SecretKey(brand: .shelly, owner: mac, item: "password")
    }

    // MARK: - Lifecycle

    /// Opens Gen2+ notification sockets and starts polling. Idempotent.
    public func start() {
        guard pollTask == nil else { return }
        openSockets()
        let interval = configuration.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
                await self.openSockets()
            }
        }
    }

    /// Stops polling and closes notification sockets (app in background).
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for mac in Array(sockets.keys) { closeSocket(mac) }
    }

    /// Re-registers devices persisted by the app (`DeviceStore`) without touching the network.
    /// Passwords are read from `SecretStore` on first use.
    public func restore(_ paired: [PairedDevice]) {
        for p in paired where p.brand == .shelly {
            guard let mac = ShellyDeviceInfo.normalizeMAC(p.id), let host = p.hostHint else { continue }
            let m = p.metadata
            let info = ShellyDeviceInfo(
                mac: mac, generation: Int(m["gen"] ?? "") ?? 1, model: m["model"] ?? p.model ?? "unknown", app: m["app"],
                deviceID: m["deviceID"], authRequired: m["auth"] == "true", authDomain: m["authDomain"] ?? m["deviceID"]
            )
            var d = devices[mac] ?? Device(mac: mac, host: host, port: p.port ?? configuration.port, info: info)
            d.host = host
            d.name = d.name ?? p.name
            d.username = m["username"]
            if d.channels.isEmpty, let json = m["channels"], let channels = try? JSONDecoder().decode([ShellyChannel].self, from: Data(json.utf8)) {
                d.channels = channels
            }
            d.paired = p
            devices[mac] = d
            reindex(mac)
        }
    }

    /// MACs of paired devices (diagnostics/tests).
    public var pairedMACs: [String] { devices.values.filter { $0.paired != nil }.map(\.mac).sorted() }

    /// Cached host for a light (diagnostics/tests).
    public func host(of id: LightID) -> String? { lightIndex[id].flatMap { devices[$0.mac]?.host } }

    /// Whether the Gen2+ notification socket of the light's device is open (diagnostics/tests).
    public func hasNotificationSocket(_ id: LightID) -> Bool { lightIndex[id].map { sockets[$0.mac] != nil } ?? false }

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
        let browse = methods.contains(.bonjour) ? environment.browseBonjour : nil
        let sweepHosts = methods.contains(.sweep) ? environment.sweepHosts() : []
        var direct: [(String, Int, DiscoveryMethod)] = []
        var specs: [(String, DiscoveryMethod)] = []
        if methods.contains(.cached) {
            specs += options.cachedHosts.map { ($0, .cached) }
            specs += devices.values.map { ("\($0.host):\($0.port)", .cached) }
        }
        if methods.contains(.manual) { specs += options.manualHosts.map { ($0, .manual) } }
        for (spec, method) in specs {
            if let (host, port) = Self.parseHost(spec, defaultPort: config.port) { direct.append((host, port, method)) }
        }
        let directProbes = direct

        await withTaskGroup(of: Void.self) { group in
            if let browse {
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        for await hit in browse() {
                            // IPv6 literals would need URL brackets; such devices are still found by sweep/manual.
                            guard let host = hit.host, !host.contains(":") else { continue }
                            if hit.type == "_http._tcp", !ShellyDeviceInfo.isShellyServiceName(hit.name) { continue }
                            let port = hit.port.map(Int.init) ?? config.port
                            inner.addTask { await report(await self.identify(host: host, port: port, method: .bonjour)) }
                        }
                    }
                }
            }
            if !sweepHosts.isEmpty {
                group.addTask {
                    // Bonjour is the normal path; sweep only when it stays silent (denied, VLANs...).
                    if browse != nil {
                        try? await Task.sleep(for: config.sweepDelay)
                        if await seen.count > 0 || Task.isCancelled { return }
                    }
                    let sweeper = SubnetSweeper(maxConcurrent: config.sweepConcurrency)
                    let results = sweeper.stream(sweepHosts.compactMap(IPv4Addr.init)) { host in
                        await self.identify(host: host.description, port: config.port, method: .sweep, timeout: config.sweepTimeout)
                    }
                    for await device in results { await report(device) }
                }
            }
            for (host, port, method) in directProbes {
                group.addTask { await report(await self.identify(host: host, port: port, method: method)) }
            }
        }
    }

    /// `GET /shelly` (unauthenticated on every generation).
    private func identify(host: String, port: Int, method: DiscoveryMethod, timeout: Duration? = nil) async -> DiscoveredDevice? {
        guard let info = await fetchInfo(host: host, port: port, timeout: timeout ?? configuration.requestTimeout) else { return nil }
        noteEndpoint(info, host: host, port: port)
        return DiscoveredDevice(
            id: info.mac,
            brand: .shelly,
            name: devices[info.mac]?.name ?? info.name ?? "\(info.displayModel) \(info.mac.suffix(6).uppercased())",
            model: info.displayModel,
            host: host,
            port: port,
            macAddress: info.mac,
            method: method,
            metadata: Self.metadata(info)
        )
    }

    private func fetchInfo(host: String, port: Int, timeout: Duration) async -> ShellyDeviceInfo? {
        let request = ShellyHTTPRequest(host: host, port: port, uri: "/shelly")
        guard let response = try? await environment.http.perform(request, timeout: timeout), response.status == 200 else { return nil }
        return ShellyDeviceInfo.parse(response.body)
    }

    // MARK: - LightProvider: pairing

    /// Confirms the device answers, asks for the device password when one is set (Gen2+ user
    /// `admin`, Gen1 the configured user), reads its light outputs and records it.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .shelly else { throw LightCoreError.unsupported("\(device.name) is not a Shelly device") }
        var hostSpec = device.host.map { h in device.port.map { "\(h):\($0)" } ?? h }
        if hostSpec == nil || hostSpec?.isEmpty == true {
            hostSpec = try await ui.text("IP address of the Shelly device (Shelly app > device > Settings > Device information)")
        }
        guard let spec = hostSpec, let (host, port) = Self.parseHost(spec, defaultPort: configuration.port) else {
            throw LightCoreError.unreachable("no address for \(device.name)")
        }
        await ui.status("Contacting \(host)...")
        guard let info = await fetchInfo(host: host, port: port, timeout: configuration.requestTimeout) else {
            throw LightCoreError.unreachable("No Shelly device answered at \(host)")
        }
        noteEndpoint(info, host: host, port: port)
        let mac = info.mac
        let label = info.name ?? device.name

        if info.authRequired {
            if devices[mac]?.password == nil, let stored = try? await secretStore.string(for: Self.passwordKey(mac: mac)) {
                devices[mac]?.password = stored
            }
            var attempts = 0
            while true {
                if devices[mac]?.password == nil {
                    let user: String
                    if info.usesRPC {
                        user = ShellyDigest.defaultUser
                    } else {
                        let typed = try await ui.text("Username for \(label) (set in the Shelly app under Restrict login, usually admin)")
                        user = typed.trimmingCharacters(in: .whitespaces).isEmpty ? ShellyDigest.defaultUser : typed.trimmingCharacters(in: .whitespaces)
                    }
                    let password = try await ui.secureText(
                        "Password for \(label). It is the device password set in the Shelly app (username \(user))."
                    )
                    devices[mac]?.username = user
                    devices[mac]?.password = password
                    devices[mac]?.challenge = nil
                }
                do {
                    try await loadConfiguration(mac)
                    break
                } catch LightCoreError.authenticationRequired {
                    attempts += 1
                    devices[mac]?.password = nil
                    log.notice("wrong password for Shelly \(mac) (attempt \(attempts))")
                    if attempts >= 3 { throw LightCoreError.authenticationRequired(.shelly) }
                    await ui.status("The password was not accepted. Try again.")
                }
            }
        } else {
            try await loadConfiguration(mac)
        }

        guard let d = devices[mac], !d.channels.isEmpty else {
            throw LightCoreError.unsupported("\(info.displayModel) has no light outputs SmartLights can control")
        }
        if let password = d.password {
            try await secretStore.set(password, for: Self.passwordKey(mac: mac))
            log.info("stored Shelly \(mac) password (\(Log.redact(password)))")
        }
        var metadata = Self.metadata(info)
        if let user = d.username { metadata["username"] = user }
        if let data = try? JSONEncoder().encode(d.channels) { metadata["channels"] = String(decoding: data, as: UTF8.self) }
        let paired = PairedDevice(
            id: mac,
            brand: .shelly,
            name: d.name ?? info.name ?? "\(info.displayModel) \(mac.suffix(6).uppercased())",
            model: info.displayModel,
            hostHint: d.host,
            port: d.port,
            lightIDs: lightIDs(of: d),
            metadata: metadata,
            lastSeen: d.lastSeen
        )
        devices[mac]?.paired = paired
        reindex(mac)
        for light in lights(of: mac) { emit(.lightAdded(light)) }
        if pollTask != nil { openSockets() }
        return paired
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        let macs = pairedMACs
        await withTaskGroup(of: Void.self) { group in
            for mac in macs { group.addTask { await self.refresh(mac, emitChanges: false) } }
        }
        return macs.flatMap(lights(of:))
    }

    /// One polling round over paired devices without a live notification socket; emits changes.
    public func pollOnce() async {
        let macs = pairedMACs.filter { sockets[$0] == nil }
        await withTaskGroup(of: Void.self) { group in
            for mac in macs { group.addTask { await self.refresh(mac, emitChanges: true) } }
        }
    }

    private func refresh(_ mac: String, emitChanges: Bool) async {
        let before = lights(of: mac)
        do {
            if devices[mac]?.channels.isEmpty ?? true {
                try await loadConfiguration(mac)
            } else {
                try await loadStatus(mac)
            }
        } catch LightCoreError.authenticationRequired {
            emit(.needsReauthentication(accountID: mac))
            return
        } catch {
            markReachable(mac, false, emit: emitChanges)
            return
        }
        if emitChanges { emitDiff(before: before, after: lights(of: mac)) }
    }

    /// Channels + status: Gen2+ `Shelly.GetConfig` and `Shelly.GetStatus`; Gen1 `/settings` and `/status`.
    private func loadConfiguration(_ mac: String) async throws {
        guard let d = devices[mac] else { throw LightCoreError.lightNotFound(Self.anyLightID(mac)) }
        if d.info.usesRPC {
            let config = try await rpc(mac, "Shelly.GetConfig")
            let status = try await rpc(mac, "Shelly.GetStatus")
            let channels = ShellyMapping.rpcChannels(config: config, status: status)
            devices[mac]?.channels = channels
            devices[mac]?.statuses = ShellyMapping.statuses(for: channels, rpcStatus: status)
            if let name = config["sys"]?["device"]?["name"]?.string, !name.isEmpty { devices[mac]?.name = name }
        } else {
            let settings = try await gen1(mac, ShellyGen1Request(path: "/settings"))
            let status = try await gen1(mac, ShellyGen1Request(path: "/status"))
            let channels = ShellyMapping.gen1Channels(type: d.info.model, settings: settings)
            devices[mac]?.channels = channels
            devices[mac]?.statuses = ShellyMapping.statuses(for: channels, gen1Status: status)
            if let name = settings["name"]?.string, !name.isEmpty { devices[mac]?.name = name }
        }
        devices[mac]?.lastSeen = Date()
        markReachable(mac, true, emit: true)
        reindex(mac)
    }

    private func loadStatus(_ mac: String) async throws {
        guard let d = devices[mac] else { return }
        if d.info.usesRPC {
            let status = try await rpc(mac, "Shelly.GetStatus")
            devices[mac]?.statuses = ShellyMapping.statuses(for: d.channels, rpcStatus: status)
        } else {
            let status = try await gen1(mac, ShellyGen1Request(path: "/status"))
            devices[mac]?.statuses = ShellyMapping.statuses(for: d.channels, gen1Status: status)
        }
        devices[mac]?.lastSeen = Date()
        markReachable(mac, true, emit: true)
    }

    private func lightIDs(of d: Device) -> [LightID] {
        d.channels.enumerated().map { i, c in ShellyMapping.lightID(mac: d.mac, channel: c, primary: i == 0) }
    }

    private func lights(of mac: String) -> [Light] {
        guard let d = devices[mac] else { return [] }
        return d.channels.enumerated().map { i, c in
            let id = ShellyMapping.lightID(mac: mac, channel: c, primary: i == 0)
            var state = d.statuses[c.key].map { ShellyMapping.state($0, channel: c, at: d.lastSeen ?? Date()) } ?? LightState(reachable: false)
            state.reachable = d.reachable && d.statuses[c.key] != nil
            let base = d.name ?? d.paired?.name ?? d.info.displayModel
            let name = c.name ?? (d.channels.count > 1 ? "\(base) \(i + 1)" : base)
            return Light(id: id, name: name, capabilities: ShellyMapping.capabilities(for: c), state: state,
                         providerRef: "\(d.host):\(d.port)/\(c.key)", manufacturer: "Shelly", model: d.info.displayModel)
        }
    }

    private func reindex(_ mac: String) {
        lightIndex = lightIndex.filter { $0.value.mac != mac }
        guard let d = devices[mac] else { return }
        for (i, c) in d.channels.enumerated() {
            lightIndex[ShellyMapping.lightID(mac: mac, channel: c, primary: i == 0)] = (mac, c.key)
        }
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to id: LightID) async throws {
        guard let (mac, key) = lightIndex[id], let d = devices[mac], let channel = d.channels.first(where: { $0.key == key }) else {
            throw LightCoreError.lightNotFound(id)
        }
        if command.isEmpty { return }
        guard let (action, predicted) = ShellyMapping.plan(command, channel: channel, current: d.statuses[key]) else { return }
        do {
            switch action {
            case .rpc(let method, let params):
                _ = try await rpc(mac, method, params: params, retries: 0)
                devices[mac]?.statuses[key] = predicted
            case .gen1(let request):
                let reply = try await gen1(mac, request, retries: 0)
                devices[mac]?.statuses[key] = ShellyChannelStatus.parseGen1(reply) ?? predicted
            }
        } catch LightCoreError.authenticationRequired {
            emit(.needsReauthentication(accountID: mac))
            throw LightCoreError.authenticationRequired(.shelly)
        } catch let error as LightCoreError {
            if case .protocolError = error { throw error }
            markReachable(mac, false, emit: true)
            throw LightCoreError.unreachable("Shelly \(d.name ?? mac) did not answer")
        }
        devices[mac]?.lastSeen = Date()
        markReachable(mac, true, emit: true)
        if let light = lights(of: mac).first(where: { $0.id == id }) { emit(.stateChanged(id, light.state)) }
    }

    /// Concurrent fan-out (each device is independent).
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

    // MARK: - HTTP: Gen2+ RPC with digest auth

    /// `POST /rpc`. On 401 computes the digest from the challenge and retries; a 401 for an
    /// answer to a fresh challenge means a wrong password (`authenticationRequired`).
    @discardableResult
    func rpc(_ mac: String, _ method: String, params: ShellyJSON? = nil, retries: Int? = nil) async throws -> ShellyJSON {
        var transportAttempts = 1 + max(0, retries ?? configuration.retries)
        var answeredFreshChallenge = false
        var authRounds = 0
        while true {
            guard let d = devices[mac] else { throw LightCoreError.lightNotFound(Self.anyLightID(mac)) }
            if d.password == nil, d.info.authRequired, let stored = try? await secretStore.string(for: Self.passwordKey(mac: mac)) {
                devices[mac]?.password = stored
            }
            rpcID += 1
            let body = ShellyRPCRequest(id: rpcID, src: configuration.clientID, method: method, params: params).encoded()
            var headers = ["Content-Type": "application/json"]
            let usedChallenge = devices[mac]?.challenge
            if let challenge = usedChallenge, let password = devices[mac]?.password {
                devices[mac]?.nonceCount += 1
                headers["Authorization"] = ShellyDigest.authorization(
                    challenge: challenge, method: "POST", uri: "/rpc", username: devices[mac]?.username ?? ShellyDigest.defaultUser,
                    password: password, cnonce: ShellyDigest.makeCnonce(), nonceCount: devices[mac]?.nonceCount ?? 1
                )
            }
            let request = ShellyHTTPRequest(method: "POST", host: d.host, port: d.port, uri: "/rpc", headers: headers, body: body)
            let response: ShellyHTTPResponse
            do {
                response = try await environment.http.perform(request, timeout: configuration.requestTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transportAttempts -= 1
                if transportAttempts > 0 { continue }
                throw (error as? LightCoreError) ?? LightCoreError.transport(String(describing: error))
            }
            if response.status == 401 {
                guard devices[mac]?.password != nil,
                      let challenge = response.header("WWW-Authenticate").flatMap(ShellyDigestChallenge.init(header:)) else {
                    throw LightCoreError.authenticationRequired(.shelly)
                }
                // A 401 to an answer computed from a fresh challenge = wrong password (unless the nonce went stale).
                authRounds += 1
                if (answeredFreshChallenge && !challenge.stale) || authRounds > 3 { throw LightCoreError.authenticationRequired(.shelly) }
                answeredFreshChallenge = true
                devices[mac]?.challenge = challenge
                devices[mac]?.nonceCount = 0
                if devices[mac]?.info.authRequired == false { devices[mac]?.info.authRequired = true }
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw LightCoreError.protocolError("Shelly \(method) HTTP \(response.status)")
            }
            switch ShellyRPCFrame.parse(response.body) {
            case .result(_, let result):
                devices[mac]?.lastSeen = Date()
                return result
            case .error(_, let code, let message):
                if code == ShellyRPCErrorCode.unauthorized { throw LightCoreError.authenticationRequired(.shelly) }
                throw LightCoreError.protocolError("Shelly \(method) error \(code): \(message)")
            default:
                throw LightCoreError.protocolError("Shelly \(method): unreadable reply")
            }
        }
    }

    // MARK: - HTTP: Gen1 REST with basic auth

    func gen1(_ mac: String, _ request: ShellyGen1Request, retries: Int? = nil) async throws -> ShellyJSON {
        var attempts = 1 + max(0, retries ?? configuration.retries)
        while true {
            guard let d = devices[mac] else { throw LightCoreError.lightNotFound(Self.anyLightID(mac)) }
            if d.password == nil, d.info.authRequired, let stored = try? await secretStore.string(for: Self.passwordKey(mac: mac)) {
                devices[mac]?.password = stored
            }
            var headers: [String: String] = [:]
            if let password = devices[mac]?.password {
                headers["Authorization"] = ShellyDigest.basicAuthorization(username: devices[mac]?.username ?? ShellyDigest.defaultUser, password: password)
            }
            let http = ShellyHTTPRequest(host: d.host, port: d.port, uri: request.uri, headers: headers)
            let response: ShellyHTTPResponse
            do {
                response = try await environment.http.perform(http, timeout: configuration.requestTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempts -= 1
                if attempts > 0 { continue }
                throw (error as? LightCoreError) ?? LightCoreError.transport(String(describing: error))
            }
            if response.status == 401 { throw LightCoreError.authenticationRequired(.shelly) }
            guard (200..<300).contains(response.status), let json = try? ShellyJSON.parse(response.body) else {
                throw LightCoreError.protocolError("Shelly \(request.path) HTTP \(response.status)")
            }
            devices[mac]?.lastSeen = Date()
            return json
        }
    }

    // MARK: - WebSocket notifications (Gen2+)

    private func openSockets() {
        guard configuration.useWebSocket, let open = environment.openWebSocket else { return }
        for d in devices.values where d.paired != nil && d.info.usesRPC && sockets[d.mac] == nil && !opening.contains(d.mac) {
            let mac = d.mac, host = d.host, port = d.port
            opening.insert(mac)
            Task {
                do {
                    let socket = try await open(host, port)
                    await self.attach(socket, to: mac)
                } catch {
                    self.openFailed(mac, error)
                }
            }
        }
    }

    private func openFailed(_ mac: String, _ error: any Error) {
        opening.remove(mac)
        log.debug("Shelly \(mac) WebSocket unavailable, polling: \(error)")
    }

    private func attach(_ socket: any ShellyWebSocket, to mac: String) async {
        opening.remove(mac)
        guard pollTask != nil, sockets[mac] == nil else {
            socket.close()
            return
        }
        rpcID += 1
        let id = rpcID
        let messages = socket.messages
        let task = Task { [weak self] in
            do {
                for try await text in messages {
                    guard let self else { return }
                    await self.received(text, from: mac)
                }
            } catch {}
            await self?.socketEnded(mac)
        }
        sockets[mac] = Socket(socket: socket, task: task, requestID: id)
        emit(.connectionChanged(connected: true, detail: "shelly \(mac) notifications"))
        // Any request registers our `src` for notifications; GetStatus also syncs the state.
        await sendStatusRequest(mac, auth: nil)
    }

    private func sendStatusRequest(_ mac: String, auth: ShellyJSON?) async {
        guard let s = sockets[mac] else { return }
        let frame = ShellyRPCRequest(id: s.requestID, src: configuration.clientID, method: "Shelly.GetStatus", auth: auth)
        do { try await s.socket.send(frame.json.jsonString) } catch { closeSocket(mac) }
    }

    private func received(_ text: String, from mac: String) async {
        guard let frame = ShellyRPCFrame.parse(Data(text.utf8)), devices[mac] != nil else { return }
        let before = lights(of: mac)
        switch frame {
        case .result(let id, let result) where id == sockets[mac]?.requestID:
            if let channels = devices[mac]?.channels { devices[mac]?.statuses = ShellyMapping.statuses(for: channels, rpcStatus: result) }
        case .error(_, ShellyRPCErrorCode.unauthorized, let message):
            guard let challenge = ShellyDigestChallenge(rpcErrorMessage: message), let password = devices[mac]?.password,
                  sockets[mac]?.authSent == false else {
                closeSocket(mac)
                return
            }
            sockets[mac]?.authSent = true
            let auth = ShellyDigest.rpcAuth(challenge: challenge, username: devices[mac]?.username ?? ShellyDigest.defaultUser,
                                            password: password, cnonce: ShellyDigest.makeCnonce(), nonceCount: challenge.nc ?? 1)
            await sendStatusRequest(mac, auth: auth)
            return
        case .notification("NotifyStatus", _, let params), .notification("NotifyFullStatus", _, let params):
            guard let d = devices[mac] else { return }
            for c in d.channels {
                guard let patch = params[c.key] else { continue }
                if let current = d.statuses[c.key] {
                    devices[mac]?.statuses[c.key] = current.merging(rpcPatch: patch)
                } else if let full = ShellyChannelStatus.parseRPC(patch) {
                    devices[mac]?.statuses[c.key] = full
                }
            }
        default:
            return
        }
        devices[mac]?.lastSeen = Date()
        markReachable(mac, true, emit: true)
        emitDiff(before: before, after: lights(of: mac))
    }

    private func socketEnded(_ mac: String) {
        guard sockets[mac] != nil else { return }
        sockets[mac] = nil
        emit(.connectionChanged(connected: false, detail: "shelly \(mac) notifications"))
    }

    private func closeSocket(_ mac: String) {
        guard let s = sockets.removeValue(forKey: mac) else { return }
        s.task.cancel()
        s.socket.close()
        emit(.connectionChanged(connected: false, detail: "shelly \(mac) notifications"))
    }

    // MARK: - Helpers

    private func noteEndpoint(_ info: ShellyDeviceInfo, host: String, port: Int) {
        let mac = info.mac
        if var d = devices[mac] {
            if d.host != host || d.port != port {
                log.info("Shelly \(mac) moved to \(host):\(port)")
                d.host = host
                d.port = port
                if var p = d.paired { p.hostHint = host; p.port = port; d.paired = p }
                devices[mac] = d
                closeSocket(mac)
            }
            devices[mac]?.info = info
        } else {
            devices[mac] = Device(mac: mac, host: host, port: port, info: info, name: info.name)
        }
        devices[mac]?.lastSeen = Date()
    }

    private func emitDiff(before: [Light], after: [Light]) {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for light in after {
            guard let prev = old[light.id] else { emit(.lightAdded(light)); continue }
            if prev.name != light.name || prev.capabilities != light.capabilities {
                emit(.lightUpdated(light))
            } else if !Self.sameState(prev.state, light.state) {
                emit(.stateChanged(light.id, light.state))
            }
        }
        let now = Set(after.map(\.id))
        for id in old.keys where !now.contains(id) { emit(.lightRemoved(id)) }
    }

    private func markReachable(_ mac: String, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[mac], d.reachable != reachable else { return }
        devices[mac]?.reachable = reachable
        guard shouldEmit, d.paired != nil else { return }
        for id in lightIDs(of: d) { emit(.reachabilityChanged(id, reachable: reachable)) }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    private static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    private static func anyLightID(_ mac: String) -> LightID { LightID(brand: .shelly, stableId: mac)! }

    private static func metadata(_ info: ShellyDeviceInfo) -> [String: String] {
        var m: [String: String] = ["gen": String(info.generation), "model": info.model, "auth": info.authRequired ? "true" : "false"]
        if let app = info.app { m["app"] = app }
        if let id = info.deviceID { m["deviceID"] = id }
        if let domain = info.authDomain { m["authDomain"] = domain }
        if let fw = info.firmware { m["firmware"] = fw }
        return m
    }

    /// `"192.168.1.20"` or `"192.168.1.20:8080"` -> host + port.
    static func parseHost(_ spec: String, defaultPort: Int) -> (String, Int)? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        if parts.count == 1 { return (trimmed, defaultPort) }
        return nil
    }
}

/// Thread-safe "first time seen" set for discovery de-duplication.
private actor SeenSet {
    private var ids: Set<String> = []
    func insert(_ id: String) -> Bool { ids.insert(id).inserted }
    var count: Int { ids.count }
}
