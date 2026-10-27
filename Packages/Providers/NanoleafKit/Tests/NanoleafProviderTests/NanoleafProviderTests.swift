import Foundation
import LightCore
import NanoleafCodec
import NetKit
import Testing
@testable import NanoleafProvider

/// Collects provider events in the background so tests can wait for a matching one.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    deinit { task?.cancel() }

    private func append(_ e: ProviderEvent) {
        lock.lock()
        events.append(e)
        lock.unlock()
    }

    private func first(_ predicate: (ProviderEvent) -> Bool) -> ProviderEvent? {
        lock.lock()
        defer { lock.unlock() }
        return events.first(where: predicate)
    }

    /// Waits until an event matching `predicate` was recorded (or `timeout`).
    func wait(timeout: Duration = .seconds(10), _ predicate: (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let e = first(predicate) { return e }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return first(predicate)
    }
}

private func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private let fastConfig = NanoleafProvider.Configuration(
    pairingWindow: .seconds(3),
    pairingRetryInterval: .milliseconds(50),
    requestTimeout: .seconds(3),
    probeTimeout: .seconds(1),
    eventIdleTimeout: .seconds(30),
    eventBackoff: ExponentialBackoff(initial: .milliseconds(50), multiplier: 2, maximum: .milliseconds(400))
)

private func makeDiscovered(_ server: FakeNanoleafServer, bonjourID: String? = "59:7E:43:1A:2B:3C") -> DiscoveredDevice {
    var metadata: [String: String] = [:]
    if let bonjourID { metadata["id"] = bonjourID }
    return DiscoveredDevice(
        id: bonjourID ?? "ip:127.0.0.1", brand: .nanoleaf, name: "Shapes", host: "127.0.0.1", port: Int(server.port),
        method: .bonjour, metadata: metadata)
}

/// Starts a fake controller and a provider already paired with it.
private func pairedFixture(
    config: NanoleafProvider.Configuration = fastConfig
) async throws -> (FakeNanoleafServer, NanoleafProvider, InMemorySecretStore, LightID) {
    let server = FakeNanoleafServer()
    try server.start()
    let secrets = InMemorySecretStore()
    let provider = NanoleafProvider(secrets: secrets, serviceBrowser: nil, configuration: config)
    let ui = ScriptedPairingInteraction([.confirm(true)])
    let paired = try await provider.pair(makeDiscovered(server), using: ui)
    let id = try #require(paired.lightIDs.first)
    return (server, provider, secrets, id)
}

@Suite("NanoleafProvider", .serialized)
struct NanoleafProviderTests {
    @Test func pairsAfterPowerButtonHold() async throws {
        let server = FakeNanoleafServer(rejectAddUser: 3) // 403 three times, then a token
        try server.start()
        defer { server.stop() }
        let secrets = InMemorySecretStore()
        let provider = NanoleafProvider(secrets: secrets, serviceBrowser: nil, configuration: fastConfig)
        let ui = ScriptedPairingInteraction([.confirm(true)])

        let paired = try await provider.pair(makeDiscovered(server), using: ui)

        #expect(paired.id == "S19124C8036") // serialNo wins over the Bonjour id
        #expect(paired.brand == .nanoleaf)
        #expect(paired.name == "Shapes 4A2B")
        #expect(paired.model == "NL42")
        #expect(paired.hostHint == "127.0.0.1")
        #expect(paired.port == Int(server.port))
        #expect(paired.lightIDs.map(\.rawValue) == ["nanoleaf:S19124C8036"])
        #expect(paired.metadata["bonjourID"] == "59:7E:43:1A:2B:3C")
        #expect(server.addUserAttempts == 4)
        let prompts = await ui.prompts
        #expect(prompts.first == NanoleafProvider.pairingMessage)
        #expect(prompts.contains { $0.contains("Waiting for the Nanoleaf controller") })
        let token = try await secrets.string(for: SecretKey(brand: .nanoleaf, owner: "S19124C8036", item: "authToken"))
        #expect(token == server.token)
        #expect(await provider.pairedDevices.map(\.id) == ["S19124C8036"])
    }

