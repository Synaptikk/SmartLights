import Foundation
import LightCore
import MagicHomeCodec
import Testing
@testable import MagicHomeProvider

// MARK: - Helpers

private func testConfig() -> MagicHomeProvider.Configuration {
    MagicHomeProvider.Configuration(
        connectTimeout: .milliseconds(300),
        requestTimeout: .milliseconds(250),
        retries: 2,
        broadcastListen: .milliseconds(200),
        probeTimeout: .milliseconds(200),
        pollInterval: .milliseconds(100)
    )
}

private func raw(_ model: UInt8, on: Bool = true, mode: UInt8 = 0x23, version: UInt8 = 4,
                 r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, ww: UInt8 = 0, cw: UInt8 = 0) -> MagicHomeRawState {
    MagicHomeRawState(modelNumber: model, power: on ? 0x23 : 0x24, presetPattern: 0x61, mode: mode, speed: 0x10,
                      red: r, green: g, blue: b, warmWhite: ww, version: version, coolWhite: cw, colorMode: 0)
}

private func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

private func pair(_ provider: MagicHomeProvider, _ fake: FakeMagicHomeDevice) async throws -> LightID {
    let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [fake.ip])))
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

@Suite("MagicHomeProvider against in-process fake devices", .serialized)
struct MagicHomeProviderTests {
    @Test func broadcastDiscoveryReadsModelOverTCP() async {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.20", mac: "b4e842e10588", raw: raw(0x35, mode: 0x17, version: 9, r: 255))
        let strip = FakeMagicHomeDevice(ip: "10.0.0.21", mac: "accf23000001", hardware: "HF-LPB100-ZJ200", raw: raw(0x06, version: 2, r: 9))
        let net = FakeMagicHomeNetwork([bulb, strip])
        let provider = MagicHomeProvider(configuration: testConfig(), environment: net.environment)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast], broadcastAvailable: true)))
        #expect(Set(found.map(\.id)) == ["b4e842e10588", "accf23000001"])
        let b = try! #require(found.first { $0.id == "b4e842e10588" })
        #expect(b.method == .broadcast)
        #expect(b.host == "10.0.0.20")
        #expect(b.model == "Bulb RGBCW (0x35)")
        #expect(b.metadata["protocol"] == "LEDENET_9BYTE_DIMMABLE_EFFECTS")
        #expect(b.metadata["hardware"] == "AK001-ZJ2145")
        #expect(b.macAddress == "b4e842e10588")
    }

    @Test func sweepWhenBroadcastUnavailable() async {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.30", mac: "b4e842e10599", raw: raw(0x44))
        let net = FakeMagicHomeNetwork([bulb], sweep: ["10.0.0.29", "10.0.0.30", "10.0.0.31"], broadcast: false)
        let provider = MagicHomeProvider(configuration: testConfig(), environment: net.environment)
        // broadcastAvailable false -> the provider must not broadcast, it sweeps instead.
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast, .sweep])))
        #expect(found.map(\.id) == ["b4e842e10599"])
        #expect(found.first?.method == .sweep)
    }

    @Test func pairLoadAndCapabilities() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.40", mac: "b4e842e10511", raw: raw(0x35, mode: 0x17, version: 9, ww: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        let id = try await pair(provider, bulb)
        #expect(id.rawValue == "magichome:b4e842e10511")
        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(light.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(light.state.colorMode == .colorTemp)
        #expect(light.state.kelvin == 2700)
        #expect(light.state.isOn)
        #expect(light.model == "Bulb RGBCW (0x35)")
        #expect(await provider.isConnected(id))
        // Discovery closes its probe connection; pairing opens the one persistent connection.
        #expect(bulb.connectCount == 2)
        #expect(bulb.openConnections == 1)
        _ = try await provider.loadLights()
        #expect(bulb.connectCount == 2)
    }

    @Test func sendsOneLevelsMessageAndEmitsState() async throws {
        let ctrl = FakeMagicHomeDevice(ip: "10.0.0.41", mac: "b4e842e10512", raw: raw(0x33, version: 9, r: 255, g: 255, b: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([ctrl]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let id = try await pair(provider, ctrl)
        let before = ctrl.received.count
        try await provider.send(LightCommand(brightness: 0.5, color: .hs(HS(h: 240, s: 1))), to: id)
        let sent = Array(ctrl.received.dropFirst(before))
        #expect(sent.map(hex) == ["31 00 00 80 00 00 0f c0"])
        #expect((ctrl.raw.red, ctrl.raw.green, ctrl.raw.blue) == (0, 0, 128))
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let s) = e { return lid == id && s.rgb == RGB(r: 0, g: 0, b: 255) && abs((s.brightness ?? 0) - 128.0 / 255) < 1e-9 }
            return false
        })
    }

    @Test func powersOnFirstWhenLevelsDoNotTurnOn() async throws {
        let old = FakeMagicHomeDevice(ip: "10.0.0.42", mac: "b4e842e10513", raw: raw(0x06, on: false, version: 0, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([old]).environment)
        let id = try await pair(provider, old)
        let before = old.received.count
        try await provider.send(LightCommand(brightness: 1, color: .rgbw(RGBW(r: 0, g: 255, b: 0, w: 0))), to: id)
        let sent = Array(old.received.dropFirst(before))
        #expect(sent.map(hex) == ["71 23 0f a3", "31 00 ff 00 00 00 0f 3f"])
        #expect(old.raw.isOn)
    }

    @Test func pushedChangesBecomeEvents() async throws {
        let ctrl = FakeMagicHomeDevice(ip: "10.0.0.43", mac: "b4e842e10514", raw: raw(0x33, version: 9, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([ctrl]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let id = try await pair(provider, ctrl)
        ctrl.externalChange { $0.power = MagicHomeRawState.offByte }
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let s) = e { return lid == id && !s.isOn }
            return false
        })
    }

    @Test func pollingReportsChangesOnNonPushFirmware() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.44", mac: "b4e842e10515", raw: raw(0x44, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let id = try await pair(provider, bulb)
        bulb.externalChange { $0.red = 0; $0.warmWhite = 200 }   // no push on this firmware
        await provider.start()
        defer { Task { await provider.stop() } }
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let s) = e { return lid == id && s.colorMode == .white }
            return false
        })
    }

    @Test func retriesDroppedQueries() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.45", mac: "b4e842e10516", raw: raw(0x21, version: 2, r: 128))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        _ = try await pair(provider, bulb)
        bulb.externalChange { $0.red = 51 }
        bulb.dropQueries(2)
        let lights = try await provider.loadLights()
        #expect(lights.first?.state.brightness == 0.2)
        #expect(lights.first?.state.reachable == true)
        // Each retry opens a fresh connection.
        #expect(bulb.connectCount >= 3)
    }

    @Test func unreachableAfterDeviceGoesOffline() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.46", mac: "b4e842e10517", raw: raw(0x52, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let id = try await pair(provider, bulb)
        bulb.setOffline(true)
        await #expect(throws: LightCoreError.self) { try await provider.send(LightCommand(brightness: 0.4), to: id) }
        #expect(await log.waitFor { e in
            if case .reachabilityChanged(let lid, false) = e { return lid == id }
            return false
        })
        let lights = try await provider.loadLights()
        #expect(lights.first?.state.reachable == false)
        // Back online: the next command reconnects.
        bulb.setOffline(false)
        try await provider.send(LightCommand(brightness: 1, color: .kelvin(6500)), to: id)
        #expect((bulb.raw.red, bulb.raw.green) == (0, 255))
    }

    @Test func wrappedCCTTableLamp() async throws {
        let lamp = FakeMagicHomeDevice(ip: "10.0.0.47", mac: "b4e842e10518", raw: raw(0x1C, ww: 0, cw: 100))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([lamp]).environment)
        let id = try await pair(provider, lamp)
        let light = try #require(try await provider.loadLights().first)
        #expect(light.capabilities.supportedColorModes == [.colorTemp])
        #expect(light.state.kelvin == 2700)
        try await provider.send(LightCommand(brightness: 0.5, color: .kelvin(6500)), to: id)
        #expect((lamp.raw.warmWhite, lamp.raw.coolWhite) == (100, 50))
        #expect(lamp.received.last?.first == 0x35)   // the fake records the unwrapped inner message
    }

    @Test func unsupportedModelIsRejectedAtPairing() async throws {
        let strip = FakeMagicHomeDevice(ip: "10.0.0.48", mac: "b4e842e10519", raw: raw(0xA3, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([strip]).environment)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [strip.ip])))
        let device = try #require(found.first)
        #expect(device.metadata["protocol"] == "unsupported")
        await #expect(throws: LightCoreError.self) { _ = try await provider.pair(device, using: ScriptedPairingInteraction([])) }
    }

    @Test func manualHostWithoutUDPGetsProvisionalID() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.49", mac: "b4e842e10520", raw: raw(0x44))
        bulb.setAnswersUDP(false)
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [bulb.ip])))
        let device = try #require(found.first)
        #expect(device.id == "ip:10.0.0.49")
        #expect(device.model == "Bulb RGBW (0x44)")
        // Pairing needs the MAC (stable id): UDP still silent -> error; once it answers -> paired.
        await #expect(throws: LightCoreError.self) { _ = try await provider.pair(device, using: ScriptedPairingInteraction([])) }
        bulb.setAnswersUDP(true)
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(paired.id == "b4e842e10520")
    }

    @Test func addByIPAsksForAddress() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.50", mac: "b4e842e10521", raw: raw(0x44))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([bulb]).environment)
        let ui = ScriptedPairingInteraction([.text("10.0.0.50")])
        let paired = try await provider.pair(DiscoveredDevice(id: "manual", brand: .magicHome, name: "Magic Home", method: .manual), using: ui)
        #expect(paired.id == "b4e842e10521")
        #expect(paired.hostHint == "10.0.0.50")
        #expect(paired.metadata["modelNumber"] == "0x44")
    }

    @Test func rediscoveryFollowsIPChange() async throws {
        let bulb = FakeMagicHomeDevice(ip: "10.0.0.51", mac: "b4e842e10522", raw: raw(0x44, r: 255))
        let net = FakeMagicHomeNetwork([bulb])
        let provider = MagicHomeProvider(configuration: testConfig(), environment: net.environment)
        let id = try await pair(provider, bulb)
        let moved = net.move(bulb, to: "10.0.0.77")
        _ = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast], broadcastAvailable: true)))
        #expect(await provider.host(of: id) == "10.0.0.77")
        try await provider.send(.turnOff, to: id)
        #expect(!moved.raw.isOn)
    }

    @Test func restoreAndGroupPartialFailure() async throws {
        let a = FakeMagicHomeDevice(ip: "10.0.0.60", mac: "b4e842e10601", raw: raw(0x44, r: 255))
        let b = FakeMagicHomeDevice(ip: "10.0.0.61", mac: "b4e842e10602", raw: raw(0x44, r: 255))
        let provider = MagicHomeProvider(configuration: testConfig(), environment: FakeMagicHomeNetwork([a, b]).environment)
        await provider.restore([
            PairedDevice(id: a.mac, brand: .magicHome, name: "Desk", hostHint: a.ip, lightIDs: [MagicHomeMapping.lightID(mac: a.mac)]),
            PairedDevice(id: b.mac, brand: .magicHome, name: "Shelf", hostHint: b.ip, lightIDs: [MagicHomeMapping.lightID(mac: b.mac)]),
        ])
        let names = try await provider.loadLights().map(\.name)
        #expect(names == ["Desk", "Shelf"])
        b.setOffline(true)
        let ids = [MagicHomeMapping.lightID(mac: a.mac), MagicHomeMapping.lightID(mac: b.mac)]
        do {
            try await provider.sendGroup(.turnOff, to: ids)
            Issue.record("expected a partial failure")
        } catch LightCoreError.partialFailure(let failures) {
            #expect(Array(failures.keys) == [ids[1]])
        }
        #expect(!a.raw.isOn)
        await provider.shutdown()
        #expect(a.openConnections == 0)
    }
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined(separator: " ") }
