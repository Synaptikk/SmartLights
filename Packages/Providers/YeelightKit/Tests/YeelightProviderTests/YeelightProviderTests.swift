import Foundation
import LightCore
import NetKit
import Testing
import YeelightCodec
@testable import YeelightProvider

private let host1 = "192.168.1.239"
private let host2 = "192.168.1.240"
private let bulbID = "0x000000000015243f"
private let lightID = LightID(brand: .yeelight, stableId: bulbID)!

@Suite("YeelightProvider (in-memory device)")
struct YeelightProviderTests {
    struct Harness {
        let provider: YeelightProvider
        let connector: InMemoryConnector
        let bulb: FakeYeelightBulb
        let recorder: EventRecorder
    }

    private func make(
        bulb: FakeYeelightBulb = FakeYeelightBulb(),
        backend: FakeDiscoveryBackend? = nil,
        configuration: YeelightProvider.Configuration = .test()
    ) async -> Harness {
        let connector = InMemoryConnector()
        connector.add(bulb, at: host1)
        let backend = backend ?? FakeDiscoveryBackend(unicast: [host1: bulb.advertisement(host: host1)])
        let provider = YeelightProvider(connector: connector, discovery: backend, configuration: configuration)
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        return Harness(provider: provider, connector: connector, bulb: bulb, recorder: recorder)
    }

    private func pairDefault(_ h: Harness) async throws -> PairedDevice {
        let device = DiscoveredDevice(id: bulbID, brand: .yeelight, name: "Bulb", model: "color", host: host1, port: 55443, method: .manual)
        return try await h.provider.pair(device, using: ScriptedPairingInteraction([]))
    }

    @Test func brandAndAccount() async {
        let h = await make()
        #expect(YeelightProvider.brand == .yeelight)
        #expect(await h.provider.account == nil)
    }

    // MARK: Discovery

