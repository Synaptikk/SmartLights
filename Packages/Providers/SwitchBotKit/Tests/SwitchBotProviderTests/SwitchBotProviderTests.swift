import Foundation
import LightCore
import Synchronization
import SwitchBotCodec
import Testing

@testable import SwitchBotProvider

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
    let cloud: FakeSwitchBotCloud
    let store: InMemorySecretStore
    let provider: SwitchBotProvider
    let events: EventLog
    let configuration: SwitchBotProvider.Configuration

    static let bulb = LightID(brand: .switchbot, stableId: "6055F92B4F5A")!
    static let strip = LightID(brand: .switchbot, stableId: "C1D2E3F4A5B6")!
    static let ceiling = LightID(brand: .switchbot, stableId: "F0E1D2C3B4A5")!

    static func make(cloud: FakeSwitchBotCloud = .standard(), store: InMemorySecretStore = InMemorySecretStore(),
                     account: ProviderAccount? = nil, configure: (inout SwitchBotProvider.Configuration) -> Void = { _ in }) -> Harness {
        var configuration = SwitchBotProvider.Configuration()
        configuration.http = cloud
        configuration.burstLimit = .init(1000, per: .seconds(1))
        configure(&configuration)
        let provider = SwitchBotProvider(account: account, secretStore: store, configuration: configuration)
        return Harness(cloud: cloud, store: store, provider: provider, events: EventLog(provider.events), configuration: configuration)
    }

    func pair(token: String? = nil, secret: String? = nil) async throws -> PairedDevice {
        let ui = ScriptedPairingInteraction([.text(token ?? cloud.token), .text(secret ?? cloud.secret)])
        return try await provider.pair(SwitchBotProvider.accountPlaceholder(), using: ui)
    }

    func secret(_ item: String) async throws -> String? {
        guard let owner = await provider.account?.id else { return nil }
        return try await store.string(for: SecretKey(brand: .switchbot, owner: owner, item: item))
    }
}

@Suite("SwitchBotProvider against a fake SwitchBot cloud", .serialized)
struct SwitchBotProviderTests {
    @Test func pairingVerifiesAndStoresTokenAndSecret() async throws {
        let h = Harness.make()
        let paired = try await h.pair(token: "  \(h.cloud.token)\n", secret: h.cloud.secret)
        #expect(paired.lightIDs == [Harness.bulb, Harness.strip, Harness.ceiling]) // hub skipped
        let account = try #require(await h.provider.account)
        #expect(account.id.hasPrefix("switchbot-") && !account.id.contains(h.cloud.token))
        #expect(!account.displayName.contains(h.cloud.token))
        #expect(try await h.secret("token") == h.cloud.token) // trimmed
        #expect(try await h.secret("secret") == h.cloud.secret)
        #expect(h.cloud.calls == 1)
    }

    @Test func badCredentialsAreRejected() async throws {
        let h = Harness.make()
        await #expect(throws: SwitchBotError.unauthorized) { _ = try await h.pair(secret: "wrong") }
        #expect(await h.provider.account == nil)
        #expect(await h.store.count == 0)
    }

