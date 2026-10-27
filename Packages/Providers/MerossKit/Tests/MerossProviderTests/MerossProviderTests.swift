import Foundation
import LightCore
import MerossCodec
import Synchronization
import Testing

@testable import MerossProvider

/// Collects provider events (single consumer) for assertions.
final class EventLog: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[ProviderEvent]>([])
    }

    private let storage = Storage()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<ProviderEvent>) {
        let storage = storage
        task = Task { for await e in stream { storage.events.withLock { $0.append(e) } } }
    }

    var all: [ProviderEvent] { storage.events.withLock { $0 } }

    func wait(timeout: Duration = .seconds(5), _ predicate: @escaping @Sendable (ProviderEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if all.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    deinit { task.cancel() }
}

struct Harness {
    static let key = "0123456789abcdef0123456789abcdef"
    static let lampUUID = "2106040981431251802148e1e9a1b2c3"
    static let lampHost = "192.168.1.50"
    static let euIndex = MerossRegion.allCases.firstIndex(of: .eu)!

    let lan: FakeMerossLAN
    let cloud: FakeMerossCloud
    let store: InMemorySecretStore
    let provider: MerossProvider
    let events: EventLog
    let configuration: MerossProvider.Configuration

    static func make(cloudConfig: FakeMerossCloud.Configuration? = nil, lamp: FakeMerossDeviceState? = nil,
                     sweep: [String] = ["192.168.1.10", "192.168.1.50", "192.168.1.77"],
                     store: InMemorySecretStore = InMemorySecretStore(), account: ProviderAccount? = nil,
                     poll: Duration = .seconds(3600)) -> Harness {
        let lan = FakeMerossLAN(key: key)
        lan.add(lamp ?? FakeMerossDeviceState(uuid: lampUUID), at: lampHost)
        var cfg = cloudConfig ?? FakeMerossCloud.Configuration()
        if cfg.devices.isEmpty {
            cfg.devices = [
                MerossCloudDevice(uuid: lampUUID, name: "Desk lamp", deviceType: "msl120d"),
                MerossCloudDevice(uuid: "1912345678901234567890abcdef0001", name: "Kettle plug", deviceType: "mss310"),
            ]
        }
        let cloud = FakeMerossCloud(cfg)
        var configuration = MerossProvider.Configuration()
        configuration.cloudBaseURLOverride = nil
        configuration.cloud = cloud
        configuration.local = lan
        configuration.sweepHosts = { sweep }
        configuration.pollInterval = poll
        configuration.rediscoveryInterval = .zero
        configuration.localTimeout = .seconds(1)
        configuration.probeTimeout = .milliseconds(500)
        let provider = MerossProvider(account: account, secretStore: store, configuration: configuration)
        return Harness(lan: lan, cloud: cloud, store: store, provider: provider, events: EventLog(provider.events),
                       configuration: configuration)
    }

    func signIn(email: String = "user@example.com", password: String = "s3cret-pw", extra: [ScriptedPairingInteraction.Answer] = []) async throws -> PairedDevice {
        let ui = ScriptedPairingInteraction([.choice(0), .choice(Self.euIndex), .text(email), .text(password)] + extra)
        return try await provider.pair(MerossProvider.accountPlaceholder(), using: ui)
    }

    var lampID: LightID { LightID(brand: .meross, stableId: Self.lampUUID)! }

    func secret(_ item: String, owner: String = "user@example.com") async throws -> String? {
        try await store.string(for: SecretKey(brand: .meross, owner: owner, item: item))
    }
}

@Suite("MerossProvider against fake cloud + LAN", .serialized)
struct MerossProviderTests {
    @Test func signInStoresKeyNotPasswordAndLocatesLights() async throws {
        let h = Harness.make()
        let paired = try await h.signIn()
        #expect(paired.lightIDs == [h.lampID]) // the plug is not a light
        #expect(paired.accountID == "user@example.com")
        let account = try #require(await h.provider.account)
        #expect(account.displayName == "us***@example.com")
        #expect(account.region == "eu")
        #expect(try await h.secret("key") == Harness.key)
        #expect(try await h.secret("token") == "tok-1")
        #expect(try await h.secret("userId") == "1234567")
        for item in MerossProvider.SecretItem.all {
            #expect(!(try await h.secret(item) ?? "").contains("s3cret-pw"))
        }
        #expect(h.cloud.lastSignInParams?["password"]?.stringValue == MerossCrypto.md5Hex("s3cret-pw"))
        #expect(h.cloud.lastSignInParams?["accountCountryCode"]?.stringValue == "eu")
        // The sweep found the lamp's IP, which is cached with the device list.
        let cache = try #require(try await h.secret("deviceCache"))
        #expect(cache.contains(Harness.lampHost))

        let lights = try await h.provider.loadLights()
        #expect(lights.count == 1)
        let lamp = try #require(lights.first)
        #expect(lamp.id == h.lampID && lamp.name == "Desk lamp" && lamp.model == "msl120d")
        #expect(lamp.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(lamp.state.reachable && !lamp.state.isOn && lamp.state.brightness == 0.6)
        #expect(lamp.state.colorMode == .colorTemp && lamp.state.kelvin == MerossLightScale.nativeToKelvin(50))
        #expect(h.cloud.signInCount == 1)
    }

    @Test func commandsGoOverTheLAN() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()

        try await h.provider.send(LightCommand(on: true, brightness: 0.25, color: .rgb(RGB(r: 0, g: 0, b: 255))), to: h.lampID)
        var d = try #require(h.lan.device(Harness.lampUUID))
        #expect(d.isOn && d.luminance == 25 && d.rgb == 255 && d.mode == 5)
        #expect(d.log.suffix(2).map(\.0) == [MerossNamespace.controlLight, MerossNamespace.controlToggleX])
        #expect(await h.events.wait { if case .stateChanged(let id, let s) = $0 { return id == h.lampID && s.isOn && s.rgb == RGB(r: 0, g: 0, b: 255) }; return false })

        try await h.provider.send(LightCommand(color: .kelvin(6500)), to: h.lampID)
        d = try #require(h.lan.device(Harness.lampUUID))
        #expect(d.temperature == 100 && d.mode == 6 && d.luminance == 25)
        #expect(d.log.last?.0 == MerossNamespace.controlLight) // already on: no extra toggle

        try await h.provider.send(.turnOff, to: h.lampID)
        d = try #require(h.lan.device(Harness.lampUUID))
        #expect(!d.isOn && d.log.last?.0 == MerossNamespace.controlToggleX)

        await #expect(throws: LightCoreError.unsupported("Meross effects are not implemented")) {
            try await h.provider.send(LightCommand(effect: "party"), to: h.lampID)
        }
        await #expect(throws: LightCoreError.lightNotFound(LightID(brand: .meross, stableId: "nope")!)) {
            try await h.provider.send(.turnOn, to: LightID(brand: .meross, stableId: "nope")!)
        }
    }

    @Test func followsRegionRedirectAndAsksForMFA() async throws {
        var cfg = FakeMerossCloud.Configuration()
        cfg.homeDomain = "https://iotx-us.meross.com"
        cfg.mfaCode = "424242"
        let h = Harness.make(cloudConfig: cfg)
        _ = try await h.signIn(extra: [.text("424242")])
        // eu -> 1030 redirect -> us (MFA required) -> eu again with code -> redirect -> us with code.
        #expect(h.cloud.paths.filter { $0.hasSuffix("/v1/Auth/signIn") }.last == "https://iotx-us.meross.com/v1/Auth/signIn")
        #expect(await h.provider.account?.metadata["domain"] == "https://iotx-us.meross.com")
        #expect(h.cloud.paths.contains("https://iotx-us.meross.com/v1/Device/devList"))
    }

    @Test func wrongPasswordDoesNotStoreAnything() async throws {
        let h = Harness.make()
        await #expect(throws: MerossCloudError.wrongCredentials(1004)) { _ = try await h.signIn(password: "nope") }
        #expect(await h.store.count == 0)
        #expect(await h.provider.account == nil)
    }

    @Test func signInsAreRateLimited() async throws {
        let h = Harness.make()
        for _ in 0..<3 {
            _ = try? await h.provider.signIn(region: .eu, email: "user@example.com", password: "bad")
        }
        await #expect(throws: MerossCloudError.rateLimited(0)) {
            try await h.provider.signIn(region: .eu, email: "user@example.com", password: "s3cret-pw")
        }
        #expect(h.cloud.signInCount == 3)
    }

    @Test func wrongKeyAsksForReauthentication() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()
        // The device now expects another key (e.g. the account key was reset).
        let other = FakeMerossLAN(key: "another-key")
        other.add(try #require(h.lan.device(Harness.lampUUID)), at: Harness.lampHost)
        var cfg = h.configuration
        cfg.local = other
        let fresh = MerossProvider(account: await h.provider.account, secretStore: h.store, configuration: cfg)
        let events = EventLog(fresh.events)
        _ = try await fresh.loadLights()
        await #expect(throws: LightCoreError.authenticationRequired(.meross)) {
            try await fresh.send(.turnOn, to: h.lampID)
        }
        #expect(await events.wait { if case .needsReauthentication("user@example.com") = $0 { return true }; return false })
    }

    @Test func restoresFromKeychainCacheWithoutCloud() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        let devListCalls = h.cloud.devListCount
        h.cloud.revokeTokens() // cloud unusable now
        let account = await h.provider.account
        let restored = MerossProvider(account: account, secretStore: h.store, configuration: h.configuration)
        let lights = try await restored.loadLights()
        #expect(lights.map(\.id) == [h.lampID])
        #expect(lights.first?.state.reachable == true)
        try await restored.send(.turnOn, to: h.lampID)
        #expect(h.lan.device(Harness.lampUUID)?.isOn == true)
        #expect(h.cloud.devListCount == devListCalls) // fresh cache: no list refresh
    }

    @Test func expiredTokenKeepsLANControl() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        h.cloud.revokeTokens()
        await #expect(throws: LightCoreError.authenticationRequired(.meross)) { try await h.provider.refreshDeviceList() }
        #expect(await h.events.wait { if case .needsReauthentication = $0 { return true }; return false })
        #expect(try await h.secret("token") == nil)
        #expect(try await h.secret("key") == Harness.key)
        try await h.provider.send(.turnOn, to: h.lampID)
        #expect(h.lan.device(Harness.lampUUID)?.isOn == true)
    }

    @Test func ipChangeIsDetectedAndRediscovered() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()
        // DHCP: the lamp moves to .77 and another Meross device takes .50.
        h.lan.move(uuid: Harness.lampUUID, to: "192.168.1.77")
        h.lan.add(FakeMerossDeviceState(uuid: "ffff0000ffff0000ffff000011112222"), at: Harness.lampHost)
        await #expect(throws: LightCoreError.unreachable("Desk lamp moved to another IP address")) {
            try await h.provider.send(.turnOn, to: h.lampID)
        }
        #expect(await h.events.wait { if case .reachabilityChanged(let id, false) = $0 { return id == h.lampID }; return false })
        var found: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.sweep, .cloud])) { found.append(d) }
        #expect(found.contains { $0.id == Harness.lampUUID && $0.host == "192.168.1.77" && $0.method == .sweep })
        try await h.provider.send(.turnOn, to: h.lampID)
        #expect(h.lan.device(Harness.lampUUID)?.isOn == true)
    }

    @Test func discoveryReportsManualCachedAndCloudOnlyDevices() async throws {
        let h = Harness.make(sweep: [])
        _ = try await h.signIn() // nothing found (no sweep hosts)
        var found: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.manual, .cloud], manualHosts: ["192.168.1.99"])) {
            found.append(d)
        }
        #expect(found.map(\.method) == [.cloud])
        #expect(found.first?.host == nil)
        found = []
        for await d in h.provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.manual, .cloud], manualHosts: [Harness.lampHost])) {
            found.append(d)
        }
        #expect(found.count == 1)
        let lamp = try #require(found.first)
        #expect(lamp.method == .manual && lamp.model == "msl120d" && lamp.macAddress == "48:e1:e9:00:00:01" && lamp.name == "Desk lamp")
    }

    @Test func encryptedDevicesUseECDHEBodies() async throws {
        var lamp = FakeMerossDeviceState(uuid: Harness.lampUUID)
        lamp.encrypted = true
        lamp.mac = MerossSystemInfo.macAddress(fromUUID: Harness.lampUUID)
        let h = Harness.make(lamp: lamp)
        _ = try await h.signIn()
        let lights = try await h.provider.loadLights()
        #expect(lights.first?.state.reachable == true)
        try await h.provider.send(LightCommand(on: true, brightness: 0.9), to: h.lampID)
        let d = try #require(h.lan.device(Harness.lampUUID))
        #expect(d.isOn && d.luminance == 90)
    }

    @Test func manualKeyAndIP() async throws {
        let h = Harness.make()
        let ui = ScriptedPairingInteraction([.choice(1), .text(Harness.key), .text(Harness.lampHost)])
        let paired = try await h.provider.pair(MerossProvider.accountPlaceholder(), using: ui)
        #expect(paired.id == Harness.lampUUID && paired.hostHint == Harness.lampHost && paired.lightIDs == [h.lampID])
        #expect(paired.model == "msl120d")
        #expect(h.cloud.signInCount == 0)
        #expect(try await h.secret("key", owner: MerossProvider.manualAccountID) == Harness.key)
        let lights = try await h.provider.loadLights()
        #expect(lights.map(\.id) == [h.lampID])
        try await h.provider.send(.turnOn, to: h.lampID)
        #expect(h.lan.device(Harness.lampUUID)?.isOn == true)
    }

    @Test func pollingPublishesExternalChanges() async throws {
        let h = Harness.make(poll: .milliseconds(100))
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()
        await h.provider.start()
        h.lan.update(Harness.lampUUID) { $0.isOn = true; $0.luminance = 12 }
        #expect(await h.events.wait { if case .stateChanged(let id, let s) = $0 { return id == h.lampID && s.isOn && s.brightness == 0.12 }; return false })
        await h.provider.stop()
    }

    @Test func signOutRemovesSecrets() async throws {
        let h = Harness.make()
        _ = try await h.signIn()
        await h.provider.signOut()
        #expect(await h.store.count == 0)
        #expect(h.cloud.paths.last?.hasSuffix(MerossCloudAPI.logoutPath) == true)
        await #expect(throws: LightCoreError.authenticationRequired(.meross)) { _ = try await h.provider.loadLights() }
    }
}
