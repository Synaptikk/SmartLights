import Foundation
import LIFXCodec
import LightCore
import NetKit

/// LIFX over the LAN protocol (binary UDP 56700, no authentication).
///
/// - Devices are keyed by serial (MAC, `lifx:d073d5xxxxxx`); IPs are cached hints refreshed from
///   every reply.
/// - One UDP socket; replies are matched by `source` + `sequence`. Each request waits
///   `requestTimeout` (1 s) and is retried `retries` (3) times; per-device rate limit 20 msg/s.
/// - Discovery: Bonjour `_lifx._udp`, broadcast `GetService` when allowed, else a unicast sweep
///   of the Wi-Fi /24, plus cached and manual hosts.
/// - No push protocol: `start()` polls every paired light every `pollInterval` (10 s).
public actor LIFXProvider: LightProvider {
    public static let brand: Brand = .lifx
    /// LIFX LAN UDP port.
    public static let defaultPort: UInt16 = 56700
    /// Keychain item for the optional LIFX cloud token (cloud.lifx.com/settings).
    public static let cloudTokenKey = SecretKey(brand: .lifx, owner: "cloud", item: "accessToken")

    public struct Configuration: Sendable {
        /// Destination port for broadcasts, sweeps and hosts given without a port.
        public var port: UInt16
        public var requestTimeout: Duration
        /// Extra attempts after the first one.
        public var retries: Int
        /// Per-host timeout during the unicast sweep (single attempt).
        public var sweepTimeout: Duration
        public var sweepConcurrency: Int
        /// Polling period while `start()`ed.
        public var pollInterval: Duration
        /// Per-device rate limit (LIFX recommends at most 20 messages per second per device).
        public var messagesPerSecond: Int
        /// Client id echoed in replies. Values 0 and 1 are avoided (some firmware treats them specially).
        public var source: UInt32

        public init(
            port: UInt16 = LIFXProvider.defaultPort,
            requestTimeout: Duration = .seconds(1),
            retries: Int = 3,
            sweepTimeout: Duration = .milliseconds(500),
            sweepConcurrency: Int = 32,
            pollInterval: Duration = .seconds(10),
            messagesPerSecond: Int = 20,
            source: UInt32 = UInt32.random(in: 2...UInt32.max)
        ) {
            self.port = port
            self.requestTimeout = requestTimeout
            self.retries = retries
            self.sweepTimeout = sweepTimeout
            self.sweepConcurrency = sweepConcurrency
            self.pollInterval = pollInterval
            self.messagesPerSecond = messagesPerSecond
            self.source = source
        }
    }

    /// A reply with the address it came from.
    public struct Reply: Sendable {
        public var packet: LIFXPacket
        public var host: String
        public var port: UInt16
    }

    struct Device {
        var serial: LIFXSerial
        var host: String
        var port: UInt16
        var label: String?
        var vendor: UInt32?
        var productID: UInt32?
        var firmware: LIFXFirmwareVersion?
        var color: HSBK?
        var power: UInt16?
        var reachable = true
        var lastSeen: Date?
        var paired: PairedDevice?

        var product: LIFXProduct? {
            guard let productID else { return nil }
            return LIFXProduct.lookup(vendor: vendor ?? 1, product: productID).resolved(firmware: firmware)
        }
    }

    private struct Waiter {
        var token: UInt64
        var host: String?
        var expects: Set<UInt16>
        var continuation: CheckedContinuation<Reply, any Error>
        var timer: Task<Void, Never>?
    }

    private enum RequestError: Error { case timedOut }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    public nonisolated let configuration: Configuration
    private let environment: LIFXNetworkEnvironment
    private let secretStore: any SecretStore
    private let limiter: RateLimiter<String>
    private let log = Log(package: "lifxkit", category: "provider")

    private var transport: (any LIFXTransport)?
    private var receiveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var sequence: UInt8 = 0
    private var nextToken: UInt64 = 0
    private var waiters: [UInt8: Waiter] = [:]
    private var collectors: [UInt8: AsyncStream<Reply>.Continuation] = [:]
    private var devices: [LIFXSerial: Device] = [:]
    private var cloudAccount: ProviderAccount?

    public init(
        configuration: Configuration = Configuration(),
        environment: LIFXNetworkEnvironment,
        secretStore: any SecretStore = InMemorySecretStore()
    ) {
        self.configuration = configuration
        self.environment = environment
        self.secretStore = secretStore
        self.limiter = RateLimiter(.init(max(1, configuration.messagesPerSecond), per: .seconds(1)))
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        receiveTask?.cancel()
        transport?.close()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts polling paired lights every `configuration.pollInterval` (LIFX has no push).
    /// Idempotent.
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

    /// Closes the socket and stops polling. Pending requests fail.
    public func shutdown() {
        stop()
        receiveTask?.cancel()
        receiveTask = nil
        transport?.close()
        transport = nil
        for (_, w) in waiters {
            w.timer?.cancel()
            w.continuation.resume(throwing: LightCoreError.transport("LIFX provider shut down"))
        }
        waiters.removeAll()
        for (_, c) in collectors { c.finish() }
        collectors.removeAll()
    }

    /// Re-registers devices persisted by the app (`DeviceStore`) without touching the network.
    public func restore(_ paired: [PairedDevice]) {
        for p in paired where p.brand == .lifx {
            guard let serial = LIFXSerial(p.id), let host = p.hostHint else { continue }
            var d = devices[serial] ?? Device(serial: serial, host: host, port: UInt16(clamping: p.port ?? Int(configuration.port)))
            d.host = host
            if let port = p.port { d.port = UInt16(clamping: port) }
            d.label = d.label ?? p.name
            d.vendor = d.vendor ?? p.metadata["vendor"].flatMap { UInt32($0) }
            d.productID = d.productID ?? p.metadata["product"].flatMap { UInt32($0) }
            d.firmware = d.firmware ?? p.metadata["firmware"].flatMap(LIFXFirmwareVersion.init)
            d.paired = p
            devices[serial] = d
        }
    }

    /// Serials of paired devices (diagnostics/tests).
    public var pairedSerials: [LIFXSerial] { devices.values.filter { $0.paired != nil }.map(\.serial).sorted() }

    /// Cached `host:port` for a light (diagnostics/tests).
    public func endpoint(of id: LightID) -> String? {
        guard let serial = LIFXMapping.serial(of: id), let d = devices[serial] else { return nil }
        return "\(d.host):\(d.port)"
    }

    // MARK: - Cloud token (optional)

    /// The cloud account, present once a LIFX cloud token is stored.
    public var account: ProviderAccount? { cloudAccount }

    /// Loads the cloud account reference if a token is in the `SecretStore`.
    public func loadCloudAccount() async {
        let token = try? await secretStore.string(for: Self.cloudTokenKey)
        cloudAccount = (token?.isEmpty == false) ? Self.makeCloudAccount() : nil
    }

    /// Stores (or with `nil` removes) the personal LIFX cloud token. Never logged.
    ///
    /// TODO(T3.10): LIFX HTTP API fallback (https://api.lifx.com/v1, Bearer token, 120 req/min,
    /// `X-RateLimit-*` headers) for away-from-home control when the LAN path is unreachable.
    /// Only the token storage exists today; nothing calls the cloud yet.
    public func setCloudToken(_ token: String?) async throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try await secretStore.remove(Self.cloudTokenKey)
            cloudAccount = nil
        } else {
            try await secretStore.set(trimmed, for: Self.cloudTokenKey)
            cloudAccount = Self.makeCloudAccount()
        }
        log.info("cloud token \(trimmed.isEmpty ? "removed" : "stored") (\(Log.redact(trimmed.isEmpty ? nil : trimmed)))")
    }

    /// Asks the user for the optional cloud token (onboarding §5) and stores it.
    public func configureCloudToken(using ui: any PairingInteraction) async throws {
        let token = try await ui.secureText("Paste your LIFX cloud token from cloud.lifx.com/settings (optional, for away-from-home control)")
        try await setCloudToken(token)
    }

    private static func makeCloudAccount() -> ProviderAccount {
        ProviderAccount(id: "lifx-cloud", brand: .lifx, displayName: "LIFX Cloud", secretKeys: [cloudTokenKey])
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
        do { try ensureTransport() } catch {
            emit(.error("LIFX: cannot open UDP socket: \(error)"))
            return
        }
        let seen = SeenSet()
        let defaultPort = configuration.port
        let methods = options.methods
        let report: @Sendable (DiscoveredDevice?) async -> Void = { device in
            guard let device, await seen.insert(device.id) else { return }
            continuation.yield(device)
        }

        let browse = methods.contains(.bonjour) ? environment.browseBonjour : nil
        let useBroadcast = options.broadcastAvailable && methods.contains(.broadcast)
        let sweepHosts = !useBroadcast && methods.contains(.sweep) ? environment.sweepHosts() : []
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)
        let sweepTimeout = configuration.sweepTimeout
        var direct: [(String, UInt16, DiscoveryMethod)] = []
        var specs: [(String, DiscoveryMethod)] = []
        if methods.contains(.cached) {
            specs += options.cachedHosts.map { ($0, .cached) }
            specs += devices.values.map { ("\($0.host):\($0.port)", .cached) }
        }
        if methods.contains(.manual) { specs += options.manualHosts.map { ($0, .manual) } }
        for (spec, method) in specs {
            if let (host, port) = Self.parseHost(spec, defaultPort: defaultPort) { direct.append((host, port, method)) }
        }
        let directProbes = direct

        await withTaskGroup(of: Void.self) { group in
            if let browse {
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        for await hit in browse() {
                            guard let host = hit.host, IPv4Addr(host) != nil else { continue }
                            let port = hit.port ?? defaultPort
                            inner.addTask { await report(await self.identify(host: host, port: port, method: .bonjour, bonjour: hit)) }
                        }
                    }
                }
            }
            if useBroadcast {
                group.addTask { await self.broadcastDiscovery(report: report) }
            } else if !sweepHosts.isEmpty {
                group.addTask {
                    let results = sweeper.stream(sweepHosts) { host in
                        await self.identify(host: host.description, port: defaultPort, method: .sweep, timeout: sweepTimeout, retries: 0)
                    }
                    for await device in results { await report(device) }
                }
            }
            for (host, port, method) in directProbes {
                group.addTask { await report(await self.identify(host: host, port: port, method: method)) }
            }
        }
    }

    /// Broadcasts a tagged `GetService` and identifies every responder.
    private func broadcastDiscovery(report: @escaping @Sendable (DiscoveredDevice?) async -> Void) async {
        let addresses = environment.broadcastAddresses()
        guard !addresses.isEmpty, let transport else { return }
        let (seq, replies) = openCollector()
        defer { closeCollector(seq) }
        let packet = LIFXPacket(.getService, source: configuration.source, target: .all, tagged: true, sequence: seq).encode()
        let port = configuration.port
        let sender = Task {
            // A few rounds: UDP broadcasts get lost; replies are de-duplicated by serial.
            for round in 0..<3 {
                if round > 0 { try? await Task.sleep(for: .milliseconds(300 * round)) }
                for address in addresses {
                    do { try await transport.send(packet, to: address, port: port) } catch {
                        self.log.notice("broadcast GetService to \(address) failed: \(error)")
                    }
                }
            }
        }
        defer { sender.cancel() }
        await withTaskGroup(of: Void.self) { group in
            var probed: Set<LIFXSerial> = []
            for await reply in replies {
                guard case .stateService(let service, let svcPort) = reply.packet.message,
                      service == LIFXMessage.serviceUDP else { continue }
                let serial = reply.packet.header.target
                guard probed.insert(serial).inserted else { continue }
                let devicePort = svcPort > 0 && svcPort <= UInt32(UInt16.max) ? UInt16(svcPort) : reply.port
                group.addTask {
                    await report(await self.describe(serial: serial, host: reply.host, port: devicePort, method: .broadcast, bonjour: nil))
                }
            }
        }
    }

    /// Unicast `GetService` to a host, then fetch label/version/firmware.
    private func identify(
        host: String, port: UInt16, method: DiscoveryMethod, bonjour: LIFXBonjourHit? = nil,
        timeout: Duration? = nil, retries: Int? = nil
    ) async -> DiscoveredDevice? {
        guard let reply = try? await request(.getService, host: host, port: port, target: .all,
                                             expects: [LIFXMessage.Kind.stateService], timeout: timeout, retries: retries)
        else { return nil }
        var devicePort = port
        if case .stateService(let service, let p) = reply.packet.message, service == LIFXMessage.serviceUDP,
           p > 0, p <= UInt32(UInt16.max) {
            devicePort = UInt16(p)
        }
        return await describe(serial: reply.packet.header.target, host: reply.host, port: devicePort, method: method, bonjour: bonjour)
    }

    private func describe(serial: LIFXSerial, host: String, port: UInt16, method: DiscoveryMethod, bonjour: LIFXBonjourHit?) async -> DiscoveredDevice? {
        guard !serial.isAll else { return nil }
        noteEndpoint(serial, host: host, port: port)
        if let hit = bonjour {
            if devices[serial]?.productID == nil, let p = hit.productID {
                devices[serial]?.vendor = 1
                devices[serial]?.productID = p
            }
            if devices[serial]?.firmware == nil, let fw = hit.firmware { devices[serial]?.firmware = fw }
        }
        await refreshInfo(serial, quick: true)
        guard let d = devices[serial] else { return nil }
        let product = d.product
        var metadata: [String: String] = ["port": String(d.port)]
        if let v = d.vendor { metadata["vendor"] = String(v) }
        if let p = d.productID { metadata["product"] = String(p) }
        if let fw = d.firmware { metadata["firmware"] = fw.description }
        if let product { metadata["features"] = product.features.names.joined(separator: ",") }
        return DiscoveredDevice(
            id: serial.hex,
            brand: .lifx,
            name: d.label ?? product?.name ?? "LIFX \(serial.hex.suffix(6))",
            model: product?.name,
            host: d.host,
            port: Int(d.port),
            macAddress: serial.macAddress,
            method: method,
            metadata: metadata
        )
    }

    // MARK: - LightProvider: pairing

    /// LIFX needs no credentials: pairing confirms the device answers and records it.
    /// Devices without a host (manual add) ask for an IP address.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .lifx else { throw LightCoreError.unsupported("\(device.name) is not a LIFX device") }
        var hostSpec = device.host
        if hostSpec == nil || hostSpec?.isEmpty == true {
            hostSpec = try await ui.text("IP address of the LIFX light (shown in the LIFX app under the light's settings)")
        }
        guard let spec = hostSpec, let (host, specPort) = Self.parseHost(spec, defaultPort: configuration.port) else {
            throw LightCoreError.unreachable("no address for \(device.name)")
        }
        let port = device.port.map { UInt16(clamping: $0) } ?? specPort
        try ensureTransport()

        var serial = LIFXSerial(device.id) ?? device.macAddress.flatMap(LIFXSerial.init)
        if serial == nil {
            await ui.status("Contacting \(host)...")
            guard let found = await identify(host: host, port: port, method: .manual), let s = LIFXSerial(found.id) else {
                throw LightCoreError.unreachable("No LIFX light answered at \(host)")
            }
            serial = s
        }
        guard let serial else { throw LightCoreError.unreachable(host) }
        noteEndpoint(serial, host: host, port: port)
        await refreshInfo(serial, quick: false)
        guard devices[serial]?.productID != nil else {
            throw LightCoreError.unreachable("LIFX light \(serial.hex) did not answer at \(host)")
        }
        _ = try? await refreshState(serial)
        let d = devices[serial]!
        let product = d.product
        var metadata: [String: String] = [:]
        if let v = d.vendor { metadata["vendor"] = String(v) }
        if let p = d.productID { metadata["product"] = String(p) }
        if let fw = d.firmware { metadata["firmware"] = fw.description }
        if let product { metadata["features"] = product.features.names.joined(separator: ",") }
        let paired = PairedDevice(
            id: serial.hex,
            brand: .lifx,
            name: d.label ?? product?.name ?? device.name,
            model: product?.name,
            hostHint: d.host,
            port: Int(d.port),
            lightIDs: [LIFXMapping.lightID(serial)],
            metadata: metadata,
            lastSeen: d.lastSeen
        )
        devices[serial]?.paired = paired
        if let light = light(for: serial) { emit(.lightAdded(light)) }
        return paired
    }

    // MARK: - LightProvider: state

    public func loadLights() async throws -> [Light] {
        try ensureTransport()
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

    private func refresh(_ serial: LIFXSerial, emitChanges: Bool) async {
        guard let before = devices[serial] else { return }
        if before.productID == nil || before.firmware == nil { await refreshInfo(serial, quick: true) }
        let oldLight = light(for: serial)
        do {
            try await refreshState(serial)
        } catch {
            markReachable(serial, false, emit: emitChanges)
            return
        }
        guard emitChanges, let newLight = light(for: serial), let oldLight else { return }
        if oldLight.name != newLight.name {
            emit(.lightUpdated(newLight))
        } else if !Self.sameState(oldLight.state, newLight.state) {
            emit(.stateChanged(newLight.id, newLight.state))
        }
    }

    /// `LightGet` -> colour, power, label.
    @discardableResult
    private func refreshState(_ serial: LIFXSerial) async throws -> LIFXLightStatePayload {
        let reply = try await request(.lightGet, to: serial, expects: [LIFXMessage.Kind.lightState])
        guard case .lightState(let s) = reply.packet.message else { throw LightCoreError.protocolError("expected LightState") }
        devices[serial]?.color = s.color
        devices[serial]?.power = s.power
        if !s.label.isEmpty { devices[serial]?.label = s.label }
        markReachable(serial, true, emit: true)
        return s
    }

    /// Version, firmware and label. `quick` uses a single short attempt per message (discovery).
    private func refreshInfo(_ serial: LIFXSerial, quick: Bool) async {
        let timeout: Duration? = quick ? configuration.requestTimeout : nil
        let retries: Int? = quick ? 1 : nil
        if devices[serial]?.productID == nil,
           let r = try? await request(.getVersion, to: serial, expects: [LIFXMessage.Kind.stateVersion], timeout: timeout, retries: retries),
           case .stateVersion(let vendor, let product) = r.packet.message {
            devices[serial]?.vendor = vendor
            devices[serial]?.productID = product
        }
        if devices[serial]?.firmware == nil,
           let r = try? await request(.getHostFirmware, to: serial, expects: [LIFXMessage.Kind.stateHostFirmware], timeout: timeout, retries: retries),
           case .stateHostFirmware(_, let major, let minor) = r.packet.message {
            devices[serial]?.firmware = LIFXFirmwareVersion(major: Int(major), minor: Int(minor))
        }
        if devices[serial]?.label == nil,
           let r = try? await request(.getLabel, to: serial, expects: [LIFXMessage.Kind.stateLabel], timeout: timeout, retries: retries),
           case .stateLabel(let label) = r.packet.message, !label.isEmpty {
            devices[serial]?.label = label
        }
    }

    private func light(for serial: LIFXSerial) -> Light? {
        guard let d = devices[serial] else { return nil }
        let product = d.product ?? LIFXProduct.lookup(vendor: 1, product: 0)
        var state: LightState
        if let color = d.color, let power = d.power {
            state = LIFXMapping.state(color: color, power: power, product: product, at: d.lastSeen ?? Date())
        } else {
            state = LightState(reachable: false)
        }
        state.reachable = d.reachable && d.color != nil
        return Light(
            id: LIFXMapping.lightID(serial),
            name: d.label ?? d.paired?.name ?? product.name,
            capabilities: LIFXMapping.capabilities(for: product),
            state: state,
            providerRef: "\(d.host):\(d.port)",
            manufacturer: "LIFX",
            model: d.product?.name
        )
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to id: LightID) async throws {
        guard let serial = LIFXMapping.serial(of: id), devices[serial] != nil else { throw LightCoreError.lightNotFound(id) }
        if command.isEmpty { return }
        try ensureTransport()
        do {
            if devices[serial]?.productID == nil { await refreshInfo(serial, quick: false) }
            if devices[serial]?.color == nil || devices[serial]?.power == nil { try await refreshState(serial) }
            guard let d = devices[serial], let color = d.color, let power = d.power else { throw LightCoreError.unreachable(id.rawValue) }
            let product = d.product ?? LIFXProduct.lookup(vendor: 1, product: 0)
            let plan = LIFXMapping.plan(command, current: color, isOn: power > 0, product: product)
            if plan.isEmpty { return }
            for message in plan.messages(currentlyOn: power > 0) {
                _ = try await request(message, to: serial, expects: [LIFXMessage.Kind.acknowledgement], ack: true)
            }
            let next = LIFXMapping.apply(plan, current: color, isOn: power > 0)
            devices[serial]?.color = next.color
            devices[serial]?.power = next.isOn ? 65535 : 0
            markReachable(serial, true, emit: true)
            if let light = light(for: serial) { emit(.stateChanged(light.id, light.state)) }
        } catch LightCoreError.timeout {
            markReachable(serial, false, emit: true)
            throw LightCoreError.unreachable("LIFX light \(devices[serial]?.label ?? serial.hex) did not answer")
        }
    }

    /// Concurrent fan-out (each light has its own rate limit and sequence space).
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

    // MARK: - Multizone (strips, beams, neon)

    /// Zone colours of a multizone light. Uses extended multizone (511/512) when the product and
    /// firmware support it, else `GetColorZones` (502 -> 506 batches of 8).
    public func zones(of id: LightID) async throws -> [HSBK] {
        guard let serial = LIFXMapping.serial(of: id), let d = devices[serial] else { throw LightCoreError.lightNotFound(id) }
        guard let product = d.product, product.features.contains(.multizone) else {
            throw LightCoreError.unsupported("\(d.label ?? serial.hex) has no zones")
        }
        try ensureTransport()
        let extended = product.features.contains(.extendedMultizone)
        let message: LIFXMessage = extended ? .extendedGetColorZones : .getColorZones(start: 0, end: 255)
        let expects: Set<UInt16> = extended
            ? [LIFXMessage.Kind.extendedStateMultiZone]
            : [LIFXMessage.Kind.stateMultiZone, LIFXMessage.Kind.stateZone]
        for _ in 0...max(0, configuration.retries) {
            var total: Int?
            var zones: [Int: HSBK] = [:]
            let complete = await collect(message, to: serial, expects: expects) { reply in
                switch reply.packet.message {
                case .extendedStateMultiZone(let count, let index, let colors):
                    total = Int(count)
                    for (i, c) in colors.enumerated() { zones[Int(index) + i] = c }
                case .stateMultiZone(let count, let index, let colors):
                    total = Int(count)
                    for (i, c) in colors.enumerated() where Int(index) + i < Int(count) { zones[Int(index) + i] = c }
                case .stateZone(let count, let index, let color):
                    total = Int(count)
                    zones[Int(index)] = color
                default:
                    break
                }
                guard let total else { return false }
                return (0..<total).allSatisfy { zones[$0] != nil }
            }
            if complete, let total { return (0..<total).map { zones[$0]! } }
        }
        markReachable(serial, false, emit: true)
        throw LightCoreError.unreachable("LIFX light \(serial.hex) did not report its zones")
    }

    /// Sets every zone (`colors[i]` -> zone i). Extended multizone sends batches of 82 in one
    /// apply; legacy devices get one `SetColorZones` per zone with apply on the last.
    public func setZones(_ colors: [HSBK], on id: LightID, transition: Duration? = nil) async throws {
        guard let serial = LIFXMapping.serial(of: id), let d = devices[serial] else { throw LightCoreError.lightNotFound(id) }
        guard let product = d.product, product.features.contains(.multizone) else {
            throw LightCoreError.unsupported("\(d.label ?? serial.hex) has no zones")
        }
        guard !colors.isEmpty else { return }
        try ensureTransport()
        let duration = UInt32(clamping: LightCommand(transition: transition).transitionMilliseconds ?? 0)
        var messages: [LIFXMessage] = []
        if product.features.contains(.extendedMultizone) {
            let cap = LIFXMessage.extendedZoneCapacity
            var index = 0
            while index < colors.count {
                let chunk = Array(colors[index..<min(index + cap, colors.count)])
                let last = index + cap >= colors.count
                messages.append(.extendedSetColorZones(durationMs: duration, apply: last ? .apply : .noApply,
                                                       index: UInt16(index), colors: chunk))
                index += cap
            }
        } else {
            for (i, c) in colors.prefix(256).enumerated() {
                let last = i == min(colors.count, 256) - 1
                messages.append(.setColorZones(start: UInt8(i), end: UInt8(i), color: c, durationMs: duration, apply: last ? .apply : .noApply))
            }
        }
        do {
            for m in messages { _ = try await request(m, to: serial, expects: [LIFXMessage.Kind.acknowledgement], ack: true) }
        } catch LightCoreError.timeout {
            markReachable(serial, false, emit: true)
            throw LightCoreError.unreachable("LIFX light \(serial.hex) did not answer")
        }
    }

    // MARK: - Request/response

    /// Sends `message` to a known device and waits for a reply of one of `expects`
    /// (`requestTimeout` per attempt, `retries` extra attempts). Throws `LightCoreError.timeout`.
    public func request(
        _ message: LIFXMessage, to serial: LIFXSerial, expects: Set<UInt16>, ack: Bool = false,
        timeout: Duration? = nil, retries: Int? = nil
    ) async throws -> Reply {
        guard let d = devices[serial] else { throw LightCoreError.lightNotFound(LIFXMapping.lightID(serial)) }
        try await limiter.acquire(serial.hex)
        return try await request(message, host: d.host, port: d.port, target: serial, expects: expects, ack: ack,
                                 timeout: timeout, retries: retries)
    }

    private func request(
        _ message: LIFXMessage, host: String, port: UInt16, target: LIFXSerial, expects: Set<UInt16>,
        ack: Bool = false, timeout: Duration? = nil, retries: Int? = nil
    ) async throws -> Reply {
        try ensureTransport()
        let attempts = 1 + max(0, retries ?? configuration.retries)
        for attempt in 1...attempts {
            try Task.checkCancellation()
            let seq = nextSequence()
            let packet = LIFXPacket(message, source: configuration.source, target: target, ackRequired: ack, sequence: seq)
            do {
                return try await exchange(packet.encode(), sequence: seq, host: host, port: port, expects: expects,
                                          timeout: timeout ?? configuration.requestTimeout)
            } catch RequestError.timedOut {
                log.debug("timeout \(message.type) -> \(host):\(port) attempt \(attempt)/\(attempts)")
                continue
            }
        }
        throw LightCoreError.timeout
    }

    private func exchange(_ data: Data, sequence seq: UInt8, host: String, port: UInt16, expects: Set<UInt16>, timeout: Duration) async throws -> Reply {
        guard let transport else { throw LightCoreError.transport("LIFX socket closed") }
        nextToken &+= 1
        let token = nextToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, any Error>) in
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.fail(seq, token: token, RequestError.timedOut)
                }
                waiters[seq] = Waiter(token: token, host: host, expects: expects, continuation: continuation, timer: timer)
                Task { [weak self] in
                    do { try await transport.send(data, to: host, port: port) } catch {
                        await self?.fail(seq, token: token, LightCoreError.transport(String(describing: error)))
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(seq, token: token, CancellationError()) }
        }
    }

    private func fail(_ seq: UInt8, token: UInt64, _ error: any Error) {
        guard let w = waiters[seq], w.token == token else { return }
        waiters[seq] = nil
        w.timer?.cancel()
        w.continuation.resume(throwing: error)
    }

    /// Sends one request and feeds every reply with its sequence to `accept` until it returns true
    /// or `requestTimeout` passes. For multi-packet replies (zones).
    private func collect(_ message: LIFXMessage, to serial: LIFXSerial, expects: Set<UInt16>,
                         accept: (Reply) -> Bool) async -> Bool {
        guard let d = devices[serial], let transport else { return false }
        try? await limiter.acquire(serial.hex)
        let (seq, replies) = openCollector()
        defer { closeCollector(seq) }
        let packet = LIFXPacket(message, source: configuration.source, target: serial, sequence: seq).encode()
        do { try await transport.send(packet, to: d.host, port: d.port) } catch { return false }
        let timeout = configuration.requestTimeout
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await self?.closeCollector(seq)
        }
        defer { timer.cancel() }
        for await reply in replies where expects.contains(reply.packet.message.type) {
            if accept(reply) { return true }
        }
        return false
    }

    private func openCollector() -> (UInt8, AsyncStream<Reply>) {
        let seq = nextSequence()
        let (stream, continuation) = AsyncStream.makeStream(of: Reply.self)
        collectors[seq] = continuation
        return (seq, stream)
    }

    private func closeCollector(_ seq: UInt8) {
        collectors.removeValue(forKey: seq)?.finish()
    }

    /// Next free sequence number (wrapping; skips numbers with a request in flight).
    private func nextSequence() -> UInt8 {
        for _ in 0..<256 {
            sequence &+= 1
            if waiters[sequence] == nil && collectors[sequence] == nil { return sequence }
        }
        return sequence
    }

    private func ensureTransport() throws {
        guard transport == nil else { return }
        let t = try environment.makeTransport()
        transport = t
        let stream = t.datagrams
        receiveTask = Task { [weak self] in
            for await datagram in stream {
                guard let self else { return }
                await self.handle(datagram)
            }
        }
    }

    private func handle(_ datagram: LIFXDatagram) {
        guard let packet = try? LIFXPacket.decode(datagram.data) else { return }
        // Replies carry our source and the responder's serial; our own broadcasts (target 0) are ignored.
        guard packet.header.source == configuration.source, !packet.header.target.isAll else { return }
        let serial = packet.header.target
        if devices[serial] != nil {
            devices[serial]?.lastSeen = Date()
            if datagram.host != devices[serial]?.host, IPv4Addr(datagram.host) != nil {
                log.info("LIFX \(serial.hex) moved to \(datagram.host)")
                devices[serial]?.host = datagram.host
                if var p = devices[serial]?.paired { p.hostHint = datagram.host; devices[serial]?.paired = p }
            }
        }
        let reply = Reply(packet: packet, host: datagram.host, port: datagram.port)
        let seq = packet.header.sequence
        if let collector = collectors[seq] {
            collector.yield(reply)
            return
        }
        guard let w = waiters[seq] else { return }
        // A stale reply from another device that happens to reuse this sequence number.
        if let expected = w.host, IPv4Addr(expected) != nil, expected != datagram.host { return }
        if w.expects.contains(packet.message.type) {
            waiters[seq] = nil
            w.timer?.cancel()
            w.continuation.resume(returning: reply)
        } else if case .stateUnhandled(let type) = packet.message {
            waiters[seq] = nil
            w.timer?.cancel()
            w.continuation.resume(throwing: LightCoreError.unsupported("LIFX device does not handle message \(type)"))
        }
    }

    // MARK: - Helpers

    private func noteEndpoint(_ serial: LIFXSerial, host: String, port: UInt16) {
        if devices[serial] == nil {
            devices[serial] = Device(serial: serial, host: host, port: port)
        } else {
            devices[serial]?.host = host
            devices[serial]?.port = port
        }
        devices[serial]?.lastSeen = Date()
    }

    private func markReachable(_ serial: LIFXSerial, _ reachable: Bool, emit shouldEmit: Bool) {
        guard let d = devices[serial], d.reachable != reachable else { return }
        devices[serial]?.reachable = reachable
        if shouldEmit, d.paired != nil { emit(.reachabilityChanged(LIFXMapping.lightID(serial), reachable: reachable)) }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    private static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }

    /// `"192.168.1.20"` or `"192.168.1.20:56700"` -> host + port.
    static func parseHost(_ spec: String, defaultPort: UInt16) -> (String, UInt16)? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        if parts.count == 1 { return (trimmed, defaultPort) }
        return nil
    }
}

/// Thread-safe "first time seen" set for discovery de-duplication.
private actor SeenSet {
    private var ids: Set<String> = []
    func insert(_ id: String) -> Bool { ids.insert(id).inserted }
}
