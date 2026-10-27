import Foundation
import GoveeCodec
import LightCore
import NetKit

/// Govee as a SmartLights provider: LAN API first, Developer (cloud) API as a per-device fallback.
///
/// - Devices are keyed by the Govee `device` id (MAC-like, identical on LAN and cloud); IPs are hints.
/// - LAN: one UDP socket on 4002. Discovery sends `scan` to 239.255.255.250:4001 when broadcast is
///   available (multicast entitlement), always unicast `scan` to manual/cached hosts, and sweeps the
///   /24 with unicast scans when broadcast is not available. Commands go to the device's 4003.
/// - Cloud: an API key (pasted during pairing, stored in `SecretStore`) adds every light on the
///   account; devices whose SKU has no LAN API are controlled through the cloud only.
/// - While `start()`ed: `devStatus` polling every 10 s for LAN devices, cloud `device/state` polling
///   (>= 60 s, stretched to fit the ~10,000 requests/day budget) for devices not reachable on LAN.
public actor GoveeProvider: LightProvider {
    public static let brand: Brand = .govee

    /// Id of the pseudo-device that stands for "connect the Govee Developer API" in the add flow.
    public static let cloudAccountDeviceID = "govee-developer-api"
    /// `ProviderAccount.id` of the (single) Govee API-key account.
    public static let accountID = "govee-developer-api"
    /// Prompt shown by `pair` when an API key is needed.
    public static let apiKeyPrompt = "Paste your Govee API key"
    /// Where the API key is stored.
    public static let apiKeySecret = SecretKey(brand: .govee, owner: accountID, item: "apiKey")

    /// The pseudo-device the wizard passes to `pair` to connect a Govee account by API key.
    public static var cloudAccountDevice: DiscoveredDevice {
        DiscoveredDevice(id: cloudAccountDeviceID, brand: .govee, name: "Govee account (API key)", method: .cloud,
                         metadata: ["kind": "account"])
    }

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var multicastAddress: String = GoveeLAN.multicastAddress
        /// Device port for `scan` (4001).
        public var scanPort: UInt16 = GoveeLAN.scanPort
        /// Device port for commands (4003).
        public var controlPort: UInt16 = GoveeLAN.controlPort
        /// `devStatus` polling period while started.
        public var lanPollInterval: Duration = .seconds(10)
        /// How long to wait for a `devStatus` reply.
        public var lanStatusTimeout: Duration = .seconds(2)
        /// A LAN device not heard from for this long is considered off the LAN (cloud fallback).
        public var lanStaleAfter: Duration = .seconds(35)
        /// Re-scan for IP changes every N LAN polls.
        public var rescanEveryPolls: Int = 6
        /// Multicast scan repetitions per discovery (UDP is lossy).
        public var scanRepeats: Int = 3
        public var scanRepeatInterval: Duration = .seconds(1)
        /// Pause between datagrams of one command (`turn`, `brightness`, `colorwc`). `[verify]`
        public var lanCommandSpacing: Duration = .milliseconds(30)
        /// After a LAN command, read back `devStatus` after this delay (nil = never).
        public var lanConfirmDelay: Duration? = .milliseconds(500)
        /// Per-device LAN send limit.
        public var lanLimit = RateLimiter<String>.Limit(capacity: 5, refillPerSecond: 10)
        /// Hosts for the unicast /24 sweep (default: current Wi-Fi subnet on Apple platforms).
        public var sweepHosts: @Sendable () -> [String] = GoveeProvider.defaultSweepHosts
        public var sweepMaxConcurrent: Int = 16
        public var sweepLaunchInterval: Duration? = .milliseconds(5)
        /// Daily request budget for the API key.
        public var budget: GoveeCloudBudget = .default
        /// Minimum age of the cached cloud device list before `loadLights`/discovery refetch it.
        public var cloudDeviceListMaxAge: Duration = .seconds(60)
        /// Documented Developer API limits.
        public var cloudDevicesLimit = RateLimiter<String>.Limit(30, per: .seconds(60))
        public var cloudControlDeviceLimit = RateLimiter<String>.Limit(capacity: 6, refillPerSecond: 2)
        public var cloudControlAccountLimit = RateLimiter<String>.Limit(capacity: 80, refillPerSecond: 12)
        public var cloudStateDeviceLimit = RateLimiter<String>.Limit(30, per: .seconds(60))

        public init() {}
    }

    /// Unicast sweep hosts: the current Wi-Fi /24 on Apple platforms, none elsewhere.
    public static let defaultSweepHosts: @Sendable () -> [String] = {
        #if canImport(Darwin)
        SubnetSweeper.currentWiFiHosts().map(\.description)
        #else
        []
        #endif
    }

    // MARK: State

    struct DeviceRecord: Sendable {
        var id: String
        var sku: String
        var name: String
        var host: String?
        var lanSeen: Date?
        /// Answered a LAN scan or is on the LAN allow-list.
        var lanCapable: Bool
        var cloud: GoveeCloudDevice?
        /// Explicitly paired (LAN devices) — cloud devices are lights whenever the account is set.
        var paired: Bool
        var state: LightState
        var metadata: [String: String]
    }

    struct YieldedInfo {
        var hasHost: Bool
        var hasCloud: Bool
        var method: DiscoveryMethod
    }

    struct DiscoverySession {
        var continuation: AsyncStream<DiscoveredDevice>.Continuation
        var yielded: [String: YieldedInfo] = [:]
        var manualHosts: Set<String>
        var cachedHosts: Set<String>
        var broadcastSent = false
    }

    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let configuration: Configuration
    private let lanTransport: (any GoveeLANTransport)?
    private let http: any GoveeHTTPTransport
    private let secrets: any SecretStore
    private let log = Log(package: "goveekit", category: "provider")

    public private(set) var account: ProviderAccount?
    /// Whether multicast may be used outside `discover` (polling re-scans).
    public private(set) var broadcastAvailable: Bool

    private var records: [String: DeviceRecord] = [:]
    private var apiKeyCache: String?
    private var apiKeyLoaded = false
    private var cloudListFetchedAt: ContinuousClock.Instant?
    private var quota: GoveeDailyQuota
    private var loadedOnce = false

    private var lanOpen = false
    private var receiveTask: Task<Void, Never>?
    private var statusWaiters: [String: [UUID: GoveeOneShot<GoveeDevStatus>]] = [:]
    private var sessions: [UUID: DiscoverySession] = [:]
    private var sendTails: [String: Task<Void, any Error>] = [:]
    private var lanPollTask: Task<Void, Never>?
    private var cloudPollTask: Task<Void, Never>?

    private let lanLimiter: RateLimiter<String>
    private let devicesLimiter: RateLimiter<String>
    private let controlDeviceLimiter: RateLimiter<String>
    private let controlAccountLimiter: RateLimiter<String>
    private let stateLimiter: RateLimiter<String>

    /// - Parameters:
    ///   - lanTransport: nil disables the LAN API (cloud only).
    ///   - httpTransport: Developer API transport (`URLSessionGoveeHTTPTransport()` in the app).
    ///   - secrets: Keychain in the app; holds the API key under `apiKeySecret`.
    ///   - account: the persisted Govee account, if the user connected one.
    ///   - pairedDevices: devices from `DeviceStore` (their `hostHint` is used for unicast control).
    public init(
        configuration: Configuration = Configuration(),
        lanTransport: (any GoveeLANTransport)?,
        httpTransport: any GoveeHTTPTransport = URLSessionGoveeHTTPTransport(),
        secrets: any SecretStore,
        account: ProviderAccount? = nil,
        pairedDevices: [PairedDevice] = [],
        broadcastAvailable: Bool = false
    ) {
        self.configuration = configuration
        self.lanTransport = lanTransport
        self.http = httpTransport
        self.secrets = secrets
        self.account = account
        self.broadcastAvailable = broadcastAvailable
        self.quota = GoveeDailyQuota(budget: configuration.budget)
        lanLimiter = RateLimiter(configuration.lanLimit)
        devicesLimiter = RateLimiter(configuration.cloudDevicesLimit)
        controlDeviceLimiter = RateLimiter(configuration.cloudControlDeviceLimit)
        controlAccountLimiter = RateLimiter(configuration.cloudControlAccountLimit)
        stateLimiter = RateLimiter(configuration.cloudStateDeviceLimit)
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(512))
        for device in pairedDevices where device.brand == .govee && device.metadata["kind"] != "account" {
            let id = GoveeDeviceID.normalize(device.id)
            let sku = device.metadata["sku"] ?? device.model ?? ""
            records[id] = DeviceRecord(
                id: id, sku: sku, name: device.name, host: device.hostHint, lanSeen: nil,
                lanCapable: device.metadata["lan"] != "unsupported" && (device.hostHint != nil || GoveeSKUCatalog.isLANCapable(sku)),
                cloud: nil, paired: true, state: LightState(reachable: false), metadata: device.metadata
            )
        }
    }

    #if canImport(Darwin)
    /// Production wiring: NetKit LAN transport on 4002 + URLSession Developer API.
    public static func live(secrets: any SecretStore, account: ProviderAccount?, pairedDevices: [PairedDevice],
                            broadcastAvailable: Bool) -> GoveeProvider {
        GoveeProvider(lanTransport: NetKitGoveeLANTransport(), secrets: secrets, account: account,
                      pairedDevices: pairedDevices, broadcastAvailable: broadcastAvailable)
    }
    #endif

    deinit {
        receiveTask?.cancel()
        lanPollTask?.cancel()
        cloudPollTask?.cancel()
        continuation.finish()
    }

    /// Updates whether multicast may be used (after the app re-checks the entitlement).
    public func setBroadcastAvailable(_ available: Bool) {
        broadcastAvailable = available
    }

    // MARK: - Lifecycle

    /// Starts `devStatus` polling (10 s) for LAN devices and budgeted cloud polling. Idempotent.
    public func start() async {
        if lanPollTask == nil, lanTransport != nil {
            let interval = configuration.lanPollInterval
            lanPollTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollLAN(rescan: tick > 0 && tick % max(1, self.configuration.rescanEveryPolls) == 0)
                    tick += 1
                    guard (try? await Task.sleep(for: interval)) != nil else { return }
                }
            }
        }
        if cloudPollTask == nil {
            cloudPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = await self.pollCloud()
                    guard (try? await Task.sleep(for: interval)) != nil else { return }
                }
            }
        }
    }

    /// Stops polling and closes the LAN socket.
    public func stop() async {
        lanPollTask?.cancel()
        lanPollTask = nil
        cloudPollTask?.cancel()
        cloudPollTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        if lanOpen { await lanTransport?.close() }
        lanOpen = false
    }

    // MARK: - LightProvider: discovery

    public func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        let task = Task { await self.runDiscovery(options: options, continuation: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDiscovery(options: DiscoveryOptions, continuation: AsyncStream<DiscoveredDevice>.Continuation) async {
        let sessionID = UUID()
        let methods = options.methods
        let manual = methods.contains(.manual) ? options.manualHosts.map(Self.trimHost).filter { !$0.isEmpty } : []
        var cached = methods.contains(.cached) ? options.cachedHosts.map(Self.trimHost) : []
        if methods.contains(.cached) {
            cached += records.values.compactMap(\.host)
        }
        cached = Array(Set(cached).subtracting(manual)).sorted()
        sessions[sessionID] = DiscoverySession(continuation: continuation, manualHosts: Set(manual), cachedHosts: Set(cached))
        if options.broadcastAvailable { broadcastAvailable = true }

        var lanReady = false
        let wantsLAN = !methods.isDisjoint(with: [.broadcast, .manual, .cached, .sweep])
        if wantsLAN, lanTransport != nil {
            do {
                try await ensureLAN()
                lanReady = true
            } catch {
                log.error("LAN socket unavailable: \(error)")
                self.continuation.yield(.error("Govee LAN: cannot open UDP port \(GoveeLAN.listenPort) (\(error))"))
            }
        }

        let useMulticast = lanReady && methods.contains(.broadcast) && options.broadcastAvailable
        let useSweep = lanReady && methods.contains(.sweep) && !options.broadcastAvailable
        let useCloud = methods.contains(.cloud)
        let unicastHosts = lanReady ? manual + cached : []
        if useMulticast { sessions[sessionID]?.broadcastSent = true }

        await withTaskGroup(of: Void.self) { group in
            if useMulticast {
                group.addTask { await self.multicastScans() }
            }
            if !unicastHosts.isEmpty {
                group.addTask {
                    for host in unicastHosts { try? await self.sendScan(to: host) }
                }
            }
            if useSweep {
                let skip = Set(unicastHosts)
                group.addTask { await self.sweep(skipping: skip) }
            }
            if useCloud {
                group.addTask { await self.discoverCloud(sessionID: sessionID) }
            }
            try? await Task.sleep(for: options.timeout)
            group.cancelAll()
        }
        sessions[sessionID] = nil
        continuation.finish()
    }

    private func multicastScans() async {
        for attempt in 0..<max(1, configuration.scanRepeats) {
            if attempt > 0 { guard (try? await Task.sleep(for: configuration.scanRepeatInterval)) != nil else { return } }
            do {
                try await lanTransport?.send(GoveeLANCommand.scan.encoded(), to: configuration.multicastAddress, port: configuration.scanPort)
            } catch {
                log.notice("multicast scan failed: \(error)")
                continuation.yield(.error("Govee multicast scan failed (multicast entitlement?): \(error)"))
                return
            }
        }
    }

    private func sendScan(to host: String) async throws {
        try await lanTransport?.send(GoveeLANCommand.scan.encoded(), to: host, port: configuration.scanPort)
    }

    private func sweep(skipping: Set<String>) async {
        let hosts = configuration.sweepHosts().filter { !skipping.contains($0) }.compactMap(IPv4Addr.init)
        guard !hosts.isEmpty else { return }
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepMaxConcurrent, launchInterval: configuration.sweepLaunchInterval)
        _ = await sweeper.sweep(hosts) { host -> Int? in
            try? await self.sendScan(to: host.description)
            return nil
        }
    }

    private func discoverCloud(sessionID: UUID) async {
        guard await apiKey() != nil else { return }
        do {
            try await refreshCloudDevices(force: false)
        } catch {
            continuation.yield(.error("Govee cloud device list: \(error)"))
            return
        }
        for record in records.values.sorted(by: { $0.id < $1.id }) where record.cloud?.isLight == true {
            yield(record, method: .cloud, to: sessionID)
        }
    }

    private func discovered(_ record: DeviceRecord, method: DiscoveryMethod) -> DiscoveredDevice {
        var metadata = record.metadata
        metadata["sku"] = record.sku
        metadata["cloud"] = record.cloud != nil ? "true" : "false"
        metadata["lan"] = record.lanSeen != nil ? "seen" : (record.lanCapable ? "capable" : "unsupported")
        return DiscoveredDevice(
            id: record.id, brand: .govee, name: record.name, model: record.sku,
            host: record.host, port: record.host == nil ? nil : Int(configuration.controlPort),
            method: method, metadata: metadata
        )
    }

    private func yield(_ record: DeviceRecord, method: DiscoveryMethod, to sessionID: UUID) {
        guard var session = sessions[sessionID] else { return }
        let current = YieldedInfo(hasHost: record.host != nil && record.lanSeen != nil, hasCloud: record.cloud != nil, method: method)
        var method = method
        if let previous = session.yielded[record.id] {
            // Re-yield only when LAN or cloud information was added (consumers keep the latest by id).
            guard (current.hasHost && !previous.hasHost) || (current.hasCloud && !previous.hasCloud) else { return }
            // A LAN find keeps its LAN method when the cloud list later adds to it.
            if previous.hasHost { method = previous.method }
        }
        session.yielded[record.id] = YieldedInfo(hasHost: current.hasHost, hasCloud: current.hasCloud, method: method)
        sessions[sessionID] = session
        session.continuation.yield(discovered(record, method: method))
    }

    // MARK: - LightProvider: pairing

    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard device.brand == .govee else { throw LightCoreError.unsupported("\(device.name) is not a Govee device") }
        if device.id == Self.cloudAccountDeviceID || device.metadata["kind"] == "account" {
            let devices = try await connectCloud(using: ui)
            let lightIDs = devices.filter(\.isLight).compactMap { GoveeDeviceID.lightID($0.device) }
            return PairedDevice(id: Self.accountID, brand: .govee, name: "Govee account", accountID: Self.accountID,
                                lightIDs: lightIDs, metadata: ["kind": "account", "devices": "\(lightIDs.count)"], lastSeen: Date())
        }

        let id = GoveeDeviceID.normalize(device.id)
        guard let lightID = GoveeDeviceID.lightID(id) else { throw LightCoreError.invalidLightID(device.id) }
        var record = records[id] ?? DeviceRecord(
            id: id, sku: device.model ?? device.metadata["sku"] ?? "", name: device.name,
            host: device.host, lanSeen: nil,
            lanCapable: device.host != nil || GoveeSKUCatalog.isLANCapable(device.model ?? ""),
            cloud: nil, paired: false, state: LightState(), metadata: device.metadata
        )
        if record.host == nil { record.host = device.host }

        let lanUsable = record.host != nil && lanTransport != nil && record.lanCapable
        if !lanUsable {
            // Cloud-only model (no LAN API) or LAN unavailable: needs the Developer API.
            if await apiKey() == nil {
                _ = try await connectCloud(using: ui)
            } else {
                try await refreshCloudDevices(force: false)
            }
            if let cloud = records[id]?.cloud { record.cloud = cloud }
            guard record.cloud != nil else {
                throw LightCoreError.unreachable("\(device.name) is not on the LAN and not in the Govee account")
            }
        }
        record.paired = true
        records[id] = record
        var metadata = record.metadata
        metadata["sku"] = record.sku
        metadata["lan"] = record.lanSeen != nil ? "seen" : (record.lanCapable ? "capable" : "unsupported")
        return PairedDevice(
            id: id, brand: .govee, name: record.name, model: record.sku,
            hostHint: record.host, port: record.host == nil ? nil : Int(configuration.controlPort),
            accountID: record.cloud != nil ? Self.accountID : nil,
            lightIDs: [lightID], metadata: metadata, lastSeen: record.lanSeen
        )
    }

    /// Asks for the API key, validates it with `GET /user/devices`, stores it and merges the
    /// account's devices. Returns the cloud device list.
    @discardableResult
    public func connectCloud(using ui: any PairingInteraction) async throws -> [GoveeCloudDevice] {
        let key = try await ui.secureText(Self.apiKeyPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LightCoreError.userCancelled }
        await ui.status("Checking the API key with Govee...")
        return try await setAPIKey(key)
    }

    /// Validates and stores an API key (Settings screen), then merges the account's devices.
    @discardableResult
    public func setAPIKey(_ key: String) async throws -> [GoveeCloudDevice] {
        let devices: [GoveeCloudDevice]
        do {
            devices = try await fetchCloudDevices(apiKey: key)
        } catch GoveeCloudError.unauthorized {
            throw LightCoreError.authenticationRequired(.govee)
        } catch let error as GoveeCloudError {
            throw LightCoreError.transport(error.description)
        }
        try await secrets.set(key, for: Self.apiKeySecret)
        apiKeyCache = key
        apiKeyLoaded = true
        let lights = devices.filter(\.isLight)
        account = ProviderAccount(
            id: Self.accountID, brand: .govee, displayName: "Govee Developer API (\(lights.count) lights)",
            secretKeys: [Self.apiKeySecret], metadata: ["devices": "\(lights.count)"]
        )
        log.info("Govee API key stored (\(Log.redact(key))), \(lights.count) lights")
        mergeCloud(devices)
        return devices
    }

    /// Removes the API key; cloud-only lights disappear.
    public func removeAPIKey() async throws {
        try await secrets.remove(Self.apiKeySecret)
        apiKeyCache = nil
        apiKeyLoaded = true
        account = nil
        for (id, record) in records where record.cloud != nil {
            if record.paired {
                records[id]?.cloud = nil
            } else {
                records[id] = nil
                if let lightID = GoveeDeviceID.lightID(id) { continuation.yield(.lightRemoved(lightID)) }
            }
        }
    }

    // MARK: - LightProvider: lights

    public func loadLights() async throws -> [Light] {
        if await apiKey() != nil {
            do {
                try await refreshCloudDevices(force: false)
            } catch let error as LightCoreError {
                if case .authenticationRequired = error, !records.values.contains(where: \.paired) { throw error }
                continuation.yield(.error("Govee cloud: \(error.localizedDescription)"))
            } catch {
                continuation.yield(.error("Govee cloud: \(error)"))
            }
        }
        if lanTransport != nil, records.values.contains(where: { isLight($0) && $0.host != nil }) {
            do {
                try await ensureLAN()
                await refreshLANStatuses(emit: loadedOnce)
            } catch {
                continuation.yield(.error("Govee LAN: \(error)"))
            }
        }
        // Cloud-only lights without any state yet: one state read each (budget permitting).
        for record in records.values where isLight(record) && record.cloud != nil && !lanFresh(record) && record.state.colorMode == nil {
            await refreshCloudState(record.id, emit: loadedOnce)
        }
        loadedOnce = true
        return records.values.filter(isLight).sorted { $0.id < $1.id }.compactMap(light(for:))
    }

    private func isLight(_ record: DeviceRecord) -> Bool {
        if record.cloud?.isLight == true { return true }
        return record.paired && (record.cloud == nil || record.cloud?.isLight == true)
    }

    private func capabilities(of record: DeviceRecord) -> LightCapabilities {
        if let cloud = record.cloud {
            var caps = GoveeMapper.capabilities(for: cloud)
            if let model = GoveeSKUCatalog.lanModel(for: record.sku), model.colorTemperature, caps.supportsColorTemp {
                // LAN firmware may clamp tighter than the cloud range (govee-local-api notes).
                caps.minKelvin = max(caps.minKelvin ?? model.kelvinRange.lowerBound, model.kelvinRange.lowerBound)
                caps.maxKelvin = min(caps.maxKelvin ?? model.kelvinRange.upperBound, model.kelvinRange.upperBound)
            }
            return caps
        }
        return GoveeMapper.capabilities(for: GoveeSKUCatalog.modelForLANDevice(sku: record.sku))
    }

    private func light(for record: DeviceRecord) -> Light? {
        guard let id = GoveeDeviceID.lightID(record.id) else { return nil }
        let ref: String
        if let host = record.host, lanTransport != nil, record.lanCapable {
            ref = "lan:\(host)"
        } else {
            ref = "cloud:\(record.sku)"
        }
        return Light(id: id, name: record.name, capabilities: capabilities(of: record), state: record.state,
                     providerRef: ref, manufacturer: nil, model: record.sku)
    }

    // MARK: - LightProvider: commands

    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard light.brand == .govee else { throw LightCoreError.lightNotFound(light) }
        let id = GoveeDeviceID.normalize(light.stableId)
        guard let record = records[id], isLight(record) else { throw LightCoreError.lightNotFound(light) }
        if command.isEmpty { return }
        let previous = sendTails[id]
        let task = Task<Void, any Error> {
            _ = await previous?.result
            try await self.perform(command, on: id, light: light)
        }
        sendTails[id] = task
        defer { if sendTails[id] == task { sendTails[id] = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Concurrent fan-out (devices are independent on LAN; cloud limits are enforced per device
    /// and per account).
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
            var failures: [LightID: String] = [:]
            for await (id, message) in group {
                if let message { failures[id] = message }
            }
            return failures
        }
        try Task.checkCancellation()
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    private func perform(_ command: LightCommand, on id: String, light: LightID) async throws {
        guard let record = records[id] else { throw LightCoreError.lightNotFound(light) }
        let caps = capabilities(of: record)
        let normalized = command.normalized(for: caps)
        let hasKey = await apiKey() != nil
        let cloudPossible = hasKey && record.cloud != nil
        let needsCloud = normalized.effect != nil && cloudPossible

        var lanError: (any Error)?
        if !needsCloud, let host = record.host, lanTransport != nil, record.lanCapable, lanFresh(record) || !cloudPossible {
            do {
                try await sendLAN(normalized, record: record, host: host, capabilities: caps)
                applyOptimistic(normalized, to: id, light: light)
                scheduleLANConfirm(id)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lanError = error
                log.notice("LAN send to \(id) failed: \(error)")
            }
        }
        if cloudPossible, let cloud = record.cloud {
            try await sendCloud(normalized, device: cloud, isOn: record.state.isOn)
            applyOptimistic(normalized, to: id, light: light)
            return
        }
        if let lanError { throw LightCoreError.transport(String(describing: lanError)) }
        throw LightCoreError.unreachable("\(record.name) is not reachable on the LAN and no Govee API key is set")
    }

    private func applyOptimistic(_ command: LightCommand, to id: String, light: LightID) {
        guard var record = records[id] else { return }
        record.state = record.state.applying(command)
        records[id] = record
        continuation.yield(.stateChanged(light, record.state))
    }

    // MARK: - LAN

    private func ensureLAN() async throws {
        guard !lanOpen, let lanTransport else { return }
        let stream = try await lanTransport.open()
        lanOpen = true
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            for await datagram in stream {
                guard let self else { return }
                await self.handle(datagram)
            }
            await self?.lanClosed()
        }
    }

    private func lanClosed() {
        lanOpen = false
    }

    private func handle(_ datagram: GoveeDatagram) {
        guard let message = GoveeLANResponse.decode(datagram.data) else { return }
        let now = Date()
        switch message {
        case .scan(let scan):
            let id = scan.deviceID
            guard let lightID = GoveeDeviceID.lightID(id) else { return }
            let host = IPv4Addr(scan.ip) != nil ? scan.ip : datagram.host
            var record = records[id] ?? DeviceRecord(
                id: id, sku: scan.sku, name: GoveeMapper.displayName(sku: scan.sku, deviceName: nil),
                host: host, lanSeen: nil, lanCapable: true, cloud: nil, paired: false,
                state: LightState(), metadata: [:]
            )
            let hostChanged = record.host != host
            record.host = host
            record.lanSeen = now
            record.lanCapable = true
            if !scan.sku.isEmpty { record.sku = scan.sku }
            record.metadata.merge(scan.metadata) { _, new in new }
            records[id] = record
            if hostChanged, isLight(record), let light = light(for: record) {
                continuation.yield(.lightUpdated(light))
            }
            _ = lightID
            for (sessionID, session) in sessions {
                let method: DiscoveryMethod
                if session.manualHosts.contains(host) { method = .manual }
                else if session.cachedHosts.contains(host) { method = .cached }
                else if session.broadcastSent { method = .broadcast }
                else { method = .sweep }
                yield(record, method: method, to: sessionID)
            }
        case .devStatus(let status):
            let host = datagram.host
            for waiter in (statusWaiters[host] ?? [:]).values { waiter.resume(status) }
            statusWaiters[host] = nil
            for (id, record) in records where record.host == host {
                update(id, with: status, at: now, emit: true)
            }
        }
    }

    private func update(_ id: String, with status: GoveeDevStatus, at now: Date, emit: Bool) {
        guard var record = records[id], let lightID = GoveeDeviceID.lightID(id) else { return }
        let wasReachable = record.state.reachable
        let next = GoveeMapper.state(from: status, capabilities: capabilities(of: record), at: now)
        let changed = !Self.sameState(record.state, next)
        record.state = next
        record.lanSeen = now
        records[id] = record
        guard emit, isLight(record) else { return }
        if !wasReachable { continuation.yield(.reachabilityChanged(lightID, reachable: true)) }
        if changed { continuation.yield(.stateChanged(lightID, next)) }
    }

    static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var x = a
        x.updatedAt = b.updatedAt
        return x == b
    }

    /// Sends `devStatus` to `host` and waits for the reply (nil on timeout).
    private func requestStatus(host: String) async -> GoveeDevStatus? {
        guard let lanTransport, lanOpen else { return nil }
        let waiter = GoveeOneShot<GoveeDevStatus>()
        let token = UUID()
        statusWaiters[host, default: [:]][token] = waiter
        do {
            try await lanTransport.send(GoveeLANCommand.devStatus.encoded(), to: host, port: configuration.controlPort)
        } catch {
            statusWaiters[host]?[token] = nil
            return nil
        }
        let result = await waiter.wait(timeout: configuration.lanStatusTimeout)
        statusWaiters[host]?[token] = nil
        if statusWaiters[host]?.isEmpty == true { statusWaiters[host] = nil }
        return result
    }

    /// Polls `devStatus` for every LAN light concurrently; marks silent devices unreachable once stale.
    private func refreshLANStatuses(emit: Bool) async {
        let targets = records.values.filter { isLight($0) && $0.host != nil && $0.lanCapable }.map { ($0.id, $0.host!) }
        guard !targets.isEmpty else { return }
        let hosts = Set(targets.map(\.1))
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { _ = await self.requestStatus(host: host) }
            }
        }
        // Replies were applied by `handle`; now age out devices that stayed silent.
        let now = Date()
        let hasKey = await apiKey() != nil
        for (id, _) in targets {
            guard var record = records[id], let lightID = GoveeDeviceID.lightID(id) else { continue }
            let stale = record.lanSeen.map { now.timeIntervalSince($0) > configuration.lanStaleAfter.timeInterval } ?? true
            // Cloud-backed devices stay reachable through the Developer API.
            guard stale, record.cloud == nil || !hasKey else { continue }
            if record.state.reachable {
                record.state.reachable = false
                records[id] = record
                if emit { continuation.yield(.reachabilityChanged(lightID, reachable: false)) }
            }
        }
    }

    private func pollLAN(rescan: Bool) async {
        guard lanTransport != nil, records.values.contains(where: { isLight($0) && $0.host != nil }) else { return }
        do { try await ensureLAN() } catch {
            continuation.yield(.error("Govee LAN: \(error)"))
            return
        }
        if rescan {
            if broadcastAvailable {
                try? await lanTransport?.send(GoveeLANCommand.scan.encoded(), to: configuration.multicastAddress, port: configuration.scanPort)
            }
            for host in Set(records.values.compactMap(\.host)) { try? await sendScan(to: host) }
        }
        await refreshLANStatuses(emit: true)
    }

    private func lanFresh(_ record: DeviceRecord) -> Bool {
        guard let seen = record.lanSeen else { return false }
        return Date().timeIntervalSince(seen) <= configuration.lanStaleAfter.timeInterval
    }

    private func sendLAN(_ command: LightCommand, record: DeviceRecord, host: String, capabilities: LightCapabilities) async throws {
        guard let lanTransport else { throw LightCoreError.unsupported("LAN disabled") }
        try await ensureLAN()
        let messages = GoveeMapper.lanCommands(for: command, capabilities: capabilities, isOn: record.state.isOn)
        for (index, message) in messages.enumerated() {
            if index > 0 { try await Task.sleep(for: configuration.lanCommandSpacing) }
            try await lanLimiter.acquire(record.id)
            try await lanTransport.send(message.encoded(), to: host, port: configuration.controlPort)
        }
    }

    private func scheduleLANConfirm(_ id: String) {
        guard let delay = configuration.lanConfirmDelay else { return }
        Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            await self.confirmLAN(id)
        }
    }

    private func confirmLAN(_ id: String) async {
        guard let host = records[id]?.host else { return }
        _ = await requestStatus(host: host)
    }

    // MARK: - Cloud

    /// The stored API key (cached after the first read).
    private func apiKey() async -> String? {
        if apiKeyLoaded { return apiKeyCache }
        apiKeyCache = (try? await secrets.string(for: Self.apiKeySecret)).flatMap { $0?.isEmpty == false ? $0 : nil }
        apiKeyLoaded = true
        return apiKeyCache
    }

    /// Daily requests left (own count and server headers).
    public func cloudRequestsRemaining() -> Int {
        quota.remaining()
    }

    private func perform(_ request: GoveeHTTPRequest, polling: Bool) async throws -> GoveeHTTPResponse {
        guard quota.canSpend(polling: polling) else { throw GoveeCloudError.budgetExhausted }
        quota.record()
        let response: GoveeHTTPResponse
        do {
            response = try await http.perform(request)
        } catch {
            throw LightCoreError.transport(String(describing: error))
        }
        if let info = GoveeRateLimitInfo.parse(response) { quota.update(info) }
        if response.status == 429,
           let retry = response.header("Retry-After").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), retry > 3600 {
            // A long Retry-After means the daily cap, not a per-minute window.
            quota.exhaust(until: Date().addingTimeInterval(TimeInterval(retry)))
        }
        if response.status == 401 || response.status == 403 {
            continuation.yield(.needsReauthentication(accountID: Self.accountID))
        }
        log.debug("\(request.logDescription) -> \(response.status)")
        return response
    }

    private func fetchCloudDevices(apiKey: String) async throws -> [GoveeCloudDevice] {
        try await devicesLimiter.acquire("account")
        let response = try await perform(GoveeCloudAPI.devicesRequest(apiKey: apiKey), polling: false)
        return try GoveeCloudAPI.decodeDevices(response)
    }

    /// Refetches the cloud device list if older than `cloudDeviceListMaxAge` (or `force`).
    public func refreshCloudDevices(force: Bool) async throws {
        guard let key = await apiKey() else { return }
        if !force, let fetched = cloudListFetchedAt, ContinuousClock.now - fetched < configuration.cloudDeviceListMaxAge { return }
        do {
            let devices = try await fetchCloudDevices(apiKey: key)
            cloudListFetchedAt = .now
            mergeCloud(devices)
        } catch GoveeCloudError.unauthorized {
            throw LightCoreError.authenticationRequired(.govee)
        } catch let error as GoveeCloudError {
            throw LightCoreError.transport(error.description)
        }
    }

    private func mergeCloud(_ devices: [GoveeCloudDevice]) {
        cloudListFetchedAt = .now
        var seen: Set<String> = []
        for device in devices where !device.device.isEmpty {
            let id = device.deviceID
            seen.insert(id)
            let existed = records[id].map(isLight) ?? false
            var record = records[id] ?? DeviceRecord(
                id: id, sku: device.sku, name: GoveeMapper.displayName(sku: device.sku, deviceName: device.deviceName),
                host: nil, lanSeen: nil, lanCapable: GoveeSKUCatalog.isLANCapable(device.sku), cloud: nil, paired: false,
                state: LightState(), metadata: [:]
            )
            let renamed = device.deviceName.map { !$0.isEmpty && $0 != record.name } ?? false
            record.cloud = device
            if !device.sku.isEmpty { record.sku = device.sku }
            if let name = device.deviceName, !name.isEmpty { record.name = name }
            if !record.lanCapable { record.lanCapable = GoveeSKUCatalog.isLANCapable(device.sku) }
            records[id] = record
            if loadedOnce, isLight(record), let light = light(for: record) {
                if !existed { continuation.yield(.lightAdded(light)) }
                else if renamed { continuation.yield(.lightUpdated(light)) }
            }
        }
        for (id, record) in records where record.cloud != nil && !seen.contains(id) {
            if record.paired {
                records[id]?.cloud = nil
            } else {
                records[id] = nil
                if loadedOnce, let lightID = GoveeDeviceID.lightID(id) { continuation.yield(.lightRemoved(lightID)) }
            }
        }
    }

    private func sendCloud(_ command: LightCommand, device: GoveeCloudDevice, isOn: Bool) async throws {
        guard let key = await apiKey() else { throw LightCoreError.authenticationRequired(.govee) }
        let commands = GoveeMapper.cloudCommands(for: command, device: device, isOn: isOn)
        for capability in commands {
            try await controlAccountLimiter.acquire("account")
            try await controlDeviceLimiter.acquire(device.deviceID)
            let request = GoveeCloudAPI.controlRequest(apiKey: key, requestID: UUID().uuidString, sku: device.sku,
                                                       device: device.device, capability: capability)
            do {
                let response = try await perform(request, polling: false)
                _ = try GoveeCloudAPI.decodeControl(response)
            } catch GoveeCloudError.unauthorized {
                throw LightCoreError.authenticationRequired(.govee)
            } catch let error as GoveeCloudError {
                throw LightCoreError.transport(error.description)
            }
        }
    }

    private func refreshCloudState(_ id: String, emit: Bool) async {
        guard let record = records[id], let cloud = record.cloud, let key = await apiKey(),
              let lightID = GoveeDeviceID.lightID(id) else { return }
        guard await stateLimiter.tryAcquire(id) else { return }
        do {
            let request = GoveeCloudAPI.stateRequest(apiKey: key, requestID: UUID().uuidString, sku: cloud.sku, device: cloud.device)
            let response = try await perform(request, polling: true)
            let states = try GoveeCloudAPI.decodeState(response)
            guard var current = records[id] else { return }
            let wasReachable = current.state.reachable
            let next = GoveeMapper.state(fromCloud: states, device: cloud, previous: current.state)
            let changed = !Self.sameState(current.state, next)
            current.state = next
            records[id] = current
            guard emit else { return }
            if wasReachable != next.reachable { continuation.yield(.reachabilityChanged(lightID, reachable: next.reachable)) }
            if changed { continuation.yield(.stateChanged(lightID, next)) }
        } catch GoveeCloudError.budgetExhausted {
            log.notice("cloud poll skipped: daily budget reserve reached")
        } catch {
            if emit { continuation.yield(.error("Govee cloud state for \(record.name): \(error)")) }
        }
    }

    /// One cloud polling round; returns the delay until the next round.
    private func pollCloud() async -> Duration {
        let idle = configuration.budget.minimumPollInterval
        guard await apiKey() != nil else { return idle }
        let targets = records.values.filter { isLight($0) && $0.cloud != nil && !lanFresh($0) }.map(\.id).sorted()
        guard let interval = configuration.budget.pollInterval(devices: targets.count) else { return idle }
        for id in targets {
            if Task.isCancelled { break }
            await refreshCloudState(id, emit: true)
        }
        return interval
    }

    /// Current cloud poll interval for the devices that need it (diagnostics/tests).
    public func cloudPollInterval() -> Duration? {
        let count = records.values.filter { isLight($0) && $0.cloud != nil && !lanFresh($0) }.count
        return configuration.budget.pollInterval(devices: count)
    }

    // MARK: - Helpers

    static func trimHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
