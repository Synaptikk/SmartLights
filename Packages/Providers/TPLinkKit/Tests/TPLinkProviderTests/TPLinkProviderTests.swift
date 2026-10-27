import Foundation
import LightCore
import NetKit
import Testing
import TPLinkCodec
@testable import TPLinkProvider

// MARK: - Helpers

private func makeProvider(
    legacyPort: UInt16,
    klapPort: UInt16,
    datagrams: FakeDatagramNetwork? = nil,
    sweep: [IPv4Addr] = [],
    secrets: InMemorySecretStore = InMemorySecretStore()
) -> TPLinkProvider {
    let env = TPLinkNetworkEnvironment(
        datagrams: datagrams,
        broadcastAddresses: { ["255.255.255.255"] },
        sweepHosts: { sweep }
    )
    let config = TPLinkProvider.Configuration(
        requestTimeout: .seconds(3),
        probeTimeout: .milliseconds(500),
        pollInterval: .milliseconds(200),
        legacyPort: legacyPort,
        klapPort: klapPort,
        keyedDiscoveryProbe: false
    )
    return TPLinkProvider(configuration: config, environment: env, secretStore: secrets)
}

private func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

private func discoverManual(_ provider: TPLinkProvider, host: String = "127.0.0.1") async -> [DiscoveredDevice] {
    await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(5), methods: [.manual], manualHosts: [host])))
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

// MARK: - Legacy Kasa (XOR over TCP)

@Suite("TPLinkProvider against a fake Kasa bulb (XOR/TCP)", .serialized)
struct TPLinkKasaProviderTests {
    @Test func manualDiscoveryPairLoadAndSend() async throws {
        let bulb = try FakeKasaBulb()
        defer { bulb.stop() }
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort())
        let events = EventLog()
        await events.start(provider.events)

        let found = await discoverManual(provider)
        let device = try #require(found.first)
        #expect(device.id == bulb.stableID)
        #expect(device.name == "Desk lamp")
        #expect(device.model == "KL130(US)")
        #expect(device.metadata["connection"] == "xor:\(bulb.port)")
        #expect(device.metadata["needsCredentials"] == "false")

        let ui = ScriptedPairingInteraction([])
        let paired = try await provider.pair(device, using: ui)
        #expect(await ui.prompts.isEmpty) // no credentials for legacy Kasa
        #expect(paired.id == "1c3bf3112233")
        #expect(paired.lightIDs == [LightID("tplink:1c3bf3112233")!])
        #expect(paired.metadata["connection"] == "xor:\(bulb.port)")

        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(light.capabilities.supportsTransition)
        #expect(light.state.isOn)
        #expect(light.state.kelvin == 2700)
        #expect(light.state.brightness == 0.5)

        try await provider.send(LightCommand(brightness: 0.42, color: .hs(HS(h: 120, s: 0.75)), transition: .milliseconds(500)), to: light.id)
        let args = try #require(bulb.requests.last?[TPLinkIOT.bulbService]?[TPLinkIOT.bulbSetCommand])
        #expect(args == ["brightness": 42, "hue": 120, "saturation": 75, "color_temp": 0, "transition_period": 500, "on_off": 1, "ignore_default": 1])
        #expect(bulb.state == FakeLightState(on: true, brightness: 42, hue: 120, saturation: 75, colorTemp: 0))
        #expect(await events.waitFor { if case .stateChanged(let id, let s) = $0 { return id == light.id && s.hs == HS(h: 120, s: 0.75) }; return false })

