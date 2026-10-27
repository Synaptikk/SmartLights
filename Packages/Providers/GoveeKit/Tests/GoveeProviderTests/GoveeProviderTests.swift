import Foundation
import GoveeCodec
import LightCore
import Testing
@testable import GoveeProvider

/// Collects provider events.
actor EventRecorder {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { for await e in stream { self.append(e) } }
    }

    private func append(_ e: ProviderEvent) { events.append(e) }

    func states(for id: LightID) -> [LightState] {
        events.compactMap { if case .stateChanged(id, let s) = $0 { return s } else { return nil } }
    }

    func contains(_ predicate: @Sendable (ProviderEvent) -> Bool) -> Bool { events.contains(where: predicate) }
}

/// Polls `condition` until it holds or `timeout` elapses.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

func fastConfiguration() -> GoveeProvider.Configuration {
    var c = GoveeProvider.Configuration()
    c.lanStatusTimeout = .milliseconds(400)
    c.lanPollInterval = .milliseconds(150)
    c.lanStaleAfter = .seconds(30)
    c.scanRepeats = 1
    c.lanCommandSpacing = .zero
    c.lanConfirmDelay = nil
    c.sweepHosts = { [] }
    c.sweepLaunchInterval = nil
    return c
}

let lampID = "1F:80:C5:32:32:36:72:4E"
let stripID = "AA:BB:CC:DD:EE:FF:00:11"
let cloudOnlyID = "9D:FA:85:EB:D3:00:8B:FF"

@Suite("GoveeProvider over UDP (fake LAN device)", .serialized)
struct GoveeProviderUDPTests {

    @Test func discoverPairLoadAndControlOverRealUDP() async throws {
        let device = try FakeGoveeUDPDevice(device: lampID, sku: "H6076")
        defer { device.stop() }
        var config = fastConfiguration()
        config.scanPort = device.scanPort
        config.controlPort = device.controlPort
        let transport = POSIXGoveeLANTransport()
        let provider = GoveeProvider(configuration: config, lanTransport: transport, secrets: InMemorySecretStore())
        let recorder = EventRecorder()
        await recorder.start(provider.events)

        // Unicast scan to a manual host (no multicast entitlement).
        let found = await collect(provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(700), methods: [.manual], broadcastAvailable: false, manualHosts: ["127.0.0.1"])))
        let discovered = try #require(found.first)
        #expect(found.count == 1)
        #expect(discovered.id == lampID)
        #expect(discovered.brand == .govee)
        #expect(discovered.method == .manual)
        #expect(discovered.model == "H6076")
        #expect(discovered.host == "127.0.0.1")
        #expect(discovered.metadata["wifiVersionSoft"] == "1.02.03")
        #expect(discovered.metadata["lan"] == "seen")
        #expect(discovered.metadata["cloud"] == "false")

        // LAN devices pair without prompts.
        let ui = ScriptedPairingInteraction([])
        let paired = try await provider.pair(discovered, using: ui)
        #expect(await ui.prompts.isEmpty)
        #expect(paired.id == lampID)
        #expect(paired.hostHint == "127.0.0.1")
        #expect(paired.lightIDs == [LightID("govee:\(lampID)")!])

        device.logic.set { $0 = .init(onOff: 1, brightness: 40, color: GoveeRGB(r: 0, g: 0, b: 0), kelvin: 3000) }
        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(lights.count == 1)
        #expect(light.id.rawValue == "govee:\(lampID)")
        #expect(light.model == "H6076")
        #expect(light.providerRef == "lan:127.0.0.1")
        #expect(light.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(light.capabilities.kelvinRange == 2700...6500)
        #expect(light.state.isOn)
        #expect(light.state.brightness == 0.4)
        #expect(light.state.colorMode == .colorTemp)
        #expect(light.state.kelvin == 3000)

        device.logic.clearLog()
        try await provider.send(LightCommand(on: true, brightness: 0.8, color: .rgb(RGB(r: 255, g: 0, b: 64))), to: light.id)
        let applied = await eventually { device.logic.current.brightness == 80 && device.logic.current.color == GoveeRGB(r: 255, g: 0, b: 64) }
        #expect(applied)
        #expect(device.logic.received == [.turn(true), .brightness(80), .color(RGB(r: 255, g: 0, b: 64))])
        let optimistic = await recorder.states(for: light.id).last
        #expect(optimistic?.rgb == RGB(r: 255, g: 0, b: 64))

        try await provider.send(.turnOff, to: light.id)
        #expect(await eventually { device.logic.current.onOff == 0 })
        await provider.stop()
    }

    @Test func pollingPicksUpExternalChanges() async throws {
        let device = try FakeGoveeUDPDevice(device: lampID, sku: "H618A")
        defer { device.stop() }
        var config = fastConfiguration()
        config.scanPort = device.scanPort
        config.controlPort = device.controlPort
        let paired = PairedDevice(id: lampID, brand: .govee, name: "Strip", model: "H618A", hostHint: "127.0.0.1", metadata: ["sku": "H618A"])
        let provider = GoveeProvider(configuration: config, lanTransport: POSIXGoveeLANTransport(), secrets: InMemorySecretStore(),
                                     pairedDevices: [paired])
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        let lights = try await provider.loadLights()
        #expect(lights.first?.state.reachable == true)
        await provider.start()
        device.logic.set { $0.onOff = 1; $0.color = GoveeRGB(r: 0, g: 255, b: 0); $0.kelvin = 0 }
        let id = LightID("govee:\(lampID)")!
        let seen = await eventually { await recorder.states(for: id).contains { $0.isOn && $0.rgb == RGB(r: 0, g: 255, b: 0) } }
        #expect(seen)
        await provider.stop()
    }
}

