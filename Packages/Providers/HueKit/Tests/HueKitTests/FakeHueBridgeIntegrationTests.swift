// Integration tests: real URLSessionHueTransport (TLS trust, TOFU, SSE) against the FakeHueBridge
// simulator. macOS only: the simulator dependency is skipped on Linux (see Package.swift) and the
// transport needs URLSession + Security.
#if canImport(Simulators) && canImport(Darwin)
import Foundation
import HueCodec
import LightCore
import NetKit
import Simulators
import Testing

@testable import HueKit

@Suite("HueProvider against FakeHueBridge", .serialized, .timeLimit(.minutes(2)))
struct FakeHueBridgeIntegrationTests {
    typealias S = FakeHueBridge.SeedID
    static let bridgeID = "001788FFFE000001"

    struct Harness {
        let runner: SimulatorRunner
        let bridge: FakeHueBridge
        let provider: HueProvider
        let secrets: InMemorySecretStore
        let pins: InMemoryTOFUPinStore
        let host: String

        func lightID(_ rid: String) -> LightID { HueIdentifiers.lightID(bridgeID: bridge.bridgeId, resourceID: rid)! }
    }

    static func withBridge(
        autoConnect: Bool = false, _ body: (Harness) async throws -> Void
    ) async throws {
        let runner = SimulatorRunner()
        let bridge = try await runner.start(try FakeHueBridge(.init(httpsPort: 0, bridgeId: bridgeID)))
        let port = try #require(bridge.httpsPort)
        let secrets = InMemorySecretStore()
        let pins = InMemoryTOFUPinStore()
        var config = HueProvider.Configuration()
        config.autoConnectEvents = autoConnect
        config.pairingPollInterval = .milliseconds(100)
        let provider = HueProvider(secrets: secrets, pinStore: pins, configuration: config)
        let harness = Harness(runner: runner, bridge: bridge, provider: provider, secrets: secrets, pins: pins, host: "127.0.0.1:\(port)")
        do {
            try await body(harness)
        } catch {
            await provider.disconnectEventStreams()
            try? await runner.stopAll()
            throw error
        }
        await provider.disconnectEventStreams()
        try await runner.stopAll()
    }

    /// Pairs through the real flow (link button pressed by the "user" before confirming).
    static func pair(_ h: Harness) async throws -> PairedDevice {
        h.bridge.pressLinkButton()
        let device = DiscoveredDevice(id: "ip:127.0.0.1", brand: .hue, name: "Fake", host: h.host, method: .manual)
        return try await h.provider.pair(device, using: ScriptedPairingInteraction([.confirm(true)]))
    }

    @Test func discoverManualHostProbesConfigOverTLS() async throws {
        try await Self.withBridge { h in
            var found: [DiscoveredDevice] = []
            let options = DiscoveryOptions(timeout: .seconds(5), methods: [.manual], manualHosts: [h.host])
            for await device in await h.provider.discover(options: options) { found.append(device) }
            #expect(found.map(\.id) == [Self.bridgeID])
            #expect(found.first?.model == "BSB002")
            #expect(found.first?.metadata["scheme"] == "https")
        }
    }

    @Test func pairStoresKeysAndPinsSelfSignedCertificate() async throws {
        try await Self.withBridge { h in
            let paired = try await Self.pair(h)
            #expect(paired.id == Self.bridgeID)
            let appKey = try await h.secrets.string(for: HueProvider.appKeySecret(bridgeID: Self.bridgeID))
            #expect(appKey.map { h.bridge.appKeys[$0] != nil } == true)
            #expect(try await h.secrets.string(for: HueProvider.clientKeySecret(bridgeID: Self.bridgeID))?.count == 32)
            #expect(await h.pins.pin(for: Self.bridgeID) != nil)
        }
    }

    @Test func pairWaitsForLinkButton() async throws {
        try await Self.withBridge { h in
            let device = DiscoveredDevice(id: Self.bridgeID, brand: .hue, name: "Fake", host: h.host, method: .manual)
            let bridge = h.bridge
            let presser = Task {
                try await Task.sleep(for: .milliseconds(400))
                bridge.pressLinkButton()
            }
            let paired = try await h.provider.pair(device, using: ScriptedPairingInteraction([.confirm(true)]))
            _ = try await presser.value
            #expect(paired.id == Self.bridgeID)
        }
    }