        try await provider.send(.turnOff, to: light.id)
        #expect(bulb.state.on == false)
        let off = try #require(try await provider.loadLights().first)
        #expect(!off.state.isOn)
        #expect(off.state.brightness == 0.42) // dft_on_state
    }

    @Test func stripUsesSetLightState() async throws {
        let strip = try FakeKasaBulb(model: "KL430(US)", mac: "E8:48:B8:00:11:22", alias: "Shelf", strip: true)
        defer { strip.stop() }
        let provider = makeProvider(legacyPort: strip.port, klapPort: try LoopbackServer.closedPort())
        let device = try #require(await discoverManual(provider).first)
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(paired.metadata["strip"] == "true")
        let id = try #require(paired.lightIDs.first)
        try await provider.send(LightCommand(color: .kelvin(4000)), to: id)
        let args = try #require(strip.requests.last?[TPLinkIOT.stripService]?[TPLinkIOT.stripSetCommand])
        #expect(args["color_temp"] == 4000)
        #expect(strip.state.colorTemp == 4000)
    }

    @Test func broadcastDiscoveryUsesUDP9999() async throws {
        let bulb = try FakeKasaBulb()
        defer { bulb.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { bulb.discoveryAnswer($0) }
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort(), datagrams: net)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast], broadcastAvailable: true)))
        #expect(net.broadcasts == 1)
        let device = try #require(found.first)
        #expect(device.method == .broadcast)
        #expect(device.id == bulb.stableID)
        #expect(device.host == "127.0.0.1")
        // The legacy connection uses the configured TCP port.
        #expect(device.metadata["connection"] == "xor:\(bulb.port)")
        _ = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(try await provider.loadLights().count == 1)
    }

    @Test func pollingReportsExternalChanges() async throws {
        let bulb = try FakeKasaBulb()
        defer { bulb.stop() }
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort())
        let events = EventLog()
        await events.start(provider.events)
        let device = try #require(await discoverManual(provider).first)
        let id = try #require(try await provider.pair(device, using: ScriptedPairingInteraction([])).lightIDs.first)
        _ = try await provider.loadLights()
        await provider.start()
        defer { Task { await provider.stop() } }
        bulb.state.brightness = 10
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { return lid == id && s.brightness == 0.1 }; return false })
        bulb.alias = "Renamed"
        #expect(await events.waitFor { if case .lightUpdated(let l) = $0 { return l.name == "Renamed" }; return false })
    }

    @Test func unreachableWhenTheBulbIsGone() async throws {
        let bulb = try FakeKasaBulb()
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort())
        let events = EventLog()
        await events.start(provider.events)
        let device = try #require(await discoverManual(provider).first)
        let id = try #require(try await provider.pair(device, using: ScriptedPairingInteraction([])).lightIDs.first)
        bulb.stop()
        try? await Task.sleep(for: .milliseconds(100))
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOn, to: id) }
        #expect(await events.waitFor { $0 == .reachabilityChanged(id, reachable: false) })
        let light = try #require(try await provider.loadLights().first)
        #expect(!light.state.reachable)
    }

    @Test func groupSendReportsPartialFailure() async throws {
        let bulb = try FakeKasaBulb()
        defer { bulb.stop() }
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort())
        let device = try #require(await discoverManual(provider).first)
        let id = try #require(try await provider.pair(device, using: ScriptedPairingInteraction([])).lightIDs.first)
        let missing = LightID("tplink:ffffffffffff")!
        do {
            try await provider.sendGroup(.turnOff, to: [id, missing])
            Issue.record("expected partial failure")
        } catch LightCoreError.partialFailure(let failures) {
            #expect(failures.keys.sorted() == [missing])
        }
        #expect(bulb.state.on == false)
    }

    @Test func restoreUsesStoredDevice() async throws {
        let bulb = try FakeKasaBulb()
        defer { bulb.stop() }
        let provider = makeProvider(legacyPort: bulb.port, klapPort: try LoopbackServer.closedPort())
        await provider.restore([PairedDevice(id: bulb.stableID, brand: .tplink, name: "Stored", model: "KL130(US)", hostHint: "127.0.0.1",
                                             lightIDs: [LightID("tplink:\(bulb.stableID)")!], metadata: ["connection": "xor:9999"])])
        let light = try #require(try await provider.loadLights().first)
        #expect(light.name == "Desk lamp")
        #expect(light.state.reachable)
        #expect(await provider.endpoint(of: light.id) == "127.0.0.1:\(bulb.port)")
    }
}

// MARK: - Tapo (SMART over KLAP/HTTP)

