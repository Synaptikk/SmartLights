import Foundation
import Testing
@testable import LightCore

/// Minimal provider used to exercise the protocol and the registry.
actor FakeProvider: LightProvider {
    static let brand: Brand = .wiz
    let account: ProviderAccount? = nil
    private(set) var sent: [(LightCommand, LightID)] = []
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let events: AsyncStream<ProviderEvent>
    var failing: Set<LightID> = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self)
    }

    func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        AsyncStream { c in
            c.yield(DiscoveredDevice(id: "a8bb5006033d", brand: .wiz, name: "WiZ bulb", host: "192.168.1.20", method: .sweep))
            c.finish()
        }
    }

    func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard try await ui.confirm("Power-cycle the bulb") else { throw LightCoreError.userCancelled }
        let key = try await ui.secureText("Signing key")
        _ = key
        return PairedDevice(id: device.id, brand: .wiz, name: device.name, hostHint: device.host)
    }

    func loadLights() async throws -> [Light] {
        [Light(id: LightID(brand: .wiz, stableId: "a8bb5006033d")!, name: "Desk", capabilities: LightCapabilities(supportedColorModes: [.rgb, .colorTemp]))]
    }

    func send(_ command: LightCommand, to light: LightID) async throws {
        if failing.contains(light) { throw LightCoreError.unreachable(light.rawValue) }
        sent.append((command, light))
    }

    func setFailing(_ ids: Set<LightID>) { failing = ids }
    func emit(_ event: ProviderEvent) { continuation.yield(event) }
    func sentIDs() -> [LightID] { sent.map(\.1) }
}

@Suite("ProviderRegistry")
struct RegistryTests {
    let a = LightID("wiz:aaaa")!
    let b = LightID("wiz:bbbb")!

    @Test func routesCommandsAndForwardsEvents() async throws {
        let registry = ProviderRegistry()
        let provider = FakeProvider()
        await registry.register(provider)
        #expect(await registry.registeredBrands == [.wiz])

        try await registry.send(.turnOn, to: a)
        #expect(await provider.sentIDs() == [a])

        await #expect(throws: LightCoreError.providerNotRegistered(.hue)) {
            try await registry.send(.turnOn, to: LightID("hue:x")!)
        }

        await provider.emit(.reachabilityChanged(a, reachable: false))
        var iterator = registry.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == RegistryEvent(brand: .wiz, event: .reachabilityChanged(a, reachable: false)))

        let loaded = await registry.loadAllLights()
        #expect(loaded.lights.count == 1 && loaded.failures.isEmpty)
    }

    @Test func groupSendReportsPartialFailures() async throws {
        let registry = ProviderRegistry()
        let provider = FakeProvider()
        await provider.setFailing([b])
        await registry.register(provider)
        let hue = LightID("hue:cccc")!
        do {
            try await registry.sendGroup(.turnOff, to: [a, b, hue])
            Issue.record("expected partial failure")
        } catch let LightCoreError.partialFailure(failures) {
            #expect(Set(failures.keys) == [b, hue])
        }
        #expect(await provider.sentIDs() == [a])
    }

    @Test func appSceneReplay() async throws {
        let registry = ProviderRegistry()
        let provider = FakeProvider()
        await registry.register(provider)
        let scene = LightScene(id: "s", name: "S", kind: .app, commands: [a: .turnOn, b: .turnOff])
        try await registry.recall(scene)
        #expect(await provider.sentIDs() == [a, b])
        await #expect(throws: LightCoreError.self) {
            try await registry.recall(LightScene(id: "v", name: "V", kind: .vendor, brand: .wiz))
        }
    }

    @Test func pairingThroughScriptedInteraction() async throws {
        let provider = FakeProvider()
        var found: [DiscoveredDevice] = []
        for await d in await provider.discover(options: .default) { found.append(d) }
        #expect(found.count == 1)
        let ui = ScriptedPairingInteraction([.confirm(true), .text("00112233445566778899aabbccddeeff")])
        let paired = try await provider.pair(found[0], using: ui)
        #expect(paired.id == "a8bb5006033d" && paired.hostHint == "192.168.1.20")
        #expect(await ui.prompts == ["Power-cycle the bulb", "Signing key"])

        let cancelling = ScriptedPairingInteraction([.cancel])
        await #expect(throws: LightCoreError.userCancelled) { try await provider.pair(found[0], using: cancelling) }
    }
}

