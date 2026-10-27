import Foundation
import LightCore
import NetKit
import Synchronization
import Testing
import TwinklyCodec
@testable import TwinklyProvider

/// Provider against `FakeTwinkly` over real loopback HTTP + UDP (Linux and macOS).
@Suite("TwinklyProvider (loopback fake)", .timeLimit(.minutes(1)))
struct TwinklyProviderTests {
    struct Harness {
        let fake: FakeTwinkly
        let provider: TwinklyProvider
        let secrets: InMemorySecretStore

        var lightID: LightID { LightID(brand: .twinkly, stableId: fake.stableID)! }
    }

    static func config(port: Int?, udpPort: UInt16 = 5555, _ tweak: (inout TwinklyProvider.Configuration) -> Void = { _ in }) -> TwinklyProvider.Configuration {
        var c = TwinklyProvider.Configuration()
        c.httpPort = port
        c.discoveryPort = udpPort
        c.pollInterval = nil
        c.requestTimeout = .seconds(2)
        c.probeTimeout = .seconds(1)
        tweak(&c)
        return c
    }

    static func harness(
        fake: FakeTwinkly? = nil,
        transport: (any TwinklyTransport)? = nil,
        secrets: InMemorySecretStore = InMemorySecretStore(),
        _ tweak: (inout TwinklyProvider.Configuration) -> Void = { _ in }
    ) throws -> Harness {
        let fake = try fake ?? FakeTwinkly()
        let provider = TwinklyProvider(
            secrets: secrets, transport: transport ?? LoopbackTwinklyTransport(sweep: ["127.0.0.1"]),
            configuration: config(port: fake.httpPort, udpPort: fake.udpPort, tweak))
        return Harness(fake: fake, provider: provider, secrets: secrets)
    }

    static func discovered(_ fake: FakeTwinkly) -> DiscoveredDevice {
        DiscoveredDevice(id: fake.stableID, brand: .twinkly, name: fake.name, host: "127.0.0.1", port: fake.httpPort, method: .manual)
    }

    static func paired(_ h: Harness) async throws -> PairedDevice {
        try await h.provider.pair(discovered(h.fake), using: ScriptedPairingInteraction([]))
    }

