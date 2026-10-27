import Foundation
import Testing
import LightCore
import NetKit
import WLEDCodec
@testable import WLEDProvider

// MARK: - Helpers

private func testConfig() -> WLEDProvider.Configuration {
    WLEDProvider.Configuration(
        requestTimeout: .seconds(2),
        retries: 1,
        pollInterval: .milliseconds(150),
        minRequestInterval: .milliseconds(5)
    )
}

private func makeProvider(bonjour: [WLEDBonjourHit]? = nil) -> WLEDProvider {
    var browse: (@Sendable () -> AsyncStream<WLEDBonjourHit>)?
    if let hits = bonjour {
        browse = {
            AsyncStream { c in
                for h in hits { c.yield(h) }
                c.finish()
            }
        }
    }
    return WLEDProvider(configuration: testConfig(), environment: WLEDNetworkEnvironment(browseBonjour: browse))
}

private func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

private func manual(_ host: String) -> DiscoveryOptions {
    DiscoveryOptions(timeout: .seconds(5), methods: [.manual], manualHosts: [host])
}

/// Pairs `fake` through manual discovery and returns its light id.
private func pairManually(_ provider: WLEDProvider, _ fake: FakeWLEDController) async throws -> LightID {
    let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
    let device = try #require(found.first)
    let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
    return try #require(paired.lightIDs.first)
}

private func lastPostBody(_ fake: FakeWLEDController) throws -> [String: Any] {
    try #require(fake.requests("POST", "/json/state").last?.bodyJSON)
}

/// Collects provider events in the background.
private actor EventLog {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { for await e in stream { self.append(e) } }
    }

    private func append(_ e: ProviderEvent) { events.append(e) }

    func waitFor(timeout: Duration = .seconds(5), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if events.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events.contains(where: predicate)
    }
}

// MARK: - Tests