    @Test func listToggleColourAndScene() async throws {
        try await Self.withBridge { h in
            _ = try await Self.pair(h)
            let lights = try await h.provider.loadLights()
            #expect(lights.count == 3)
            let living = try #require(lights.first { $0.id == h.lightID(S.colorLight) })
            #expect(living.roomHint == "Living room")
            #expect(living.capabilities.gamut == .hueC)

            try await h.provider.send(.turnOff, to: h.lightID(S.colorLight))
            #expect(h.bridge.resource(type: "light", id: S.colorLight)?["on"]?["on"]?.boolValue == false)

            try await h.provider.send(
                LightCommand(on: true, brightness: 0.4, color: .xy(XY(x: 0.3, y: 0.3)), transition: .milliseconds(800)),
                to: h.lightID(S.colorLight))
            let light = try #require(h.bridge.resource(type: "light", id: S.colorLight))
            #expect(light["on"]?["on"]?.boolValue == true)
            #expect(light["dimming"]?["brightness"]?.doubleValue == 40)
            #expect(light["color"]?["xy"]?["x"]?.doubleValue == 0.3)
            #expect(h.bridge.lastTransitionDuration(lightId: S.colorLight) == 800)

            try await h.provider.send(LightCommand(color: .kelvin(2700)), to: h.lightID(S.ambianceLight))
            #expect(h.bridge.resource(type: "light", id: S.ambianceLight)?["color_temperature"]?["mirek"]?.intValue == 370)

            let scenes = try await h.provider.scenes()
            let relax = try #require(scenes.first { $0.name == "Relax" })
            try await h.provider.recall(relax.id)
            #expect(h.bridge.resource(type: "scene", id: S.relaxScene)?["status"]?["active"]?.stringValue == "static")
        }
    }

    @Test func sendGroupUsesGroupedLight() async throws {
        try await Self.withBridge { h in
            _ = try await Self.pair(h)
            _ = try await h.provider.loadLights()
            try await h.provider.sendGroup(
                LightCommand(on: true, brightness: 0.2), to: [h.lightID(S.colorLight), h.lightID(S.ambianceLight)])
            for id in [S.colorLight, S.ambianceLight] {
                let light = try #require(h.bridge.resource(type: "light", id: id))
                #expect(light["on"]?["on"]?.boolValue == true)
            }
        }
    }

    @Test func externalChangeArrivesViaEventStream() async throws {
        try await Self.withBridge(autoConnect: true) { h in
            _ = try await Self.pair(h)
            let collector = Collector(h.provider.events)
            _ = try await h.provider.loadLights()
            let connected = await collector.wait { $0 == .connectionChanged(connected: true, detail: nil) }
            #expect(connected != nil)
            try h.bridge.externalUpdate(type: "light", id: S.whiteLight, body: ["on": ["on": false]])
            let start = ContinuousClock.now
            let changed = await collector.wait {
                if case .stateChanged(let id, let state) = $0 { return id == h.lightID(S.whiteLight) && !state.isOn }
                return false
            }
            #expect(changed != nil)
            #expect(ContinuousClock.now - start < .seconds(1))
        }
    }

    @Test func wrongCertificateIdentityIsRejected() async throws {
        try await Self.withBridge { h in
            // Pretend the stored bridge id differs from the certificate CN.
            let secrets = InMemorySecretStore()
            try await secrets.set("whatever", for: HueProvider.appKeySecret(bridgeID: "001788FFFE0000FF"))
            var config = HueProvider.Configuration()
            config.autoConnectEvents = false
            let provider = HueProvider(secrets: secrets, pinStore: InMemoryTOFUPinStore(), configuration: config)
            await provider.addBridge(PairedDevice(id: "001788FFFE0000FF", brand: .hue, name: "Impostor", hostHint: h.host))
            await #expect(throws: LightCoreError.self) { _ = try await provider.loadLights() }
        }
    }
}

/// Minimal event collector (the mock-transport suite has its own).
final class Collector: Sendable {
    private let box = LockedEvents()
    init(_ stream: AsyncStream<ProviderEvent>) {
        let box = self.box
        Task { for await event in stream { await box.append(event) } }
    }

    func wait(timeout: Duration = .seconds(5), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let hit = await box.first(where: predicate) { return hit }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

actor LockedEvents {
    private var events: [ProviderEvent] = []
    func append(_ e: ProviderEvent) { events.append(e) }
    func first(where predicate: @Sendable (ProviderEvent) -> Bool) -> ProviderEvent? { events.first(where: predicate) }
}
#endif