@Suite("Stores")
struct StoreTests {
    @Test func jsonFileStorePersists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightcore-tests-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = LightID("hue:light-1")!
        let store = JSONFileDeviceStore(fileURL: url)
        #expect(try await store.pairedDevices().isEmpty)
        let device = PairedDevice(id: "001788fffe123456", brand: .hue, name: "Bridge", hostHint: "192.168.1.2", lightIDs: [id], pairedAt: Date(timeIntervalSince1970: 1000))
        try await store.save(device)
        try await store.save(ProviderAccount(id: "acc", brand: .aidot, displayName: "u***@x.com", secretKeys: [SecretKey(brand: .aidot, owner: "acc", item: "accessToken")]))
        try await store.cacheLights([Light(id: id, name: "Lamp", capabilities: .dimmable)])
        var renamed = device
        renamed.name = "Hue Bridge"
        try await store.save(renamed)

        let reopened = JSONFileDeviceStore(fileURL: url)
        #expect(try await reopened.pairedDevices() == [renamed])
        #expect(try await reopened.accounts().map(\.id) == ["acc"])
        #expect(try await reopened.cachedLights().map(\.id) == [id])

        try await reopened.removeDevice(brand: .hue, id: "001788fffe123456")
        #expect(try await reopened.pairedDevices().isEmpty)
        #expect(try await reopened.cachedLights().isEmpty)
        try await reopened.removeAccount(id: "acc")
        #expect(try await JSONFileDeviceStore(fileURL: url).accounts().isEmpty)
    }

    @Test func corruptFileThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lightcore-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        await #expect(throws: LightCoreError.self) { try await JSONFileDeviceStore(fileURL: url).pairedDevices() }
    }

    @Test func inMemorySecrets() async throws {
        let store = InMemorySecretStore()
        let key = SecretKey(brand: .hue, owner: "001788fffe123456", item: "appKey")
        #expect(key.service == "com.sinap.smartlights.hue")
        #expect(key.account == "001788fffe123456/appKey")
        #expect(try await store.string(for: key) == nil)
        try await store.set("s3cret", for: key)
        #expect(try await store.string(for: key) == "s3cret")
        await store.remove(key)
        #expect(await store.data(for: key) == nil)
        #expect(Log.redact("s3cret") == "<redacted 6 chars>")
        Log.lightCore.info("secret store test ran") // must not crash on Linux
    }
}

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func burstThenRefuse() async {
        let limiter = RateLimiter<String>(capacity: 2, refillPerSecond: 1)
        #expect(await limiter.tryAcquire("light"))
        #expect(await limiter.tryAcquire("light"))
        #expect(await !limiter.tryAcquire("light"))
        #expect(await limiter.tryAcquire("other"))
    }

    @Test func acquireWaitsForRefill() async throws {
        let limiter = RateLimiter<String>(capacity: 1, refillPerSecond: 20) // 50 ms per token
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<4 { try await limiter.acquire("k") }
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(140))
        #expect(elapsed < .seconds(2))
    }

    @Test func perKeyOverride() async {
        let limiter = RateLimiter<String>(RateLimiter<String>.Limit(10, per: .seconds(1)))
        await limiter.setLimit(.init(1, per: .seconds(1)), for: "group")
        #expect(await limiter.tryAcquire("group"))
        #expect(await !limiter.tryAcquire("group"))
        for _ in 0..<10 { #expect(await limiter.tryAcquire("light")) }
    }

    @Test func cancellationReturnsToken() async throws {
        let limiter = RateLimiter<String>(capacity: 1, refillPerSecond: 0.1)
        #expect(await limiter.tryAcquire("k"))
        let task = Task { try await limiter.acquire("k") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await limiter.available("k") < 0.5)
        #expect(await limiter.available("k") > -0.5)
    }
}
