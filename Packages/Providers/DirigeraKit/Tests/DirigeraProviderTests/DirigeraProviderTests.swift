import DirigeraCodec
import Foundation
import LightCore
import NetKit
import Testing
@testable import DirigeraProvider

/// Provider against `FakeDirigeraHub` over real loopback HTTP + WebSocket (Linux and macOS).
@Suite("DirigeraProvider (loopback fake hub)", .timeLimit(.minutes(1)))
struct DirigeraProviderTests {
    typealias F = FakeDirigeraHub

    struct Harness {
        let hub: FakeDirigeraHub
        let transport: LoopbackDirigeraTransport
        let provider: DirigeraProvider
        let secrets: InMemorySecretStore
        let pins: InMemoryTOFUPinStore

        func lightID(_ device: String) -> LightID { DirigeraIdentifiers.lightID(hubID: F.hubID, deviceID: device)! }
    }

    static func config(port: Int, _ tweak: (inout DirigeraProvider.Configuration) -> Void = { _ in }) -> DirigeraProvider.Configuration {
        var c = DirigeraProvider.Configuration()
        c.scheme = "http"
        c.webSocketScheme = "ws"
        c.port = port
        c.autoConnectEvents = false
        c.requestTimeout = .seconds(2)
        c.probeTimeout = .seconds(1)
        c.pairingTimeout = .seconds(2)
        c.pairingPollInterval = .milliseconds(20)
        c.eventBackoff = ExponentialBackoff(initial: .milliseconds(20), maximum: .milliseconds(100))
        tweak(&c)
        return c
    }

    static func harness(_ tweak: (inout DirigeraProvider.Configuration) -> Void = { _ in }) throws -> Harness {
        let hub = try FakeDirigeraHub()
        let transport = LoopbackDirigeraTransport()
        let secrets = InMemorySecretStore()
        let pins = InMemoryTOFUPinStore()
        let provider = DirigeraProvider(secrets: secrets, pinStore: pins, transport: transport, configuration: config(port: hub.port, tweak))
        return Harness(hub: hub, transport: transport, provider: provider, secrets: secrets, pins: pins)
    }

    static func discovered(_ hub: FakeDirigeraHub) -> DiscoveredDevice {
        DiscoveredDevice(id: "ip:127.0.0.1", brand: .dirigera, name: "DIRIGERA", host: "127.0.0.1", port: hub.port, method: .manual)
    }

    /// Pairs with the button already pressed.
    static func paired(_ h: Harness) async throws -> PairedDevice {
        h.hub.pressButton()
        return try await h.provider.pair(discovered(h.hub), using: ScriptedPairingInteraction([.confirm(true)]))
    }

    /// Waits for the first event matching `predicate`.
    static func next(_ events: inout AsyncStream<ProviderEvent>.Iterator, where predicate: (ProviderEvent) -> Bool) async -> ProviderEvent? {
        while let event = await events.next() {
            if predicate(event) { return event }
        }
        return nil
    }

    // MARK: Discovery