#if canImport(Darwin)
@Suite("NetKit LAN transport (Apple)", .serialized)
struct NetKitTransportTests {
    @Test func netKitTransportTalksToFakeDevice() async throws {
        let device = try FakeGoveeUDPDevice(device: lampID, sku: "H6076")
        defer { device.stop() }
        var config = fastConfiguration()
        config.scanPort = device.scanPort
        config.controlPort = device.controlPort
        let transport = NetKitGoveeLANTransport(listenPort: 0, interfaceName: "lo0")
        let provider = GoveeProvider(configuration: config, lanTransport: transport, secrets: InMemorySecretStore())
        let found = await collect(provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(700), methods: [.manual], manualHosts: ["127.0.0.1"])))
        #expect(found.map(\.id) == [lampID])
        _ = try await provider.pair(try #require(found.first), using: ScriptedPairingInteraction([]))
        try await provider.send(.turnOn, to: LightID("govee:\(lampID)")!)
        #expect(await eventually { device.logic.current.onOff == 1 })
        await provider.stop()
    }
}
#endif

@Suite("GoveeProvider LAN logic (in-memory network)")
struct GoveeProviderLANTests {

    private func network() -> (FakeLANNetwork, FakeGoveeDeviceLogic, FakeGoveeDeviceLogic) {
        let lamp = FakeGoveeDeviceLogic(device: lampID, sku: "H6076", ip: "10.0.0.20")
        let strip = FakeGoveeDeviceLogic(device: stripID, sku: "H619A", ip: "10.0.0.21")
        return (FakeLANNetwork([lamp, strip]), lamp, strip)
    }

    @Test func multicastDiscoveryFindsAllDevices() async throws {
        let (net, _, _) = network()
        let provider = GoveeProvider(configuration: fastConfiguration(), lanTransport: net, secrets: InMemorySecretStore())
        let found = await collect(provider.discover(options: DiscoveryOptions(timeout: .milliseconds(300), methods: [.broadcast], broadcastAvailable: true)))
        #expect(Set(found.map(\.id)) == [lampID, stripID])
        #expect(found.allSatisfy { $0.method == .broadcast })
        #expect(net.sent.first == .init(host: "239.255.255.250", port: 4001, command: .scan))
    }

