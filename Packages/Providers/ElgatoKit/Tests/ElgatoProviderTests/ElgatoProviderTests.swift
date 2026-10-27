import Foundation
import Testing
import LightCore
import NetKit
import ElgatoCodec
@testable import ElgatoProvider

// MARK: - Helpers

private func testConfig() -> ElgatoProvider.Configuration {
    ElgatoProvider.Configuration(
        requestTimeout: .seconds(2),
        retries: 1,
        pollInterval: .milliseconds(150),
        minRequestInterval: .milliseconds(5)
    )
}

private func makeProvider(bonjour: [ElgatoBonjourHit]? = nil) -> ElgatoProvider {
    var browse: (@Sendable () -> AsyncStream<ElgatoBonjourHit>)?
    if let hits = bonjour {
        browse = {
            AsyncStream { c in
                for h in hits { c.yield(h) }
                c.finish()
            }
        }
    }
    return ElgatoProvider(configuration: testConfig(), environment: ElgatoNetworkEnvironment(browseBonjour: browse))
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
private func pairManually(_ provider: ElgatoProvider, _ fake: FakeElgatoLight) async throws -> LightID {
    let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
    let device = try #require(found.first)
    let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
    return try #require(paired.lightIDs.first)
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

@Suite("ElgatoProvider against a fake HTTP light", .serialized)
struct ElgatoProviderTests {
    @Test func discoversManualHost() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let found = await collect(await provider.discover(options: manual(fake.hostSpec)))
        #expect(found.count == 1)
        let d = try #require(found.first)
        #expect(d.id == "CN11A1A00001")
        #expect(d.brand == .elgato)
        #expect(d.name == "Desk Light")
        #expect(d.model == "Elgato Key Light")
        #expect(d.host == "127.0.0.1")
        #expect(d.port == Int(fake.port))
        #expect(d.macAddress == "3C:6A:9D:14:D0:F5")
        #expect(d.method == .manual)
        #expect(d.metadata["firmware"] == "1.0.3")
        #expect(d.metadata["color"] == "0")
        #expect(fake.requests("GET", "/elgato/accessory-info").count == 1)
    }

    @Test func discoversViaBonjour() async throws {
        let fake = try FakeElgatoLight(serial: "BW33J1A01234", displayName: "Ring", lightStrip: true)
        defer { fake.stop() }
        let hit = ElgatoBonjourHit(name: "Elgato Light Strip 5E1A", host: "127.0.0.1", port: fake.port,
                                   txt: ["id": "3C:6A:9D:00:00:01", "md": "Elgato Light Strip 20LAB9901", "mf": "Elgato"])
        let provider = makeProvider(bonjour: [hit])
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.bonjour])))
        #expect(found.map(\.id) == ["BW33J1A01234"])
        #expect(found.first?.method == .bonjour)
        #expect(found.first?.metadata["color"] == "1")
        #expect(found.first?.name == "Ring")
    }

    @Test func unreachableManualHostYieldsNothing() async throws {
        let fake = try FakeElgatoLight()
        let spec = fake.hostSpec
        fake.stop()
        try await Task.sleep(for: .milliseconds(150))
        let provider = makeProvider()
        let found = await collect(await provider.discover(options: manual(spec)))
        #expect(found.isEmpty)
    }

    @Test func pairAsksForAddressWhenMissing() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let ui = ScriptedPairingInteraction([.text(fake.hostSpec)])
        let manualDevice = DiscoveredDevice(id: "ip:manual", brand: .elgato, name: "Elgato", method: .manual)
        let paired = try await provider.pair(manualDevice, using: ui)
        #expect(paired.id == "CN11A1A00001")
        #expect(paired.lightIDs.map(\.rawValue) == ["elgato:CN11A1A00001"])
        #expect(paired.hostHint == "127.0.0.1")
        #expect(paired.port == Int(fake.port))
        #expect(paired.model == "Elgato Key Light")
        #expect(paired.metadata["mac"] == "3C:6A:9D:14:D0:F5")
        let prompts = await ui.prompts
        #expect(prompts.first?.contains("IP address") == true)
    }

    @Test func pairRejectsOtherBrands() async throws {
        let provider = makeProvider()
        let wiz = DiscoveredDevice(id: "a8bb5006033d", brand: .wiz, name: "WiZ", host: "127.0.0.1", method: .manual)
        await #expect(throws: LightCoreError.self) { try await provider.pair(wiz, using: ScriptedPairingInteraction([])) }
    }

    @Test func loadsLightState() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(light.id == id)
        #expect(light.name == "Desk Light")
        #expect(light.manufacturer == "Elgato")
        #expect(light.model == "Elgato Key Light")
        #expect(light.capabilities.supportedColorModes == [.colorTemp])
        #expect(light.capabilities.kelvinRange == 2907...6993)
        #expect(light.state.isOn)
        #expect(light.state.brightness == 0.21)
        #expect(light.state.colorMode == .colorTemp)
        #expect(light.state.kelvin == 3367)
        #expect(light.state.reachable)
    }

    @Test func sendsBrightnessAndTemperatureInOnePut() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let events = EventLog()
        await events.start(provider.events)

        try await provider.send(LightCommand(brightness: 0.5, color: .kelvin(4000)), to: id)

        let puts = fake.requests("PUT", "/elgato/lights")
        #expect(puts.count == 1)
        let put = try #require(puts.first)
        #expect(put.headers["connection"]?.lowercased() == "close")
        #expect(put.headers["content-type"] == "application/json")
        let body = try #require(put.bodyJSON)
        #expect(body["numberOfLights"] as? Int == 1)
        let entry = try #require((body["lights"] as? [[String: Any]])?.first)
        #expect(entry["brightness"] as? Int == 50)
        #expect(entry["temperature"] as? Int == 250)
        #expect(entry["on"] == nil)
        #expect(fake.state.brightness == 50 && fake.state.temperature == 250)
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { lid == id && s.kelvin == 4000 && s.brightness == 0.5 } else { false } })
    }

    @Test func everyRequestAsksToCloseTheConnection() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        try await provider.send(.turnOff, to: id)
        _ = try await provider.loadLights()
        #expect(fake.requests.count >= 5)
        #expect(fake.requests.allSatisfy { $0.headers["connection"]?.lowercased() == "close" })
        #expect(fake.state.on == 0)
    }

    @Test func lightStripColour() async throws {
        let fake = try FakeElgatoLight(serial: "EW52J1A00082", displayName: "", lightStrip: true)
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let before = try #require(try await provider.loadLights().first)
        #expect(before.capabilities.supportedColorModes == [.colorTemp, .hs])
        #expect(before.name == "Elgato Light Strip")

        try await provider.send(LightCommand(on: true, color: .rgb(RGB(r: 0, g: 0, b: 255))), to: id)
        let entry = try #require((fake.requests("PUT", "/elgato/lights").last?.bodyJSON?["lights"] as? [[String: Any]])?.first)
        #expect(entry["hue"] as? Double == 240)
        #expect(entry["saturation"] as? Double == 100)
        #expect(entry["temperature"] == nil)
        let after = try #require(try await provider.loadLights().first)
        #expect(after.state.colorMode == .hs)
        #expect(after.state.hs == HS(h: 240, s: 1))

        try await provider.send(LightCommand(color: .kelvin(3367)), to: id)
        let white = try #require(try await provider.loadLights().first)
        #expect(white.state.colorMode == .colorTemp)
        #expect(white.state.kelvin == 3367)
    }

    @Test func retriesOnceAfterConnectionReset() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        fake.dropNext(1)
        try await provider.send(.turnOff, to: id)
        #expect(fake.requests("PUT", "/elgato/lights").count == 2)
        #expect(fake.state.on == 0)
    }

    @Test func unreachableAfterRetries() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        let events = EventLog()
        await events.start(provider.events)
        fake.setOffline(true)
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOff, to: id) }
        // 1 + `retries` attempts (URLSession on Apple may add its own retry of an idempotent PUT).
        #expect(fake.requests("PUT", "/elgato/lights").count >= 2)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })
        let light = try #require(try await provider.loadLights().first)
        #expect(!light.state.reachable)
    }

    @Test func unknownLightThrows() async throws {
        let provider = makeProvider()
        let id = try #require(LightID("elgato:NOPE"))
        await #expect(throws: LightCoreError.lightNotFound(id)) { try await provider.send(.turnOn, to: id) }
    }

    @Test func pollingEmitsExternalChangesAndReachability() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        _ = try await provider.loadLights()
        let events = EventLog()
        await events.start(provider.events)
        await provider.start()

        fake.state = FakeElgatoLight.State(on: 0, brightness: 80, temperature: 200)
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { lid == id && !s.isOn && s.kelvin == 5000 } else { false } })

        fake.setOffline(true)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })
        fake.setOffline(false)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: true) })
        await provider.stop()
    }

    @Test func restoreThenLoadWithoutDiscovery() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let stored = PairedDevice(id: "CN11A1A00001", brand: .elgato, name: "Stored name", model: "Elgato Key Light",
                                  hostHint: "127.0.0.1", port: Int(fake.port),
                                  lightIDs: [try #require(LightID("elgato:CN11A1A00001"))], metadata: ["color": "0"])
        await provider.restore([stored])
        #expect(await provider.pairedSerials == ["CN11A1A00001"])
        let light = try #require(try await provider.loadLights().first)
        #expect(light.state.reachable)
        #expect(light.name == "Desk Light")   // refreshed from accessory-info
        #expect(await provider.endpoint(of: light.id) == "127.0.0.1:\(fake.port)")
    }

    @Test func identifyBlinksTheLight() async throws {
        let fake = try FakeElgatoLight()
        defer { fake.stop() }
        let provider = makeProvider()
        let id = try await pairManually(provider, fake)
        try await provider.identify(id)
        #expect(fake.identifyCount == 1)
    }

    @Test func groupReportsPartialFailure() async throws {
        let a = try FakeElgatoLight(serial: "AAAA00000001")
        let b = try FakeElgatoLight(serial: "BBBB00000002")
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
        #expect(a.state.on == 0)
    }

    @Test func parsesHostSpecs() {
        #expect(ElgatoProvider.parseHost("192.168.1.20", defaultPort: 9123)! == ("192.168.1.20", 9123))
        #expect(ElgatoProvider.parseHost(" 192.168.1.20:8080 ", defaultPort: 9123)! == ("192.168.1.20", 8080))
        #expect(ElgatoProvider.parseHost("elgato-key-light.local", defaultPort: 9123)! == ("elgato-key-light.local", 9123))
        #expect(ElgatoProvider.parseHost("[fe80::1]:9123", defaultPort: 1)! == ("fe80::1", 9123))
        #expect(ElgatoProvider.parseHost("fe80::1", defaultPort: 9123)! == ("fe80::1", 9123))
        #expect(ElgatoProvider.parseHost("", defaultPort: 9123) == nil)
        #expect(ElgatoProvider.parseHost("host:notaport", defaultPort: 9123) == nil)
        #expect(ElgatoHTTPRequest(method: .get, host: "fe80::1%en0", port: 9123, path: "/elgato/lights").url?.absoluteString
                == "http://[fe80::1%25en0]:9123/elgato/lights")
    }
}