@Suite("TPLinkProvider against a fake Tapo bulb (KLAP/HTTP)", .serialized)
struct TPLinkTapoProviderTests {
    private func discoverTapo(_ provider: TPLinkProvider) async throws -> DiscoveredDevice {
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast], broadcastAvailable: true)))
        return try #require(found.first)
    }

    @Test func pairAsksForCaseSensitiveCredentialsAndStoresThem() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let secrets = InMemorySecretStore()
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net, secrets: secrets)

        let device = try await discoverTapo(provider)
        #expect(device.id == tapo.stableID)
        #expect(device.metadata["connection"] == "klap2-smart:\(tapo.port)")
        #expect(device.metadata["needsCredentials"] == "true")
        #expect(device.macAddress == "5C:E9:31:12:34:56")

        let ui = ScriptedPairingInteraction([.text(tapo.username), .text(tapo.password)])
        let paired = try await provider.pair(device, using: ui)
        let prompts = await ui.prompts
        #expect(prompts.contains { $0.contains("case-sensitive") && $0.contains("email") })
        #expect(paired.id == "5ce931123456")
        #expect(paired.name == "Living room")
        #expect(paired.accountID == TPLinkProvider.accountID)
        #expect(try await secrets.string(for: TPLinkProvider.usernameKey) == "Jane.Doe@Example.com")
        #expect(try await secrets.string(for: TPLinkProvider.passwordKey) == "S3cret!")
        let account = try #require(await provider.account)
        #expect(account.displayName == "J***@Example.com")
        #expect(!account.displayName.contains("S3cret"))
        #expect(tapo.handshake2Count >= 1)

        let light = try #require(try await provider.loadLights().first)
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(light.capabilities.minKelvin == 2500 && light.capabilities.maxKelvin == 6500)
        #expect(!light.capabilities.supportsTransition)
        #expect(!light.state.isOn)
        #expect(light.state.kelvin == 2700)
    }

    @Test func wrongCaseEmailIsRejectedThenRetried() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net)
        let device = try await discoverTapo(provider)
        let ui = ScriptedPairingInteraction([
            .text(tapo.username.lowercased()), .text(tapo.password), // wrong case
            .confirm(true),
            .text(tapo.username), .text(tapo.password),
        ])
        let paired = try await provider.pair(device, using: ui)
        #expect(paired.id == tapo.stableID)
        #expect(await ui.prompts.contains { $0.contains("Third-Party Compatibility") })
        #expect(tapo.handshake1Count >= 3) // blank attempt, wrong case, correct
    }

    @Test func givingUpAfterRejectionNeedsAuthentication() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let secrets = InMemorySecretStore()
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net, secrets: secrets)
        let device = try await discoverTapo(provider)
        let ui = ScriptedPairingInteraction([.text("someone@example.com"), .text("wrong"), .confirm(false)])
        await #expect(throws: LightCoreError.authenticationRequired(.tplink)) { try await provider.pair(device, using: ui) }
        #expect(try await secrets.string(for: TPLinkProvider.usernameKey) == nil)
        #expect(await provider.account == nil)
    }

    @Test func sendUsesSetDeviceInfo() async throws {
        let (tapo, provider, id) = try await pairedTapo()
        defer { tapo.stop() }
        let events = EventLog()
        await events.start(provider.events)
        try await provider.send(LightCommand(brightness: 0.3, color: .hs(HS(h: 200, s: 0.5))), to: id)
        #expect(tapo.setParams.last == ["device_on": true, "brightness": 30, "hue": 200, "saturation": 50, "color_temp": 0])
        #expect(tapo.state == FakeLightState(on: true, brightness: 30, hue: 200, saturation: 50, colorTemp: 0))
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { return lid == id && s.isOn && s.colorMode == .hs }; return false })

        try await provider.send(LightCommand(color: .kelvin(10_000)), to: id)
        #expect(tapo.setParams.last == ["color_temp": 6500])
        try await provider.send(LightCommand(brightness: 0), to: id)
        #expect(tapo.setParams.last == ["device_on": false])
    }

    @Test func rehandshakesAfterHTTP403() async throws {
        let (tapo, provider, id) = try await pairedTapo()
        defer { tapo.stop() }
        let before = tapo.handshake2Count
        tapo.dropSessions()
        try await provider.send(.turnOn, to: id)
        #expect(tapo.handshake2Count == before + 1)
        #expect(tapo.state.on)
    }

    @Test func rehandshakesAfterSessionTimeoutErrorCode() async throws {
        let (tapo, provider, id) = try await pairedTapo()
        defer { tapo.stop() }
        let before = tapo.handshake2Count
        tapo.failNext(errorCode: 9999)
        try await provider.send(.turnOn, to: id)
        #expect(tapo.handshake2Count == before + 1)
        #expect(tapo.methods.suffix(2) == ["set_device_info", "set_device_info"])
        #expect(tapo.state.on)
    }

    @Test func authenticationErrorCodeAsksForReauthentication() async throws {
        let (tapo, provider, id) = try await pairedTapo()
        defer { tapo.stop() }
        let events = EventLog()
        await events.start(provider.events)
        tapo.failNext(errorCode: -1501)
        await #expect(throws: LightCoreError.authenticationRequired(.tplink)) { try await provider.send(.turnOn, to: id) }
        #expect(await events.waitFor { $0 == .needsReauthentication(accountID: TPLinkProvider.accountID) })
    }

    @Test func pollingSeesChangesMadeInTheTapoApp() async throws {
        let (tapo, provider, id) = try await pairedTapo()
        defer { tapo.stop() }
        let events = EventLog()
        await events.start(provider.events)
        _ = try await provider.loadLights()
        await provider.start()
        defer { Task { await provider.stop() } }
        tapo.state.on = true
        tapo.state.colorTemp = 0
        tapo.state.hue = 30
        #expect(await events.waitFor { if case .stateChanged(let lid, let s) = $0 { return lid == id && s.isOn && s.hs?.h == 30 }; return false })
    }

    @Test func addByIPWithoutUDP() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        // No datagram transport (Linux, or broadcast denied and no sweep): TCP 9999 is refused,
        // then the KLAP handshake1 probe identifies a TP-Link device.
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port)
        let device = try #require(await discoverManual(provider).first)
        #expect(device.id == "ip:127.0.0.1")
        #expect(device.metadata["connection"] == "klap2-smart:\(tapo.port)")
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([.text(tapo.username), .text(tapo.password)]))
        #expect(paired.id == tapo.stableID)
    }

    @Test func storedCredentialsAreUsedWithoutPrompting() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let secrets = InMemorySecretStore()
        try await secrets.set(tapo.username, for: TPLinkProvider.usernameKey)
        try await secrets.set(tapo.password, for: TPLinkProvider.passwordKey)
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net, secrets: secrets)
        let device = try await discoverTapo(provider)
        let ui = ScriptedPairingInteraction([])
        _ = try await provider.pair(device, using: ui)
        #expect(await ui.prompts.allSatisfy { !$0.contains("email") })
    }

    @Test func sweepFindsDevicesWithoutBroadcast() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net,
                                    sweep: [IPv4Addr(127, 0, 0, 1), IPv4Addr(127, 0, 0, 2)])
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast, .sweep], broadcastAvailable: false)))
        #expect(net.broadcasts == 0)
        #expect(Set(net.probedHosts) == ["127.0.0.1", "127.0.0.2"])
        #expect(found.map(\.id) == [tapo.stableID])
        #expect(found.first?.method == .sweep)
    }

    @Test func aesFirmwareIsRefusedWithAnExplanation() async throws {
        let tapo = try FakeTapoBulb()
        defer { tapo.stop() }
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0, encryptType: "AES") }
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net)
        let device = try await discoverTapo(provider)
        #expect(device.metadata["unsupported"]?.contains("AES") == true)
        do {
            _ = try await provider.pair(device, using: ScriptedPairingInteraction([]))
            Issue.record("expected unsupported")
        } catch LightCoreError.unsupported(let why) {
            #expect(why.contains("firmware"))
        }
    }

    /// A paired fake Tapo bulb.
    private func pairedTapo() async throws -> (FakeTapoBulb, TPLinkProvider, LightID) {
        let tapo = try FakeTapoBulb()
        let net = FakeDatagramNetwork()
        net.add(host: "127.0.0.1") { tapo.discoveryAnswer($0) }
        let provider = makeProvider(legacyPort: try LoopbackServer.closedPort(), klapPort: tapo.port, datagrams: net)
        let device = try await discoverTapo(provider)
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([.text(tapo.username), .text(tapo.password)]))
        return (tapo, provider, try #require(paired.lightIDs.first))
    }
}

@Suite("Provider helpers")
struct TPLinkProviderHelperTests {
    @Test func maskedEmail() {
        #expect(TPLinkProvider.maskedEmail("jane.doe@example.com") == "j***@example.com")
        #expect(TPLinkProvider.maskedEmail("nobody") == "TP-Link account")
    }

    @Test func parseHost() {
        #expect(TPLinkProvider.parseHost(" 192.168.1.20 ") == "192.168.1.20")
        #expect(TPLinkProvider.parseHost("192.168.1.20:9999") == "192.168.1.20")
        #expect(TPLinkProvider.parseHost("bulb.local") == nil)
        #expect(TPLinkProvider.parseHost("") == nil)
    }
}
