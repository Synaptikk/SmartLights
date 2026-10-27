import Foundation
import LightCore
import NetKit
import WiZCodec

/// WiZ local-UDP provider (research_wiz.md §1, §7, §8).
///
/// - Devices are keyed by MAC; IPs are cached hints refreshed by discovery, pushes and relocation.
/// - Requests to one bulb are serialised; each is re-sent on pywizlight's schedule
///   (0.75/1.5/3/3/3 s gaps, 13 s total) and late replies whose `method` differs are dropped.
/// - Writes are signed with the home `udp_signing_key` once a bulb answers -32602 + `sigTs`.
/// - Push: call ``start()`` in the foreground, ``stop()`` in the background.
public actor WiZProvider: LightProvider {
    public static let brand: Brand = .wiz
    /// Keychain location of the home signing key (one per WiZ home).
    public static let signingSecretKey = SecretKey(brand: .wiz, owner: "home", item: "udp_signing_key")
    /// `ProviderAccount.id` used once a signing key is stored.
    public static let homeAccountID = "wiz:home"

    public struct Configuration: Sendable {
        public var bulbPort: UInt16 = WiZPort.control
        public var pushPort: UInt16 = WiZPort.push
        /// Gaps between re-sends of a request (pywizlight): sends at 0, 0.75, 2.25, 5.25, 8.25, 11.25 s.
        public var retrySchedule: [Duration] = [.milliseconds(750), .milliseconds(1500), .seconds(3), .seconds(3), .seconds(3)]
        public var requestTimeout: Duration = .seconds(13)
        /// Writes are re-sent less often to avoid flicker (pywizlight README).
        public var writeRetrySchedule: [Duration] = [.milliseconds(750), .milliseconds(1500)]
        public var writeTimeout: Duration = .seconds(5)
        /// Refresh / poll / registration / cached-host probes give up sooner.
        public var quickRetrySchedule: [Duration] = [.milliseconds(750), .milliseconds(1500)]
        public var quickTimeout: Duration = .seconds(3)
        /// Unicast sweep: one datagram per host, this long to answer.
        public var sweepTimeout: Duration = .seconds(1)
        public var sweepConcurrency: Int = 32
        /// Broadcast discovery: re-send every `broadcastInterval` for `broadcastWindow`.
        public var broadcastWindow: Duration = .seconds(5)
        public var broadcastInterval: Duration = .seconds(1)
        /// Push registration refresh while started.
        public var registrationInterval: Duration = .seconds(20)
        /// Poll a bulb that has not pushed for this long...
        public var pushTimeout: Duration = .seconds(33)
        /// ...every `pollInterval`.
        public var pollInterval: Duration = .seconds(30)
        /// Granularity of the push watchdog.
        public var monitorTick: Duration = .seconds(1)
        /// Look for bulbs whose IP stopped answering (sweep/broadcast) automatically.
        public var autoRelocate: Bool = true
        public var relocateTimeout: Duration = .seconds(15)
        /// 12-hex pseudo MAC sent as `phoneMac` in `registration`.
        public var phoneMac: String

        public init() {
            var rng = SystemRandomNumberGenerator()
            phoneMac = (0..<6).map { _ in
                let b = UInt8.random(in: 0...255, using: &rng)
                return String(b, radix: 16).count == 1 ? "0" + String(b, radix: 16) : String(b, radix: 16)
            }.joined()
        }
    }

    /// Whether writes to a bulb must be signed.
    public enum SigningMode: String, Sendable, Codable {
        case unknown
        case notRequired
        case required
    }

    struct DeviceRecord: Sendable {
        var mac: String
        var lightID: LightID
        var host: IPv4Addr?
        var name: String
        var module: WiZModuleInfo?
        var systemConfig: WiZSystemConfig?
        var modelConfig: WiZModelConfig?
        var userConfig: WiZUserConfig?
        var capabilities: LightCapabilities
        var state: LightState
        var signing: SigningMode = .unknown
        /// Bulb clock minus our clock (seconds), learned from `sigTs` in replies.
        var clockOffset: Int = 0
        var lastPush: ContinuousClock.Instant?
        var lastPoll: ContinuousClock.Instant?
    }

    private struct Pending {
        let host: IPv4Addr
        let method: String
        let payload: Data
        var result: Result<WiZResponse, any Error>?
        var waiter: CheckedContinuation<WiZResponse, any Error>?
        var retryTask: Task<Void, Never>?
    }

    private struct DiscoverySession {
        var continuation: AsyncStream<DiscoveredDevice>.Continuation?
        var seen: Set<String> = []
    }

    struct ProbeHit: Sendable {
        var mac: String
        var host: IPv4Addr
        var pilot: WiZPilot?
        var signedReplies: Bool
    }

    // MARK: State

    public private(set) var account: ProviderAccount?
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation

    private let transport: any WiZTransport
    private let secrets: any SecretStore
    public nonisolated let configuration: Configuration
    private let log = Log(package: "wizkit", category: "provider")
    private let clock = ContinuousClock()

    private var devices: [String: DeviceRecord] = [:]
    private var cachedKey: WiZSigningKey?

    private var requestSocket: (any WiZDatagramEndpoint)?
    private var requestSocketTask: Task<any WiZDatagramEndpoint, any Error>?
    private var requestReader: Task<Void, Never>?
    private var pending: [UInt64: Pending] = [:]
    private var pendingByHost: [IPv4Addr: UInt64] = [:]
    private var nextToken: UInt64 = 0
    private var nextRequestID = 0
    private var busyHosts: Set<IPv4Addr> = []
    private var hostWaiters: [IPv4Addr: [CheckedContinuation<Void, Never>]] = [:]

    private var sessions: [UInt64: DiscoverySession] = [:]
    private var nextSession: UInt64 = 0
    private var relocateTask: Task<Void, Never>?

    private var running = false
    private var startedAt: ContinuousClock.Instant?
    private var pushSocket: (any WiZDatagramEndpoint)?
    private var pushReader: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lastRegistration: ContinuousClock.Instant?
    private var phoneIP: IPv4Addr?

    public init(secrets: any SecretStore, transport: any WiZTransport, configuration: Configuration = Configuration()) {
        self.secrets = secrets
        self.transport = transport
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    #if canImport(Darwin)
    /// Production provider on NetKit BSD sockets.
    public init(secrets: any SecretStore, configuration: Configuration = Configuration()) {
        self.init(secrets: secrets, transport: NetKitWiZTransport(), configuration: configuration)
    }
    #endif

    deinit {
        monitorTask?.cancel()
        pushReader?.cancel()
        requestReader?.cancel()
        relocateTask?.cancel()
        pushSocket?.close()
        requestSocket?.close()
        eventContinuation.finish()
    }

    private var config: Configuration { configuration }

    private func emit(_ event: ProviderEvent) { eventContinuation.yield(event) }

    // MARK: - Restore / inspection

    /// Re-adds bulbs paired earlier (from `DeviceStore`) and loads the account if a key is stored.
    public func restore(_ paired: [PairedDevice]) async {
        for p in paired where p.brand == .wiz {
            guard let mac = WiZMAC.normalize(p.id), let lightID = LightID(brand: .wiz, stableId: mac) else { continue }
            let module = p.metadata["moduleName"].flatMap { WiZModuleInfo(moduleName: $0) }
            let kind = module?.kind ?? p.metadata["kind"].flatMap(WiZModuleInfo.Kind.init(rawValue:)) ?? .rgb
            var model: WiZModelConfig?
            if let lo = p.metadata["kelvinMin"].flatMap(Int.init), let hi = p.metadata["kelvinMax"].flatMap(Int.init) {
                model = WiZModelConfig(cctRange: [lo, hi])
            }
            let caps = WiZCapabilities.make(kind: kind, modelConfig: model)
            var record = devices[mac] ?? DeviceRecord(
                mac: mac, lightID: lightID, host: nil, name: p.name, module: module, capabilities: caps,
                state: LightState(reachable: false)
            )
            record.name = p.name
            record.module = module
            record.modelConfig = model
            record.capabilities = caps
            if record.host == nil { record.host = p.hostHint.flatMap(IPv4Addr.init) }
            record.signing = p.metadata["signing"].flatMap(SigningMode.init(rawValue:)) ?? .unknown
            devices[mac] = record
        }
        _ = try? await loadSigningKey()
    }

    /// Forgets a bulb (does not touch the stored key).
    public func remove(_ light: LightID) {
        guard devices.removeValue(forKey: light.stableId) != nil else { return }
        emit(.lightRemoved(light))
    }

    /// Cached IP of a bulb (diagnostics).
    public func host(for light: LightID) -> String? { devices[light.stableId]?.host?.description }

    /// Signing requirement learned for a bulb (diagnostics).
    public func signingMode(for light: LightID) -> SigningMode? { devices[light.stableId]?.signing }

    public var isRunning: Bool { running }

    // MARK: - Signing key

    /// Stores (after validation by the caller) a new home key, e.g. from Settings.
    public func setSigningKey(_ key: WiZSigningKey) async throws {
        try await secrets.set(key.hexString, for: Self.signingSecretKey)
        cachedKey = key
        account = Self.makeAccount()
    }

    public func removeSigningKey() async throws {
        try await secrets.remove(Self.signingSecretKey)
        cachedKey = nil
        account = nil
    }

    private static func makeAccount() -> ProviderAccount {
        ProviderAccount(id: homeAccountID, brand: .wiz, displayName: "WiZ home key", secretKeys: [signingSecretKey])
    }

    private func loadSigningKey() async throws -> WiZSigningKey? {
        if let cachedKey { return cachedKey }
        guard let hex = try await secrets.string(for: Self.signingSecretKey), let key = WiZSigningKey(hex: hex) else { return nil }
        cachedKey = key
        account = Self.makeAccount()
        return key
    }

    // MARK: - Discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        let task = Task { await self.runDiscovery(options: options, continuation: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(options: DiscoveryOptions, continuation: AsyncStream<DiscoveredDevice>.Continuation?) async {
        nextSession += 1
        let sid = nextSession
        sessions[sid] = DiscoverySession(continuation: continuation)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.discoveryBody(options: options, session: sid) }
            group.addTask { try? await Task.sleep(for: options.timeout) }
            await group.next()
            group.cancelAll()
        }
        sessions[sid] = nil
        continuation?.finish()
    }

    private func discoveryBody(options: DiscoveryOptions, session sid: UInt64) async {
        var manual: [IPv4Addr] = []
        if options.methods.contains(.manual) {
            for text in options.manualHosts {
                if let ip = IPv4Addr(text.trimmingCharacters(in: .whitespaces)) {
                    manual.append(ip)
                } else {
                    log.notice("Ignoring manual host '\(text)': WiZ needs an IPv4 address")
                }
            }
        }
        var cached: [IPv4Addr] = []
        if options.methods.contains(.cached) {
            cached = options.cachedHosts.compactMap { IPv4Addr($0) } + devices.values.compactMap(\.host)
        }
        let manualSet = Set(manual)
        cached = Array(Set(cached).subtracting(manualSet)).sorted()

        await withTaskGroup(of: Void.self) { group in
            for ip in manual {
                group.addTask { await self.probeAndReport(ip, method: .manual, session: sid) }
            }
            for ip in cached {
                group.addTask { await self.probeAndReport(ip, method: .cached, session: sid) }
            }
            group.addTask { await self.scan(options: options, session: sid) }
        }
    }

    /// Broadcast when allowed, else (or if broadcast found nothing) a unicast /24 sweep.
    private func scan(options: DiscoveryOptions, session sid: UInt64) async {
        var broadcastFound = 0
        var broadcastWorked = false
        if options.methods.contains(.broadcast) {
            var allowed = options.broadcastAvailable
            if !allowed { allowed = await transport.broadcastStatus() == .entitled }
            if allowed {
                (broadcastWorked, broadcastFound) = await broadcastDiscovery(session: sid)
            }
        }
        guard !Task.isCancelled else { return }
        if options.methods.contains(.sweep), !broadcastWorked || broadcastFound == 0 {
            await sweep(session: sid)
        }
    }

    private func probeAndReport(_ host: IPv4Addr, method: DiscoveryMethod, session sid: UInt64) async {
        guard let hit = await probe(host, schedule: config.quickRetrySchedule, timeout: config.quickTimeout) else { return }
        report(hit, method: method, session: sid)
    }

    /// Unicast `getPilot`; nil if nothing (or no MAC) came back.
    func probe(_ host: IPv4Addr, schedule: [Duration], timeout: Duration) async -> ProbeHit? {
        guard let response = try? await perform(WiZRequest.getPilot(id: makeRequestID()).encoded(), method: WiZMethod.getPilot,
                                                host: host, schedule: schedule, timeout: timeout),
              response.error == nil, let mac = response.mac
        else { return nil }
        return ProbeHit(mac: mac, host: host, pilot: response.pilot, signedReplies: response.hmac != nil)
    }

    private func sweep(session sid: UInt64) async {
        let hosts = await transport.sweepHosts()
        guard !hosts.isEmpty else {
            log.notice("Sweep skipped: no Wi-Fi subnet")
            return
        }
        let sweeper = SubnetSweeper(maxConcurrent: config.sweepConcurrency)
        let timeout = config.sweepTimeout
        let stream = sweeper.stream(hosts) { host in
            await self.probe(host, schedule: [], timeout: timeout)
        }
        for await hit in stream {
            report(hit, method: .sweep, session: sid)
        }
    }

    /// `registration register:false` + `getPilot` to the broadcast addresses every second.
    /// Returns whether sending worked and how many MACs answered.
    private func broadcastDiscovery(session sid: UInt64) async -> (worked: Bool, found: Int) {
        let socket: any WiZDatagramEndpoint
        do {
            socket = try await transport.bind(port: 0, broadcast: true)
        } catch {
            log.notice("Broadcast socket unavailable (\(error)); falling back to sweep")
            return (false, 0)
        }
        defer { socket.close() }
        let targets = await transport.broadcastAddresses()
        let port = config.bulbPort
        let probes = [WiZRequest.discoveryRegistration().encoded(), WiZRequest.getPilot().encoded()]
        var sentAny = false
        for target in targets {
            for payload in probes {
                do {
                    try socket.sendDatagram(payload, to: target, port: port)
                    sentAny = true
                } catch {
                    log.notice("Broadcast to \(target) failed: \(error)")
                }
            }
        }
        guard sentAny else { return (false, 0) }

        let interval = config.broadcastInterval
        let window = config.broadcastWindow
        let sender = Task {
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled || start.duration(to: clock.now) >= window { break }
                for target in targets {
                    for payload in probes { try? socket.sendDatagram(payload, to: target, port: port) }
                }
            }
            socket.close() // ends `datagrams`
        }
        var found: Set<String> = []
        for await datagram in socket.datagrams {
            guard let response = try? WiZResponse.parse(datagram.data), response.error == nil, let mac = response.mac else { continue }
            found.insert(mac)
            let pilot = response.method == WiZMethod.getPilot ? response.pilot : nil
            report(ProbeHit(mac: mac, host: datagram.host, pilot: pilot, signedReplies: response.hmac != nil),
                   method: .broadcast, session: sid)
        }
        sender.cancel()
        return (true, found.count)
    }

    private func report(_ hit: ProbeHit, method: DiscoveryMethod, session sid: UInt64) {
        if var record = devices[hit.mac] {
            let moved = record.host != hit.host
            record.host = hit.host
            devices[hit.mac] = record
            if moved {
                log.info("WiZ \(hit.mac) is now at \(hit.host)")
                emit(.lightUpdated(makeLight(record)))
            }
            if let pilot = hit.pilot { applyPilot(pilot, mac: hit.mac) } else { markReachable(hit.mac) }
        }
        guard var session = sessions[sid], session.seen.insert(hit.mac).inserted else { return }
        sessions[sid] = session
        var metadata: [String: String] = ["signedReplies": hit.signedReplies ? "true" : "false"]
        if let rssi = hit.pilot?.rssi { metadata["rssi"] = String(rssi) }
        if let on = hit.pilot?.state { metadata["state"] = on ? "on" : "off" }
        session.continuation?.yield(DiscoveredDevice(
            id: hit.mac,
            brand: .wiz,
            name: devices[hit.mac]?.name ?? Self.defaultName(mac: hit.mac, kind: nil),
            host: hit.host.description,
            port: Int(config.bulbPort),
            macAddress: hit.mac,
            method: method,
            metadata: metadata
        ))
    }

    static func defaultName(mac: String, kind: WiZModuleInfo.Kind?) -> String {
        let suffix = String(mac.suffix(4)).uppercased()
        switch kind {
        case .socket: return "WiZ plug \(suffix)"
        case .fanDimmable, .fanTunableWhite: return "WiZ fan light \(suffix)"
        default: return "WiZ light \(suffix)"
        }
    }

    /// Finds bulbs whose cached IP stopped answering (DHCP changes) in the background.
    private func startRelocation() {
        guard config.autoRelocate, relocateTask == nil else { return }
        let options = DiscoveryOptions(timeout: config.relocateTimeout, methods: [.broadcast, .sweep])
        relocateTask = Task {
            await self.runDiscovery(options: options, continuation: nil)
            self.relocationFinished()
        }
    }

    private func relocationFinished() { relocateTask = nil }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        let expectedMAC = device.macAddress.flatMap(WiZMAC.normalize) ?? WiZMAC.normalize(device.id)
        guard let host = device.host.flatMap({ IPv4Addr($0) }) ?? expectedMAC.flatMap({ devices[$0]?.host }) else {
            throw LightCoreError.unreachable("\(device.name) has no IPv4 address")
        }
        await ui.status("Reading \(device.name)...")

        let system = try await read(WiZRequest.getSystemConfig(id: makeRequestID()), host: host)
        if let error = system.error { throw LightCoreError.protocolError("getSystemConfig: \(error)") }
        guard let sys = system.systemConfig, let mac = sys.mac ?? expectedMAC else {
            throw LightCoreError.protocolError("getSystemConfig returned no MAC")
        }
        if let expectedMAC, expectedMAC != mac {
            throw LightCoreError.protocolError("\(host) is now a different WiZ device (\(mac)); run discovery again")
        }
        guard let lightID = LightID(brand: .wiz, stableId: mac) else { throw LightCoreError.invalidLightID(mac) }

        // Optional on older firmware (-32601) - tolerate errors and timeouts.
        let model = try? await read(WiZRequest.getModelConfig(id: makeRequestID()), host: host, quick: true)
        let user = try? await read(WiZRequest.getUserConfig(id: makeRequestID()), host: host, quick: true)
        let pilotResponse = try await read(WiZRequest.getPilot(id: makeRequestID()), host: host)
        let pilot = pilotResponse.error == nil ? pilotResponse.pilot : nil

        let module = sys.moduleInfo
        let modelConfig = model?.error == nil ? model?.modelConfig : nil
        let userConfig = user?.error == nil ? user?.userConfig : nil
        let caps = WiZCapabilities.make(module: module, modelConfig: modelConfig, userConfig: userConfig, pilot: pilot)
        let kind = module?.kind ?? WiZModuleInfo.fallbackKind(pilot: pilot)
        let name = device.name.isEmpty || device.name.hasPrefix("WiZ light ") ? Self.defaultName(mac: mac, kind: kind) : device.name

        var record = devices[mac] ?? DeviceRecord(
            mac: mac, lightID: lightID, host: host, name: name, module: module,
            capabilities: caps, state: LightState(reachable: true)
        )
        record.host = host
        record.name = name
        record.module = module
        record.systemConfig = sys
        record.modelConfig = modelConfig
        record.userConfig = userConfig
        record.capabilities = caps
        if let sigTs = system.sigTs { record.clockOffset = sigTs - WiZSigner.timestamp() }
        if let pilot { record.state = WiZStateMapping.state(from: pilot, capabilities: caps) }
        devices[mac] = record

        let signing = try await negotiateSigning(mac: mac, currentState: pilot?.state ?? false, ui: ui)
        devices[mac]?.signing = signing
        let final = devices[mac] ?? record
        emit(.lightAdded(makeLight(final)))

        var metadata: [String: String] = ["signing": signing.rawValue, "kind": kind.rawValue]
        if let m = sys.moduleName { metadata["moduleName"] = m }
        if let fw = sys.fwVersion { metadata["fwVersion"] = fw }
        if let homeId = sys.homeId { metadata["homeId"] = String(homeId) }
        if let roomId = sys.roomId { metadata["roomId"] = String(roomId) }
        if let lo = caps.minKelvin, let hi = caps.maxKelvin {
            metadata["kelvinMin"] = String(lo)
            metadata["kelvinMax"] = String(hi)
        }
        if pilotResponse.hmac != nil { metadata["signedReplies"] = "true" }
        return PairedDevice(
            id: mac, brand: .wiz, name: name, model: sys.moduleName, hostHint: host.description,
            port: Int(config.bulbPort), accountID: signing == .required ? Self.homeAccountID : nil,
            lightIDs: [lightID], metadata: metadata, pairedAt: Date(), lastSeen: Date()
        )
    }

    /// Probes with `setState` to the current state; asks for the key (or the app setting) if the
    /// bulb answers -32602 with `sigTs`.
    private func negotiateSigning(mac: String, currentState: Bool, ui: any PairingInteraction) async throws -> SigningMode {
        let probe = WiZRequest.setState(["state": .bool(currentState)])
        let first = try await rawWrite(probe, mac: mac, key: nil)
        guard let error = first.error else { return .notRequired }
        guard error.indicatesSigningRequired || error.kind == .securityError || error.kind == .invalidParams else {
            throw LightCoreError.protocolError("setState probe: \(error)")
        }

        if let stored = try await loadSigningKey() {
            if try await rawWrite(probe, mac: mac, key: stored).error == nil { return .required }
            await ui.status(WiZPairingText.storedKeyRejected)
        }

        for _ in 0..<3 {
            let choice = try await ui.choose(WiZPairingText.signingChoice, options: WiZPairingText.signingOptions)
            switch choice {
            case 0, 1:
                let key: WiZSigningKey
                do {
                    if choice == 0 {
                        let data = try await ui.importFile(WiZPairingText.importFile, allowedTypes: WiZPairingText.importTypes)
                        key = try WiZSigningKey.parseImport(data)
                    } else {
                        key = try WiZSigningKey.parseImport(try await ui.secureText(WiZPairingText.pasteKey))
                    }
                } catch let importError as WiZSigningKey.ImportError {
                    await ui.status(importError.description)
                    continue
                }
                if try await rawWrite(probe, mac: mac, key: key).error == nil {
                    try await setSigningKey(key)
                    log.info("Stored WiZ signing key \(Log.redact(key.hexString))")
                    return .required
                }
                await ui.status(WiZPairingText.keyRejected)
            default:
                guard try await ui.confirm(WiZPairingText.allowAllControls) else { throw LightCoreError.userCancelled }
                if try await rawWrite(probe, mac: mac, key: nil).error == nil { return .notRequired }
                await ui.status(WiZPairingText.stillUnsigned)
            }
        }
        throw LightCoreError.authenticationRequired(.wiz)
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        _ = try? await loadSigningKey()
        let macs = devices.keys.sorted()
        await withTaskGroup(of: Void.self) { group in
            for mac in macs {
                group.addTask { _ = await self.refresh(mac) }
            }
        }
        if devices.values.contains(where: { !$0.state.reachable }) { startRelocation() }
        return macs.compactMap { devices[$0].map(makeLight) }
    }

    /// Reads `getPilot` and publishes the state. False if the bulb did not answer at its cached IP.
    @discardableResult
    func refresh(_ mac: String) async -> Bool {
        guard let host = devices[mac]?.host else {
            markUnreachable(mac)
            return false
        }
        do {
            let response = try await read(WiZRequest.getPilot(id: makeRequestID()), host: host, quick: true)
            guard response.error == nil, let pilot = response.pilot else { return false }
            if let other = pilot.mac, other != mac {
                log.notice("\(host) now answers as \(other), not \(mac)")
                markUnreachable(mac)
                return false
            }
            learnClock(response, mac: mac)
            applyPilot(pilot, mac: mac)
            return true
        } catch {
            markUnreachable(mac)
            return false
        }
    }

    private func makeLight(_ record: DeviceRecord) -> Light {
        Light(
            id: record.lightID, name: record.name, capabilities: record.capabilities, state: record.state,
            providerRef: record.host?.description ?? "", model: record.module?.moduleName ?? record.systemConfig?.moduleName
        )
    }

    private func applyPilot(_ pilot: WiZPilot, mac: String) {
        guard var record = devices[mac] else { return }
        let next = WiZStateMapping.state(from: pilot, capabilities: record.capabilities)
        let wasReachable = record.state.reachable
        var a = record.state, b = next
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        record.state = next
        devices[mac] = record
        if !wasReachable { emit(.reachabilityChanged(record.lightID, reachable: true)) }
        if a != b || !wasReachable { emit(.stateChanged(record.lightID, next)) }
    }

    private func markReachable(_ mac: String) {
        guard var record = devices[mac], !record.state.reachable else { return }
        record.state.reachable = true
        devices[mac] = record
        emit(.reachabilityChanged(record.lightID, reachable: true))
    }

    private func markUnreachable(_ mac: String) {
        guard var record = devices[mac], record.state.reachable else { return }
        record.state.reachable = false
        devices[mac] = record
        emit(.reachabilityChanged(record.lightID, reachable: false))
    }

    private func learnClock(_ response: WiZResponse, mac: String) {
        if let sigTs = response.sigTs { devices[mac]?.clockOffset = sigTs - WiZSigner.timestamp() }
    }

    // MARK: - Commands

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .wiz, let record = devices[light.stableId] else { throw LightCoreError.lightNotFound(light) }
        let params = WiZCommandEncoder.params(for: command, capabilities: record.capabilities)
        guard !params.isEmpty else { return }
        do {
            try await write(params, mac: record.mac)
        } catch LightCoreError.timeout {
            markUnreachable(record.mac)
            startRelocation()
            throw LightCoreError.unreachable(record.name)
        }
        applyCommand(command, mac: record.mac)
    }

    /// Sends every bulb its datagram back-to-back (no waiting in between, avoiding the "popcorn"
    /// effect), then collects the replies.
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        struct Job {
            var id: LightID
            var mac: String
            var host: IPv4Addr
            var payload: Data
            var signed: Bool
        }
        var failures: [LightID: String] = [:]
        var jobs: [Job] = []
        var usedHosts: Set<IPv4Addr> = []
        let key = try? await loadSigningKey()
        for id in lights {
            guard id.brand == .wiz, let record = devices[id.stableId] else {
                failures[id] = LightCoreError.lightNotFound(id).localizedDescription
                continue
            }
            guard let host = record.host, usedHosts.insert(host).inserted else {
                failures[id] = LightCoreError.unreachable(record.name).localizedDescription
                continue
            }
            let params = WiZCommandEncoder.params(for: command, capabilities: record.capabilities)
            guard !params.isEmpty else { continue }
            let request = WiZRequest.setPilot(params, id: makeRequestID())
            if record.signing == .required {
                guard let key else {
                    failures[id] = LightCoreError.authenticationRequired(.wiz).localizedDescription
                    continue
                }
                let payload = request.encoded(signingKey: key, sigTs: WiZSigner.timestamp(offset: record.clockOffset))
                jobs.append(Job(id: id, mac: record.mac, host: host, payload: payload, signed: true))
            } else {
                jobs.append(Job(id: id, mac: record.mac, host: host, payload: request.encoded(), signed: false))
            }
        }

        var retryIndividually: [LightID] = []
        if !jobs.isEmpty {
            _ = try await ensureRequestSocket()
            let hosts = jobs.map(\.host).sorted()
            for host in hosts { await acquire(host) }
            var tokens: [(Job, Result<UInt64, any Error>)] = []
            for job in jobs {
                tokens.append((job, Result {
                    try begin(payload: job.payload, method: WiZMethod.setPilot, host: job.host,
                              schedule: config.writeRetrySchedule, timeout: config.writeTimeout)
                }))
            }
            for (job, token) in tokens {
                do {
                    let response = try await wait(try token.get())
                    if let error = response.error {
                        if error.indicatesSigningRequired, !job.signed {
                            retryIndividually.append(job.id)
                        } else {
                            failures[job.id] = error.description
                        }
                    } else {
                        if devices[job.mac]?.signing == .unknown { devices[job.mac]?.signing = .notRequired }
                        applyCommand(command, mac: job.mac)
                    }
                } catch {
                    failures[job.id] = String(describing: error)
                    if error is CancellationError { continue }
                    markUnreachable(job.mac)
                }
            }
            for host in hosts { release(host) }
            try Task.checkCancellation()
        }
        for id in retryIndividually {
            do { try await send(command, to: id) } catch { failures[id] = String(describing: error) }
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    /// Short dim pulse to identify a bulb.
    public func identify(_ light: LightID) async throws {
        guard let record = devices[light.stableId] else { throw LightCoreError.lightNotFound(light) }
        let request = WiZRequest.pulse()
        try await write(request.params, method: request.method, mac: record.mac)
    }

    private func applyCommand(_ command: LightCommand, mac: String) {
        guard var record = devices[mac] else { return }
        record.state = record.state.applying(command.normalized(for: record.capabilities))
        record.state.reachable = true
        devices[mac] = record
        emit(.stateChanged(record.lightID, record.state))
    }

    /// Signed-or-unsigned write with error interpretation.
    private func write(_ params: WiZObject, method: String = WiZMethod.setPilot, mac: String) async throws {
        guard let record = devices[mac] else { throw LightCoreError.unreachable(mac) }
        let request = WiZRequest(id: makeRequestID(), method: method, params: params)
        var key: WiZSigningKey?
        if record.signing == .required {
            key = try await loadSigningKey()
            guard key != nil else { throw authenticationFailure() }
        }
        var response = try await rawWrite(request, mac: mac, key: key)
        if let error = response.error, error.indicatesSigningRequired, key == nil {
            devices[mac]?.signing = .required
            guard let stored = try await loadSigningKey() else { throw authenticationFailure() }
            key = stored
            response = try await rawWrite(request, mac: mac, key: stored)
        }
        if let error = response.error {
            if error.kind == .securityError || error.indicatesSigningRequired { throw authenticationFailure() }
            throw LightCoreError.protocolError("\(method): \(error)")
        }
        if devices[mac]?.signing == .unknown { devices[mac]?.signing = .notRequired }
    }

    private func authenticationFailure() -> LightCoreError {
        emit(.needsReauthentication(accountID: Self.homeAccountID))
        return LightCoreError.authenticationRequired(.wiz)
    }

    /// One write exchange; returns the bulb's reply (including error replies) as is.
    private func rawWrite(_ request: WiZRequest, mac: String, key: WiZSigningKey?) async throws -> WiZResponse {
        guard let record = devices[mac], let host = record.host else { throw LightCoreError.unreachable(mac) }
        let payload = key.map { request.encoded(signingKey: $0, sigTs: WiZSigner.timestamp(offset: record.clockOffset)) }
            ?? request.encoded()
        let response = try await perform(payload, method: request.method, host: host,
                                         schedule: config.writeRetrySchedule, timeout: config.writeTimeout)
        learnClock(response, mac: mac)
        return response
    }

    private func read(_ request: WiZRequest, host: IPv4Addr, quick: Bool = false) async throws -> WiZResponse {
        try await perform(request.encoded(), method: request.method, host: host,
                          schedule: quick ? config.quickRetrySchedule : config.retrySchedule,
                          timeout: quick ? config.quickTimeout : config.requestTimeout)
    }

    private func makeRequestID() -> Int {
        nextRequestID = nextRequestID >= 9999 ? 1 : nextRequestID + 1
        return nextRequestID
    }

    // MARK: - Push

    /// Foreground: listen on UDP 38900, register with every bulb now and every 20 s, and poll
    /// bulbs that stay silent for 33 s.
    public func start() async {
        guard !running else { return }
        running = true
        startedAt = clock.now
        lastRegistration = nil
        do {
            let socket = try await transport.bind(port: config.pushPort, broadcast: false)
            pushSocket = socket
            let stream = socket.datagrams
            pushReader = Task { [weak self] in
                for await datagram in stream {
                    guard let self else { return }
                    await self.handlePush(datagram)
                }
            }
            emit(.connectionChanged(connected: true, detail: "Listening for WiZ pushes on UDP \(config.pushPort)"))
        } catch {
            log.error("Push listener unavailable: \(error)")
            emit(.connectionChanged(connected: false, detail: "Push listener unavailable (\(error)); polling every \(config.pollInterval)"))
        }
        for mac in devices.keys {
            devices[mac]?.lastPush = nil
            devices[mac]?.lastPoll = nil
        }
        let tick = config.monitorTick
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, !Task.isCancelled else { return }
                await self.monitorTick()
            }
        }
        lastRegistration = clock.now
        await registerAll()
    }

    /// Background: stop listening and polling.
    public func stop() async {
        guard running else { return }
        running = false
        monitorTask?.cancel()
        monitorTask = nil
        pushReader?.cancel()
        pushReader = nil
        pushSocket?.close()
        pushSocket = nil
        emit(.connectionChanged(connected: false, detail: "Stopped"))
    }

    private func monitorTick() async {
        guard running, let startedAt else { return }
        let now = clock.now
        if let last = lastRegistration, last.duration(to: now) >= config.registrationInterval {
            lastRegistration = now
            Task { await self.registerAll() }
        }
        for (mac, record) in devices where record.host != nil {
            let lastHeard = record.lastPush ?? startedAt
            guard lastHeard.duration(to: now) > config.pushTimeout else { continue }
            if let lastPoll = record.lastPoll, lastPoll.duration(to: now) < config.pollInterval { continue }
            devices[mac]?.lastPoll = now
            Task {
                if await !self.refresh(mac) { self.startRelocationIfRunning() }
            }
        }
    }

    private func startRelocationIfRunning() { if running { startRelocation() } }

    /// Sends `registration register:true` with the current Wi-Fi IP to every known bulb.
    private func registerAll() async {
        guard running else { return }
        phoneIP = await transport.localIPv4Address()
        guard let ip = phoneIP else {
            log.notice("No Wi-Fi address; WiZ push registration skipped (polling instead)")
            return
        }
        let targets = devices.values.compactMap(\.host)
        await withTaskGroup(of: Void.self) { group in
            for host in targets {
                group.addTask { await self.register(host: host, phoneIP: ip) }
            }
        }
    }

    private func register(host: IPv4Addr, phoneIP: IPv4Addr) async {
        let request = WiZRequest.registration(phoneIp: phoneIP.description, phoneMac: config.phoneMac, register: true, id: makeRequestID())
        do {
            _ = try await read(request, host: host, quick: true)
        } catch {
            log.debug("registration to \(host) failed: \(error)")
        }
    }

    private func handlePush(_ datagram: Datagram) async {
        guard let response = try? WiZResponse.parse(datagram.data), response.isPush, let mac = response.mac,
              devices[mac] != nil
        else { return }
        if let key = cachedKey, response.verifySignature(key: key) == false {
            log.notice("Dropping push for \(mac) with an invalid signature")
            return
        }
        if devices[mac]?.host != datagram.host {
            devices[mac]?.host = datagram.host
            if let record = devices[mac] { emit(.lightUpdated(makeLight(record))) }
        }
        devices[mac]?.lastPush = clock.now
        learnClock(response, mac: mac)
        switch response.method {
        case WiZMethod.syncPilot:
            if let pilot = response.pilot { applyPilot(pilot, mac: mac) }
        case WiZMethod.firstBeat:
            // The bulb (re)joined the network: subscribe again and read its state.
            markReachable(mac)
            if running, let ip = phoneIP {
                let host = datagram.host
                Task {
                    await self.register(host: host, phoneIP: ip)
                    await self.refresh(mac)
                }
            }
        default:
            break
        }
    }

    // MARK: - Request engine

    private func ensureRequestSocket() async throws -> any WiZDatagramEndpoint {
        if let requestSocket { return requestSocket }
        if let requestSocketTask { return installRequestSocket(try await requestSocketTask.value) }
        let transport = self.transport
        let task = Task { try await transport.bind(port: 0, broadcast: false) }
        requestSocketTask = task
        defer { requestSocketTask = nil }
        return installRequestSocket(try await task.value)
    }

    /// Idempotent: every concurrent first caller installs (or reuses) the same socket before use.
    private func installRequestSocket(_ socket: any WiZDatagramEndpoint) -> any WiZDatagramEndpoint {
        if let requestSocket { return requestSocket }
        requestSocket = socket
        let stream = socket.datagrams
        requestReader = Task { [weak self] in
            for await datagram in stream {
                guard let self else { return }
                await self.handleReply(datagram)
            }
        }
        return socket
    }

    /// Serialised request to one bulb with re-sends; returns the first reply whose `method` matches.
    private func perform(_ payload: Data, method: String, host: IPv4Addr, schedule: [Duration], timeout: Duration) async throws -> WiZResponse {
        _ = try await ensureRequestSocket()
        await acquire(host)
        defer { release(host) }
        try Task.checkCancellation()
        let token = try begin(payload: payload, method: method, host: host, schedule: schedule, timeout: timeout)
        return try await wait(token)
    }

    private func acquire(_ host: IPv4Addr) async {
        if busyHosts.insert(host).inserted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            hostWaiters[host, default: []].append(continuation)
        }
        // Ownership was handed over by `release`.
    }

    private func release(_ host: IPv4Addr) {
        if var waiters = hostWaiters[host], !waiters.isEmpty {
            let next = waiters.removeFirst()
            hostWaiters[host] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            busyHosts.remove(host)
        }
    }

    /// Sends the first datagram and arms re-sends + timeout. Must hold the host lock.
    private func begin(payload: Data, method: String, host: IPv4Addr, schedule: [Duration], timeout: Duration) throws -> UInt64 {
        guard let socket = requestSocket else { throw LightCoreError.transport("request socket not open") }
        do {
            try socket.sendDatagram(payload, to: host, port: config.bulbPort)
        } catch {
            throw LightCoreError.transport("send to \(host) failed: \(error)")
        }
        nextToken += 1
        let token = nextToken
        if let previous = pendingByHost[host] { complete(previous, .failure(LightCoreError.timeout)) }
        pending[token] = Pending(host: host, method: method, payload: payload)
        pendingByHost[host] = token
        pending[token]?.retryTask = Task { await self.retryLoop(token: token, schedule: schedule, timeout: timeout) }
        return token
    }

    private func retryLoop(token: UInt64, schedule: [Duration], timeout: Duration) async {
        let start = clock.now
        for gap in schedule {
            guard start.duration(to: clock.now) + gap < timeout else { break }
            do { try await Task.sleep(for: gap) } catch { return }
            guard let entry = pending[token], entry.result == nil else { return }
            do {
                try requestSocket?.sendDatagram(entry.payload, to: entry.host, port: config.bulbPort)
            } catch {
                log.debug("re-send to \(entry.host) failed: \(error)")
            }
        }
        let remaining = timeout - start.duration(to: clock.now)
        if remaining > .zero {
            do { try await Task.sleep(for: remaining) } catch { return }
        }
        complete(token, .failure(LightCoreError.timeout))
    }

    private func wait(_ token: UInt64) async throws -> WiZResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WiZResponse, any Error>) in
                guard var entry = pending[token] else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result = entry.result {
                    pending[token] = nil
                    continuation.resume(with: result)
                } else {
                    entry.waiter = continuation
                    pending[token] = entry
                }
            }
        } onCancel: {
            Task { await self.complete(token, .failure(CancellationError())) }
        }
    }

    private func complete(_ token: UInt64, _ result: Result<WiZResponse, any Error>) {
        guard var entry = pending[token], entry.result == nil else { return }
        entry.retryTask?.cancel()
        entry.retryTask = nil
        if pendingByHost[entry.host] == token { pendingByHost[entry.host] = nil }
        if let waiter = entry.waiter {
            pending[token] = nil
            waiter.resume(with: result)
        } else {
            entry.result = result
            pending[token] = entry
        }
    }

    private func handleReply(_ datagram: Datagram) {
        guard let token = pendingByHost[datagram.host], let entry = pending[token], entry.result == nil else { return }
        guard let response = try? WiZResponse.parse(datagram.data) else { return }
        if let method = response.method, method != entry.method {
            log.debug("Dropping late \(method) reply from \(datagram.host) while waiting for \(entry.method)")
            return
        }
        complete(token, .success(response))
    }
}