    @Test func loadLightsReadsStatuses() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        let lights = try await h.provider.loadLights()
        #expect(lights.map(\.id) == [Harness.bulb, Harness.strip, Harness.ceiling])
        let bulb = lights[0], strip = lights[1], ceiling = lights[2]
        #expect(bulb.name == "Bedroom bulb" && bulb.model == "Color Bulb" && bulb.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(!bulb.state.isOn && bulb.state.brightness == 0.5 && bulb.state.colorMode == .colorTemp && bulb.state.kelvin == 4000)
        #expect(strip.state.isOn && strip.state.colorMode == .rgb && strip.state.rgb == RGB(r: 0, g: 0, b: 255))
        #expect(ceiling.state.kelvin == 6500 && ceiling.state.reachable)
        #expect(h.cloud.calls == 1 + 3)
        // Statuses are fresh: a second load spends nothing.
        _ = try await h.provider.loadLights()
        #expect(h.cloud.calls == 4)
    }

    @Test func commandsAreSignedAndApplied() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        _ = try await h.provider.loadLights()
        try await h.provider.send(LightCommand(brightness: 0.75, color: .rgb(RGB(r: 255, g: 0, b: 0))), to: Harness.bulb)
        #expect(h.cloud.commands.map(\.1) == ["turnOn", "setColor", "setBrightness"])
        let l = try #require(h.cloud.light("6055F92B4F5A"))
        #expect(l.power == "on" && l.color == "255:0:0" && l.brightness == 75)
        #expect(await h.events.wait {
            if case .stateChanged(Harness.bulb, let s) = $0 { return s.isOn && s.colorMode == .rgb && s.brightness == 0.75 }
            return false
        })
        // The commanded mode wins over the status heuristic on the next read.
        try await h.provider.send(.turnOff, to: Harness.bulb)
        #expect(h.cloud.light("6055F92B4F5A")?.power == "off")
        try await h.provider.send(LightCommand(color: .kelvin(3000)), to: Harness.ceiling)
        #expect(h.cloud.light("F0E1D2C3B4A5")?.colorTemperature == 3000)
        await #expect(throws: LightCoreError.unsupported("SwitchBot effects are not implemented")) {
            try await h.provider.send(LightCommand(effect: "x"), to: Harness.bulb)
        }
    }

    @Test func offlineDeviceIsReportedUnreachable() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        _ = try await h.provider.loadLights()
        h.cloud.update("F0E1D2C3B4A5") { $0.offline = true }
        await #expect(throws: LightCoreError.self) { try await h.provider.send(.turnOn, to: Harness.ceiling) }
        #expect(await h.events.wait { if case .reachabilityChanged(Harness.ceiling, false) = $0 { return true }; return false })
    }

    @Test func cloudServiceOffIsExplained() async throws {
        let cloud = FakeSwitchBotCloud(lights: [
            .init(device: SwitchBotDevice(deviceId: "AA11BB22CC33", deviceName: "Hallway bulb", deviceType: "Color Bulb",
                                          enableCloudService: false, hubDeviceId: "FA7310762361")),
        ])
        let h = Harness.make(cloud: cloud)
        _ = try await h.pair()
        let lights = try await h.provider.loadLights()
        #expect(lights.count == 1 && lights[0].state.reachable == false)
        #expect(cloud.calls == 1) // no status call for it
        let id = LightID(brand: .switchbot, stableId: "AA11BB22CC33")!
        await #expect(throws: LightCoreError.unreachable("Turn on Cloud Services for Hallway bulb in the SwitchBot app")) {
            try await h.provider.send(.turnOn, to: id)
        }
    }

    @Test func dailyBudgetIsEnforcedLocally() async throws {
        let h = Harness.make { $0.dailyBudget = .init(capacity: 5, refillPerSecond: 0.000_001) }
        _ = try await h.pair()                       // 1
        _ = try await h.provider.loadLights()        // 3 statuses -> 4
        #expect(await h.provider.remainingBudget() == 1)
        try await h.provider.send(.turnOff, to: Harness.strip) // 5
        await #expect(throws: SwitchBotError.budgetExhausted) { try await h.provider.send(.turnOn, to: Harness.strip) }
        #expect(h.cloud.calls == 5)
        #expect(await h.events.wait { if case .error(let m) = $0 { return m.contains("budget") }; return false })
    }

    @Test func pollingKeepsAReserve() async throws {
        let h = Harness.make {
            $0.dailyBudget = .init(capacity: 6, refillPerSecond: 0.000_001)
            $0.pollReserve = 2
            $0.pollInterval = .milliseconds(50)
        }
        _ = try await h.pair()                // 1
        _ = try await h.provider.loadLights() // 4
        await h.provider.start()
        h.cloud.update("C1D2E3F4A5B6") { $0.power = "off" }
        try await Task.sleep(for: .milliseconds(500))
        await h.provider.stop()
        // Polling may spend only down to the reserve (2 left) ...
        #expect(await h.provider.remainingBudget() >= 2)
        // ... which user commands can still use.
        try await h.provider.send(.turnOn, to: Harness.strip)
        try await h.provider.send(.turnOn, to: Harness.bulb)
    }

    @Test func pollingPublishesExternalChanges() async throws {
        let h = Harness.make { $0.pollInterval = .milliseconds(50) }
        _ = try await h.pair()
        _ = try await h.provider.loadLights()
        await h.provider.start()
        h.cloud.update("C1D2E3F4A5B6") { $0.color = "0:255:0"; $0.brightness = 20 }
        #expect(await h.events.wait {
            if case .stateChanged(Harness.strip, let s) = $0 { return s.rgb == RGB(r: 0, g: 255, b: 0) && s.brightness == 0.2 }
            return false
        })
        await h.provider.stop()
    }

    @Test func rejectedTokenAsksForReauthentication() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        let account = await h.provider.account
        h.cloud.rotateToken() // user reset the token in the app
        let restored = SwitchBotProvider(account: account, secretStore: h.store, configuration: h.configuration)
        let events = EventLog(restored.events)
        // The cached list keeps the lights visible; status reads fail.
        let lights = try await restored.loadLights()
        #expect(lights.count == 3)
        await #expect(throws: LightCoreError.authenticationRequired(.switchbot)) { try await restored.refreshDeviceList() }
        #expect(await events.wait { if case .needsReauthentication = $0 { return true }; return false })
    }

    @Test func unauthorizedAfterSuccessMeansDailyLimit() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        h.cloud.setQuota(h.cloud.calls) // the account-wide 10k/day is used up elsewhere
        await #expect(throws: SwitchBotError.unauthorized) { try await h.provider.send(.turnOn, to: Harness.strip) }
        #expect(!h.events.all.contains { if case .needsReauthentication = $0 { return true }; return false })
    }

    @Test func discoveryListsCloudLights() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        var found: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: DiscoveryOptions(methods: [.cloud])) { found.append(d) }
        #expect(found.map(\.id) == ["6055F92B4F5A", "C1D2E3F4A5B6", "F0E1D2C3B4A5"])
        #expect(found.allSatisfy { $0.method == .cloud })
        #expect(found[2].metadata["hubDeviceId"] == "FA7310762361")
        var none: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: DiscoveryOptions(methods: [.sweep])) { none.append(d) }
        #expect(none.isEmpty)
        // Pairing a discovered light returns that light.
        let one = try await h.provider.pair(found[0], using: ScriptedPairingInteraction([]))
        #expect(one.id == "6055F92B4F5A" && one.lightIDs == [Harness.bulb] && one.model == "Color Bulb")
    }

    @Test func signOutRemovesSecrets() async throws {
        let h = Harness.make()
        _ = try await h.pair()
        await h.provider.signOut()
        #expect(await h.store.count == 0)
        await #expect(throws: LightCoreError.authenticationRequired(.switchbot)) { _ = try await h.provider.loadLights() }
    }
}