    @Test func manualHostIsIdentifiedByUnicastSSDP() async {
        let h = await make()
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [host1])) {
            found.append(d)
        }
        #expect(found.count == 1)
        #expect(found.first?.id == bulbID)
        #expect(found.first?.host == host1)
        #expect(found.first?.model == "color")
        #expect(found.first?.method == .manual)
        #expect(found.first?.metadata["support"]?.contains("set_rgb") == true)
    }

    @Test func manualHostWithoutSSDPReplyGetsProvisionalID() async {
        let h = await make(backend: FakeDiscoveryBackend())
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [host1])) {
            found.append(d)
        }
        #expect(found.map(\.id) == ["ip:\(host1)"])
        #expect(found.first?.metadata["idSource"] == "provisional")
    }

    @Test func manualHostWithLANControlOffIsReportedAsSuch() async {
        let h = await make()
        h.connector.refuse(host1)
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [host1])) {
            found.append(d)
        }
        #expect(found.first?.id == bulbID)
        #expect(found.first?.metadata["lanControl"] == "off")
    }

    @Test func multicastBonjourAndDedupe() async {
        let bulb = FakeYeelightBulb()
        let other = FakeYeelightBulb(id: "0x0000000000aaaaaa", model: "ceiling4")
        let backend = FakeDiscoveryBackend(
            multicast: [bulb.advertisement(host: host1), bulb.advertisement(host: host1)],
            unicast: [host1: bulb.advertisement(host: host1)],
            bonjourHits: [
                YeelightBonjourHit(serviceName: "yeelink-light-color1_miio1385535", host: host1),
                YeelightBonjourHit(serviceName: "yeelink-light-ceiling4_miio11184810", host: host2),
            ]
        )
        let h = await make(bulb: bulb, backend: backend)
        _ = other
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast, .bonjour], broadcastAvailable: true)) {
            found.append(d)
        }
        // host1: one entry despite multicast x2 + bonjour; host2 does not answer TCP/SSDP so its id
        // comes from the Bonjour name.
        #expect(found.filter { $0.id == bulbID }.count == 1)
        let fromName = found.first { $0.host == host2 }
        #expect(fromName?.id == "0x0000000000aaaaaa")
        #expect(fromName?.model == "ceiling4")
        #expect(found.count == 2)
    }

    @Test func sweepFindsBulbsByTCPProbeOnlyWithoutBroadcast() async {
        let bulb = FakeYeelightBulb()
        let backend = FakeDiscoveryBackend(
            unicast: [host1: bulb.advertisement(host: host1)],
            sweep: [IPv4Addr(host1)!, IPv4Addr(host2)!, IPv4Addr("192.168.1.241")!]
        )
        let h = await make(bulb: bulb, backend: backend)
        h.connector.refuse("192.168.1.241") // LAN control off: skipped by the sweep
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(3), methods: [.sweep])) {
            found.append(d)
        }
        #expect(found.map(\.id) == [bulbID])
        #expect(found.first?.method == .sweep)

        // With broadcast available the sweep is skipped.
        var none: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(1), methods: [.sweep], broadcastAvailable: true)) {
            none.append(d)
        }
        #expect(none.isEmpty)
    }

    // MARK: Pairing

    @Test func pairReadsStateAndCapabilities() async throws {
        let bulb = FakeYeelightBulb(state: .init(power: true, bright: 80, ct: 3000, colorMode: 2, name: "desk"))
        let h = await make(bulb: bulb)
        let paired = try await pairDefault(h)
        #expect(paired.id == bulbID)
        #expect(paired.brand == .yeelight)
        #expect(paired.name == "desk")
        #expect(paired.hostHint == host1)
        #expect(paired.lightIDs == [lightID])
        #expect(paired.metadata["kind"] == "color")
        let added = await h.recorder.waitFor { if case .lightAdded = $0 { true } else { false } }
        guard case .lightAdded(let light)? = added else { Issue.record("no lightAdded"); return }
        #expect(light.id == lightID)
        #expect(light.capabilities.supportedColorModes == [.colorTemp, .hs, .rgb])
        #expect(light.capabilities.kelvinRange == 1700...6500)
        #expect(light.state.isOn)
        #expect(light.state.kelvin == 3000)
        #expect(light.state.brightness == 0.8)
        #expect(light.providerRef == "\(host1):55443")
    }

    @Test func pairProvisionalDeviceUpgradesToSSDPID() async throws {
        let h = await make()
        let device = DiscoveredDevice(id: "ip:\(host1)", brand: .yeelight, name: "Typed IP", host: host1, method: .manual)
        let paired = try await h.provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(paired.id == bulbID)
        #expect(paired.model == "color")
    }

    @Test func lanControlOffAsksUserAndRetries() async throws {
        let h = await make()
        h.connector.refuse(host1, count: 1)
        let ui = ScriptedPairingInteraction([.confirm(true)])
        let device = DiscoveredDevice(id: bulbID, brand: .yeelight, name: "Bulb", host: host1, method: .manual)
        let paired = try await h.provider.pair(device, using: ui)
        #expect(paired.id == bulbID)
        let prompts = await ui.prompts
        #expect(prompts.contains(YeelightProvider.lanControlGuidance))
        #expect(prompts.contains { $0.contains("LAN Control") })
    }

    @Test func lanControlOffUserDeclines() async throws {
        let h = await make()
        h.connector.refuse(host1)
        let device = DiscoveredDevice(id: bulbID, brand: .yeelight, name: "Bulb", host: host1, method: .manual)
        await #expect(throws: LightCoreError.userCancelled) {
            try await h.provider.pair(device, using: ScriptedPairingInteraction([.confirm(false)]))
        }
        #expect(try await h.provider.loadLights().isEmpty)
    }

    @Test func lanControlStaysOffGivesUpAfterAttempts() async {
        let h = await make()
        h.connector.refuse(host1)
        let device = DiscoveredDevice(id: bulbID, brand: .yeelight, name: "Bulb", host: host1, method: .manual)
        do {
            _ = try await h.provider.pair(device, using: ScriptedPairingInteraction([.confirm(true), .confirm(true)]))
            Issue.record("expected failure")
        } catch let LightCoreError.unreachable(message) {
            #expect(message.contains("LAN Control"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(h.connector.connectCount(host1) == 3)
    }

    @Test func pairWithoutHostFails() async {
        let h = await make()
        let device = DiscoveredDevice(id: bulbID, brand: .yeelight, name: "Bulb", method: .manual)
        await #expect(throws: LightCoreError.self) {
            try await h.provider.pair(device, using: ScriptedPairingInteraction([]))
        }
    }

    // MARK: Control

    @Test func turnOnWithColorUsesSingleSetScene() async throws {
        let h = await make()
        _ = try await pairDefault(h)
        h.bulb.clearLog()
        try await h.provider.send(LightCommand(on: true, brightness: 0.5, color: .rgb(RGB(r: 0, g: 255, b: 0))), to: lightID)
        #expect(h.bulb.receivedMethods == ["set_scene"])
        #expect(h.bulb.received.first?.params == ["color", 65280, 50])
        #expect(h.bulb.state.power)
        #expect(h.bulb.state.rgb == 65280)
        #expect(h.bulb.state.bright == 50)
        let changed = await h.recorder.waitFor {
            if case .stateChanged(lightID, let s) = $0 { s.isOn && s.rgb == RGB(r: 0, g: 255, b: 0) } else { false }
        }
        #expect(changed != nil)
    }

    @Test func transitionUsesSmoothSetters() async throws {
        let h = await make(bulb: FakeYeelightBulb(state: .init(power: true)))
        _ = try await pairDefault(h)
        h.bulb.clearLog()
        try await h.provider.send(LightCommand(brightness: 0.3, color: .kelvin(2700), transition: .milliseconds(800)), to: lightID)
        #expect(h.bulb.receivedMethods == ["set_ct_abx", "set_bright"])
        #expect(h.bulb.received[0].params == [2700, "smooth", 800])
        #expect(h.bulb.received[1].params == [30, "smooth", 800])
        try await h.provider.send(.turnOff, to: lightID)
        #expect(h.bulb.state.power == false)
    }

    @Test func toggleAndSetName() async throws {
        let h = await make()
        _ = try await pairDefault(h)
        try await h.provider.toggle(lightID)
        #expect(h.bulb.state.power)
        try await h.provider.setName("Hallway", for: lightID)
        #expect(h.bulb.state.name == "Hallway")
        let lights = try await h.provider.loadLights()
        #expect(lights.first?.name == "Hallway")
    }

    @Test func externalChangesArriveAsStateChanged() async throws {
        let h = await make(bulb: FakeYeelightBulb(state: .init(power: true, bright: 100)))
        _ = try await pairDefault(h)
        await h.recorder.clear()
        h.bulb.externalChange { $0.bright = 10; $0.ct = 6500; $0.colorMode = 2 }
        let event = await h.recorder.waitFor {
            if case .stateChanged(lightID, let s) = $0 { s.brightness == 0.1 } else { false }
        }
        guard case .stateChanged(_, let state)? = event else { Issue.record("no notification"); return }
        #expect(state.kelvin == 6500)
        #expect(state.colorMode == .colorTemp)
        h.bulb.externalChange { $0.power = false }
        #expect(await h.recorder.waitFor { if case .stateChanged(lightID, let s) = $0 { !s.isOn } else { false } } != nil)
    }

    @Test func reconnectsAfterDropAndRefreshes() async throws {
        let h = await make(bulb: FakeYeelightBulb(state: .init(power: true)))
        _ = try await pairDefault(h)
        await h.recorder.clear()
        await h.connector.drop(host1)
        let down = await h.recorder.waitFor { $0 == .reachabilityChanged(lightID, reachable: false) }
        #expect(down != nil)
        let up = await h.recorder.waitFor { $0 == .reachabilityChanged(lightID, reachable: true) }
        #expect(up != nil)
        #expect(h.connector.connectCount(host1) >= 2)
        // Notifications flow over the new connection.
        h.bulb.externalChange { $0.bright = 42 }
        #expect(await h.recorder.waitFor { if case .stateChanged(lightID, let s) = $0 { s.brightness == 0.42 } else { false } } != nil)
    }

    @Test func firstCommandIgnoredAfterReconnectIsRetried() async throws {
        let h = await make(bulb: FakeYeelightBulb(state: .init(power: true)), configuration: .test(requestTimeout: .milliseconds(200)))
        _ = try await pairDefault(h)
        await h.provider.disconnectAll()
        h.bulb.ignoreNext(1)
        h.bulb.clearLog()
        try await h.provider.send(LightCommand(brightness: 0.6, transition: .zero), to: lightID)
        #expect(h.bulb.receivedMethods == ["set_bright", "set_bright"])
        #expect(h.bulb.state.bright == 60)
    }

    @Test func monoBulbDropsColorAndUnknownRefreshThrows() async throws {
        let bulb = FakeYeelightBulb(model: "mono", support: ["get_prop", "set_power", "set_bright", "toggle", "set_name"], state: .init(power: true))
        let h = await make(bulb: bulb)
        _ = try await pairDefault(h)
        let lights = try await h.provider.loadLights()
        #expect(lights.first?.capabilities.supportedColorModes == [.brightness])
        await #expect(throws: LightCoreError.self) {
            try await h.provider.refresh(LightID(brand: .yeelight, stableId: "0xdead")!)
        }
        // Mono drops colour; brightness still works.
        try await h.provider.send(LightCommand(brightness: 0.25, color: .rgb(RGB(r: 255, g: 0, b: 0))), to: lightID)
        #expect(bulb.receivedMethods.last == "set_bright")
    }

    @Test func rateLimiterThrottlesPerBulb() async throws {
        let h = await make(configuration: .test(rateLimit: RateLimiter<String>.Limit(capacity: 2, refillPerSecond: 5)))
        _ = try await pairDefault(h) // uses 1 token (get_prop)
        let start = ContinuousClock.now
        try await h.provider.send(.turnOn, to: lightID)
        try await h.provider.send(.turnOff, to: lightID)
        try await h.provider.send(.turnOn, to: lightID)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(300)) // 2 calls waited ~200 ms each
    }

    @Test func sendGroupFansOutAndReportsFailures() async throws {
        let h = await make()
        _ = try await pairDefault(h)
        let missing = LightID(brand: .yeelight, stableId: "0xmissing")!
        do {
            try await h.provider.sendGroup(.turnOn, to: [lightID, missing])
            Issue.record("expected partial failure")
        } catch let LightCoreError.partialFailure(failures) {
            #expect(Array(failures.keys) == [missing])
        }
        #expect(h.bulb.state.power)
    }

    @Test func unknownLightThrows() async {
        let h = await make()
        await #expect(throws: LightCoreError.lightNotFound(lightID)) {
            try await h.provider.send(.turnOn, to: lightID)
        }
    }

    @Test func restoreAndLoadLights() async throws {
        let h = await make(bulb: FakeYeelightBulb(state: .init(power: true, bright: 20, ct: 2900, colorMode: 2)))
        let record = PairedDevice(
            id: bulbID, brand: .yeelight, name: "Saved", model: "color", hostHint: host1, port: 55443,
            lightIDs: [lightID], metadata: ["kind": "color", "support": "get_prop set_power set_scene set_rgb set_ct_abx"]
        )
        await h.provider.restore([record])
        let lights = try await h.provider.loadLights()
        #expect(lights.count == 1)
        #expect(lights[0].state.reachable)
        #expect(lights[0].state.isOn)
        #expect(lights[0].state.kelvin == 2900)
        #expect(lights[0].state.brightness == 0.2)
        let devices = await h.provider.pairedDevices()
        #expect(devices.first?.metadata["support"]?.contains("set_scene") == true)

        // A bulb that moved is followed via discovery (keyed by id, not IP).
        h.connector.add(h.bulb, at: host2)
        await h.provider.note(h.bulb.advertisement(host: host2))
        #expect(await h.provider.pairedDevices().first?.hostHint == host2)
        try await h.provider.send(.turnOff, to: lightID)
        #expect(h.connector.connectCount(host2) == 1)
    }

    @Test func unreachableBulbIsMarkedOnLoad() async throws {
        let h = await make()
        let record = PairedDevice(id: bulbID, brand: .yeelight, name: "Gone", model: "color", hostHint: "10.9.9.9", lightIDs: [lightID])
        await h.provider.restore([record])
        let lights = try await h.provider.loadLights()
        #expect(lights.first?.state.reachable == false)
        await #expect(throws: LightCoreError.self) { try await h.provider.send(.turnOn, to: lightID) }
    }
}