    @Test func withoutEntitlementSweepsUnicast() async throws {
        let (net, _, _) = network()
        var config = fastConfiguration()
        config.sweepHosts = { (1...30).map { "10.0.0.\($0)" } }
        let provider = GoveeProvider(configuration: config, lanTransport: net, secrets: InMemorySecretStore())
        let found = await collect(provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(400), methods: [.broadcast, .sweep, .cached], broadcastAvailable: false, cachedHosts: ["10.0.0.21"])))
        #expect(Set(found.map(\.id)) == [lampID, stripID])
        #expect(found.first { $0.id == stripID }?.method == .cached)
        #expect(found.first { $0.id == lampID }?.method == .sweep)
        #expect(!net.sent.contains { $0.host == GoveeLAN.multicastAddress })
        #expect(net.sent.filter { $0.command == .scan }.count == 30) // cached host not swept twice
    }

    @Test func multicastFailureIsReportedNotFatal() async throws {
        let (net, _, _) = network()
        net.multicastDenied.withLock { $0 = true }
        let provider = GoveeProvider(configuration: fastConfiguration(), lanTransport: net, secrets: InMemorySecretStore())
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        let found = await collect(provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(300), methods: [.broadcast, .manual], broadcastAvailable: true, manualHosts: ["10.0.0.20"])))
        #expect(found.map(\.id) == [lampID])
        #expect(await eventually { await recorder.contains { if case .error(let m) = $0 { m.contains("multicast") } else { false } } })
    }

    @Test func groupFanOutAndPartialFailure() async throws {
        let (net, lamp, strip) = network()
        let paired = [
            PairedDevice(id: lampID, brand: .govee, name: "Lamp", model: "H6076", hostHint: "10.0.0.20", metadata: ["sku": "H6076"]),
            PairedDevice(id: stripID, brand: .govee, name: "Strip", model: "H619A", hostHint: "10.0.0.21", metadata: ["sku": "H619A"]),
        ]
        let provider = GoveeProvider(configuration: fastConfiguration(), lanTransport: net, secrets: InMemorySecretStore(), pairedDevices: paired)
        let lights = try await provider.loadLights()
        #expect(lights.count == 2)
        try await provider.sendGroup(LightCommand(on: true, color: .kelvin(4000)), to: lights.map(\.id))
        #expect(lamp.current.onOff == 1 && lamp.current.kelvin == 4000)
        #expect(strip.current.onOff == 1 && strip.current.kelvin == 4000)

        let missing = LightID("govee:00:00:00:00:00:00:00:00")!
        await #expect(throws: LightCoreError.self) {
            try await provider.sendGroup(.turnOff, to: lights.map(\.id) + [missing])
        }
        #expect(lamp.current.onOff == 0 && strip.current.onOff == 0)
    }

    @Test func silentLANDeviceBecomesUnreachable() async throws {
        let (net, lamp, _) = network()
        var config = fastConfiguration()
        config.lanStaleAfter = .milliseconds(200)
        let paired = PairedDevice(id: lampID, brand: .govee, name: "Lamp", model: "H6076", hostHint: "10.0.0.20", metadata: ["sku": "H6076"])
        let provider = GoveeProvider(configuration: config, lanTransport: net, secrets: InMemorySecretStore(), pairedDevices: [paired])
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        #expect(try await provider.loadLights().first?.state.reachable == true)
        lamp.online.withLock { $0 = false }
        await provider.start()
        let id = LightID("govee:\(lampID)")!
        #expect(await eventually { await recorder.contains { $0 == .reachabilityChanged(id, reachable: false) } })
        lamp.online.withLock { $0 = true }
        #expect(await eventually { await recorder.contains { $0 == .reachabilityChanged(id, reachable: true) } })
        await provider.stop()
        // No API key: an unreachable-but-paired LAN device still gets UDP (fire and forget).
        try await provider.send(.turnOn, to: id)
    }
}

@Suite("GoveeProvider cloud (fake Developer API)", .serialized)
struct GoveeProviderCloudTests {

    private func make(cloudDevices: [GoveeCloudDevice], lan: FakeLANNetwork? = nil, config: GoveeProvider.Configuration = fastConfiguration(),
                      secrets: InMemorySecretStore = InMemorySecretStore()) throws -> (GoveeProvider, FakeGoveeCloud) {
        let cloud = try FakeGoveeCloud(devices: cloudDevices)
        let provider = GoveeProvider(configuration: config, lanTransport: lan,
                                     httpTransport: URLSessionGoveeHTTPTransport(baseURL: cloud.baseURL), secrets: secrets)
        return (provider, cloud)
    }

