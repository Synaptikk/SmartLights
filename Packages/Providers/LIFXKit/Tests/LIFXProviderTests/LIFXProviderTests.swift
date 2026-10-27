import Foundation
import Testing
import LightCore
import NetKit
import LIFXCodec
@testable import LIFXProvider

// MARK: - Helpers

private func testConfig(port: UInt16 = LIFXProvider.defaultPort) -> LIFXProvider.Configuration {
    LIFXProvider.Configuration(
        port: port,
        requestTimeout: .milliseconds(250),
        retries: 3,
        sweepTimeout: .milliseconds(250),
        pollInterval: .milliseconds(150),
        messagesPerSecond: 1000,
        source: 0x5EED_0001
    )
}

private func makeProvider(
    port: UInt16 = LIFXProvider.defaultPort,
    broadcast: [String] = [],
    sweep: [IPv4Addr] = [],
    secrets: InMemorySecretStore = InMemorySecretStore()
) throws -> (LIFXProvider, TestTransport) {
    let transport = try TestTransport()
    let env = LIFXNetworkEnvironment(
        makeTransport: { transport },
        broadcastAddresses: { broadcast },
        sweepHosts: { sweep }
    )
    return (LIFXProvider(configuration: testConfig(port: port), environment: env, secretStore: secrets), transport)
}

private func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

/// Pairs `fake` through manual discovery and returns its light id.
private func pairManually(_ provider: LIFXProvider, _ fake: FakeLIFXDevice) async throws -> LightID {
    let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(3), methods: [.manual], manualHosts: [fake.hostSpec])))
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

    func waitFor(timeout: Duration = .seconds(3), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if events.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events.contains(where: predicate)
    }
}

// MARK: - Tests