    static func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
        var out: [DiscoveredDevice] = []
        for await d in stream { out.append(d) }
        return out
    }

    // MARK: Discovery

    @Test func sweepFindsDeviceAndConfirmsWithGestalt() async throws {
        let h = try Self.harness()
        let found = await Self.collect(await h.provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(800), methods: [.sweep], broadcastAvailable: false)))
        let device = try #require(found.first)
        #expect(found.count == 1)
        #expect(device.id == "98f4ab1cc190")
        #expect(device.name == "Twinkly_1CC190")
        #expect(device.model == "TWI190SPP")
        #expect(device.method == .sweep)
        #expect(device.host == "127.0.0.1")
        #expect(device.metadata["firmware"] == "2.8.3")
        #expect(device.metadata["discovery_id"] == "Twinkly_1CC190")
        #expect(device.metadata["led_profile"] == "RGBW")
    }

    @Test func broadcastIsUsedWhenEntitledAndSkipsSweep() async throws {
        let fake = try FakeTwinkly()
        let transport = LoopbackTwinklyTransport(broadcast: ["127.0.0.1"], sweep: ["127.0.0.2"])
        let h = try Self.harness(fake: fake, transport: transport)
        let found = await Self.collect(await h.provider.discover(options: DiscoveryOptions(
            timeout: .milliseconds(800), methods: [.broadcast, .sweep], broadcastAvailable: true)))
        #expect(found.map(\.method) == [.broadcast])
    }

    @Test func manualHostWithPortIsProbedOverHTTP() async throws {
        let h = try Self.harness()
        let found = await Self.collect(await h.provider.discover(options: DiscoveryOptions(
            timeout: .seconds(2), methods: [.manual], manualHosts: ["http://\(h.fake.host)/"])))
        #expect(found.map(\.id) == [h.fake.stableID])
        #expect(found.first?.port == h.fake.httpPort)
    }

    @Test func hostThatIsNotATwinklyIsIgnored() async throws {
        let other = try LoopbackHTTPServer { _ in .response(.text("Not Found", status: 404)) }
        defer { other.stop() }
        let h = try Self.harness()
        let found = await Self.collect(await h.provider.discover(options: DiscoveryOptions(
            timeout: .seconds(1), methods: [.manual], manualHosts: [other.baseHost])))
        #expect(found.isEmpty)
    }

    // MARK: Pairing and state

    @Test func pairingLogsInOnceStoresTokenAndReadsCapabilities() async throws {
        let h = try Self.harness()
        let paired = try await Self.paired(h)
        #expect(paired.id == "98f4ab1cc190")
        #expect(paired.lightIDs == [h.lightID])
        #expect(paired.model == "TWI190SPP")
        #expect(paired.metadata["firmware"] == "2.8.3")
        #expect(h.fake.logins == 1)
        let stored = try #require(await h.secrets.data(for: TwinklyProvider.tokenSecret(deviceID: paired.id)))
        let token = try #require(h.fake.read(\.validToken))
        let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["value"] as? String == token)

        let lights = try await h.provider.loadLights()
        let light = try #require(lights.first)
        #expect(light.capabilities.supportedColorModes == [.hs])
        #expect(light.capabilities.effects.count == 16) // movie + 15 predefined
        #expect(light.capabilities.effects.allSatisfy { $0.isFast })
        #expect(light.state.isOn)
        #expect(light.state.effect == "movie")
        #expect(light.state.brightness == 1)
        #expect(light.state.reachable)
        #expect(h.fake.logins == 1) // token reused
    }

    @Test func pairingRejectsADifferentDeviceAtTheHost() async throws {
        let h = try Self.harness()
        var device = Self.discovered(h.fake)
        device.id = "aabbccddeeff"
        await #expect(throws: LightCoreError.self) {
            _ = try await h.provider.pair(device, using: ScriptedPairingInteraction([]))
        }
    }

    @Test func colorIsSentAsHSVThenColorMode() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        try await h.provider.send(LightCommand(color: .hs(HS(h: 120, s: 0.5))), to: h.lightID)
        #expect(h.fake.writes == [#"led/color {"hue":120,"saturation":128,"value":255}"#, #"led/mode {"mode":"color"}"#])
        #expect(h.fake.read(\.mode) == "color")

        // Already in colour mode: only the colour changes.
        try await h.provider.send(LightCommand(brightness: 0.4, color: .rgb(RGB(r: 255, g: 0, b: 0))), to: h.lightID)
        #expect(Array(h.fake.writes.suffix(2)) == [#"led/color {"hue":0,"saturation":255,"value":255}"#,
                                                    #"led/out/brightness {"mode":"enabled","type":"A","value":40}"#])

        let lights = try await h.provider.loadLights()
        let state = try #require(lights.first?.state)
        #expect(state.colorMode == .hs)
        #expect(state.hs?.h == 0)
        #expect(state.brightness == 0.4)
    }

    @Test func offThenBrightnessRestoresLastMode() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        try await h.provider.send(.turnOff, to: h.lightID)
        #expect(h.fake.read(\.mode) == "off")
        try await h.provider.send(LightCommand(brightness: 0.25), to: h.lightID)
        #expect(Array(h.fake.writes.suffix(2)) == [#"led/out/brightness {"mode":"enabled","type":"A","value":25}"#,
                                                    #"led/mode {"mode":"movie"}"#])
        #expect(h.fake.read(\.mode) == "movie")
    }

    @Test func effectSelectsCurrentEffectAndEffectMode() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        var events = h.provider.events.makeAsyncIterator()
        try await h.provider.send(LightCommand(effect: "effect:3"), to: h.lightID)
        #expect(h.fake.read(\.effectID) == 3)
        #expect(h.fake.read(\.mode) == "effect")
        var sawEffect = false
        while let event = await events.next() {
            if case .stateChanged(let id, let state) = event, id == h.lightID {
                sawEffect = state.effect == "effect:3" && state.isOn
                break
            }
        }
        #expect(sawEffect)
    }

    @Test func tokenInvalidatedByAnotherControllerTriggersOneRelogin() async throws {
        let h = try Self.harness()
        _ = try await Self.paired(h)
        h.fake.invalidateToken()
        try await h.provider.send(.turnOff, to: h.lightID)
        #expect(h.fake.logins == 2)
        #expect(h.fake.read(\.mode) == "off")
    }

    @Test func expiringTokenIsRenewedBeforeUse() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let h = try Self.harness { $0.now = { clock.withLock { $0 } } }
        _ = try await Self.paired(h)
        clock.withLock { $0 = $0.addingTimeInterval(14_400 - 30) } // inside the 60 s refresh margin
        try await h.provider.send(.turnOff, to: h.lightID)
        #expect(h.fake.logins == 2)
        // Renewed proactively: login + verify come before the write, not after a 401.
        #expect(h.fake.requests.suffix(3).map { "\($0.method) \($0.path)" }
            == ["POST /xled/v1/login", "POST /xled/v1/verify", "POST /xled/v1/led/mode"])
    }

    @Test func persistedTokenIsReusedByANewProviderInstance() async throws {
        let fake = try FakeTwinkly()
        let secrets = InMemorySecretStore()
        let first = try Self.harness(fake: fake, secrets: secrets)
        let paired = try await Self.paired(first)
        let second = try Self.harness(fake: fake, secrets: secrets)
        await second.provider.addDevice(paired)
        _ = try await second.provider.loadLights()
        #expect(fake.logins == 1)
    }

    @Test func oldFirmwareWithoutColorEndpointIsBrightnessOnly() async throws {
        let h = try Self.harness(fake: try FakeTwinkly(firmware: "2.5.6"))
        _ = try await Self.paired(h)
        let light = try #require(try await h.provider.loadLights().first)
        #expect(light.capabilities.supportedColorModes == [.brightness])
        try await h.provider.send(LightCommand(brightness: 0.5, color: .hs(HS(h: 10, s: 1))), to: h.lightID)
        #expect(!h.fake.writes.contains { $0.hasPrefix("led/color") })
        #expect(h.fake.read(\.brightness) == 50)
    }

    @Test func pollingEmitsExternalChanges() async throws {
        let h = try Self.harness { $0.pollInterval = .milliseconds(100) }
        _ = try await Self.paired(h)
        _ = try await h.provider.loadLights()
        #expect(await h.provider.isPolling)
        var events = h.provider.events.makeAsyncIterator()
        h.fake.mutate { $0.mode = "off" }
        var sawOff = false
        while let event = await events.next() {
            if case .stateChanged(_, let state) = event, !state.isOn {
                sawOff = true
                break
            }
        }
        #expect(sawOff)
        await h.provider.stopPolling()
    }

    @Test func unreachableDeviceIsReportedNotThrownByLoadLights() async throws {
        let h = try Self.harness()
        let paired = try await Self.paired(h)
        h.fake.stop()
        let lights = try await h.provider.loadLights()
        #expect(lights.map(\.id) == paired.lightIDs)
        #expect(lights.first?.state.reachable == false)
        await #expect(throws: LightCoreError.self) {
            try await h.provider.send(.turnOff, to: h.lightID)
        }
    }

    @Test func unknownLightIsRejected() async throws {
        let h = try Self.harness()
        await #expect(throws: LightCoreError.lightNotFound(LightID(brand: .twinkly, stableId: "001122334455")!)) {
            try await h.provider.send(.turnOn, to: LightID(brand: .twinkly, stableId: "001122334455")!)
        }
    }
}