    @Test func fallsBackToBonjourIDWithoutSerial() async throws {
        let server = FakeNanoleafServer()
        server.mutate { $0.serialNo = nil }
        try server.start()
        defer { server.stop() }
        let provider = NanoleafProvider(secrets: InMemorySecretStore(), serviceBrowser: nil, configuration: fastConfig)
        let paired = try await provider.pair(makeDiscovered(server), using: ScriptedPairingInteraction([.confirm(true)]))
        #expect(paired.id == "59:7E:43:1A:2B:3C")
        #expect(paired.lightIDs.map(\.rawValue) == ["nanoleaf:59:7E:43:1A:2B:3C"])
    }

    @Test func pairingTimesOutWhenNotInPairingMode() async throws {
        let server = FakeNanoleafServer(rejectAddUser: nil)
        try server.start()
        defer { server.stop() }
        var config = fastConfig
        config.pairingWindow = .milliseconds(600)
        let secrets = InMemorySecretStore()
        let provider = NanoleafProvider(secrets: secrets, serviceBrowser: nil, configuration: config)
        let ui = ScriptedPairingInteraction([.confirm(true)])
        await #expect(throws: LightCoreError.timeout) {
            _ = try await provider.pair(makeDiscovered(server), using: ui)
        }
        #expect(server.addUserAttempts >= 3)
        #expect(await ui.prompts.last == NanoleafProvider.notInPairingModeMessage)
        #expect(await secrets.count == 0)
    }

    @Test func pairingCancelledByUser() async throws {
        let server = FakeNanoleafServer()
        try server.start()
        defer { server.stop() }
        let provider = NanoleafProvider(secrets: InMemorySecretStore(), serviceBrowser: nil, configuration: fastConfig)
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await provider.pair(makeDiscovered(server), using: ScriptedPairingInteraction([.confirm(false)]))
        }
        #expect(server.addUserAttempts == 0)
    }

    @Test func rejectsIPv6Host() async throws {
        let provider = NanoleafProvider(secrets: InMemorySecretStore(), serviceBrowser: nil, configuration: fastConfig)
        let device = DiscoveredDevice(id: "x", brand: .nanoleaf, name: "N", host: "fe80::1", port: 16021, method: .manual)
        await #expect(throws: LightCoreError.self) {
            _ = try await provider.pair(device, using: ScriptedPairingInteraction([.confirm(true)]))
        }
    }

    @Test func loadsLightWithCapabilitiesAndState() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        let lights = try await provider.loadLights()
        let light = try #require(lights.first)
        #expect(lights.count == 1)
        #expect(light.id == id)
        #expect(light.name == "Shapes 4A2B")
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(light.capabilities.kelvinRange == 1200...6500)
        #expect(light.capabilities.effects.map(\.id) == ["Fireworks", "Flames", "Forest", "Northern Lights"])
        #expect(light.state.isOn)
        #expect(light.state.brightness == 0.65)
        #expect(light.state.effect == "Northern Lights")
        #expect(light.state.reachable)
        #expect(light.providerRef == "127.0.0.1:\(server.port)")
    }

    @Test func sendsCombinedStateWrite() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        _ = try await provider.loadLights()
        let recorder = EventRecorder(provider.events)

        try await provider.send(LightCommand(on: true, brightness: 0.4, color: .hs(HS(h: 120, s: 1))), to: id)

        let puts = server.requests.filter { $0.method == "PUT" && $0.path.hasSuffix("/state") }
        #expect(puts.count == 1)
        let body = try JSONSerialization.jsonObject(with: Data(try #require(puts.first).body.utf8)) as? [String: Any]
        #expect((body?["brightness"] as? [String: Any])?["value"] as? Int == 40)
        #expect((body?["hue"] as? [String: Any])?["value"] as? Int == 120)
        #expect((body?["sat"] as? [String: Any])?["value"] as? Int == 100)
        #expect((body?["on"] as? [String: Any])?["value"] as? Bool == true)
        server.mutate { s in
            #expect(s.brightness == 40)
            #expect(s.colorMode == "hs")
        }
        let event = await recorder.wait { event in
            if case .stateChanged(let lid, let state) = event { return lid == id && state.brightness == 0.4 }
            return false
        }
        if case .stateChanged(_, let state)? = event {
            #expect(state.colorMode == .hs)
            #expect(state.hs == HS(h: 120, s: 1))
        } else {
            Issue.record("no optimistic stateChanged")
        }
    }

    @Test func splitsWritesWhenConfigured() async throws {
        var config = fastConfig
        config.combineStateWrites = false
        let (server, provider, _, id) = try await pairedFixture(config: config)
        defer { server.stop() }
        _ = try await provider.loadLights()
        try await provider.send(LightCommand(brightness: 0.5, color: .kelvin(2700), transition: .seconds(2)), to: id)
        let bodies = server.requests.filter { $0.method == "PUT" && $0.path.hasSuffix("/state") }.map(\.body)
        #expect(bodies == [#"{"brightness":{"duration":2,"value":50}}"#, #"{"ct":{"value":2700}}"#])
    }

    @Test func effectsAreScenesAndEffects() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        let scenes = try await provider.scenes()
        #expect(scenes.map(\.name) == ["Fireworks", "Flames", "Forest", "Northern Lights"])
        #expect(scenes.allSatisfy { $0.kind == .vendor && $0.lightIDs == [id] })

        try await provider.recall(try #require(scenes.first { $0.name == "Forest" }).id)
        #expect(server.requests.last { $0.path.hasSuffix("/effects") }?.body == #"{"select":"Forest"}"#)
        server.mutate { #expect($0.select == "Forest") }

        try await provider.send(LightCommand(effect: "Flames"), to: id)
        server.mutate { #expect($0.select == "Flames") }

        await #expect(throws: LightCoreError.self) { try await provider.recall("nanoleaf:nope") }
    }

    @Test func receivesSSEEventsAndReconnects() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        _ = try await provider.loadLights()
        let recorder = EventRecorder(provider.events)
        await provider.start()
        defer { Task { await provider.stop() } }

        #expect(await waitUntil { server.openEventClients == 1 })
        #expect(server.requests.contains { $0.path.hasSuffix("/events?id=1,2,3,4") })
        #expect(await recorder.wait { if case .connectionChanged(true, _) = $0 { return true }; return false } != nil)

        // External change (e.g. from the Nanoleaf app or the physical button).
        server.push(id: 1, json: #"{"events":[{"attr":2,"value":12}]}"#)
        let dimmed = await recorder.wait { event in
            if case .stateChanged(let lid, let s) = event { return lid == id && s.brightness == 0.12 }
            return false
        }
        #expect(dimmed != nil)

        // Connection drops; the provider reconnects and keeps receiving.
        server.dropEventClients()
        #expect(await waitUntil { server.eventConnections >= 2 && server.openEventClients == 1 })
        server.push(id: 1, json: #"{"events":[{"attr":1,"value":false}]}"#)
        let off = await recorder.wait { event in
            if case .stateChanged(let lid, let s) = event { return lid == id && !s.isOn }
            return false
        }
        #expect(off != nil)

        // Effect selected externally.
        server.push(id: 3, json: #"{"events":[{"attr":1,"value":"Flames"}]}"#)
        server.push(id: 1, json: #"{"events":[{"attr":6,"value":"effect"},{"attr":1,"value":true}]}"#)
        let effect = await recorder.wait { event in
            if case .stateChanged(let lid, let s) = event { return lid == id && s.effect == "Flames" && s.isOn }
            return false
        }
        #expect(effect != nil)
    }

    @Test func forwardsTouchEvents() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        await provider.start()
        defer { Task { await provider.stop() } }
        #expect(await waitUntil { server.openEventClients == 1 })
        server.push(id: 4, json: #"{"events":[{"panelId":2,"gesture":1}]}"#)
        let reader = Task {
            var iterator = provider.touchEvents.makeAsyncIterator()
            return await iterator.next()
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            reader.cancel()
        }
        let touch = await reader.value
        watchdog.cancel()
        #expect(touch == NanoleafTouchEvent(light: id, touch: NanoleafTouch(panelId: 2, gesture: 1)))
    }

    @Test func unreachableController() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        _ = try await provider.loadLights()
        let recorder = EventRecorder(provider.events)
        server.stop()

        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOff, to: id) }
        let down = await recorder.wait { $0 == .reachabilityChanged(id, reachable: false) }
        #expect(down != nil)
        let lights = try await provider.loadLights()
        #expect(lights.first?.state.reachable == false)
    }

    @Test func revokedTokenNeedsReauthentication() async throws {
        let (server, provider, _, id) = try await pairedFixture()
        defer { server.stop() }
        let recorder = EventRecorder(provider.events)
        server.revokeToken()
        await #expect(throws: LightCoreError.authenticationRequired(.nanoleaf)) {
            try await provider.send(.turnOn, to: id)
        }
        #expect(await recorder.wait { $0 == .needsReauthentication(accountID: id.stableId) } != nil)
    }

    @Test func identifyAndRemove() async throws {
        let (server, provider, secrets, id) = try await pairedFixture()
        defer { server.stop() }
        try await provider.identify(id)
        #expect(server.identifyCount == 1)

        let recorder = EventRecorder(provider.events)
        try await provider.removeDevice(id.stableId)
        #expect(server.requests.last?.method == "DELETE")
        #expect(!server.tokenValid)
        #expect(await secrets.count == 0)
        #expect(try await provider.loadLights().isEmpty)
        #expect(await recorder.wait { $0 == .lightRemoved(id) } != nil)
        await #expect(throws: LightCoreError.lightNotFound(id)) { try await provider.send(.turnOn, to: id) }
    }

    @Test func restoresPairedDevices() async throws {
        let (server, first, secrets, id) = try await pairedFixture()
        defer { server.stop() }
        let stored = await first.pairedDevices

        let second = NanoleafProvider(secrets: secrets, devices: stored, serviceBrowser: nil, configuration: fastConfig)
        let lights = try await second.loadLights()
        #expect(lights.map(\.id) == [id])
        #expect(lights.first?.state.brightness == 0.65)
        try await second.send(.turnOff, to: id)
        server.mutate { #expect($0.on == false) }

        let third = NanoleafProvider(secrets: secrets, serviceBrowser: nil, configuration: fastConfig)
        await third.restore(stored)
        #expect(try await third.loadLights().map(\.id) == [id])
    }

    @Test func discoversManualHostsAndBonjourRecords() async throws {
        let server = FakeNanoleafServer()
        try server.start()
        defer { server.stop() }
        let port = Int(server.port)
        let browser: NanoleafServiceBrowser = { _ in
            AsyncStream { c in
                c.yield(NanoleafServiceRecord(name: "Canvas 1", host: "127.0.0.1", port: port, txt: ["id": "AA:BB:CC:DD:EE:FF", "md": "NL29"]))
                c.yield(NanoleafServiceRecord(name: "IPv6 only", host: "fe80::2", port: port, txt: ["id": "11:22:33:44:55:66"]))
                c.finish()
            }
        }
        let provider = NanoleafProvider(secrets: InMemorySecretStore(), serviceBrowser: browser, configuration: fastConfig)
        let options = DiscoveryOptions(
            timeout: .seconds(5), manualHosts: ["127.0.0.1:\(port)", "fe80::1", "127.0.0.1:1"])
        var found: [DiscoveredDevice] = []
        for await device in await provider.discover(options: options) { found.append(device) }

        #expect(Set(found.map(\.id)) == ["AA:BB:CC:DD:EE:FF", "ip:127.0.0.1"])
        let manual = try #require(found.first { $0.method == .manual })
        #expect(manual.port == port)
        let bonjour = try #require(found.first { $0.method == .bonjour })
        #expect(bonjour.model == "NL29")

        // The Bonjour result can be paired directly.
        let paired = try await provider.pair(bonjour, using: ScriptedPairingInteraction([.confirm(true)]))
        #expect(paired.metadata["bonjourID"] == "AA:BB:CC:DD:EE:FF")
    }

    @Test func bonjourRefreshesHostOfPairedDevice() async throws {
        let (server, _, secrets, id) = try await pairedFixture()
        defer { server.stop() }
        // Stored with a stale IP; Bonjour reports the controller at its current address.
        var stale = PairedDevice(id: id.stableId, brand: .nanoleaf, name: "Shapes", hostHint: "127.0.0.2", port: 9,
                                 metadata: ["bonjourID": "59:7E:43:1A:2B:3C"])
        stale.lightIDs = [id]
        let port = Int(server.port)
        let browser: NanoleafServiceBrowser = { _ in
            AsyncStream { c in
                c.yield(NanoleafServiceRecord(name: "Shapes", host: "127.0.0.1", port: port, txt: ["id": "59:7E:43:1A:2B:3C"]))
                c.finish()
            }
        }
        let provider = NanoleafProvider(secrets: secrets, devices: [stale], serviceBrowser: browser, configuration: fastConfig)
        var found: [DiscoveredDevice] = []
        for await d in await provider.discover(options: DiscoveryOptions(timeout: .seconds(3))) { found.append(d) }
        #expect(found.map(\.id) == [id.stableId])
        #expect(await provider.pairedDevices.first?.hostHint == "127.0.0.1")
        #expect(try await provider.loadLights().first?.state.reachable == true)
    }
}