    @Test func pairAccountStoresKeyAndAddsCloudLights() async throws {
        let secrets = InMemorySecretStore()
        let (provider, cloud) = try make(cloudDevices: [
            FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp", scenes: ["Sunrise": 3_853_288]),
            FakeGoveeCloud.humidifier,
        ], secrets: secrets)
        defer { cloud.stop() }
        let ui = ScriptedPairingInteraction([.text("  test-api-key \n")])
        let paired = try await provider.pair(GoveeProvider.cloudAccountDevice, using: ui)
        #expect(await ui.prompts.first == GoveeProvider.apiKeyPrompt)
        #expect(paired.id == GoveeProvider.accountID)
        #expect(paired.lightIDs == [LightID("govee:\(cloudOnlyID)")!])
        #expect(try await secrets.string(for: GoveeProvider.apiKeySecret) == "test-api-key")
        let account = try #require(await provider.account)
        #expect(account.secretKeys == [GoveeProvider.apiKeySecret])
        #expect(!account.displayName.contains("test-api-key"))
        #expect(cloud.requests.first?.apiKey == "test-api-key")

        let lights = try await provider.loadLights()
        #expect(lights.map(\.name) == ["Desk lamp"])
        let lamp = try #require(lights.first)
        #expect(lamp.providerRef == "cloud:H6601")
        #expect(lamp.capabilities.effects.map(\.id) == ["snapshot/Sunrise"])
        #expect(lamp.state.reachable)

        cloud.clearLog()
        try await provider.send(LightCommand(on: true, brightness: 0.25, color: .rgb(RGB(r: 255, g: 128, b: 0))), to: lamp.id)
        let caps = cloud.controlRequests.compactMap { $0["payload"]?["capability"] }
        #expect(caps.map { $0["instance"]?.stringValue } == ["powerSwitch", "brightness", "colorRgb"])
        #expect(caps.map { $0["value"]?.intValue } == [1, 25, 0xFF8000])
        #expect(cloud.controlRequests.first?["payload"]?["sku"] == .string("H6601"))
        #expect(cloud.state(cloudOnlyID) == .init(power: 1, brightness: 25, rgb: 0xFF8000, kelvin: 0))

        cloud.clearLog()
        try await provider.send(LightCommand(effect: "snapshot/Sunrise"), to: lamp.id)
        #expect(cloud.controlRequests.first?["payload"]?["capability"]?["value"] == .int(3_853_288))
        #expect(await provider.cloudRequestsRemaining() < 10_000)
    }

    @Test func wrongKeyIsRejectedAndNotStored() async throws {
        let secrets = InMemorySecretStore()
        let (provider, cloud) = try make(cloudDevices: [FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp")], secrets: secrets)
        defer { cloud.stop() }
        await #expect(throws: LightCoreError.authenticationRequired(.govee)) {
            try await provider.pair(GoveeProvider.cloudAccountDevice, using: ScriptedPairingInteraction([.text("nope")]))
        }
        #expect(await secrets.count == 0)
        #expect(await provider.account == nil)
        await #expect(throws: LightCoreError.userCancelled) {
            try await provider.pair(GoveeProvider.cloudAccountDevice, using: ScriptedPairingInteraction([.cancel]))
        }
    }