#if canImport(Darwin)
/// The production URLSession + NetKit UDP transport against the same fake (macOS CI).
@Suite("URLSessionTwinklyTransport against FakeTwinkly", .timeLimit(.minutes(1)))
struct URLSessionTwinklyTransportTests {
    final class LoopbackSweepTransport: TwinklyTransport {
        let base = URLSessionTwinklyTransport(interfaceName: nil)
        func send(_ request: TwinklyHTTPRequest) async throws -> TwinklyHTTPResponse { try await base.send(request) }
        func probeUDP(_ payload: Data, destinations: [String], port: UInt16, window: Duration) -> AsyncStream<TwinklyDatagram> {
            base.probeUDP(payload, destinations: destinations, port: port, window: window)
        }
        func sweepHosts() -> [String] { ["127.0.0.1"] }
    }

    @Test func discoverPairAndControlOverURLSession() async throws {
        let fake = try FakeTwinkly()
        let provider = TwinklyProvider(
            secrets: InMemorySecretStore(), transport: LoopbackSweepTransport(),
            configuration: TwinklyProviderTests.config(port: fake.httpPort, udpPort: fake.udpPort))
        let found = await TwinklyProviderTests.collect(await provider.discover(options: DiscoveryOptions(
            timeout: .seconds(1), methods: [.sweep])))
        let device = try #require(found.first)
        #expect(device.id == fake.stableID)
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        let lightID = try #require(paired.lightIDs.first)
        try await provider.send(LightCommand(color: .hs(HS(h: 200, s: 1))), to: lightID)
        #expect(fake.read(\.mode) == "color")
        #expect(fake.read(\.hue) == 200)
        fake.invalidateToken()
        try await provider.send(.turnOff, to: lightID)
        #expect(fake.logins == 2)
        #expect(fake.read(\.mode) == "off")
    }
}
#endif