@Suite("WLEDProvider against a fake HTTP controller", .serialized)
struct WLEDProviderTests {
    @Test func discoversManualHostUsingConfiguredMDNSName() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
        #expect(found.count == 1)
        let d = try #require(found.first)
        #expect(d.id == "wled-kitchen")
        #expect(d.brand == .wled)
        #expect(d.name == "Kitchen Strip")
        #expect(d.model == "WLED (esp32)")
        #expect(d.host == "127.0.0.1")
        #expect(d.port == Int(fake.port))
        #expect(d.macAddress == "a4:cf:12:fd:ae:a8")
        #expect(d.method == .manual)
        #expect(d.metadata["mac"] == "a4cf12fdaea8")
        #expect(d.metadata["version"] == "0.14.4")
        #expect(d.metadata["lc"] == "1")
        #expect(fake.requests("GET", "/json/cfg").count == 1)
    }

    @Test func fallsBackToDefaultMDNSNameFromMAC() async throws {
        let fake = try FakeWLEDController(mac: "84f3eb123456", mdns: nil, name: "WLED")
        defer { fake.stop() }
        let provider = makeProvider()
        let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
        #expect(found.map(\.id) == ["wled-123456"])
        // Factory name "WLED" -> the mDNS name is shown instead.
        #expect(found.first?.name == "wled-123456")
    }

    @Test func discoversViaBonjourInstanceName() async throws {
        let fake = try FakeWLEDController(mdns: "something-else")
        defer { fake.stop() }
        let hit = WLEDBonjourHit(name: "wled-porch", host: "127.0.0.1", port: fake.port, txt: ["mac": "a4cf12fdaea8"])
        let provider = makeProvider(bonjour: [hit])
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.bonjour])))
        #expect(found.map(\.id) == ["wled-porch"])
        #expect(found.first?.method == .bonjour)
        #expect(fake.requests("GET", "/json/cfg").isEmpty)
    }

    @Test func pairAsksForAddressWhenMissing() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let ui = ScriptedPairingInteraction([.text(fake.hostSpec)])
        let device = DiscoveredDevice(id: "ip:manual", brand: .wled, name: "WLED", method: .manual)
        let paired = try await provider.pair(device, using: ui)
        #expect(paired.id == "wled-kitchen")
        #expect(paired.lightIDs.map(\.rawValue) == ["wled:wled-kitchen"])
        #expect(paired.hostHint == "127.0.0.1")
        #expect(paired.port == Int(fake.port))
        #expect(paired.metadata["mac"] == "a4cf12fdaea8")
        #expect(paired.metadata["mdns"] == "wled-kitchen")
        #expect(await ui.prompts.first?.contains("IP address") == true)
    }

    @Test func loadsStateAndEffects() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let light = try #require(try await provider.loadLights().first)
        #expect(light.id == id)
        #expect(light.name == "Kitchen Strip")
        #expect(light.manufacturer == "WLED")
        #expect(light.capabilities.supportedColorModes == [.rgb])
        #expect(light.capabilities.supportsTransition)
        #expect(light.capabilities.effects.map(\.name) == ["Solid", "Blink", "Breathe", "Wipe", "Rainbow", "Strobe"])
        #expect(light.capabilities.effects.first { $0.name == "Rainbow" }?.id == "5")
        #expect(light.capabilities.effects.first { $0.name == "Strobe" }?.isFast == true)
        #expect(light.state.isOn)
        #expect(light.state.rgb == RGB(r: 255, g: 160, b: 0))
        #expect(light.state.brightness == ColorMath.brightness(fromDeviceValue: 128, in: 1...255))
        #expect(light.state.reachable)
        #expect(try await provider.effects(of: id).count == 6)
    }

    @Test func sendsBrightnessColourAndTransitionInOnePost() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let events = EventLog()
        await events.start(provider.events)

        try await provider.send(LightCommand(brightness: 1, color: .rgb(RGB(r: 0, g: 0, b: 255)), transition: .milliseconds(700)), to: id)

        #expect(fake.requests("POST", "/json/state").count == 1)
        let body = try lastPostBody(fake)
        #expect(body["bri"] as? Int == 255)
        #expect(body["tt"] as? Int == 7)
        #expect(body["v"] as? Bool == true)
        #expect(body["transition"] == nil)
        let seg = try #require((body["seg"] as? [[String: Any]])?.first)
        #expect(seg["id"] as? Int == 0)
        #expect(seg["col"] as? [[Int]] == [[0, 0, 255]])
        #expect(seg["fx"] as? Int == 0)
        #expect(fake.state == FakeWLEDController.State(on: true, bri: 255, col: [0, 0, 255], fx: 0))
        #expect(fake.lastTransition == 7)
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { lid == id && s.rgb == RGB(r: 0, g: 0, b: 255) && s.brightness == 1 } else { false } })
    }

    @Test func selectsEffect() async throws {
        let fake = try FakeWLEDController(state: .init(on: false))
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        try await provider.send(LightCommand(effect: "5"), to: id)
        #expect(fake.state.fx == 5)
        #expect(fake.state.on)
        let light = try #require(try await provider.loadLights().first)
        #expect(light.state.effect == "5")
        // Unknown effect ids are dropped (nothing sent).
        let posts = fake.requests("POST", "/json/state").count
        try await provider.send(LightCommand(effect: "4"), to: id)
        #expect(fake.requests("POST", "/json/state").count == posts)
    }

    @Test func rgbwControllerGetsFourChannels() async throws {
        let fake = try FakeWLEDController(rgbw: true, state: .init(col: [0, 0, 0, 255]))
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let before = try #require(try await provider.loadLights().first)
        #expect(before.capabilities.supportedColorModes == [.rgbw])
        #expect(before.state.rgbw == RGBW(r: 0, g: 0, b: 0, w: 255))
        try await provider.send(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), to: id)
        let seg = try #require((try lastPostBody(fake)["seg"] as? [[String: Any]])?.first)
        #expect((seg["col"] as? [[Int]])?.first?.count == 4)
    }

    @Test func turnOffAndOnKeepBrightness() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        try await provider.send(LightCommand(brightness: 0), to: id)
        #expect(try lastPostBody(fake)["on"] as? Bool == false)
        #expect(try lastPostBody(fake)["bri"] == nil)
        #expect(!fake.state.on && fake.state.bri == 128)
        try await provider.send(.turnOn, to: id)
        #expect(fake.state.on)
    }

    @Test func retriesOnceAfterConnectionReset() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        fake.dropNext(1)
        try await provider.send(.turnOff, to: id)
        #expect(!fake.state.on)
    }

    @Test func unreachableAfterRetries() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let events = EventLog()
        await events.start(provider.events)
        fake.setOffline(true)
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOff, to: id) }
        // 1 + `retries` attempts (URLSession on Apple may add its own retry).
        #expect(fake.requests("POST", "/json/state").count >= 2)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })
    }

    @Test func pollingEmitsExternalChangesAndReachability() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        _ = try await provider.loadLights()
        let events = EventLog()
        await events.start(provider.events)
        await provider.start()

        fake.state = FakeWLEDController.State(on: true, bri: 10, col: [0, 255, 0], fx: 2)
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { lid == id && s.rgb == RGB(r: 0, g: 255, b: 0) && s.effect == "2" } else { false } })

        fake.setOffline(true)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })
        fake.setOffline(false)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: true) })
        await provider.stop()
    }

    @Test func renamedControllerKeepsItsIDByMAC() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        fake.mdns = "wled-renamed"
        let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
        #expect(found.map(\.id) == [id.stableId])
        #expect(found.first?.metadata["mdns"] == "wled-renamed")
    }

    @Test func restoreThenLoadWithoutDiscovery() async throws {
        let fake = try FakeWLEDController()
        defer { fake.stop() }
        let provider = makeProvider()
        let stored = PairedDevice(id: "wled-kitchen", brand: .wled, name: "Stored", hostHint: "127.0.0.1", port: Int(fake.port),
                                  lightIDs: [try #require(LightID("wled:wled-kitchen"))], metadata: ["mac": "a4cf12fdaea8", "lc": "1"])
        await provider.restore([stored])
        #expect(await provider.pairedIDs == ["wled-kitchen"])
        let light = try #require(try await provider.loadLights().first)
        #expect(light.state.reachable)
        #expect(light.name == "Kitchen Strip")
        #expect(!light.capabilities.effects.isEmpty)
        #expect(await provider.endpoint(of: light.id) == "127.0.0.1:\(fake.port)")
    }

    @Test func unknownLightThrows() async throws {
        let provider = makeProvider()
        let id = try #require(LightID("wled:wled-nope"))
        await #expect(throws: LightCoreError.lightNotFound(id)) { try await provider.send(.turnOn, to: id) }
    }

    @Test func groupReportsPartialFailure() async throws {
        let a = try FakeWLEDController(mac: "000000000001", mdns: "wled-a")
        let b = try FakeWLEDController(mac: "000000000002", mdns: "wled-b")
        defer { a.stop(); b.stop() }
        let provider = makeProvider()
        let idA = try await pairManually(provider, a)
        let idB = try await pairManually(provider, b)
        b.setOffline(true)
        do {
            try await provider.sendGroup(.turnOff, to: [idA, idB])
            Issue.record("expected partial failure")
        } catch LightCoreError.partialFailure(let failures) {
            #expect(Array(failures.keys) == [idB])
        }
        #expect(!a.state.on)
    }

    @Test func parsesHostSpecs() {
        #expect(WLEDProvider.parseHost("192.168.1.50", defaultPort: 80)! == ("192.168.1.50", 80))
        #expect(WLEDProvider.parseHost("wled-kitchen.local:8080", defaultPort: 80)! == ("wled-kitchen.local", 8080))
        #expect(WLEDProvider.parseHost("[fe80::1]", defaultPort: 80)! == ("fe80::1", 80))
        #expect(WLEDProvider.parseHost("  ", defaultPort: 80) == nil)
    }
}