@Suite("LIFXProvider against a fake UDP bulb", .serialized)
struct LIFXProviderTests {
    @Test func discoversManualHost() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(3), methods: [.manual], manualHosts: [fake.hostSpec])))
        #expect(found.count == 1)
        let d = try #require(found.first)
        #expect(d.id == "d073d5001337")
        #expect(d.brand == .lifx)
        #expect(d.name == "Desk")
        #expect(d.model == "LIFX (A19)")
        #expect(d.macAddress == "d0:73:d5:00:13:37")
        #expect(d.host == "127.0.0.1")
        #expect(d.port == Int(fake.port))
        #expect(d.method == .manual)
        #expect(d.metadata["product"] == "27")
        #expect(d.metadata["firmware"] == "3.70")
        await provider.shutdown()
    }

    @Test func discoversByBroadcastWhenAllowed() async throws {
        let fake = try FakeLIFXDevice(serial: "d073d5aa0001", label: "Hall")
        defer { fake.stop() }
        let (provider, _) = try makeProvider(port: fake.port, broadcast: ["127.0.0.1"])
        let opts = DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast, .sweep], broadcastAvailable: true)
        let found = await collect(await provider.discover(options: opts))
        #expect(found.map(\.id) == ["d073d5aa0001"])
        #expect(found.first?.method == .broadcast)
        let services = fake.received(LIFXMessage.Kind.getService)
        #expect(!services.isEmpty)
        #expect(services.allSatisfy { $0.header.tagged && $0.header.target.isAll })
        await provider.shutdown()
    }

    @Test func fallsBackToUnicastSweepWithoutBroadcast() async throws {
        let fake = try FakeLIFXDevice(serial: "d073d5aa0002", label: "Porch")
        defer { fake.stop() }
        let (provider, transport) = try makeProvider(port: fake.port, broadcast: ["127.0.0.255"], sweep: [IPv4Addr(127, 0, 0, 1)])
        let opts = DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast, .sweep], broadcastAvailable: false)
        let found = await collect(await provider.discover(options: opts))
        #expect(found.map(\.id) == ["d073d5aa0002"])
        #expect(found.first?.method == .sweep)
        #expect(transport.sentCount > 0)
        await provider.shutdown()
    }

    @Test func pairsAndLoadsLights() async throws {
        let fake = try FakeLIFXDevice(color: HSBK(hue: 0, saturation: 0, brightness: 65535, kelvin: 2700))
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)
        #expect(id.rawValue == "lifx:d073d5001337")
        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(lights.count == 1)
        #expect(light.name == "Desk")
        #expect(light.manufacturer == "LIFX")
        #expect(light.model == "LIFX (A19)")
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(light.capabilities.kelvinRange == 1500...9000) // fw 3.70 >= 2.80 upgrade
        #expect(light.state.isOn)
        #expect(light.state.reachable)
        #expect(light.state.colorMode == .colorTemp)
        #expect(light.state.kelvin == 2700)
        #expect(light.state.brightness == 1)
        #expect(light.providerRef == fake.hostSpec)
        #expect(await provider.pairedSerials.map(\.hex) == ["d073d5001337"])
        await provider.shutdown()
    }

    @Test func pairsByAskingForTheIPAddress() async throws {
        let fake = try FakeLIFXDevice(serial: "d073d5bb0001")
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let manual = DiscoveredDevice(id: "ip:manual", brand: .lifx, name: "LIFX", method: .manual)
        let ui = ScriptedPairingInteraction([.text(fake.hostSpec)])
        let paired = try await provider.pair(manual, using: ui)
        #expect(paired.id == "d073d5bb0001")
        #expect(paired.hostHint == "127.0.0.1")
        #expect(paired.port == Int(fake.port))
        #expect(paired.metadata["product"] == "27")
        #expect(paired.lightIDs.map(\.rawValue) == ["lifx:d073d5bb0001"])
        await provider.shutdown()
    }

    @Test func sendCombinesColourAndBrightnessInOneSetColor() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let events = EventLog()
        await events.start(provider.events)
        let id = try await pairManually(provider, fake)
        try await provider.send(LightCommand(brightness: 0.5, color: .hs(HS(h: 120, s: 1)), transition: .seconds(1)), to: id)

        #expect(fake.snapshot.color == HSBK(hue: 21845, saturation: 65535, brightness: 32768, kelvin: 3500))
        let setColors = fake.received(LIFXMessage.Kind.lightSetColor)
        #expect(setColors.count == 1)
        #expect(setColors.first?.header.ackRequired == true)
        #expect(setColors.first?.message == .lightSetColor(HSBK(hue: 21845, saturation: 65535, brightness: 32768, kelvin: 3500), durationMs: 1000))
        #expect(fake.received(LIFXMessage.Kind.lightSetPower).isEmpty) // already on
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { return lid == id && s.colorMode == .hs } else { return false } })
        await provider.shutdown()
    }

    @Test func turnOffThenOnWithFade() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)

        try await provider.send(.turnOff, to: id)
        #expect(fake.snapshot.power == 0)

        try await provider.send(LightCommand(on: true, brightness: 0.2, transition: .milliseconds(500)), to: id)
        #expect(fake.snapshot.power == 65535)
        #expect(fake.snapshot.color.brightness == HSBK.encodeUnit(0.2))
        // Colour set instantly first, then power fades in.
        let sets = fake.snapshot.received.filter { [LIFXMessage.Kind.lightSetColor, LIFXMessage.Kind.lightSetPower].contains($0.header.type) }
        #expect(sets.map(\.message) == [
            .lightSetPower(level: 0, durationMs: 0),
            .lightSetColor(HSBK(hue: 0, saturation: 0, brightness: HSBK.encodeUnit(0.2), kelvin: 3500), durationMs: 0),
            .lightSetPower(level: 65535, durationMs: 500),
        ])
        await provider.shutdown()
    }

    @Test func retriesLostPackets() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)
        fake.with { $0.dropNext = 2 }
        try await provider.send(LightCommand(color: .kelvin(5000)), to: id)
        #expect(fake.snapshot.color.kelvin == 5000)
        let attempts = fake.received(LIFXMessage.Kind.lightSetColor)
        #expect(attempts.count == 3)
        // Each retry uses a fresh sequence number.
        #expect(Set(attempts.map(\.header.sequence)).count == 3)
        await provider.shutdown()
    }

    @Test func offlineLightBecomesUnreachable() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let events = EventLog()
        await events.start(provider.events)
        let id = try await pairManually(provider, fake)
        fake.with { $0.offline = true }

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOff, to: id) }
        let elapsed = clock.now - started
        #expect(elapsed >= .milliseconds(900)) // 4 attempts x 250 ms
        #expect(fake.received(LIFXMessage.Kind.lightSetPower).count == 4) // 1 + 3 retries
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })

        let lights = try await provider.loadLights()
        #expect(lights.first?.state.reachable == false)

        fake.with { $0.offline = false }
        let again = try await provider.loadLights()
        #expect(again.first?.state.reachable == true)
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: true) })
        await provider.shutdown()
    }

    @Test func groupFanOut() async throws {
        let a = try FakeLIFXDevice(serial: "d073d5000a01", label: "A")
        let b = try FakeLIFXDevice(serial: "d073d5000b02", label: "B")
        defer { a.stop(); b.stop() }
        let (provider, _) = try makeProvider()
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(3), methods: [.manual], manualHosts: [a.hostSpec, b.hostSpec])))
        #expect(Set(found.map(\.id)) == ["d073d5000a01", "d073d5000b02"])
        var ids: [LightID] = []
        for d in found { ids += try await provider.pair(d, using: ScriptedPairingInteraction([])).lightIDs }
        try await provider.sendGroup(LightCommand(color: .kelvin(2500)), to: ids)
        #expect(a.snapshot.color.kelvin == 2500)
        #expect(b.snapshot.color.kelvin == 2500)

        b.with { $0.offline = true }
        do {
            try await provider.sendGroup(.turnOff, to: ids)
            Issue.record("expected partial failure")
        } catch LightCoreError.partialFailure(let failures) {
            #expect(Array(failures.keys) == [LightID("lifx:d073d5000b02")!])
        }
        #expect(a.snapshot.power == 0)
        await provider.shutdown()
    }

    @Test func legacyMultizoneStrip() async throws {
        // LIFX Z (product 32) on fw 2.70: multizone without extended multizone.
        let fake = try FakeLIFXDevice(serial: "d073d5222222", label: "Strip", product: 32, firmware: (2, 70), zoneCount: 16)
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)
        let zones = try await provider.zones(of: id)
        #expect(zones == fake.snapshot.zones)
        #expect(zones.count == 16)
        #expect(!fake.received(LIFXMessage.Kind.getColorZones).isEmpty)

        let rainbow = (0..<16).map { HSBK(hueDegrees: Double($0) * 22.5, saturation: 1, brightness: 1, kelvin: 3500) }
        try await provider.setZones(rainbow, on: id, transition: .milliseconds(300))
        #expect(fake.snapshot.zones == rainbow)
        let sets = fake.received(LIFXMessage.Kind.setColorZones)
        #expect(sets.count == 16)
        if case .setColorZones(_, _, _, let d, let apply) = sets.last?.message {
            #expect(apply == .apply)
            #expect(d == 300)
        }
        if case .setColorZones(_, _, _, _, let apply) = sets.first?.message { #expect(apply == .noApply) }
        await provider.shutdown()
    }

    @Test func extendedMultizoneStrip() async throws {
        // LIFX Z on fw 2.80 supports extended multizone; 100 zones need two 82-colour messages.
        let fake = try FakeLIFXDevice(serial: "d073d5333333", label: "Long strip", product: 32, firmware: (2, 80), zoneCount: 100)
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)
        let zones = try await provider.zones(of: id)
        #expect(zones.count == 100)
        #expect(zones == fake.snapshot.zones)
        #expect(!fake.received(LIFXMessage.Kind.extendedGetColorZones).isEmpty)
        #expect(fake.received(LIFXMessage.Kind.getColorZones).isEmpty)

        let warm = Array(repeating: HSBK(hue: 0, saturation: 0, brightness: 40000, kelvin: 2200), count: 100)
        try await provider.setZones(warm, on: id)
        #expect(fake.snapshot.zones == warm)
        let sets = fake.received(LIFXMessage.Kind.extendedSetColorZones)
        #expect(sets.count == 2)
        if case .extendedSetColorZones(_, let apply, let index, let colors) = sets.last?.message {
            #expect(apply == .apply)
            #expect(index == 82)
            #expect(colors.count == 18)
        }
        await provider.shutdown()
    }

    @Test func zonesOnABulbAreUnsupported() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let id = try await pairManually(provider, fake)
        await #expect(throws: LightCoreError.self) { _ = try await provider.zones(of: id) }
        // A raw request the bulb does not handle yields StateUnhandled -> .unsupported.
        do {
            _ = try await provider.request(.getColorZones(start: 0, end: 255), to: LIFXSerial("d073d5001337")!,
                                           expects: [LIFXMessage.Kind.stateMultiZone])
            Issue.record("expected unsupported")
        } catch LightCoreError.unsupported {
        }
        await provider.shutdown()
    }

    @Test func pollingEmitsExternalChanges() async throws {
        let fake = try FakeLIFXDevice()
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        let events = EventLog()
        await events.start(provider.events)
        let id = try await pairManually(provider, fake)
        _ = try await provider.loadLights()
        await provider.start()
        // Someone else (LIFX app) turns the light red.
        fake.with { $0.color = HSBK(hue: 0, saturation: 65535, brightness: 65535, kelvin: 3500) }
        #expect(await events.waitFor {
            if case .stateChanged(let lid, let s) = $0 { return lid == id && s.colorMode == .hs && s.hs?.h == 0 } else { return false }
        })
        fake.with { $0.label = "Renamed" }
        #expect(await events.waitFor { if case .lightUpdated(let l) = $0 { return l.name == "Renamed" } else { return false } })
        await provider.stop()
        await provider.shutdown()
    }

    @Test func restoreAndRediscoverUpdatesEndpoint() async throws {
        let fake = try FakeLIFXDevice(serial: "d073d5444444")
        defer { fake.stop() }
        let (provider, _) = try makeProvider()
        // Persisted with a stale port (the bulb "moved").
        let stale = PairedDevice(id: "d073d5444444", brand: .lifx, name: "Old", hostHint: "127.0.0.1", port: 9,
                                 lightIDs: [LightID("lifx:d073d5444444")!], metadata: ["vendor": "1", "product": "27", "firmware": "3.70"])
        await provider.restore([stale])
        let id = LightID("lifx:d073d5444444")!
        #expect(try await provider.loadLights().first?.state.reachable == false)

        _ = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(3), methods: [.manual], manualHosts: [fake.hostSpec])))
        #expect(await provider.endpoint(of: id) == fake.hostSpec)
        let lights = try await provider.loadLights()
        #expect(lights.first?.state.reachable == true)
        #expect(lights.first?.name == "Desk")
        await provider.shutdown()
    }

    @Test func cloudTokenIsStoredInSecretStore() async throws {
        let secrets = InMemorySecretStore()
        let (provider, _) = try makeProvider(secrets: secrets)
        #expect(await provider.account == nil)
        try await provider.configureCloudToken(using: ScriptedPairingInteraction([.text("  c0ffee-token  ")]))
        #expect(await provider.account?.secretKeys == [LIFXProvider.cloudTokenKey])
        #expect(try await secrets.string(for: LIFXProvider.cloudTokenKey) == "c0ffee-token")

        let (other, _) = try makeProvider(secrets: secrets)
        await other.loadCloudAccount()
        #expect(await other.account?.id == "lifx-cloud")

        try await provider.setCloudToken(nil)
        #expect(await provider.account == nil)
        #expect(await secrets.count == 0)
    }

    @Test func unknownLightAndEmptyCommand() async throws {
        let (provider, _) = try makeProvider()
        await #expect(throws: LightCoreError.lightNotFound(LightID("lifx:d073d5999999")!)) {
            try await provider.send(.turnOn, to: LightID("lifx:d073d5999999")!)
        }
        #expect(LIFXProvider.parseHost("10.0.0.5", defaultPort: 56700)! == ("10.0.0.5", 56700))
        #expect(LIFXProvider.parseHost("10.0.0.5:1234", defaultPort: 56700)! == ("10.0.0.5", 1234))
        #expect(LIFXProvider.parseHost(" ", defaultPort: 56700) == nil)
    }
}
