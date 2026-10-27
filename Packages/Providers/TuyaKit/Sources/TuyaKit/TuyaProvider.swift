import Foundation
import LightCore
import NetKit
import Synchronization
import TuyaCodec

/// A paired Tuya device. Contains the local key, so the whole list lives in `SecretStore` only.
public struct TuyaDeviceRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var localKey: String
    /// Last known IP (hint; the record is keyed by `id`).
    public var host: String?
    public var version: TuyaVersion
    public var deviceType: TuyaDeviceType
    public var dpset: TuyaDPSet
    public var productKey: String?

    public init(id: String, name: String, localKey: String, host: String?, version: TuyaVersion,
                deviceType: TuyaDeviceType = .default, dpset: TuyaDPSet, productKey: String? = nil) {
        self.id = id
        self.name = name
        self.localKey = localKey
        self.host = host
        self.version = version
        self.deviceType = deviceType
        self.dpset = dpset
        self.productKey = productKey
    }

    var keyBytes: [UInt8] { TuyaCrypto.keyBytes(localKey) ?? [] }
}

/// Tuya / Smart Life white-label Wi-Fi lights over the local protocol (TCP 6668, versions 3.1-3.5).
/// Every light needs its device id and **local key** (from a Tuya IoT Platform project, see README.md);
/// there is no cloud sign-in. See `docs/ONBOARDING-WALKTHROUGHS.md` §10.
public actor TuyaProvider: LightProvider {
    public static let brand: Brand = .tuya

    public struct Configuration: Sendable {
        public var tcpPort: UInt16 = TuyaConstants.tcpPort
        /// Announcement ports: 6666 (3.1 plaintext) and 6667 (encrypted).
        public var discoveryPorts: [UInt16] = [TuyaConstants.discoveryPortPlain, TuyaConstants.discoveryPortEncrypted]
        /// `REQ_DEVINFO` nudge for 3.5 devices; nil disables it.
        public var appBroadcastPort: UInt16? = TuyaConstants.appBroadcastPort
        /// Whether UDP broadcast may be used (multicast entitlement detected by the app).
        public var broadcastAvailable = false
        public var heartbeatInterval: Duration = TuyaConstants.heartbeatInterval
        public var maxMissedHeartbeats = 3
        public var connectTimeout: Duration = .seconds(5)
        /// Wait for a handshake step or the first status.
        public var responseTimeout: Duration = .seconds(5)
        public var reconnectBackoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(60), jitter: 0.2)
        /// Pause between closing a connection and opening the next one to the same device (pairing probe
        /// vs. session), so the device has freed its single client slot.
        public var connectionHandoffDelay: Duration = .milliseconds(300)
        /// Colour temperature range mapped onto Tuya's 0...max temp value.
        public var kelvinRange: ClosedRange<Int> = TuyaLightModel.defaultKelvinRange
        /// Order tried by "Detect automatically" (most common first).
        public var versionDetectionOrder: [TuyaVersion] = [.v33, .v35, .v34, .v31]
        /// Per-host TCP connect probe used by the unicast discovery fallback.
        public var probeTimeout: Duration = .milliseconds(600)
        public var sweepConcurrency = 32
        public var tcp: any TuyaTCPConnector = TuyaTransports.tcp
        public var udp: any TuyaDatagramTransport = TuyaTransports.udp

        public init() {}
    }

    /// Secret item names (`SecretKey(brand: .tuya, owner: "local", item: ...)`).
    public enum SecretItem {
        public static let owner = "local"
        /// JSON array of `TuyaDeviceRecord` (includes the local keys).
        public static let devices = "devices"
    }

    /// Shown before the key prompts (walkthrough §10, "Local path (advanced)").
    public static let advancedExplainer = """
        Advanced setup. Tuya lights are controlled on your Wi-Fi with a per-light "local key" that Tuya only \
        shows to developer accounts. You need: (1) a free project at iot.tuya.com, (2) your Smart Life / Tuya Smart \
        account linked to it by scanning its QR code in the app, (3) the IoT Core service (the free trial expires \
        and has to be renewed), then the project's device list or the tinytuya wizard shows each light's Device ID \
        and Local Key. Re-pairing a light in Smart Life changes its key. A light accepts one local connection at a \
        time, so close Smart Life (and Home Assistant's local Tuya integrations) while SmartLights is connected. \
        If the box shows a Matter logo, adding the light to Apple Home is simpler. Continue?
        """

    public private(set) var account: ProviderAccount?
    public nonisolated let events: AsyncStream<ProviderEvent>

    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    private let secretStore: any SecretStore
    private var configuration: Configuration
    private let log = Log(package: "tuyakit", category: "provider")

    private var records: [String: TuyaDeviceRecord] = [:]
    private var recordOrder: [String] = []
    private var loaded = false
    private var models: [String: TuyaLightModel] = [:]
    private var reachable: [String: Bool] = [:]
    private var sessions: [String: TuyaDeviceSession] = [:]
    /// When we last closed a connection to a host (discovery probe, failed version attempt).
    private var lastClosed: [String: ContinuousClock.Instant] = [:]

    private let sessionEvents: AsyncStream<TuyaSessionEvent>
    private let sessionContinuation: AsyncStream<TuyaSessionEvent>.Continuation
    private var pumpTask: Task<Void, Never>?
    /// `stop()` was called (background); sessions stay closed until `start()`.
    private var suspended = false

    public init(secretStore: any SecretStore, configuration: Configuration = Configuration()) {
        self.secretStore = secretStore
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (sessionEvents, sessionContinuation) = AsyncStream<TuyaSessionEvent>.makeStream()
    }

    deinit {
        pumpTask?.cancel()
        eventContinuation.finish()
        sessionContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Foreground: (re)open one TCP session per light.
    public func start() async {
        suspended = false
        try? await ensureLoaded()
        await startSessions()
    }

    /// Background: close all sessions (frees the device's single connection for the vendor app).
    public func stop() async {
        suspended = true
        for session in sessions.values { await session.stop() }
    }

    public func setBroadcastAvailable(_ available: Bool) {
        configuration.broadcastAvailable = available
    }

    // MARK: - Pairing

    /// A placeholder `DiscoveredDevice` for "Add a Tuya light by device id" in the Add flow.
    public nonisolated static func manualPlaceholder() -> DiscoveredDevice {
        DiscoveredDevice(id: "manual", brand: .tuya, name: "Tuya light (enter details)", method: .manual)
    }

    /// Asks for what discovery could not supply (device id, local key, IP, protocol version), verifies
    /// the key by connecting and reading the status, then stores the light. Prompts, in order:
    /// `confirm(advancedExplainer)`, `text` device id (skipped when discovered), `secureText` local key,
    /// `text` IP (skipped when known), `choose` version (skipped when the announcement had one).
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        try await ensureLoaded()
        guard try await ui.confirm(Self.advancedExplainer) else { throw LightCoreError.userCancelled }

        var deviceId = Self.isProvisional(device.id) ? "" : device.id
        if deviceId.isEmpty {
            deviceId = try await ui.text("Tuya device ID (Tuya IoT Platform > Devices, or the tinytuya wizard)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !deviceId.isEmpty, LightID(brand: .tuya, stableId: deviceId) != nil else { throw LightCoreError.userCancelled }

        var localKey = ""
        for attempt in 0..<3 {
            localKey = try await ui.secureText("Local key for this light (16 characters)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if TuyaCrypto.keyBytes(localKey) != nil { break }
            if attempt == 2 { throw LightCoreError.protocolError("A Tuya local key has exactly 16 characters") }
            await ui.status("That is not a 16-character local key. Copy it again from the device list.")
        }

        var host = device.host ?? records[deviceId]?.host ?? ""
        if host.isEmpty {
            host = try await ui.text("IP address of the light (tip: reserve it in your router)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !host.isEmpty else { throw LightCoreError.userCancelled }

        var versions: [TuyaVersion]
        if let known = device.metadata["version"].flatMap(TuyaVersion.init(string:)) {
            versions = [known]
        } else {
            let options = ["Detect automatically"] + TuyaVersion.allCases.reversed().map { "Protocol \($0.rawValue)" }
            let index = try await ui.choose("Tuya protocol version (shown as \"version\" in the device list)", options: options)
            versions = index == 0 ? configuration.versionDetectionOrder : [TuyaVersion.allCases.reversed()[index - 1]]
        }

        await ui.status("Connecting to the light… Close the Smart Life app first: a Tuya light accepts one local connection at a time.")
        let name = device.name == Self.manualPlaceholder().name || device.name.isEmpty
            ? "Tuya light \(deviceId.suffix(4))" : device.name
        return try await addDevice(id: deviceId, localKey: localKey, host: host, versions: versions, name: name,
                                   productKey: device.metadata["productKey"])
    }

    /// Programmatic pairing (used by `pair`): verifies the key against the device, detects the bulb type
    /// and stores the record. `versions` are tried in order until one answers.
    @discardableResult
    public func addDevice(id: String, localKey: String, host: String, versions: [TuyaVersion], name: String,
                          productKey: String? = nil) async throws -> PairedDevice {
        try await ensureLoaded()
        guard TuyaCrypto.keyBytes(localKey) != nil else { throw LightCoreError.protocolError("A Tuya local key has exactly 16 characters") }
        guard let lightID = LightID(brand: .tuya, stableId: id) else { throw LightCoreError.invalidLightID(id) }

        // One connection per device: pause our own session while probing.
        let existing = sessions.removeValue(forKey: id)
        if let existing {
            await existing.stop()
            try? await Task.sleep(for: configuration.connectionHandoffDelay)
        }

        let probe: (version: TuyaVersion, type: TuyaDeviceType, dps: [String: TuyaJSON])
        do {
            probe = try await self.probe(id: id, localKey: localKey, host: host, versions: versions)
        } catch {
            if let existing {
                sessions[id] = existing
                if !suspended { await existing.start() }
            }
            throw error
        }
        let dpset = TuyaDPSet.detect(from: probe.dps)
        let record = TuyaDeviceRecord(id: id, name: records[id]?.name ?? name, localKey: localKey, host: host,
                                      version: probe.version, deviceType: probe.type, dpset: dpset, productKey: productKey)
        let isNew = records[id] == nil
        records[id] = record
        if isNew { recordOrder.append(id) }
        var model = TuyaLightModel(dpset: dpset, kelvinRange: configuration.kelvinRange)
        model.apply(probe.dps)
        models[id] = model
        reachable[id] = true
        try await persist()
        log.notice("paired Tuya \(id) (protocol \(probe.version.rawValue), bulb type \(dpset.type.rawValue))")
        if let light = light(for: record) { eventContinuation.yield(isNew ? .lightAdded(light) : .lightUpdated(light)) }
        if !suspended {
            try? await Task.sleep(for: configuration.connectionHandoffDelay)
            if !suspended { await startSessions() }
        }
        return pairedDevice(for: record, lightID: lightID)
    }

    /// Forgets a light and its key.
    public func removeDevice(id: String) async throws {
        try await ensureLoaded()
        if let session = sessions.removeValue(forKey: id) { await session.stop() }
        guard records.removeValue(forKey: id) != nil else { return }
        recordOrder.removeAll { $0 == id }
        models[id] = nil
        reachable[id] = nil
        try await persist()
        if let lid = LightID(brand: .tuya, stableId: id) { eventContinuation.yield(.lightRemoved(lid)) }
    }

    /// Connects with each version until one completes the handshake and answers `DP_QUERY`.
    private func probe(id: String, localKey: String, host: String,
                       versions: [TuyaVersion]) async throws -> (version: TuyaVersion, type: TuyaDeviceType, dps: [String: TuyaJSON]) {
        let settings = sessionSettings.link
        var failures: [String] = []
        for version in versions {
            await waitForHandoff(host)
            let codec = try TuyaSessionCodec(version: version, deviceId: id, localKey: localKey)
            do {
                let link = try await TuyaLink.open(host: host, codec: codec, connector: configuration.tcp, settings: settings)
                do {
                    let dps = try await link.queryStatus(timeout: configuration.responseTimeout)
                    let type = await link.deviceType
                    await link.close()
                    return (version, type, dps)
                } catch {
                    await link.close()
                    throw error
                }
            } catch TuyaLink.Failure.connect(let detail) {
                throw LightCoreError.unreachable(
                    "Could not connect to \(host):\(configuration.tcpPort) (\(detail)). Check the IP, and close the Smart Life app: the light allows one local connection.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastClosed[host] = .now
                log.info("Tuya \(id): protocol \(version.rawValue) failed: \(error)")
                failures.append(version.rawValue)
            }
        }
        throw LightCoreError.protocolError(
            "The light did not accept the local key (tried protocol \(failures.joined(separator: ", "))). Check the key: re-pairing in Smart Life changes it.")
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        ensurePump()
        try await ensureLoaded()
        if !suspended { await startSessions() }
        return orderedRecords.compactMap(light(for:))
    }

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .tuya, let record = records[light.stableId], var model = models[light.stableId] else {
            throw LightCoreError.lightNotFound(light)
        }
        let dps = model.dps(for: command)
        guard !dps.isEmpty else {
            if command.effect != nil { throw LightCoreError.unsupported("Tuya scenes/effects are not implemented") }
            return
        }
        guard let session = sessions[record.id] else { throw LightCoreError.unreachable("Tuya light \(record.name) is not connected") }
        try await session.send(dps)
        // Optimistic; the device confirms with a STATUS push.
        model.apply(dps)
        models[record.id] = model
        eventContinuation.yield(.stateChanged(light, model.lightState(reachable: true)))
    }

    /// Records of all paired devices (secret: contains local keys; for export/diagnostics redact them).
    public var deviceRecords: [TuyaDeviceRecord] { orderedRecords }

    // MARK: - Discovery

    public nonisolated func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        AsyncStream { continuation in
            let task = Task {
                await self.runDiscovery(options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runDiscovery(_ options: DiscoveryOptions, report: @escaping @Sendable (DiscoveredDevice) -> Void) async {
        try? await ensureLoaded()
        let udp = configuration.udp
        let tcp = configuration.tcp
        let port = configuration.tcpPort
        let probeTimeout = configuration.probeTimeout
        let ports = configuration.discoveryPorts
        let appPort = configuration.appBroadcastPort
        let useBroadcast = (options.broadcastAvailable || configuration.broadcastAvailable) && options.methods.contains(.broadcast)
        let found = FoundSet()

        // Unicast fallback: TCP connect probes to 6668. Never probe a host we hold (or are opening) a session
        // to: the device would refuse or drop one of the two connections.
        var connectedHosts: [String: String] = [:]
        for (id, session) in sessions where await session.isRunning {
            if let host = await session.host { connectedHosts[host] = id }
        }
        var targets: [(String, DiscoveryMethod)] = []
        if options.methods.contains(.manual) { targets += options.manualHosts.map { ($0, .manual) } }
        if options.methods.contains(.cached) {
            targets += (options.cachedHosts + orderedRecords.compactMap(\.host)).map { ($0, .cached) }
        }
        let liveHosts = connectedHosts
        let sweepHosts = (!useBroadcast && options.methods.contains(.sweep))
            ? udp.sweepHosts().filter { liveHosts[$0] == nil }.compactMap(IPv4Addr.init) : []
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)
        let hostToRecord = Dictionary(orderedRecords.compactMap { r in r.host.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                if useBroadcast {
                    group.addTask {
                        if let appPort, let ip = udp.localAddress(),
                           let request = try? TuyaDiscovery.deviceInfoRequest(localIP: ip) {
                            await udp.broadcast(Data(request), port: appPort)
                        }
                    }
                    group.addTask {
                        for await datagram in udp.listen(ports: ports, duration: options.timeout) {
                            await self.handleAnnouncement(datagram, found: found, report: report)
                        }
                    }
                }
                var seen = Set<String>()
                for (host, method) in targets where seen.insert(host).inserted {
                    let known = liveHosts[host].flatMap { id in hostToRecord[host].map { _ in id } }
                    group.addTask {
                        if let known {
                            await self.reportKnown(id: known, host: host, method: method, found: found, report: report)
                        } else if await Self.tcpOpen(tcp, host: host, port: port, timeout: probeTimeout) {
                            await self.reportProbe(host: host, method: method, found: found, report: report)
                        }
                    }
                }
                if !sweepHosts.isEmpty {
                    group.addTask {
                        let stream = sweeper.stream(sweepHosts) { ip -> String? in
                            await Self.tcpOpen(tcp, host: ip.description, port: port, timeout: probeTimeout) ? ip.description : nil
                        }
                        for await host in stream {
                            await self.reportProbe(host: host, method: .sweep, found: found, report: report)
                        }
                    }
                }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: options.timeout)
            work.cancel()
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
    }

    private func handleAnnouncement(_ datagram: TuyaDatagram, found: FoundSet,
                                    report: @Sendable (DiscoveredDevice) -> Void) async {
        guard let info = TuyaDiscovery.parse(datagram: [UInt8](datagram.data)), found.insert(info.deviceId) else { return }
        let host = datagram.host
        if var record = records[info.deviceId], record.host != host {
            record.host = host
            records[info.deviceId] = record
            try? await persist()
            if let session = sessions[info.deviceId] { await session.updateHost(host) }
        }
        let record = records[info.deviceId]
        report(DiscoveredDevice(id: info.deviceId, brand: .tuya, name: record?.name ?? "Tuya device \(info.deviceId.suffix(4))",
                                model: info.productKey, host: host, port: Int(configuration.tcpPort), method: .broadcast,
                                metadata: info.metadata))
    }

    private func reportKnown(id: String, host: String, method: DiscoveryMethod, found: FoundSet,
                             report: @Sendable (DiscoveredDevice) -> Void) {
        guard found.insert(id), let record = records[id] else { return }
        report(DiscoveredDevice(id: id, brand: .tuya, name: record.name, model: record.productKey, host: host,
                                port: Int(configuration.tcpPort), method: method, metadata: ["version": record.version.rawValue]))
    }

    /// An open 6668 port: probably a Tuya device. Known hosts map to their record; others get a
    /// provisional `ip:<host>` id and the wizard asks for the device id.
    private func reportProbe(host: String, method: DiscoveryMethod, found: FoundSet,
                             report: @Sendable (DiscoveredDevice) -> Void) {
        lastClosed[host] = .now
        if let record = orderedRecords.first(where: { $0.host == host }) {
            reportKnown(id: record.id, host: host, method: method, found: found, report: report)
            return
        }
        guard found.insert("ip:\(host)") else { return }
        report(DiscoveredDevice(id: "ip:\(host)", brand: .tuya, name: "Possible Tuya device at \(host)", host: host,
                                port: Int(configuration.tcpPort), method: method))
    }

    /// The device frees its single client slot shortly after a close; connecting again at once is refused.
    private func waitForHandoff(_ host: String) async {
        guard let closed = lastClosed[host] else { return }
        let remaining = closed + configuration.connectionHandoffDelay - .now
        if remaining > .zero { try? await Task.sleep(for: remaining) }
    }

    private static func tcpOpen(_ tcp: any TuyaTCPConnector, host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let connection = try? await tcp.connect(host: host, port: port, timeout: timeout) else { return false }
        connection.close()
        return true
    }

    static func isProvisional(_ id: String) -> Bool {
        id.isEmpty || id.hasPrefix("ip:") || id == "manual"
    }

    // MARK: - Storage

    private var devicesKey: SecretKey { SecretKey(brand: .tuya, owner: SecretItem.owner, item: SecretItem.devices) }

    private var orderedRecords: [TuyaDeviceRecord] { recordOrder.compactMap { records[$0] } }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        if let data = try await secretStore.data(for: devicesKey) {
            let list = try JSONDecoder().decode([TuyaDeviceRecord].self, from: data)
            for record in list where records[record.id] == nil {
                records[record.id] = record
                recordOrder.append(record.id)
                models[record.id] = TuyaLightModel(dpset: record.dpset, kelvinRange: configuration.kelvinRange)
            }
        }
        loaded = true
        updateAccount()
    }

    private func persist() async throws {
        let data = try JSONEncoder().encode(orderedRecords)
        try await secretStore.set(data, for: devicesKey)
        updateAccount()
    }

    private func updateAccount() {
        account = records.isEmpty ? nil : ProviderAccount(
            id: SecretItem.owner, brand: .tuya, displayName: "Tuya local keys (\(records.count) light\(records.count == 1 ? "" : "s"))",
            secretKeys: [devicesKey])
    }

    // MARK: - Sessions

    private var sessionSettings: TuyaDeviceSession.Settings {
        TuyaDeviceSession.Settings(port: configuration.tcpPort, connectTimeout: configuration.connectTimeout,
                                   responseTimeout: configuration.responseTimeout,
                                   heartbeatInterval: configuration.heartbeatInterval,
                                   maxMissedHeartbeats: configuration.maxMissedHeartbeats,
                                   backoff: configuration.reconnectBackoff)
    }

    private func startSessions() async {
        ensurePump()
        let settings = sessionSettings
        for record in orderedRecords {
            let session: TuyaDeviceSession
            if let existing = sessions[record.id] {
                session = existing
            } else {
                session = TuyaDeviceSession(record: record, connector: configuration.tcp, settings: settings,
                                            events: sessionContinuation)
                sessions[record.id] = session
            }
            await session.start()
        }
    }

    private func ensurePump() {
        guard pumpTask == nil else { return }
        let stream = sessionEvents
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TuyaSessionEvent) async {
        switch event {
        case .online(let deviceId, let online):
            guard records[deviceId] != nil else { return }
            reachable[deviceId] = online
            guard let id = LightID(brand: .tuya, stableId: deviceId) else { return }
            eventContinuation.yield(.reachabilityChanged(id, reachable: online))
        case .dps(let deviceId, let dps):
            guard var model = models[deviceId], let id = LightID(brand: .tuya, stableId: deviceId) else { return }
            model.apply(dps)
            models[deviceId] = model
            eventContinuation.yield(.stateChanged(id, model.lightState(reachable: reachable[deviceId] ?? true)))
        case .deviceType(let deviceId, let type):
            guard var record = records[deviceId] else { return }
            record.deviceType = type
            records[deviceId] = record
            try? await persist()
        case .problem(let deviceId, let message):
            eventContinuation.yield(.error("Tuya \(records[deviceId]?.name ?? deviceId): \(message)"))
        }
    }

    // MARK: - Helpers

    private func light(for record: TuyaDeviceRecord) -> Light? {
        guard let id = LightID(brand: .tuya, stableId: record.id) else { return nil }
        let model = models[record.id] ?? TuyaLightModel(dpset: record.dpset, kelvinRange: configuration.kelvinRange)
        return Light(id: id, name: record.name, capabilities: model.capabilities,
                     state: model.lightState(reachable: reachable[record.id] ?? false), providerRef: record.id,
                     manufacturer: "Tuya", model: record.productKey)
    }

    private func pairedDevice(for record: TuyaDeviceRecord, lightID: LightID) -> PairedDevice {
        PairedDevice(id: record.id, brand: .tuya, name: record.name, model: record.productKey, hostHint: record.host,
                     port: Int(configuration.tcpPort), accountID: SecretItem.owner, lightIDs: [lightID],
                     metadata: ["version": record.version.rawValue, "bulbType": record.dpset.type.rawValue,
                                "deviceType": record.deviceType.rawValue])
    }
}

/// Thread-safe set of ids seen during one discovery run.
final class FoundSet: Sendable {
    private let ids = Mutex<Set<String>>([])
    func insert(_ id: String) -> Bool { ids.withLock { $0.insert(id).inserted } }
}
