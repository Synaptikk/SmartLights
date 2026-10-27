import Foundation
import HomeAssistantCodec
import LightCore
import NetKit
import Testing

@testable import HomeAssistantKit

/// Collects provider events for assertions.
actor EventRecorder {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ProviderEvent>) {
        task = nil
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: ProviderEvent) { events.append(event) }

    /// Waits until an event matching `predicate` arrives (or fails after `timeout`).
    @discardableResult
    func waitFor(
        _ description: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
        _ predicate: (ProviderEvent) -> Bool
    ) async -> ProviderEvent? {
        let deadline = ContinuousClock.now + timeout
        var checked = 0
        while ContinuousClock.now < deadline {
            while checked < events.count {
                if predicate(events[checked]) { return events[checked] }
                checked += 1
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
        return nil
    }

    func clear() { events.removeAll() }
}

/// Polls an async condition.
func eventually(
    _ description: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
}

@Suite("HomeAssistantProvider (fake HA server)")
struct HomeAssistantProviderTests {
    static let instanceID = "4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a99"

    static func config(_ tweak: (inout HomeAssistantProvider.Configuration) -> Void = { _ in }) -> HomeAssistantProvider.Configuration {
        var c = HomeAssistantProvider.Configuration()
        c.connectTimeout = .seconds(2)
        c.commandTimeout = .seconds(2)
        c.pingInterval = .seconds(3600)
        c.reconnectBackoff = ExponentialBackoff(initial: .milliseconds(10), multiplier: 2, maximum: .milliseconds(50))
        c.resyncDelay = .milliseconds(10)
        tweak(&c)
        return c
    }

    static func paired(externalURL: String? = nil, _ tweak: (inout HomeAssistantProvider.Configuration) -> Void = { _ in })
        async throws -> (HomeAssistantProvider, FakeHomeAssistant, InMemorySecretStore, EventRecorder)
    {
        let server = FakeHomeAssistant()
        let secrets = InMemorySecretStore()
        try await secrets.set("good-token", for: HomeAssistantProvider.tokenSecret(instanceID: instanceID))
        let provider = HomeAssistantProvider(secrets: secrets, transport: FakeHATransport(server: server), configuration: config(tweak))
        var metadata = ["url": "http://ha.test:8123"]
        if let externalURL { metadata["external_url"] = externalURL }
        await provider.addInstance(PairedDevice(id: instanceID, brand: .homeAssistant, name: "Home", hostHint: "http://ha.test:8123", metadata: metadata))
        return (provider, server, secrets, EventRecorder(provider.events))
    }

    static func lightID(_ key: String) -> LightID { HAIdentifiers.lightID(instanceID: instanceID, key: key)! }

    // MARK: Pairing

    @Test func pairStoresTokenAndReturnsInstance() async throws {
        let server = FakeHomeAssistant()
        let secrets = InMemorySecretStore()
        let provider = HomeAssistantProvider(secrets: secrets, transport: FakeHATransport(server: server), configuration: Self.config { $0.autoConnectEvents = false })
        let ui = ScriptedPairingInteraction([.text("https://abc123.ui.nabu.casa"), .text("good-token")])
        let device = DiscoveredDevice(
            id: "uuid-1", brand: .homeAssistant, name: "Home Assistant", host: "http://ha.test:8123", method: .bonjour,
            metadata: ["url": "http://ha.test:8123", "uuid": "uuid-1"])

        let paired = try await provider.pair(device, using: ui)

        #expect(paired.id == "uuid-1")
        #expect(paired.brand == .homeAssistant)
        #expect(paired.name == "Home")  // get_config location_name
        #expect(paired.model == "Home Assistant 2026.10.1")
        #expect(paired.hostHint == "http://ha.test:8123")
        #expect(paired.metadata["external_url"] == "https://abc123.ui.nabu.casa")
        #expect(paired.lightIDs.count == 4)
        #expect(try await secrets.string(for: HomeAssistantProvider.tokenSecret(instanceID: "uuid-1")) == "good-token")
        let prompts = await ui.prompts
        #expect(prompts.contains(HomeAssistantProvider.remoteURLPrompt))
        #expect(prompts.contains(HomeAssistantProvider.tokenPrompt))
        #expect(prompts.allSatisfy { !$0.contains("good-token") })
        let account = try #require(await provider.account)
        #expect(account.id == "uuid-1")
        #expect(account.secretKeys == [HomeAssistantProvider.tokenSecret(instanceID: "uuid-1")])
        #expect(account.metadata["external_url"] == "https://abc123.ui.nabu.casa")
    }

    @Test func pairRetriesRejectedTokens() async throws {
        let server = FakeHomeAssistant()
        let secrets = InMemorySecretStore()
        let provider = HomeAssistantProvider(secrets: secrets, transport: FakeHATransport(server: server), configuration: Self.config { $0.autoConnectEvents = false })
        // No URL from discovery: asked for. Empty remote URL, a mistyped token, then the right one.
        let ui = ScriptedPairingInteraction([.text("ha.test"), .text(""), .text("bad-token"), .text(" good-token\n")])
        let device = DiscoveredDevice(id: "manual", brand: .homeAssistant, name: "", method: .manual)

        let paired = try await provider.pair(device, using: ui)

        #expect(paired.hostHint == "http://ha.test:8123")
        #expect(paired.metadata["external_url"] == nil)
        #expect(UUID(uuidString: paired.id) != nil)  // generated, not derived from the host
        #expect(await server.authAttempts == ["bad-token", "good-token"])
        #expect(try await secrets.string(for: HomeAssistantProvider.tokenSecret(instanceID: paired.id)) == "good-token")
        #expect(await ui.prompts.contains { $0.contains("rejected the token") })
    }

    @Test func pairGivesUpAfterThreeRejectedTokens() async throws {
        let server = FakeHomeAssistant()
        let secrets = InMemorySecretStore()
        let provider = HomeAssistantProvider(secrets: secrets, transport: FakeHATransport(server: server), configuration: Self.config())
        let ui = ScriptedPairingInteraction([.text(""), .text("a"), .text("b"), .text("c")])
        let device = DiscoveredDevice(id: "x", brand: .homeAssistant, name: "HA", host: "ha.test", method: .manual)
        await #expect(throws: LightCoreError.authenticationRequired(.homeAssistant)) {
            try await provider.pair(device, using: ui)
        }
        #expect(await secrets.count == 0)
        #expect(await provider.instanceIDs.isEmpty)
    }

    @Test func pairAsksForAnotherURLWhenUnreachable() async throws {
        let server = FakeHomeAssistant()
        let provider = HomeAssistantProvider(secrets: InMemorySecretStore(), transport: FakeHATransport(server: server), configuration: Self.config { $0.autoConnectEvents = false })
        let ui = ScriptedPairingInteraction([.confirm(true), .text("http://ha.test:8123"), .text(""), .text("good-token")])
        let device = DiscoveredDevice(id: "x", brand: .homeAssistant, name: "HA", host: "10.9.9.9", method: .manual)
        let paired = try await provider.pair(device, using: ui)
        #expect(paired.hostHint == "http://ha.test:8123")

        let cancel = ScriptedPairingInteraction([.confirm(false)])
        await #expect(throws: LightCoreError.self) { try await provider.pair(device, using: cancel) }
    }

    // MARK: Lights

    @Test func loadLightsMapsEntitiesRoomsAndIds() async throws {
        let (provider, _, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        let lights = try await provider.loadLights()
        #expect(lights.count == 4)
        let byName = Dictionary(uniqueKeysWithValues: lights.map { ($0.name, $0) })
        let ceiling = try #require(byName["Ceiling"])
        #expect(ceiling.id == Self.lightID("reg-ceiling"))
        #expect(ceiling.roomHint == "Living Room")  // via the device's area
        #expect(ceiling.manufacturer == "Signify Netherlands B.V.")
        #expect(ceiling.state.isOn)
        #expect(ceiling.state.kelvin == 2700)
        #expect(ceiling.capabilities.supportsTransition)
        #expect(byName["Kitchen"]?.roomHint == "Kitchen")
        #expect(byName["Kitchen"]?.state.isOn == false)
        #expect(byName["Porch"]?.id == Self.lightID("light.porch"))  // not in the registry
        #expect(byName["Strip"]?.capabilities.effects.map(\.id) == ["rainbow"])
    }

    @Test func registryFailureFallsBackToEntityIDs() async throws {
        let (provider, server, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        await server.setRegistryAvailable(false)  // e.g. a restricted user
        let lights = try await provider.loadLights()
        #expect(Set(lights.map(\.id.stableId)) == Set(["light.ceiling", "light.kitchen", "light.porch", "light.strip"].map { "\(Self.instanceID)/\($0)" }))
        #expect(lights.allSatisfy { $0.roomHint == nil })
    }

    @Test func sendBuildsOneCallService() async throws {
        let (provider, server, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        _ = try await provider.loadLights()
        try await provider.send(
            LightCommand(on: true, brightness: 0.5, color: .kelvin(3500), transition: .milliseconds(400)), to: Self.lightID("reg-kitchen"))
        let call = try #require(await server.serviceCalls().last)
        #expect(call["domain"] == "light")
        #expect(call["service"] == "turn_on")
        #expect(call["target"] == ["entity_id": "light.kitchen"])
        // (Numbers are compared by value: 50.0 goes over the wire as 50.)
        #expect(call["service_data"]?["brightness_pct"]?.doubleValue == 50)
        #expect(call["service_data"]?["color_temp_kelvin"]?.doubleValue == 3500)
        #expect(call["service_data"]?["transition"]?.doubleValue == 0.4)
        #expect(call["service_data"]?.objectValue?.count == 3)

        try await provider.send(.turnOff, to: Self.lightID("light.porch"))
        #expect(await server.serviceCalls().last?["service"] == "turn_off")

        await #expect(throws: LightCoreError.lightNotFound(Self.lightID("nope"))) {
            try await provider.send(.turnOn, to: Self.lightID("nope"))
        }
    }

    @Test func sendGroupBatchesIdenticalPayloads() async throws {
        let (provider, server, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        _ = try await provider.loadLights()
        try await provider.sendGroup(
            LightCommand(on: true, brightness: 0.8), to: [Self.lightID("reg-ceiling"), Self.lightID("reg-kitchen"), Self.lightID("light.porch")])
        let calls = await server.serviceCalls()
        // Ceiling + kitchen share {brightness_pct: 80}; the on/off porch gets a bare turn_on.
        #expect(calls.count == 2)
        #expect(calls[0]["target"] == ["entity_id": ["light.ceiling", "light.kitchen"]])
        #expect(calls[0]["service_data"]?.objectValue?.keys.sorted() == ["brightness_pct"])
        #expect(calls[0]["service_data"]?["brightness_pct"]?.doubleValue == 80)
        #expect(calls[1]["target"] == ["entity_id": "light.porch"])
        #expect(calls[1]["service_data"] == nil)
    }

    @Test func serviceErrorsSurfaceAsProtocolErrors() async throws {
        let (provider, _, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        await #expect(throws: LightCoreError.self) {
            try await provider.callService(HAServiceCall(domain: "light", service: "explode"), instanceID: Self.instanceID)
        }
    }

    @Test func scenesAndRecall() async throws {
        let (provider, server, _, _) = try await Self.paired { $0.autoConnectEvents = false }
        let scenes = try await provider.scenes()
        #expect(scenes.map(\.name) == ["Movie"])
        #expect(scenes.first?.roomHint == "Living Room")
        #expect(scenes.first?.lightIDs == [Self.lightID("reg-ceiling"), Self.lightID("reg-kitchen")])
        try await provider.recall(try #require(scenes.first?.id))
        let call = try #require(await server.serviceCalls().last)
        #expect(call["domain"] == "scene")
        #expect(call["target"] == ["entity_id": "scene.movie"])
        await #expect(throws: LightCoreError.self) { try await provider.recall("homeassistant:\(Self.instanceID)/light.kitchen") }
    }

    // MARK: Live updates

    @Test func externalChangesArriveAsStateChanged() async throws {
        let (provider, server, _, events) = try await Self.paired()
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        #expect(await server.commands(ofType: "subscribe_events").first?["event_type"] == "state_changed")

        await server.setState("light.kitchen", "on", [
            "supported_color_modes": ["color_temp", "hs"], "min_color_temp_kelvin": 2000, "max_color_temp_kelvin": 6535,
            "color_mode": "hs", "brightness": 255, "hs_color": [120, 100], "friendly_name": "Kitchen", "supported_features": 32,
        ])
        let event = await events.waitFor("kitchen on") {
            if case .stateChanged(Self.lightID("reg-kitchen"), let s) = $0 { s.isOn } else { false }
        }
        guard case .stateChanged(_, let state)? = event else { return }
        #expect(state.colorAttribute == .hs(HS(h: 120, s: 1)))
        #expect(state.brightness == 1)

        // Our own command round-trips through HA's state machine too.
        try await provider.send(.turnOff, to: Self.lightID("reg-ceiling"))
        await events.waitFor("ceiling off") {
            if case .stateChanged(Self.lightID("reg-ceiling"), let s) = $0 { !s.isOn } else { false }
        }
        await provider.disconnectEventStreams()
    }

    @Test func reconnectsWithBackoffAndResyncs() async throws {
        let (provider, server, _, events) = try await Self.paired()
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await events.clear()

        await server.dropAllConnections()
        await server.setStateSilently("light.porch", "off", ["supported_color_modes": ["onoff"], "color_mode": nil, "friendly_name": "Porch", "supported_features": 0])
        await events.waitFor("disconnected") { if case .connectionChanged(false, _) = $0 { true } else { false } }
        await events.waitFor("porch unreachable") {
            if case .reachabilityChanged(Self.lightID("light.porch"), false) = $0 { true } else { false }
        }
        await events.waitFor("reconnected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        // The change made during the outage is picked up by the resync after reconnecting.
        await events.waitFor("porch off after resync") {
            if case .stateChanged(Self.lightID("light.porch"), let s) = $0 { !s.isOn } else { false }
        }
        #expect(await server.connectCount >= 2)
        #expect(await server.commands(ofType: "subscribe_events").filter { $0["event_type"] == "state_changed" }.count == 2)
        #expect(await provider.isConnected(instanceID: Self.instanceID))
        await provider.disconnectEventStreams()
    }

    @Test func keepsRetryingWhileUnreachable() async throws {
        let (provider, server, _, events) = try await Self.paired()
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await events.clear()
        await server.setReachableHosts([])
        await server.dropAllConnections()
        await events.waitFor("disconnected") { if case .connectionChanged(false, _) = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !provider.isConnected(instanceID: Self.instanceID))
        await server.setReachableHosts(["ha.test"])
        await events.waitFor("reconnected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await provider.disconnectEventStreams()
    }

    @Test func revokedTokenAsksForReauthentication() async throws {
        let (provider, server, _, events) = try await Self.paired()
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await events.clear()
        await server.setToken("rotated")
        await server.dropAllConnections()
        await events.waitFor("needsReauthentication") {
            if case .needsReauthentication(Self.instanceID) = $0 { true } else { false }
        }
        let attempts = await server.authAttempts.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(await server.authAttempts.count == attempts)  // no hammering with a bad token

        try await provider.setAccessToken("rotated", instanceID: Self.instanceID)
        await events.waitFor("reconnected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await provider.disconnectEventStreams()
    }

    @Test func recoversWhenUnreachableAtLaunch() async throws {
        let (provider, server, _, events) = try await Self.paired()
        await server.setReachableHosts([])
        await #expect(throws: LightCoreError.self) { try await provider.loadLights() }
        await server.setReachableHosts(["ha.test"])
        await events.waitFor("lights after recovery") { if case .lightAdded = $0 { true } else { false } }
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await provider.disconnectEventStreams()
    }

    @Test func fallsBackToRemoteURL() async throws {
        let (provider, server, _, _) = try await Self.paired(externalURL: "https://remote.test") { $0.autoConnectEvents = false }
        await server.setReachableHosts(["remote.test"])  // away from home: LAN address unreachable
        let lights = try await provider.loadLights()
        #expect(lights.count == 4)
    }

    @Test func heartbeatDetectsDeadConnection() async throws {
        let (provider, server, _, events) = try await Self.paired {
            $0.pingInterval = .milliseconds(30)
            $0.pongTimeout = .milliseconds(50)
        }
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        await eventually("pings sent") { await server.commands(ofType: "ping").count >= 2 }
        await events.clear()
        await server.setRespondToPings(false)
        await events.waitFor("heartbeat disconnect") { if case .connectionChanged(false, _) = $0 { true } else { false } }
        await server.setRespondToPings(true)
        await events.waitFor("reconnected") { if case .connectionChanged(true, _) = $0 { true } else { false } }
        #expect(await server.connectCount >= 2)
        await provider.disconnectEventStreams()
    }

    @Test func addedAndRemovedEntitiesResync() async throws {
        let (provider, server, _, events) = try await Self.paired()
        _ = try await provider.loadLights()
        await events.waitFor("connected") { if case .connectionChanged(true, _) = $0 { true } else { false } }

        await server.addRegistryEntity(["entity_id": "light.lamp", "id": "reg-lamp", "area_id": "kitchen"])
        await server.setState("light.lamp", "off", ["supported_color_modes": ["brightness"], "color_mode": nil, "friendly_name": "Lamp"])
        let added = await events.waitFor("lamp added") { if case .lightAdded(let l) = $0 { l.name == "Lamp" } else { false } }
        if case .lightAdded(let lamp)? = added {
            #expect(lamp.id == Self.lightID("reg-lamp"))
            #expect(lamp.roomHint == "Kitchen")
        }

        await server.setState("light.strip", nil)
        await events.waitFor("strip removed") { $0 == .lightRemoved(Self.lightID("reg-strip")) }

        // Registry events (no state change) trigger a resync: a renamed area becomes lightUpdated.
        await server.renameArea("kitchen", to: "Cookhouse")
        await server.fireEvent("area_registry_updated", data: ["action": "update", "area_id": "kitchen"])
        await events.waitFor("kitchen light moved") {
            if case .lightUpdated(let l) = $0 { l.id == Self.lightID("reg-kitchen") && l.roomHint == "Cookhouse" } else { false }
        }
        await provider.disconnectEventStreams()
    }

    // MARK: Discovery

    @Test func discoveryConfirmsManualHostsAndBonjour() async throws {
        let server = FakeHomeAssistant()
        var transport = FakeHATransport(server: server)
        transport.bonjour = [HADiscoveredInstance(
            uuid: "uuid-bonjour", name: "Cabin", baseURL: URL(string: "http://cabin.test:8123")!,
            externalURL: URL(string: "https://cabin.ui.nabu.casa"), version: "2026.9.0")]
        let provider = HomeAssistantProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        var found: [DiscoveredDevice] = []
        for await device in await provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(500), manualHosts: ["ha.test", "10.1.2.3", "ha.test:8123"]))
        {
            found.append(device)
        }
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        #expect(found.count == 3)  // "ha.test" and "ha.test:8123" are the same URL
        #expect(byID["url:http://ha.test:8123"]?.metadata["confirmed"] == "true")
        #expect(byID["url:http://ha.test:8123"]?.metadata["version"] == "2026.10.1")
        #expect(byID["url:http://10.1.2.3:8123"]?.metadata["confirmed"] == "false")
        let cabin = try #require(byID["uuid-bonjour"])
        #expect(cabin.method == .bonjour)
        #expect(cabin.metadata["external_url"] == "https://cabin.ui.nabu.casa")
        #expect(await server.openConnections == 0)  // probes close their sockets
    }

    @Test func removeInstanceDeletesToken() async throws {
        let (provider, _, secrets, events) = try await Self.paired { $0.autoConnectEvents = false }
        _ = try await provider.loadLights()
        await provider.removeInstance(id: Self.instanceID)
        #expect(await secrets.count == 0)
        #expect(await provider.instanceIDs.isEmpty)
        await events.waitFor("lights removed") { if case .lightRemoved = $0 { true } else { false } }
    }
}