    @Test func lanPreferredCloudFallbackAndMergeFlags() async throws {
        let lamp = FakeGoveeDeviceLogic(device: lampID, sku: "H6076", ip: "10.0.0.20")
        let net = FakeLANNetwork([lamp])
        var config = fastConfiguration()
        config.lanStaleAfter = .milliseconds(300)
        let secrets = InMemorySecretStore([GoveeProvider.apiKeySecret: Data("test-api-key".utf8)])
        let (provider, cloud) = try make(cloudDevices: [
            FakeGoveeCloud.light(lampID, sku: "H6076", name: "Floor lamp"),
            FakeGoveeCloud.light(cloudOnlyID, sku: "H6001", name: "Bulb"),
        ], lan: net, config: config, secrets: secrets)
        defer { cloud.stop() }

        // Discovery merges LAN (multicast) and cloud results, flagging capabilities.
        let found = await collect(provider.discover(options: DiscoveryOptions(timeout: .milliseconds(500), methods: [.broadcast, .cloud], broadcastAvailable: true)))
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        #expect(byID[lampID]?.metadata["cloud"] == "true")
        #expect(byID[lampID]?.host == "10.0.0.20")
        #expect(byID[cloudOnlyID]?.metadata["lan"] == "unsupported") // H6001 is not on the LAN allow-list
        #expect(byID[cloudOnlyID]?.method == .cloud)

        // A cloud-only device pairs without asking again (key already stored).
        let ui = ScriptedPairingInteraction([])
        let pairedBulb = try await provider.pair(try #require(byID[cloudOnlyID]), using: ui)
        #expect(pairedBulb.accountID == GoveeProvider.accountID)
        #expect(await ui.prompts.isEmpty)

        let lights = try await provider.loadLights()
        #expect(Set(lights.map(\.name)) == ["Floor lamp", "Bulb"])
        let lampLight = try #require(lights.first { $0.name == "Floor lamp" })
        #expect(lampLight.providerRef == "lan:10.0.0.20")
        #expect(lampLight.capabilities.kelvinRange == 2700...6500) // LAN clamp applied to cloud range

        // Fresh LAN: no cloud control requests.
        cloud.clearLog()
        try await provider.send(.turnOn, to: lampLight.id)
        #expect(net.sent(to: "10.0.0.20").contains(.turn(true)))
        #expect(cloud.controlRequests.isEmpty)

        // LAN goes silent and stale: commands fall back to the cloud.
        lamp.online.withLock { $0 = false }
        try await Task.sleep(for: .milliseconds(400))
        net.clearLog()
        try await provider.send(LightCommand(color: .kelvin(5000)), to: lampLight.id)
        #expect(net.sent(to: "10.0.0.20").isEmpty)
        #expect(cloud.controlRequests.compactMap { $0["payload"]?["capability"]?["value"]?.intValue } == [5000])
        #expect(await provider.cloudPollInterval() == .seconds(60))
    }

    @Test func cloudErrorsMapToLightCoreErrors() async throws {
        let secrets = InMemorySecretStore([GoveeProvider.apiKeySecret: Data("test-api-key".utf8)])
        let (provider, cloud) = try make(cloudDevices: [FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp")], secrets: secrets)
        defer { cloud.stop() }
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        let id = try #require(try await provider.loadLights().first?.id)

        cloud.forcedStatuses.withLock { $0 = [429] }
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOn, to: id) }

        cloud.forcedStatuses.withLock { $0 = [401] }
        await #expect(throws: LightCoreError.authenticationRequired(.govee)) { try await provider.send(.turnOn, to: id) }
        #expect(await eventually { await recorder.contains { $0 == .needsReauthentication(accountID: GoveeProvider.accountID) } })

        try await provider.send(.turnOn, to: id)
        #expect(cloud.state(cloudOnlyID)?.power == 1)
    }

    @Test func dailyBudgetStopsPollingBeforeCommands() async throws {
        var config = fastConfiguration()
        config.budget = GoveeCloudBudget(dailyLimit: 6, reserveFraction: 0.5, minimumPollInterval: .seconds(1))
        let secrets = InMemorySecretStore([GoveeProvider.apiKeySecret: Data("test-api-key".utf8)])
        let (provider, cloud) = try make(cloudDevices: [FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp")],
                                         config: config, secrets: secrets)
        defer { cloud.stop() }
        let id = try #require(try await provider.loadLights().first?.id) // devices + state = 2 requests
        #expect(await provider.cloudRequestsRemaining() == 4)
        try await provider.send(.turnOn, to: id)
        try await provider.send(.turnOff, to: id)
        try await provider.send(.turnOn, to: id)
        try await provider.send(.turnOff, to: id)
        #expect(await provider.cloudRequestsRemaining() == 0)
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOn, to: id) }
        #expect(cloud.controlRequests.count == 4)
    }

    @Test func cloudPollingEmitsStateChanges() async throws {
        var config = fastConfiguration()
        config.budget = GoveeCloudBudget(dailyLimit: 10_000, minimumPollInterval: .seconds(1))
        config.cloudStateDeviceLimit = .init(capacity: 100, refillPerSecond: 100)
        let secrets = InMemorySecretStore([GoveeProvider.apiKeySecret: Data("test-api-key".utf8)])
        let (provider, cloud) = try make(cloudDevices: [FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp")],
                                         config: config, secrets: secrets)
        defer { cloud.stop() }
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        let id = try #require(try await provider.loadLights().first?.id)
        cloud.states.withLock { $0[cloudOnlyID]?.power = 1; $0[cloudOnlyID]?.kelvin = 2700 }
        await provider.start()
        let seen = await eventually(timeout: .seconds(4)) {
            await recorder.states(for: id).contains { $0.isOn && $0.kelvin == 2700 }
        }
        #expect(seen)
        await provider.stop()
    }

    @Test func removeAPIKeyDropsCloudLights() async throws {
        let secrets = InMemorySecretStore([GoveeProvider.apiKeySecret: Data("test-api-key".utf8)])
        let (provider, cloud) = try make(cloudDevices: [FakeGoveeCloud.light(cloudOnlyID, sku: "H6601", name: "Desk lamp")], secrets: secrets)
        defer { cloud.stop() }
        #expect(try await provider.loadLights().count == 1)
        try await provider.removeAPIKey()
        #expect(try await provider.loadLights().isEmpty)
        #expect(await secrets.count == 0)
    }
}