    @Test func manualHostAnsweringUnauthorizedIsAHubCandidate() async throws {
        let h = try Self.harness()
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [h.hub.host])) {
            found.append(d)
        }
        #expect(found.count == 1)
        #expect(found.first?.id == "ip:127.0.0.1")
        #expect(found.first?.metadata["probeStatus"] == "401")
        #expect(found.first?.metadata["certificateSHA256"] == String(repeating: "ab", count: 32))
    }

    @Test func hostWithoutHubAPIIsIgnored() async throws {
        let other = try LoopbackHTTPServer { _ in .response(.text("Not Found", status: 404)) }
        defer { other.stop() }
        let h = try Self.harness()
        var found: [DiscoveredDevice] = []
        for await d in await h.provider.discover(options: DiscoveryOptions(timeout: .seconds(1), methods: [.manual], manualHosts: [other.baseHost])) {
            found.append(d)
        }
        #expect(found.isEmpty)
    }

    // MARK: Pairing

    @Test func pairingRunsPKCEFlowStoresTokenAndPinsCertificate() async throws {
        let h = try Self.harness()
        let ui = ScriptedPairingInteraction([.confirm(true)])
        // The user presses the button a moment after confirming: the provider keeps asking.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            h.hub.pressButton()
        }
        let paired = try await h.provider.pair(Self.discovered(h.hub), using: ui)
        #expect(paired.id == F.hubID)
        #expect(paired.name == "Home")
        #expect(paired.model == "DIRIGERA Hub for smart products")
        #expect(paired.metadata["firmware"] == "2.866.3")
        #expect(Set(paired.lightIDs) == [h.lightID(F.sofa), h.lightID(F.bed)])
        let prompts = await ui.prompts
        #expect(prompts.first == DirigeraProvider.buttonPrompt)
        #expect(prompts.dropFirst().contains { $0.hasPrefix("Waiting for the hub's action button") })

        let token = try #require(try await h.secrets.string(for: DirigeraProvider.tokenSecret(hubID: F.hubID)))
        #expect(h.hub.read(\.tokens).contains(token))
        #expect(await h.pins.pin(for: F.hubID)?.sha256 == Data(repeating: 0xAB, count: 32))
        // After pairing, every request uses the pinned trust for this hub.
        let afterPairing = h.transport.requests.drop { $0.trust == .pairing }
        #expect(!afterPairing.isEmpty)
        #expect(afterPairing.allSatisfy { $0.trust == .hub(id: F.hubID) && $0.headers["Authorization"] == "Bearer \(token)" })
    }

    @Test func declinedButtonPromptCancels() async throws {
        let h = try Self.harness()
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await h.provider.pair(Self.discovered(h.hub), using: ScriptedPairingInteraction([.confirm(false)]))
        }
    }

    @Test func buttonNeverPressedTimesOut() async throws {
        let h = try Self.harness { $0.pairingTimeout = .milliseconds(150) }
        await #expect(throws: LightCoreError.timeout) {
            _ = try await h.provider.pair(Self.discovered(h.hub), using: ScriptedPairingInteraction([.confirm(true)]))
        }
    }

    @Test func certificateDifferentFromPinnedOneIsRejected() async throws {
        let h = try Self.harness()
        await h.pins.setPin(CertificatePin(sha256: Data(repeating: 0x01, count: 32))!, for: F.hubID)
        h.hub.pressButton()
        await #expect(throws: LightCoreError.self) {
            _ = try await h.provider.pair(Self.discovered(h.hub), using: ScriptedPairingInteraction([.confirm(true)]))
        }
        #expect(try await h.secrets.string(for: DirigeraProvider.tokenSecret(hubID: F.hubID)) == nil)
    }

    // MARK: Lights

    @Test func loadLightsMapsOnlyLights() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        let lights = try await h.provider.loadLights()
        #expect(lights.map(\.name).sorted() == ["Bed", "Sofa"])
        let sofa = try #require(lights.first { $0.name == "Sofa" })
        #expect(sofa.roomHint == "Living room")
        #expect(sofa.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(sofa.state.isOn && sofa.state.brightness == 0.8 && sofa.state.colorMode == .hs)
        let bed = try #require(lights.first { $0.name == "Bed" })
        #expect(bed.capabilities.minKelvin == 2202 && bed.capabilities.maxKelvin == 4000)
        #expect(!bed.state.isOn)
        #expect(try await h.provider.scenes().map(\.name) == ["Movie night"])
    }

    @Test func commandIsOnePatchWithAllAttributes() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        try await h.provider.send(LightCommand(brightness: 0.3, color: .kelvin(3000)), to: h.lightID(F.bed))
        #expect(h.hub.patches == [#"[{"attributes":{"colorTemperature":3000,"isOn":true,"lightLevel":30}}]"#])
        let bed = try #require(try await h.provider.loadLights().first { $0.name == "Bed" })
        #expect(bed.state.isOn && bed.state.kelvin == 3000 && bed.state.brightness == 0.3)
    }

    @Test func rejectedCombinedPatchFallsBackToOnePerAttribute() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        h.hub.mutate { $0.rejectCombinedPatches = true }
        try await h.provider.send(LightCommand(brightness: 0.5, color: .hs(HS(h: 240, s: 1))), to: h.lightID(F.sofa))
        #expect(h.hub.patches == [#"[{"attributes":{"lightLevel":50}}]"#, #"[{"attributes":{"colorHue":240,"colorSaturation":1}}]"#])
        // Remembered: the next command goes out split straight away.
        try await h.provider.send(LightCommand(on: true, brightness: 0.2), to: h.lightID(F.bed))
        #expect(h.hub.patches.suffix(2) == [#"[{"attributes":{"isOn":true}}]"#, #"[{"attributes":{"lightLevel":20}}]"#])
    }

    @Test func sceneRecallTriggersOnHub() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        let scene = try #require(try await h.provider.scenes().first)
        #expect(scene.id == "dirigera:\(F.hubID)/\(F.scene)")
        try await h.provider.recall(scene.id)
        #expect(h.hub.read(\.triggered) == [F.scene])
    }

    @Test func revokedTokenAsksForReauthentication() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        var events = h.provider.events.makeAsyncIterator()
        h.hub.revokeTokens()
        await #expect(throws: LightCoreError.authenticationRequired(.dirigera)) {
            try await h.provider.send(.turnOff, to: h.lightID(F.sofa))
        }
        let event = await Self.next(&events) { if case .needsReauthentication = $0 { return true } else { return false } }
        #expect(event == .needsReauthentication(accountID: F.hubID))
    }

    @Test func unknownLightIsRejected() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        let ghost = DirigeraIdentifiers.lightID(hubID: F.hubID, deviceID: "nope")!
        await #expect(throws: LightCoreError.lightNotFound(ghost)) { try await h.provider.send(.turnOn, to: ghost) }
        let plug = h.lightID(F.plug)
        await #expect(throws: LightCoreError.lightNotFound(plug)) { try await h.provider.send(.turnOn, to: plug) }
    }

    // MARK: Events

    @Test func webSocketEventsUpdateStateAndReconnect() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        var events = h.provider.events.makeAsyncIterator()
        await h.provider.connectEventStreams()
        _ = await Self.next(&events) { if case .connectionChanged(true, _) = $0 { return true } else { return false } }
        #expect(await h.provider.isEventStreamConnected(hubID: F.hubID))

        h.hub.externalChange(F.sofa, ["isOn": false])
        let off = await Self.next(&events) { if case .stateChanged(_, let s) = $0 { return !s.isOn } else { return false } }
        #expect(off == .stateChanged(h.lightID(F.sofa), {
            if case .stateChanged(_, let s) = off { return s } else { return LightState() }
        }()))

        h.hub.externalChange(F.bed, [:], isReachable: false)
        let unreachable = await Self.next(&events) { if case .reachabilityChanged = $0 { return true } else { return false } }
        #expect(unreachable == .reachabilityChanged(h.lightID(F.bed), reachable: false))

        // Connection drops; a change happens while disconnected; the reconnect resyncs it.
        h.hub.dropSockets()
        _ = await Self.next(&events) { if case .connectionChanged(false, _) = $0 { return true } else { return false } }
        h.hub.externalChange(F.sofa, ["lightLevel": 10])
        _ = await Self.next(&events) { if case .connectionChanged(true, _) = $0 { return true } else { return false } }
        let resynced = await Self.next(&events) {
            if case .stateChanged(let id, let s) = $0 { return id == h.lightID(F.sofa) && s.brightness == 0.1 } else { return false }
        }
        #expect(resynced != nil)

        await h.provider.disconnectEventStreams()
        #expect(!(await h.provider.isEventStreamConnected(hubID: F.hubID)))
    }

    @Test func sceneAndDeviceListEventsAreForwarded() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        var events = h.provider.events.makeAsyncIterator()
        await h.provider.handleEvent(#"{"type":"sceneUpdated","data":{"id":"\#(F.scene)"}}"#, hubID: F.hubID)
        // Scene list unchanged in the fake -> the provider still signals a refresh.
        let scenes = await Self.next(&events) { $0 == .scenesChanged }
        #expect(scenes == .scenesChanged)
        await h.provider.handleEvent(#"{"type":"deviceRemoved","data":{"id":"\#(F.bed)","type":"light"}}"#, hubID: F.hubID)
        let removed = await Self.next(&events) { if case .lightRemoved = $0 { return true } else { return false } }
        #expect(removed == .lightRemoved(h.lightID(F.bed)))
        await h.provider.handleEvent("garbage", hubID: F.hubID)
    }

    @Test func revokedTokenStopsTheEventStream() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        h.hub.revokeTokens()
        var events = h.provider.events.makeAsyncIterator()
        await h.provider.connectEventStreams()
        let event = await Self.next(&events) { if case .needsReauthentication = $0 { return true } else { return false } }
        #expect(event == .needsReauthentication(accountID: F.hubID))
    }
}

