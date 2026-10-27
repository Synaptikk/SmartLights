import Foundation
import LightCore
import NetKit
import TPLinkCodec

/// TP-Link Kasa and Tapo lights over the LAN.
///
/// - **Legacy Kasa** (KL1xx, LB1xx, KL4xx strips on old firmware): XOR JSON over TCP 9999, no
///   credentials.
/// - **KLAP** (all Tapo, newer Kasa firmware): HTTP :80, handshake with the TP-Link account email +
///   password (case-sensitive), AES-128-CBC session. Tapo speaks SMART JSON, Kasa IOT JSON.
/// - Devices are keyed by MAC (`tplink:<12 hex>`; the device id when no MAC is known); IPs are hints
///   refreshed by discovery.
/// - Discovery: UDP 9999 + 20002 broadcast when the multicast entitlement is present, else a unicast
///   sweep of the Wi-Fi /24 with the same datagrams, plus cached/manual hosts (UDP probe, then TCP
///   9999 sysinfo, then a KLAP handshake1 probe).
/// - One `TPLinkDeviceClient` per device serialises requests and re-handshakes on 403 / 9999.
/// - No push protocol: `start()` polls every `pollInterval` (10 s).
public actor TPLinkProvider: LightProvider {
    public static let brand: Brand = .tplink
    public static let accountID = "tplink-account"
    /// Keychain items for the TP-Link account (KLAP needs the plain values to derive v1 and v2 hashes).
    public static let usernameKey = SecretKey(brand: .tplink, owner: "account", item: "username")
    public static let passwordKey = SecretKey(brand: .tplink, owner: "account", item: "password")

    public struct Configuration: Sendable {
        /// Per request (TCP connect + answer, each KLAP HTTP call).
        public var requestTimeout: Duration
        /// Unicast discovery probes (UDP, TCP 9999, KLAP handshake1) during sweeps and Add by IP.
        public var probeTimeout: Duration
        public var sweepConcurrency: Int
        public var pollInterval: Duration
        /// Broadcast rounds during discovery (datagrams get lost).
        public var broadcastRounds: Int
        /// TCP port of the legacy protocol (9999; tests use a loopback port).
        public var legacyPort: UInt16
        /// HTTP port used for KLAP when discovery did not say (80).
        public var klapPort: UInt16
        /// UDP discovery ports (legacy, new).
        public var legacyDiscoveryPort: UInt16
        public var discoveryPort: UInt16
        /// Also send python-kasa's keyed 20002 probe (`{"params":{"rsa_key":...}}`, 2048-bit key
        /// generated once). Some firmware ignores the bare header.
        public var keyedDiscoveryProbe: Bool

        public init(
            requestTimeout: Duration = .seconds(5),
            probeTimeout: Duration = .milliseconds(800),
            sweepConcurrency: Int = 32,
            pollInterval: Duration = .seconds(10),
            broadcastRounds: Int = 3,
            legacyPort: UInt16 = TPLinkXOR.port,
            klapPort: UInt16 = TPLinkKLAP.defaultPort,
            legacyDiscoveryPort: UInt16 = TPLinkDiscovery.legacyPort,
            discoveryPort: UInt16 = TPLinkDiscovery.port,
            keyedDiscoveryProbe: Bool = true
        ) {
            self.requestTimeout = requestTimeout
            self.probeTimeout = probeTimeout
            self.sweepConcurrency = sweepConcurrency
            self.pollInterval = pollInterval
            self.broadcastRounds = broadcastRounds
            self.legacyPort = legacyPort
            self.klapPort = klapPort
            self.legacyDiscoveryPort = legacyDiscoveryPort
            self.discoveryPort = discoveryPort
            self.keyedDiscoveryProbe = keyedDiscoveryProbe
        }
    }

    struct Device {
        var stableID: String
        var host: String
        var connection: TPLinkConnection
        var model: String?
        var name: String?
        var deviceID: String?
        var mac: String?
        var firmware: String?
        var isStrip = false
        var capabilities: LightCapabilities?
        var state: LightState?
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?
        var client: TPLinkDeviceClient?
    }

    /// What one state read returns.
    struct Snapshot {
        var stableID: String?
        var name: String?
        var model: String?
        var deviceID: String?
        var mac: String?
        var firmware: String?
        var isStrip: Bool
        var capabilities: LightCapabilities
        var state: LightState
        var connection: TPLinkConnection
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: TPLinkNetworkEnvironment
    private let secretStore: any SecretStore
    private let terminalUUID = TPLinkSmart.makeTerminalUUID()
    private let log = Log(package: "tplinkkit", category: "provider")

    private var devices: [String: Device] = [:]
    private var credentials: TPLinkCredentials?
    private var credentialsLoaded = false
    private var reauthAnnounced = false
    private var pollTask: Task<Void, Never>?
    private var probeKeyPayload: Data??

    public init(
        configuration: Configuration = Configuration(),
        environment: TPLinkNetworkEnvironment = TPLinkNetworkEnvironment(),
        secretStore: any SecretStore = InMemorySecretStore()
    ) {
        self.configuration = configuration
        self.environment = environment
        self.secretStore = secretStore
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Polls paired lights every `configuration.pollInterval` (TP-Link has no push). Idempotent.
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
        for p in paired where p.brand == .tplink {
            guard let host = p.hostHint else { continue }
            var connection = p.metadata["connection"].flatMap(TPLinkConnection.init(descriptor:)) ?? .legacy
            if connection.transport == .xor { connection.port = configuration.legacyPort }
            var d = devices[p.id] ?? Device(stableID: p.id, host: host, connection: connection)
            d.host = host
            d.connection = connection
            d.model = d.model ?? p.model
            d.name = d.name ?? p.name
            d.deviceID = d.deviceID ?? p.metadata["deviceId"]
            d.mac = d.mac ?? p.metadata["mac"]
            d.firmware = d.firmware ?? p.metadata["firmware"]
            d.isStrip = p.metadata["strip"] == "true"
            d.paired = p
            d.client = nil
            devices[p.id] = d
        }
    }

    /// Stable ids of paired devices (diagnostics/tests).
    public var pairedIDs: [String] { devices.values.filter { $0.paired != nil }.map(\.stableID).sorted() }

    /// Cached `host:port` and connection of a light (diagnostics/tests).
    public func endpoint(of id: LightID) -> String? {
        guard let sid = TPLinkMapping.stableID(of: id), let d = devices[sid] else { return nil }
        return "\(d.host):\(d.connection.port)"
    }

    public func connection(of id: LightID) -> TPLinkConnection? {
        TPLinkMapping.stableID(of: id).flatMap { devices[$0]?.connection }
    }

    // MARK: - Account (KLAP credentials)

    public var account: ProviderAccount? {
        guard let credentials else { return nil }
        return Self.makeAccount(credentials.username)
    }

    /// Loads stored credentials from the `SecretStore` (call once at launch; also done lazily).
    public func loadAccount() async {
        credentialsLoaded = true
        let username = try? await secretStore.string(for: Self.usernameKey)
        let password = try? await secretStore.string(for: Self.passwordKey)
        if let username, let password, !username.isEmpty {
            credentials = TPLinkCredentials(username: username, password: password)
        } else {
            credentials = nil
        }
    }

    /// Stores the TP-Link account (Keychain) and drops every KLAP session so the next request
    /// handshakes with it. The values are used exactly as given (both are case-sensitive).
    public func setCredentials(_ new: TPLinkCredentials?) async throws {
        credentialsLoaded = true
        if let new {
            try await secretStore.set(new.username, for: Self.usernameKey)
            try await secretStore.set(new.password, for: Self.passwordKey)
        } else {
            try await secretStore.remove(Self.usernameKey)
            try await secretStore.remove(Self.passwordKey)
        }
        credentials = new
        reauthAnnounced = false
        for id in devices.keys { devices[id]?.client = nil }
        log.info("TP-Link account \(new == nil ? "removed" : "stored") (\(Log.redact(new?.password)))")
    }

    /// Asks for the account (onboarding §8, re-authentication) and stores it.
    public func configureAccount(using ui: any PairingInteraction) async throws {
        try await setCredentials(try await Self.askCredentials(ui))
    }

    static let emailPrompt = "TP-Link account email (the one you use in the Tapo or Kasa app). It is case-sensitive: type it exactly as you registered it."
    static let passwordPrompt = "TP-Link account password (case-sensitive)"
    static let rejectedPrompt = "The light did not accept that email and password. Both are case-sensitive, so use the email exactly as you registered it. "
        + "Some firmware also needs Tapo app > Me > Tapo Lab > Third-Party Compatibility turned on. Try again?"

    static func askCredentials(_ ui: any PairingInteraction) async throws -> TPLinkCredentials {
        let username = try await ui.text(emailPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let password = try await ui.secureText(passwordPrompt)
        guard !username.isEmpty, !password.isEmpty else { throw LightCoreError.userCancelled }
        return TPLinkCredentials(username: username, password: password)
    }

    private static func makeAccount(_ username: String) -> ProviderAccount {
        ProviderAccount(id: accountID, brand: .tplink, displayName: maskedEmail(username), secretKeys: [usernameKey, passwordKey])
    }

    /// `jane.doe@example.com` -> `j***@example.com`.
    static func maskedEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return "TP-Link account" }
        return "\(email[email.startIndex])***\(email[at...])"
    }

    private func ensureCredentialsLoaded() async {
        if !credentialsLoaded { await loadAccount() }
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
        let report: @Sendable (DiscoveredDevice?) async -> Void = { device in
            guard let device, await seen.insert(device.id) else { return }
            continuation.yield(device)
        }
        let methods = options.methods
        let datagrams = environment.datagrams
        let probes = await discoveryProbes()
        let useBroadcast = datagrams != nil && options.broadcastAvailable && methods.contains(.broadcast)
        let sweepHosts = datagrams != nil && !useBroadcast && methods.contains(.sweep) ? environment.sweepHosts() : []
        let addresses = useBroadcast ? environment.broadcastAddresses() : []
        var direct: [(String, DiscoveryMethod)] = []
        if methods.contains(.cached) {
            direct += options.cachedHosts.map { ($0, .cached) }
            direct += devices.values.map { ($0.host, .cached) }
        }
        if methods.contains(.manual) { direct += options.manualHosts.map { ($0, .manual) } }
        let directHosts: [(String, DiscoveryMethod)] = direct.compactMap { entry in
            Self.parseHost(entry.0).map { ($0, entry.1) }
        }
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)
        let probeTimeout = configuration.probeTimeout
        let rounds = configuration.broadcastRounds

        await withTaskGroup(of: Void.self) { group in
            if useBroadcast, let datagrams, !addresses.isEmpty {
                group.addTask {
                    for await answer in datagrams.broadcast(probes, to: addresses, rounds: rounds, listen: options.timeout) {
                        await report(await self.handleAnswer(answer, method: .broadcast))
                    }
                }
            } else if let datagrams, !sweepHosts.isEmpty {
                group.addTask {
                    let results = sweeper.stream(sweepHosts) { host -> [TPLinkDatagram]? in
                        let answers = await datagrams.probe(probes, host: host.description, timeout: probeTimeout)
                        return answers.isEmpty ? nil : answers
                    }
                    for await answers in results {
                        await report(await self.handleAnswers(answers, method: .sweep))
                    }
                }
            }
            for (host, method) in directHosts {
                group.addTask { await report(await self.identify(host: host, method: method)) }
            }
        }
    }

    /// The datagrams sent to each host/broadcast address.
    private func discoveryProbes() async -> [TPLinkProbe] {
        var probes = [
            TPLinkProbe(payload: TPLinkDiscovery.legacyQuery, port: configuration.legacyDiscoveryPort),
            TPLinkProbe(payload: TPLinkDiscovery.query(), port: configuration.discoveryPort),
        ]
        if configuration.keyedDiscoveryProbe {
            if probeKeyPayload == nil {
                let pem = try? await PosixSocket.onThread { try TPLinkDiscovery.makeProbeKeyPEM() }
                probeKeyPayload = .some(pem.map { TPLinkDiscovery.query(payload: TPLinkDiscovery.rsaKeyPayload(publicKeyPEM: $0), serial: UInt32.random(in: 1...UInt32.max), flags: 17) })
            }
            if let keyed = probeKeyPayload ?? nil { probes.append(TPLinkProbe(payload: keyed, port: configuration.discoveryPort)) }
        }
        return probes
    }

    private func handleAnswers(_ answers: [TPLinkDatagram], method: DiscoveryMethod) -> DiscoveredDevice? {
        // Prefer the 20002 answer: it names the transport (a KLAP Kasa may still answer 9999).
        let legacyPort = configuration.legacyDiscoveryPort
        let ordered = answers.filter { $0.port != legacyPort } + answers.filter { $0.port == legacyPort }
        for answer in ordered {
            if let device = handleAnswer(answer, method: method) { return device }
        }
        return nil
    }

    private func handleAnswer(_ answer: TPLinkDatagram, method: DiscoveryMethod) -> DiscoveredDevice? {
        let legacy = answer.port == configuration.legacyDiscoveryPort
        let parsed: TPLinkDiscoveryResult?
        if legacy {
            parsed = try? TPLinkDiscovery.parseLegacy(answer.data, host: answer.host)
        } else {
            parsed = try? TPLinkDiscovery.parseNew(answer.data, host: answer.host)
        }
        guard var result = parsed else {
            log.debug("unparsable discovery answer from \(answer.host):\(answer.port)")
            return nil
        }
        if legacy { result.host = answer.host }
        return discovered(result, method: method)
    }

    /// Unicast identification of one host (Add by IP, cached hints).
    private func identify(host: String, method: DiscoveryMethod) async -> DiscoveredDevice? {
        if let datagrams = environment.datagrams {
            let answers = await datagrams.probe(await discoveryProbes(), host: host, timeout: configuration.probeTimeout)
            if let device = handleAnswers(answers, method: method) { return device }
        }
        if let info = try? await legacySysinfo(host: host, timeout: configuration.probeTimeout) {
            let result = TPLinkDiscoveryResult(host: host, deviceID: info.deviceID, mac: info.mac, model: info.model, deviceType: info.type,
                                               name: info.alias, connection: .legacy, firmware: info.firmware, sysinfo: info)
            return discovered(result, method: method)
        }
        if await TPLinkDeviceClient.probeKLAP(host: host, port: configuration.klapPort, environment: environment, timeout: configuration.probeTimeout) {
            var connection = TPLinkConnection.tapo
            connection.port = configuration.klapPort
            return DiscoveredDevice(
                id: "ip:\(host)",
                brand: .tplink,
                name: "TP-Link light at \(host)",
                host: host,
                port: Int(connection.port),
                method: method,
                metadata: ["connection": connection.descriptor, "needsCredentials": "true"]
            )
        }
        return nil
    }

    private func discovered(_ r: TPLinkDiscoveryResult, method: DiscoveryMethod) -> DiscoveredDevice? {
        guard r.isLight else {
            log.debug("skipping non-light TP-Link device \(r.model ?? "?") at \(r.host)")
            return nil
        }
        var metadata: [String: String] = [:]
        var port: Int?
        if var connection = r.connection {
            if connection.transport == .xor { connection.port = configuration.legacyPort }
            metadata["connection"] = connection.descriptor
            metadata["needsCredentials"] = connection.needsCredentials ? "true" : "false"
            if !connection.isSupported { metadata["unsupported"] = Self.unsupportedReason(connection) }
            port = Int(connection.port)
        }
        if let v = r.deviceID { metadata["deviceId"] = v }
        if let v = r.deviceType { metadata["deviceType"] = v }
        if let v = r.firmware { metadata["firmware"] = v }
        let stable = r.stableID
        if let stable { noteHost(stable, host: r.host) }
        let info = r.model.flatMap(TPLinkModelTable.lookup)
        return DiscoveredDevice(
            id: stable ?? "ip:\(r.host)",
            brand: .tplink,
            name: r.name ?? info?.name ?? "TP-Link \(r.model ?? "light")",
            model: r.model,
            host: r.host,
            port: port,
            macAddress: TPLinkIdentity.normalizedMAC(r.mac).map(TPLinkIdentity.displayMAC),
            method: method,
            metadata: metadata
        )
    }

    static func unsupportedReason(_ connection: TPLinkConnection) -> String {
        switch connection.transport {
        case .aes: TPLinkDeviceClient.aesMessage
        case .klap: "This device only offers HTTPS KLAP, which SmartLights does not support yet."
        case .xor: ""
        }
    }

    // MARK: - LightProvider: pairing

    /// Legacy Kasa needs no credentials. KLAP devices (Tapo, new Kasa) need the TP-Link account:
    /// stored credentials are tried first (devices never bound to a cloud account also accept the
    /// blank/default ones); on rejection the user is asked for email + password (case-sensitive).
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .tplink else { throw LightCoreError.unsupported("\(device.name) is not a TP-Link device") }
        await ensureCredentialsLoaded()
        var hostSpec = device.host
        if hostSpec?.isEmpty ?? true {
            hostSpec = try await ui.text("IP address of the TP-Link light (Tapo or Kasa app > the light > Settings > Device Info)")
        }
        guard let host = hostSpec.flatMap(Self.parseHost) else {
            throw LightCoreError.unreachable("no IPv4 address for \(device.name)")
        }
        var advertised = device.metadata["connection"].flatMap(TPLinkConnection.init(descriptor:))
        if advertised == nil {
            await ui.status("Contacting \(host)...")
            guard let found = await identify(host: host, method: .manual),
                  let c = found.metadata["connection"].flatMap(TPLinkConnection.init(descriptor:)) else {
                throw LightCoreError.unreachable("No TP-Link light answered at \(host)")
            }
            advertised = c
        }
        guard var connection = advertised else { throw LightCoreError.unreachable(host) }
        if connection.transport == .xor { connection.port = configuration.legacyPort }
        guard connection.isSupported else { throw LightCoreError.unsupported(Self.unsupportedReason(connection)) }

        let fetched: (Snapshot, TPLinkDeviceClient)
        if connection.needsCredentials {
            fetched = try await pairKLAP(host: host, connection: connection, ui: ui)
        } else {
            do {
                fetched = try await fetch(host: host, connection: connection, credentials: nil)
            } catch LightCoreError.unreachable(let why) {
                // Kasa firmware that moved to KLAP stops listening on 9999.
                guard await TPLinkDeviceClient.probeKLAP(host: host, port: configuration.klapPort, environment: environment,
                                                         timeout: configuration.probeTimeout) else {
                    throw LightCoreError.unreachable(why)
                }
                var klap = TPLinkConnection.tapo
                klap.port = configuration.klapPort
                fetched = try await pairKLAP(host: host, connection: klap, ui: ui)
            }
        }
        let (snapshot, client) = fetched
        guard let stableID = snapshot.stableID ?? TPLinkIdentity.stableID(mac: device.macAddress, deviceID: device.metadata["deviceId"]) else {
            throw LightCoreError.protocolError("\(host) reported neither a MAC nor a device id")
        }
        var d = devices[stableID] ?? Device(stableID: stableID, host: host, connection: snapshot.connection)
        d.host = host
        d.connection = snapshot.connection
        d.client = client
        apply(snapshot, to: &d)
        d.lastSeen = Date()
        d.reachable = true
        var metadata: [String: String] = ["connection": d.connection.descriptor]
        if let v = d.deviceID { metadata["deviceId"] = v }
        if let v = d.mac { metadata["mac"] = v }
        if let v = d.firmware { metadata["firmware"] = v }
        if d.isStrip { metadata["strip"] = "true" }
        let paired = PairedDevice(
            id: stableID,
            brand: .tplink,
            name: d.name ?? device.name,
            model: d.model,
            hostHint: host,
            port: Int(d.connection.port),
            accountID: d.connection.needsCredentials && credentials != nil ? Self.accountID : nil,
            lightIDs: [TPLinkMapping.lightID(stableID)],
            metadata: metadata,
            lastSeen: d.lastSeen
        )
        d.paired = paired
        devices[stableID] = d
        if let light = light(for: stableID) { emit(.lightAdded(light)) }
        return paired
    }

    private func pairKLAP(host: String, connection: TPLinkConnection, ui: any PairingInteraction) async throws -> (Snapshot, TPLinkDeviceClient) {
        var creds = credentials
        var entered = false
        for attempt in 0..<4 {
            do {
                if attempt == 0 { await ui.status("Signing in to the light at \(host)...") }
                let result = try await fetch(host: host, connection: connection, credentials: creds)
                if entered, let creds { try await setCredentials(creds) }
                return result
            } catch TPLinkClientError.authentication(let why) {
                log.notice("pairing \(host): \(why)")
                if attempt == 3 { break }
                if entered || creds != nil {
                    guard try await ui.confirm(Self.rejectedPrompt) else { break }
                }
                creds = try await Self.askCredentials(ui)
                entered = true
            } catch TPLinkClientError.unsupported(let why) {
                throw LightCoreError.unsupported(why)
            }
        }
        throw LightCoreError.authenticationRequired(.tplink)
    }

    /// Opens a client and reads the device (get_device_info or get_sysinfo).
    private func fetch(host: String, connection: TPLinkConnection, credentials: TPLinkCredentials?) async throws -> (Snapshot, TPLinkDeviceClient) {
        let client = TPLinkDeviceClient(host: host, connection: connection, environment: environment, timeout: configuration.requestTimeout,
                                        credentials: connection.needsCredentials ? credentials : nil, terminalUUID: terminalUUID)
        return (try await read(client), client)
    }

    /// One state read through `client`. A KLAP device whose family was guessed wrong (Add by IP)
    /// is retried with the other JSON dialect.
    private func read(_ client: TPLinkDeviceClient) async throws -> Snapshot {
        let connection = await client.connection
        if connection.family == .smart, connection.transport == .klap {
            do {
                return try await readSmart(client)
            } catch let error as TPLinkCodecError {
                log.info("\(client.host): SMART read failed (\(error)); trying IOT")
            } catch LightCoreError.protocolError(let why) {
                log.info("\(client.host): SMART read failed (\(why)); trying IOT")
            }
            return try await readIOT(client)
        }
        if connection.family == .iot { return try await readIOT(client) }
        return try await readSmart(client)
    }

    private func readSmart(_ client: TPLinkDeviceClient) async throws -> Snapshot {
        let info = try TPLinkSmartDeviceInfo(try await client.smart("get_device_info"))
        var capabilities = TPLinkMapping.capabilities(info: info)
        if capabilities.supportedColorModes == [.onOff], let model = info.model {
            capabilities = TPLinkMapping.capabilities(model: model, family: .smart)
        }
        var connection = await client.connection
        connection.family = .smart
        return Snapshot(
            stableID: TPLinkIdentity.stableID(mac: info.mac, deviceID: info.deviceID),
            name: info.nickname,
            model: info.model,
            deviceID: info.deviceID,
            mac: info.mac,
            firmware: info.firmware,
            isStrip: info.model.flatMap(TPLinkModelTable.lookup)?.isStrip ?? false,
            capabilities: capabilities,
            state: TPLinkMapping.state(smart: info, capabilities: capabilities),
            connection: connection
        )
    }

    private func readIOT(_ client: TPLinkDeviceClient) async throws -> Snapshot {
        let response = try await client.iot(TPLinkIOT.getSysinfo)
        let info = try TPLinkIOTSysInfo(TPLinkIOT.result(of: response, target: TPLinkIOT.systemTarget, command: "get_sysinfo"))
        guard let lightState = info.lightState else {
            throw LightCoreError.unsupported("\(info.model ?? "This TP-Link device") is not a light")
        }
        let capabilities = TPLinkMapping.capabilities(sysinfo: info)
        var connection = await client.connection
        connection.family = .iot
        var state = TPLinkMapping.state(iot: lightState, capabilities: capabilities)
        if info.effectActive { state.effect = info.effectName }
        return Snapshot(
            stableID: TPLinkIdentity.stableID(mac: info.mac, deviceID: info.deviceID),
            name: info.alias,
            model: info.model,
            deviceID: info.deviceID,
            mac: info.mac,
            firmware: info.firmware,
            isStrip: info.isStrip,
            capabilities: capabilities,
            state: state,
            connection: connection
        )
    }

    /// TCP 9999 `get_sysinfo` (identification of a host).
    private func legacySysinfo(host: String, timeout: Duration) async throws -> TPLinkIOTSysInfo {
        let answer = try await environment.stream.exchange(TPLinkXOR.frame(TPLinkIOT.getSysinfo), host: host,
                                                           port: configuration.legacyPort, timeout: timeout)
        let json = try TPLinkJSON.parse(TPLinkXOR.unframe(answer))
        return try TPLinkIOTSysInfo(TPLinkIOT.result(of: json, target: TPLinkIOT.systemTarget, command: "get_sysinfo"))
    }

    private func apply(_ s: Snapshot, to d: inout Device) {
        if let n = s.name, !n.isEmpty { d.name = n }
        d.model = s.model ?? d.model
        d.deviceID = s.deviceID ?? d.deviceID
        d.mac = s.mac ?? d.mac
        d.firmware = s.firmware ?? d.firmware
        d.isStrip = s.isStrip
        d.capabilities = s.capabilities
        d.state = s.state
        d.connection = s.connection
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        await ensureCredentialsLoaded()
        let ids = pairedIDs
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refresh(id, emitChanges: false) } }
        }
        return ids.compactMap(light(for:))
    }

    /// One polling round over every paired light; emits changes.
    public func pollOnce() async {
        await ensureCredentialsLoaded()
        let ids = pairedIDs
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refresh(id, emitChanges: true) } }
        }
    }

    private func refresh(_ id: String, emitChanges: Bool) async {
        guard devices[id] != nil else { return }
        let old = light(for: id)
        do {
            let snapshot = try await read(client(for: id))
            guard var d = devices[id] else { return }
            apply(snapshot, to: &d)
            d.lastSeen = Date()
            devices[id] = d
            markReachable(id, true, emit: emitChanges)
        } catch {
            _ = mapError(error, id: id)
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

    private func client(for id: String) -> TPLinkDeviceClient {
        if let c = devices[id]?.client { return c }
        let d = devices[id]!
        let c = TPLinkDeviceClient(host: d.host, connection: d.connection, environment: environment, timeout: configuration.requestTimeout,
                                   credentials: d.connection.needsCredentials ? credentials : nil, terminalUUID: terminalUUID)
        devices[id]?.client = c
        return c
    }

    private func light(for id: String) -> Light? {
        guard let d = devices[id] else { return nil }
        let capabilities = d.capabilities ?? TPLinkMapping.capabilities(model: d.model, family: d.connection.family)
        var state = d.state ?? LightState(reachable: false)
        state.reachable = d.reachable && d.state != nil
        return Light(
            id: TPLinkMapping.lightID(id),
            name: d.name ?? d.paired?.name ?? d.model.flatMap(TPLinkModelTable.lookup)?.name ?? "TP-Link light",
            capabilities: capabilities,
            state: state,
            providerRef: "\(d.host):\(d.connection.port)",
            manufacturer: "TP-Link",
            model: d.model
        )
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to id: LightID) async throws {
        guard let sid = TPLinkMapping.stableID(of: id), devices[sid] != nil else { throw LightCoreError.lightNotFound(id) }
        if command.isEmpty { return }
        await ensureCredentialsLoaded()
        do {
            if devices[sid]?.state == nil || devices[sid]?.capabilities == nil {
                let snapshot = try await read(client(for: sid))
                if var d = devices[sid] {
                    apply(snapshot, to: &d)
                    devices[sid] = d
                }
            }
            guard let d = devices[sid], let capabilities = d.capabilities, let current = d.state else {
                throw LightCoreError.unreachable(id.rawValue)
            }
            let plan = TPLinkMapping.plan(command, capabilities: capabilities, isOn: current.isOn)
            if plan.isEmpty { return }
            let client = client(for: sid)
            var next = TPLinkMapping.apply(plan, to: current)
            switch d.connection.family {
            case .iot:
                let target = d.isStrip ? TPLinkIOT.stripService : TPLinkIOT.bulbService
                let commandName = d.isStrip ? TPLinkIOT.stripSetCommand : TPLinkIOT.bulbSetCommand
                let response = try await client.iot(TPLinkIOT.setLightState(plan.iotPatch, strip: d.isStrip))
                let result = try TPLinkIOT.result(of: response, target: target, command: commandName)
                // Bulbs answer with the resulting light_state; use it when present.
                if result["on_off"] != nil, let ls = try? TPLinkIOTLightState(result) {
                    next = TPLinkMapping.state(iot: ls, capabilities: capabilities)
                }
            case .smart:
                _ = try await client.smart("set_device_info", params: plan.smartParams)
            }
            devices[sid]?.state = next
            devices[sid]?.lastSeen = Date()
            markReachable(sid, true, emit: true)
            if let light = light(for: sid) { emit(.stateChanged(light.id, light.state)) }
        } catch {
            throw mapError(error, id: sid)
        }
    }

    /// Concurrent fan-out (each device has its own connection).
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

    // MARK: - Helpers

    /// Maps transport/codec errors to `LightCoreError`, marks reachability and announces
    /// re-authentication once per credential change.
    private func mapError(_ error: any Error, id: String) -> any Error {
        if let e = error as? TPLinkClientError {
            switch e {
            case .authentication(let why):
                log.notice("\(id): \(why)")
                devices[id]?.client = nil
                if !reauthAnnounced {
                    reauthAnnounced = true
                    emit(.needsReauthentication(accountID: Self.accountID))
                }
                return LightCoreError.authenticationRequired(.tplink)
            case .unsupported(let why):
                return LightCoreError.unsupported(why)
            }
        }
        if let e = error as? TPLinkCodecError {
            return LightCoreError.protocolError(e.description)
        }
        if let e = error as? LightCoreError {
            switch e {
            case .timeout, .unreachable, .transport:
                devices[id]?.client = nil
                markReachable(id, false, emit: true)
                let name = devices[id]?.name ?? id
                return LightCoreError.unreachable("TP-Link light \(name) did not answer")
            default:
                return e
            }
        }
        return error
    }

    private func noteHost(_ id: String, host: String) {
        guard devices[id] != nil, devices[id]?.host != host, IPv4Addr(host) != nil else { return }
        log.info("TP-Link \(id) moved to \(host)")
        devices[id]?.host = host
        devices[id]?.client = nil
        if var p = devices[id]?.paired {
            p.hostHint = host
            devices[id]?.paired = p
        }
    }

    private func markReachable(_ id: String, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[id], d.reachable != reachable else { return }
        devices[id]?.reachable = reachable
        if shouldEmit, d.paired != nil { emit(.reachabilityChanged(TPLinkMapping.lightID(id), reachable: reachable)) }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    private static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    /// `"192.168.1.20"` (an optional `:port` is ignored: ports come from discovery/configuration).
    static func parseHost(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
        return IPv4Addr(host) != nil || host == "localhost" ? host : nil
    }
}

/// Thread-safe "first time seen" set for discovery de-duplication.
private actor SeenSet {
    private var ids: Set<String> = []
    func insert(_ id: String) -> Bool { ids.insert(id).inserted }
}
