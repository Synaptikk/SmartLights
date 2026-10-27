import Foundation
import LightCore
import MerossCodec
import NetKit
import Synchronization

/// Meross Wi-Fi lights: one cloud sign-in fetches the account key and device list, then every
/// command is a signed local `POST http://<ip>/config`. See README.md.
public actor MerossProvider: LightProvider {
    public static let brand: Brand = .meross

    public struct Configuration: Sendable {
        /// Replaces the regional cloud base URL (tests: the fake cloud).
        public var cloudBaseURLOverride: URL?
        public var localPort: UInt16 = MerossConstants.httpPort
        public var localTimeout: Duration = .seconds(5)
        public var cloudTimeout: Duration = .seconds(15)
        /// State polling interval while started (Meross pushes only over MQTT, which we do not use).
        public var pollInterval: Duration = .seconds(30)
        /// Minimum time between /24 sweeps for lights without a working IP.
        public var rediscoveryInterval: Duration = .seconds(600)
        /// Cloud device list refresh age.
        public var deviceListTTL: Duration = .seconds(24 * 3600)
        public var probeTimeout: Duration = .milliseconds(1500)
        public var sweepConcurrency = 32
        /// Local requests per device (meross_lan keeps one connection per host).
        public var perDeviceLimit = RateLimiter<String>.Limit(4, per: .seconds(1))
        /// Cloud sign-ins per hour; Meross locks accounts that log in too often.
        public var signInLimit = RateLimiter<String>.Limit(3, per: .seconds(3600))
        public var cloud: any MerossCloudTransport = MerossTransports.cloud
        public var local: any MerossLocalTransport = MerossTransports.local
        public var sweepHosts: @Sendable () -> [String] = MerossTransports.sweepHosts

        public init() {}
    }

    /// Secret items (`SecretKey(brand: .meross, owner: <account id>, item: ...)`). The password is never stored.
    public enum SecretItem {
        /// Account key: signs every local message.
        public static let key = "key"
        /// Cloud token (device list refresh, logout).
        public static let token = "token"
        public static let userId = "userId"
        /// Cached device list with IP hints and abilities, so LAN control works without the cloud.
        public static let deviceCache = "deviceCache"
        public static let all = [key, token, userId, deviceCache]
    }

    /// Account id used when the key was typed in by hand.
    public static let manualAccountID = "manual"

    public private(set) var account: ProviderAccount?
    public nonisolated let events: AsyncStream<ProviderEvent>

    private let eventContinuation: AsyncStream<ProviderEvent>.Continuation
    private let secretStore: any SecretStore
    private var configuration: Configuration
    private let log = Log(package: "merosskit", category: "provider")
    private let deviceLimiter: RateLimiter<String>
    private let signInLimiter: RateLimiter<String>

    private var key: String?
    private var token: String?
    private var credentialsLoaded = false

    private var records: [String: DeviceRecord] = [:]
    private var recordOrder: [String] = []
    private var listFetchedAt: Date?
    private var models: [String: MerossLightModel] = [:]
    private var reachable: [String: Bool] = [:]
    private var lastPublished: [String: LightState] = [:]
    private var lastSweep: ContinuousClock.Instant?
    private var pollTask: Task<Void, Never>?

    public init(account: ProviderAccount? = nil, secretStore: any SecretStore, configuration: Configuration = Configuration()) {
        self.account = account
        self.secretStore = secretStore
        self.configuration = configuration
        deviceLimiter = RateLimiter(configuration.perDeviceLimit)
        signInLimiter = RateLimiter(configuration.signInLimit)
        (events, eventContinuation) = AsyncStream<ProviderEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Foreground: poll device state and re-locate lights whose IP changed.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// Background: stop polling.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Logs the cloud token out (best effort) and removes every stored secret.
    public func signOut() async {
        stop()
        if let token {
            _ = try? await cloud(MerossCloudAPI.logout(token: token))
        }
        if let owner = account?.id {
            for item in SecretItem.all {
                try? await secretStore.remove(SecretKey(brand: .meross, owner: owner, item: item))
            }
        }
        for id in recordOrder { if let lid = LightID(brand: .meross, stableId: id) { eventContinuation.yield(.lightRemoved(lid)) } }
        account = nil
        key = nil; token = nil; credentialsLoaded = false
        records = [:]; recordOrder = []; listFetchedAt = nil; models = [:]; reachable = [:]; lastPublished = [:]
    }

    // MARK: - Pairing

    /// "Add Meross" placeholder for the Add flow (sign in or enter the key by hand).
    public nonisolated static func accountPlaceholder() -> DiscoveredDevice {
        DiscoveredDevice(id: "account", brand: .meross, name: "Meross account", method: .cloud)
    }

    /// Without a key: asks for the sign-in method (account or key + IP). Then returns the paired
    /// device: the discovered light if known, an IP typed in (`method == .manual`), or an
    /// account-level `PairedDevice` listing every light.
    public func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        try? await ensureCredentials()
        if key == nil {
            let choice = try await ui.choose("How do you want to connect your Meross lights?", options: [
                "Sign in with my Meross account",
                "Enter the device key and IP address (advanced)",
            ])
            if choice == 0 {
                try await signIn(using: ui)
                await ui.status("Loading your Meross devices…")
                try await refreshDeviceList()
                await ui.status("Looking for your Meross lights on this Wi-Fi…")
                await locate(options: DiscoveryOptions(timeout: .seconds(20), methods: [.cached, .sweep]))
            } else {
                let key = try await ui.secureText("Meross key (from your Meross account, see the guide)")
                let host = try await ui.text("IP address of the Meross light").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { throw LightCoreError.userCancelled }
                return try await addManual(host: host, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if device.method == .manual, let host = device.host, records[device.id] == nil {
            return try await addManual(host: host, key: nil)
        }
        if let record = records[device.id], record.isLight {
            if let host = device.host, record.host == nil { updateHost(host, for: record.uuid) }
            _ = try? await refresh(record.uuid)
            return pairedDevice(for: records[device.id] ?? record)
        }
        let lights = lightRecords.compactMap { LightID(brand: .meross, stableId: $0.uuid) }
        return PairedDevice(id: "account:\(account?.id ?? "")", brand: .meross, name: "Meross account", accountID: account?.id,
                            lightIDs: lights, metadata: ["lights": String(lights.count)])
    }

    /// Region, e-mail, password (and the two-factor code if Meross asks). Stores key + token, never the password.
    @discardableResult
    public func signIn(using ui: any PairingInteraction) async throws -> ProviderAccount {
        let regions = MerossRegion.allCases
        let index = try await ui.choose("Where is your Meross account registered?", options: regions.map(\.displayName))
        guard regions.indices.contains(index) else { throw LightCoreError.userCancelled }
        let email = try await ui.text("Meross e-mail address").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw LightCoreError.userCancelled }
        let password = try await ui.secureText("Meross password")
        await ui.status("Signing in to Meross…")
        do {
            return try await signIn(region: regions[index], email: email, password: password)
        } catch MerossCloudError.mfaRequired {
            let code = try await ui.text("Meross sent a verification code (two-factor authentication). Enter it")
            return try await signIn(region: regions[index], email: email, password: password, mfaCode: code)
        }
    }

    /// Programmatic sign-in. Follows one region redirect (apiStatus 1030).
    @discardableResult
    public func signIn(region: MerossRegion, email: String, password: String, mfaCode: String? = nil) async throws -> ProviderAccount {
        guard await signInLimiter.tryAcquire("signIn") else { throw MerossCloudError.rateLimited(0) }
        var base = configuration.cloudBaseURLOverride ?? region.baseURL
        var credentials: MerossCredentials
        do {
            credentials = try await signInRequest(region: region, email: email, password: password, mfaCode: mfaCode, base: base)
        } catch MerossCloudError.redirect(let domain) where URL(string: domain) != nil && !domain.isEmpty {
            base = URL(string: domain)!
            credentials = try await signInRequest(region: region, email: email, password: password, mfaCode: mfaCode, base: base)
        }
        let owner = email.lowercased()
        if let old = account, old.id != owner { await signOut() }
        let domain = credentials.domain ?? base.absoluteString
        account = ProviderAccount(
            id: owner, brand: .meross, displayName: Self.mask(email), region: region.rawValue,
            secretKeys: SecretItem.all.map { SecretKey(brand: .meross, owner: owner, item: $0) },
            metadata: ["domain": domain, "region": region.rawValue])
        key = credentials.key
        token = credentials.token
        credentialsLoaded = true
        try await storeSecret(credentials.key, SecretItem.key)
        try await storeSecret(credentials.token, SecretItem.token)
        try await storeSecret(credentials.userId, SecretItem.userId)
        log.notice("signed in to Meross (\(region.rawValue)) as \(Self.mask(email))")
        return account!
    }

    private func signInRequest(region: MerossRegion, email: String, password: String, mfaCode: String?, base: URL) async throws -> MerossCredentials {
        let request = MerossCloudAPI.signIn(email: email, password: password, region: region, mfaCode: mfaCode)
        let (status, body) = try await http(request, base: base)
        return try MerossCloudAPI.decodeSignIn(status: status, body: body)
    }

    /// Adds a light by IP. With `key` (manual mode) the key is stored under the "manual" account.
    public func addManual(host: String, key manualKey: String?) async throws -> PairedDevice {
        if let manualKey {
            if account == nil {
                account = ProviderAccount(
                    id: Self.manualAccountID, brand: .meross, displayName: "Meross (key entered manually)",
                    secretKeys: SecretItem.all.map { SecretKey(brand: .meross, owner: Self.manualAccountID, item: $0) })
            }
            key = manualKey
            credentialsLoaded = true
            try await storeSecret(manualKey, SecretItem.key)
        }
        guard let key else { throw LightCoreError.authenticationRequired(.meross) }
        let ability = try await probeUnmapped(host: host, request: .getAbility(), key: key)
        let profile = MerossDeviceProfile(ability: ability.payload)
        guard profile.isLight else { throw LightCoreError.unsupported("this Meross device has no light") }
        guard let uuid = ability.uuid else { throw LightCoreError.protocolError("Meross reply without uuid") }
        var record = records[uuid] ?? DeviceRecord(uuid: uuid, name: "Meross light", deviceType: "", manual: true)
        record.profile = profile
        record.host = host
        upsert(record)
        _ = try await refresh(uuid)
        await saveCache()
        let updated = records[uuid] ?? record
        if let light = light(for: updated) { eventContinuation.yield(.lightAdded(light)) }
        return pairedDevice(for: updated)
    }

    // MARK: - Lights

    public func loadLights() async throws -> [Light] {
        try await ensureCredentials()
        guard key != nil else { throw LightCoreError.authenticationRequired(.meross) }
        if token != nil, records.isEmpty || isDeviceListStale {
            do {
                try await refreshDeviceList()
            } catch where !records.isEmpty && !(error is CancellationError) {
                log.notice("Meross device list refresh failed (\(error)); using the cached list")
            }
        }
        for record in lightRecords where record.host != nil {
            _ = try? await refresh(record.uuid)
        }
        return lightRecords.compactMap(light(for:))
    }

    public func send(_ command: LightCommand, to lightID: LightID) async throws {
        guard lightID.brand == .meross, let record = records[lightID.stableId], var model = models[lightID.stableId] else {
            throw LightCoreError.lightNotFound(lightID)
        }
        let requests = MerossCommandPlanner.requests(for: command, model: model)
        guard !requests.isEmpty else {
            if command.effect != nil { throw LightCoreError.unsupported("Meross effects are not implemented") }
            return
        }
        for request in requests {
            _ = try await perform(request, on: record.uuid)
            model.applySent(request)
        }
        models[record.uuid] = model
        publish(record.uuid, force: true)
    }

    /// Re-reads `Appliance.System.All` (and the ability once) for one device.
    @discardableResult
    public func refresh(_ uuid: String) async throws -> LightState? {
        guard var record = records[uuid] else { return nil }
        if record.profile == nil || record.profileIsGuess {
            let ability = try await perform(.getAbility(), on: uuid, plaintext: true)
            record = records[uuid] ?? record
            record.profile = MerossDeviceProfile(ability: ability.payload)
            record.profileIsGuess = false
            upsert(record)
            await saveCache()
            if var model = models[uuid] { model.profile = record.profile!; models[uuid] = model }
            if !(record.profile?.isLight ?? false), let lid = LightID(brand: .meross, stableId: uuid) {
                eventContinuation.yield(.lightRemoved(lid))
                return nil
            }
        }
        let response = try await perform(.getAll(), on: uuid)
        var model = models[uuid] ?? MerossLightModel(profile: record.profile ?? .init(lightCapacity: [.luminance], hasToggleX: true, hasToggle: false))
        let info = model.apply(all: response.payload)
        models[uuid] = model
        if var r = records[uuid] {
            if let mac = info.macAddress { r.mac = mac }
            if let fw = info.firmwareVersion { r.firmwareVersion = fw }
            if r.deviceType.isEmpty, let t = info.type { r.deviceType = t; if r.name == "Meross light" { r.name = "Meross \(t)" } }
            upsert(r)
        }
        publish(uuid, force: false)
        return model.lightState(reachable: true)
    }

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

    /// Unicast probes (manual hosts, cached IPs, the Wi-Fi /24) with a signed `Appliance.System.All`;
    /// the reply's uuid maps the IP to a device. iOS cannot observe DHCP, so the meross_lan DHCP
    /// matchers are replaced by this sweep (Meross has no broadcast discovery on the LAN).
    private func runDiscovery(_ options: DiscoveryOptions, report: @escaping @Sendable (DiscoveredDevice) -> Void) async {
        try? await ensureCredentials()
        let found = FoundSet()
        let probeKey = key ?? ""
        let local = configuration.local
        let port = configuration.localPort
        let timeout = configuration.probeTimeout
        var targets: [(String, DiscoveryMethod)] = []
        if options.methods.contains(.manual) { targets += options.manualHosts.map { ($0, .manual) } }
        if options.methods.contains(.cached) {
            targets += (options.cachedHosts + recordOrder.compactMap { records[$0]?.host }).map { ($0, .cached) }
        }
        var seen = Set<String>()
        targets = targets.filter { seen.insert($0.0).inserted }
        let sweep = options.methods.contains(.sweep) ? configuration.sweepHosts().filter { !seen.contains($0) }.compactMap(IPv4Addr.init) : []
        if !sweep.isEmpty { lastSweep = ContinuousClock.now }
        let sweeper = SubnetSweeper(maxConcurrent: configuration.sweepConcurrency)

        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for (host, method) in targets {
                    group.addTask {
                        if let reply = await Self.probe(host: host, key: probeKey, local: local, port: port, timeout: timeout) {
                            await self.handleProbe(reply, host: host, method: method, found: found, report: report)
                        }
                    }
                }
                if !sweep.isEmpty {
                    group.addTask {
                        let stream = sweeper.stream(sweep) { ip -> (String, MerossResponse)? in
                            guard let r = await Self.probe(host: ip.description, key: probeKey, local: local, port: port, timeout: timeout) else { return nil }
                            return (ip.description, r)
                        }
                        for await (host, reply) in stream {
                            await self.handleProbe(reply, host: host, method: .sweep, found: found, report: report)
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

        if options.methods.contains(.cloud), !Task.isCancelled {
            for record in lightRecords where !found.contains(record.uuid) {
                report(DiscoveredDevice(id: record.uuid, brand: .meross, name: record.name, model: record.deviceType,
                                        host: record.host, port: Int(port), macAddress: record.mac, method: .cloud,
                                        metadata: metadata(for: record)))
            }
        }
    }

    /// Locates IPs without reporting (pairing and maintenance).
    private func locate(options: DiscoveryOptions) async {
        await runDiscovery(options) { _ in }
    }

    /// Any parseable Meross reply (even an invalid-key ERROR, which still names the uuid). Hosts that
    /// answer `Appliance.System.All` with something else get a second, clear-text `Appliance.System.Ability`
    /// probe: firmware with `Appliance.Encrypt.ECDHE` only answers that one unencrypted (meross_lan config flow).
    private static func probe(host: String, key: String, local: any MerossLocalTransport, port: UInt16, timeout: Duration) async -> MerossResponse? {
        func ask(_ request: MerossRequest) async throws -> MerossResponse? {
            let (status, data) = try await local.post(host: host, port: port, body: request.encoded(key: key),
                                                      contentType: "application/json", timeout: timeout)
            guard status == 200, let response = try? MerossResponse.parse(data), response.uuid != nil else { return nil }
            return response
        }
        do {
            if let response = try await ask(.getAll()) { return response }
        } catch {
            return nil // nothing listening
        }
        return try? await ask(.getAbility())
    }

    private func handleProbe(_ response: MerossResponse, host: String, method: DiscoveryMethod, found: FoundSet,
                             report: @Sendable (DiscoveredDevice) -> Void) {
        guard let uuid = response.uuid, found.insert(uuid) else { return }
        let info = MerossSystemInfo(all: response.payload)
        var meta: [String: String] = [:]
        if let t = info.type { meta["deviceType"] = t }
        if let fw = info.firmwareVersion { meta["firmwareVersion"] = fw }
        if let ip = info.innerIp { meta["innerIp"] = ip }
        if response.method == .error { meta["keyMismatch"] = "true" }
        if records[uuid] != nil, response.method != .error {
            updateHost(host, for: uuid)
            if var model = models[uuid] {
                model.apply(all: response.payload)
                models[uuid] = model
            }
        }
        let record = records[uuid]
        report(DiscoveredDevice(
            id: uuid, brand: .meross, name: record?.name ?? "Meross \(info.type ?? "device")",
            model: info.type ?? record?.deviceType, host: host, port: Int(configuration.localPort),
            macAddress: info.macAddress ?? record?.mac, method: method, metadata: meta))
    }

    // MARK: - Cloud

    private var isDeviceListStale: Bool {
        guard let at = listFetchedAt else { return true }
        return Date().timeIntervalSince(at) > configuration.deviceListTTL.seconds
    }

    private var cloudBase: URL {
        if let o = configuration.cloudBaseURLOverride { return o }
        if let d = account?.metadata["domain"], let url = URL(string: d) { return url }
        return (account?.region.flatMap(MerossRegion.init(rawValue:)) ?? .us).baseURL
    }

    /// `/v1/Device/devList`; keeps IPs/abilities of known devices; light-like types only.
    public func refreshDeviceList() async throws {
        try await ensureCredentials()
        guard let token else { throw LightCoreError.authenticationRequired(.meross) }
        let devices: [MerossCloudDevice]
        do {
            let (status, body) = try await cloud(MerossCloudAPI.deviceList(token: token))
            devices = try MerossCloudAPI.decodeDeviceList(status: status, body: body)
        } catch let error as MerossCloudError where error.requiresReauthentication {
            self.token = nil
            if let owner = account?.id { try? await secretStore.remove(SecretKey(brand: .meross, owner: owner, item: SecretItem.token)) }
            eventContinuation.yield(.needsReauthentication(accountID: account?.id))
            throw LightCoreError.authenticationRequired(.meross)
        }
        let hadList = !records.isEmpty
        var seen = Set<String>()
        for device in devices {
            var record = records[device.uuid] ?? DeviceRecord(uuid: device.uuid, name: device.name, deviceType: device.deviceType)
            record.name = device.name
            record.deviceType = device.deviceType
            record.firmwareVersion = device.firmwareVersion ?? record.firmwareVersion
            record.manual = false
            if record.profile == nil, let guess = MerossDeviceProfile.guess(deviceType: device.deviceType) {
                record.profile = guess
                record.profileIsGuess = true
            }
            guard record.profile?.isLight == true else { continue }
            seen.insert(device.uuid)
            let isNew = records[device.uuid] == nil
            upsert(record)
            if hadList, let l = light(for: record) { eventContinuation.yield(isNew ? .lightAdded(l) : .lightUpdated(l)) }
        }
        for uuid in recordOrder where !seen.contains(uuid) && records[uuid]?.manual != true {
            records[uuid] = nil
            models[uuid] = nil
            if let lid = LightID(brand: .meross, stableId: uuid) { eventContinuation.yield(.lightRemoved(lid)) }
        }
        recordOrder = recordOrder.filter { records[$0] != nil }
        listFetchedAt = Date()
        await saveCache()
    }

    private func cloud(_ request: MerossCloudRequest) async throws -> (Int, Data) {
        try await http(request, base: cloudBase)
    }

    private func http(_ request: MerossCloudRequest, base: URL) async throws -> (Int, Data) {
        do {
            let r = try await configuration.cloud.perform(request, baseURL: base, timeout: configuration.cloudTimeout)
            return (r.status, r.body)
        } catch let error as LightCoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LightCoreError.transport(error.localizedDescription)
        }
    }

    // MARK: - Local requests

    /// Signs, (optionally) encrypts and posts `request` to the device's current IP; checks the reply's
    /// uuid (an IP may now belong to another device) and maps errors.
    private func perform(_ request: MerossRequest, on uuid: String, plaintext: Bool = false) async throws -> MerossResponse {
        guard let record = records[uuid] else { throw LightCoreError.protocolError("unknown Meross device") }
        guard let host = record.host else {
            throw LightCoreError.unreachable("\(record.name) has no known IP address yet")
        }
        guard let key else { throw LightCoreError.authenticationRequired(.meross) }
        try await deviceLimiter.acquire(uuid)
        var body = request.encoded(key: key)
        var contentType = "application/json"
        var cipherKey: [UInt8]?
        if !plaintext, record.profile?.encrypted == true {
            let k = MerossCrypto.encryptionKey(uuid: uuid, key: key, mac: record.mac ?? MerossSystemInfo.macAddress(fromUUID: uuid))
            body = try MerossCrypto.encryptBody(body, key: k)
            contentType = "application/octet-stream"
            cipherKey = k
        }
        let status: Int
        var data: Data
        do {
            (status, data) = try await configuration.local.post(host: host, port: configuration.localPort, body: body,
                                                                contentType: contentType, timeout: configuration.localTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            setReachable(false, uuid)
            throw LightCoreError.unreachable("\(record.name) (\(host)): \(error.localizedDescription)")
        }
        guard status == 200 else {
            setReachable(false, uuid)
            throw LightCoreError.unreachable("\(record.name) answered HTTP \(status)")
        }
        if let cipherKey { data = (try? MerossCrypto.decryptBody(data, key: cipherKey)) ?? data }
        let response: MerossResponse
        do {
            response = try MerossResponse.parse(data)
        } catch {
            throw LightCoreError.protocolError("\(record.name): \(error.localizedDescription)")
        }
        if let replyUUID = response.uuid, replyUUID.lowercased() != uuid.lowercased() {
            // DHCP gave this IP to another device: forget it and let discovery find ours again.
            if var r = records[uuid] { r.host = nil; upsert(r) }
            setReachable(false, uuid)
            throw LightCoreError.unreachable("\(record.name) moved to another IP address")
        }
        do {
            try response.checked()
        } catch MerossDeviceError.invalidKey {
            eventContinuation.yield(.needsReauthentication(accountID: account?.id))
            throw LightCoreError.authenticationRequired(.meross)
        } catch let error as MerossDeviceError {
            throw LightCoreError.protocolError(error.localizedDescription)
        }
        setReachable(true, uuid)
        return response
    }

    /// One request to an IP that is not (yet) mapped to a device.
    private func probeUnmapped(host: String, request: MerossRequest, key: String) async throws -> MerossResponse {
        let (status, data): (Int, Data)
        do {
            (status, data) = try await configuration.local.post(host: host, port: configuration.localPort, body: request.encoded(key: key),
                                                                contentType: "application/json", timeout: configuration.localTimeout)
        } catch {
            throw LightCoreError.unreachable("\(host): \(error.localizedDescription)")
        }
        guard status == 200 else { throw LightCoreError.unreachable("\(host) answered HTTP \(status)") }
        let response = try MerossResponse.parse(data)
        do {
            return try response.checked()
        } catch MerossDeviceError.invalidKey {
            throw LightCoreError.authenticationRequired(.meross)
        }
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            for record in lightRecords where record.host != nil {
                if Task.isCancelled { return }
                _ = try? await refresh(record.uuid)
            }
            let lost = lightRecords.contains { $0.host == nil || reachable[$0.uuid] == false }
            let due = lastSweep.map { ContinuousClock.now - $0 > configuration.rediscoveryInterval } ?? true
            if lost {
                await locate(options: DiscoveryOptions(timeout: .seconds(15), methods: due ? [.cached, .sweep] : [.cached]))
            }
            do {
                try await Task.sleep(for: configuration.pollInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - State

    private struct DeviceRecord: Codable, Sendable, Hashable {
        var uuid: String
        var name: String
        var deviceType: String
        var firmwareVersion: String?
        var host: String?
        var mac: String?
        var profile: MerossDeviceProfile?
        var profileIsGuess = false
        /// Added by IP + key, not from the cloud list (survives list refreshes).
        var manual = false

        var isLight: Bool { profile?.isLight ?? false }
    }

    private var lightRecords: [DeviceRecord] {
        recordOrder.compactMap { records[$0] }.filter(\.isLight)
    }

    private func upsert(_ record: DeviceRecord) {
        if records[record.uuid] == nil { recordOrder.append(record.uuid) }
        records[record.uuid] = record
        if models[record.uuid] == nil, let profile = record.profile {
            models[record.uuid] = MerossLightModel(profile: profile)
        }
    }

    private func updateHost(_ host: String, for uuid: String) {
        guard var record = records[uuid], record.host != host else { return }
        record.host = host
        upsert(record)
        Task { await self.saveCache() }
    }

    private func setReachable(_ value: Bool, _ uuid: String) {
        guard reachable[uuid] != value else { return }
        reachable[uuid] = value
        if let lid = LightID(brand: .meross, stableId: uuid) {
            eventContinuation.yield(.reachabilityChanged(lid, reachable: value))
        }
    }

    /// Emits `stateChanged` when the state differs from the last one published (or always with `force`).
    private func publish(_ uuid: String, force: Bool) {
        guard let model = models[uuid], let lid = LightID(brand: .meross, stableId: uuid) else { return }
        let state = model.lightState(reachable: reachable[uuid] ?? true)
        var comparable = state
        comparable.updatedAt = .distantPast
        if !force, lastPublished[uuid] == comparable { return }
        lastPublished[uuid] = comparable
        eventContinuation.yield(.stateChanged(lid, state))
    }

    private func light(for record: DeviceRecord) -> Light? {
        guard let id = LightID(brand: .meross, stableId: record.uuid), let profile = record.profile, profile.isLight else { return nil }
        let model = models[record.uuid] ?? MerossLightModel(profile: profile)
        return Light(id: id, name: record.name, capabilities: profile.capabilities,
                     state: model.lightState(reachable: record.host != nil && (reachable[record.uuid] ?? false)),
                     providerRef: record.uuid, manufacturer: "Meross", model: record.deviceType.isEmpty ? nil : record.deviceType)
    }

    private func pairedDevice(for record: DeviceRecord) -> PairedDevice {
        PairedDevice(id: record.uuid, brand: .meross, name: record.name, model: record.deviceType, hostHint: record.host,
                     port: Int(configuration.localPort), accountID: account?.id,
                     lightIDs: LightID(brand: .meross, stableId: record.uuid).map { [$0] } ?? [], metadata: metadata(for: record))
    }

    private func metadata(for record: DeviceRecord) -> [String: String] {
        var m: [String: String] = ["deviceType": record.deviceType]
        if let v = record.firmwareVersion { m["firmwareVersion"] = v }
        if let v = record.mac { m["mac"] = v }
        if record.profile?.encrypted == true { m["encrypted"] = "true" }
        if let c = record.profile?.lightCapacity { m["capacity"] = String(c.rawValue) }
        return m
    }

    // MARK: - Secrets

    private func ensureCredentials() async throws {
        guard !credentialsLoaded, let owner = account?.id else { return }
        let store = secretStore
        func load(_ item: String) async throws -> String? {
            try await store.string(for: SecretKey(brand: .meross, owner: owner, item: item))
        }
        key = try await load(SecretItem.key)
        token = try await load(SecretItem.token)
        if records.isEmpty, let cache = try await load(SecretItem.deviceCache),
           let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: Data(cache.utf8)) {
            for record in snapshot.devices { upsert(record) }
            listFetchedAt = snapshot.fetchedAt
        }
        credentialsLoaded = true
    }

    private struct CacheSnapshot: Codable {
        var fetchedAt: Date?
        var devices: [DeviceRecord]
    }

    private func saveCache() async {
        let snapshot = CacheSnapshot(fetchedAt: listFetchedAt, devices: recordOrder.compactMap { records[$0] })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? await storeSecret(String(decoding: data, as: UTF8.self), SecretItem.deviceCache)
    }

    private func storeSecret(_ value: String, _ item: String) async throws {
        guard let owner = account?.id else { return }
        try await secretStore.set(value, for: SecretKey(brand: .meross, owner: owner, item: item))
    }

    /// `jo***@example.com`.
    static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return String(email.prefix(2)) + "***" }
        return String(email[..<at].prefix(2)) + "***" + String(email[at...])
    }
}

/// Thread-safe set of uuids seen during one discovery run.
final class FoundSet: Sendable {
    private let ids = Mutex<Set<String>>([])
    func insert(_ id: String) -> Bool { ids.withLock { $0.insert(id).inserted } }
    func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}