#if canImport(Darwin)
/// The production URLSession transport (HTTP + URLSessionWebSocketTask) against the same fake
/// over plain http/ws on macOS CI. TLS pinning itself is NetKit `TrustEvaluator`'s job.
@Suite("URLSessionDirigeraTransport against FakeDirigeraHub", .timeLimit(.minutes(1)))
struct URLSessionDirigeraTransportTests {
    @Test func pairControlAndEventsOverURLSession() async throws {
        let hub = try FakeDirigeraHub()
        let pins = InMemoryTOFUPinStore()
        let provider = DirigeraProvider(secrets: InMemorySecretStore(), pinStore: pins,
                                        configuration: DirigeraProviderTests.config(port: hub.port))
        hub.pressButton()
        let paired = try await provider.pair(DirigeraProviderTests.discovered(hub), using: ScriptedPairingInteraction([.confirm(true)]))
        #expect(paired.id == FakeDirigeraHub.hubID)
        #expect(await pins.pin(for: FakeDirigeraHub.hubID) == nil) // plain http: nothing to pin
        let sofa = DirigeraIdentifiers.lightID(hubID: FakeDirigeraHub.hubID, deviceID: FakeDirigeraHub.sofa)!
        try await provider.send(LightCommand(brightness: 0.6), to: sofa)
        #expect(hub.patches == [#"[{"attributes":{"lightLevel":60}}]"#])

        var events = provider.events.makeAsyncIterator()
        await provider.connectEventStreams()
        _ = await DirigeraProviderTests.next(&events) { if case .connectionChanged(true, _) = $0 { return true } else { return false } }
        hub.externalChange(FakeDirigeraHub.sofa, ["isOn": false])
        let off = await DirigeraProviderTests.next(&events) { if case .stateChanged(_, let s) = $0 { return !s.isOn } else { return false } }
        #expect(off != nil)
        await provider.disconnectEventStreams()
    }
}
#endif
