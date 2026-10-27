import Foundation
import LightCore
import NetKit
import Synchronization
import Testing
import TuyaCodec

@testable import TuyaKit

/// Collects provider events (single consumer) for assertions.
final class EventLog: Sendable {
    private let storage = EventBox()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<ProviderEvent>) {
        let storage = storage
        task = Task { for await e in stream { storage.append(e) } }
    }

    var all: [ProviderEvent] { storage.values }

    func wait(timeout: Duration = .seconds(10), _ predicate: @escaping @Sendable (ProviderEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if storage.values.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func clear() { storage.clear() }

    deinit { task.cancel() }
}

final class EventBox: Sendable {
    private let m = Mutex<[ProviderEvent]>([])
    func append(_ e: ProviderEvent) { m.withLock { $0.append(e) } }
    func clear() { m.withLock { $0.removeAll() } }
    var values: [ProviderEvent] { m.withLock { $0 } }
}

func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func isReachable(_ id: LightID, _ value: Bool) -> @Sendable (ProviderEvent) -> Bool {
    { if case .reachabilityChanged(id, let r) = $0 { return r == value } else { return false } }
}

func stateChanged(_ id: LightID, where predicate: @escaping @Sendable (LightState) -> Bool) -> @Sendable (ProviderEvent) -> Bool {
    { if case .stateChanged(id, let s) = $0 { return predicate(s) } else { return false } }
}

struct Harness {
    let device: FakeTuyaDevice
    let store: InMemorySecretStore
    let provider: TuyaProvider
    let events: EventLog

    static let key = "a1B2c3D4e5F6g7H8"

    static func configuration(port: UInt16) -> TuyaProvider.Configuration {
        var config = TuyaProvider.Configuration()
        config.tcpPort = port
        config.connectTimeout = .seconds(2)
        config.responseTimeout = .seconds(2)
        config.heartbeatInterval = .seconds(10)
        config.reconnectBackoff = ExponentialBackoff(initial: .milliseconds(100), multiplier: 2, maximum: .seconds(1))
        config.appBroadcastPort = nil
        config.probeTimeout = .milliseconds(500)
        return config
    }

    static func make(_ version: TuyaVersion, key: String = key, store: InMemorySecretStore = InMemorySecretStore(),
                     configure: (inout TuyaProvider.Configuration) -> Void = { _ in }) throws -> Harness {
        let device = try FakeTuyaDevice(localKey: key, version: version)
        var config = configuration(port: device.port)
        configure(&config)
        let provider = TuyaProvider(secretStore: store, configuration: config)
        return Harness(device: device, store: store, provider: provider, events: EventLog(provider.events))
    }

    var lightID: LightID { LightID(brand: .tuya, stableId: device.id)! }

    /// Manual add: explainer, device id, local key, IP, version choice (0 = detect automatically).
    func pairManually(key: String = key, versionChoice: Int = 0) async throws -> PairedDevice {
        let ui = ScriptedPairingInteraction([.confirm(true), .text(device.id), .text(key), .text("127.0.0.1"), .choice(versionChoice)])
        return try await provider.pair(TuyaProvider.manualPlaceholder(), using: ui)
    }

    func waitOnline() async -> Bool { await events.wait(isReachable(lightID, true)) }

    func shutdown() async {
        await provider.stop()
        device.stop()
    }
}

@Suite("TuyaProvider against FakeTuyaDevice", .serialized)
struct TuyaProviderTests {
    @Test(arguments: [TuyaVersion.v33, .v35])
    func manualPairingDetectsVersionAndBulbType(_ version: TuyaVersion) async throws {
        let h = try Harness.make(version)
        let paired = try await h.pairManually()
        #expect(paired.id == h.device.id && paired.lightIDs == [h.lightID])
        #expect(paired.metadata["version"] == version.rawValue)
        #expect(paired.metadata["bulbType"] == "B")
        #expect(!paired.metadata.values.contains(Harness.key))
        // The key is only in the secret store.
        let stored = try #require(try await h.store.string(for: SecretKey(brand: .tuya, owner: "local", item: "devices")))
        #expect(stored.contains(Harness.key))
        #expect(await h.provider.account?.secretKeys == [SecretKey(brand: .tuya, owner: "local", item: "devices")])

        let lights = try await h.provider.loadLights()
        let light = try #require(lights.first)
        #expect(lights.count == 1 && light.id == h.lightID && light.brand == .tuya)
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(light.state.isOn && light.state.colorMode == .colorTemp && light.state.kelvin == 2700 && light.state.brightness == 1)
        #expect(await h.waitOnline())
        // Auto-detect tried 3.3 first; a 3.5 device drops 55AA frames.
        if version == .v35 { #expect(h.device.snapshot.droppedForBadFrames >= 1) }
        #expect(h.device.snapshot.rejectedConnections == 0)
        await h.shutdown()
    }

    @Test(arguments: [TuyaVersion.v33, .v35])
    func wrongLocalKeyIsRejectedAndNothingIsStored(_ version: TuyaVersion) async throws {
        let h = try Harness.make(version)
        let choice = version == .v35 ? 1 : 3 // options: auto, 3.5, 3.4, 3.3, 3.1
        await #expect(throws: LightCoreError.self) {
            _ = try await h.pairManually(key: "ZZZZZZZZZZZZZZZZ", versionChoice: choice)
        }
        #expect(try await h.store.data(for: SecretKey(brand: .tuya, owner: "local", item: "devices")) == nil)
        #expect(try await h.provider.loadLights().isEmpty)
        await h.shutdown()
    }

    @Test func pairingCanBeCancelledAtTheExplainer() async throws {
        let h = try Harness.make(.v33)
        let ui = ScriptedPairingInteraction([.confirm(false)])
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await h.provider.pair(TuyaProvider.manualPlaceholder(), using: ui)
        }
        let prompts = await ui.prompts
        #expect(prompts.first == TuyaProvider.advancedExplainer)
        await h.shutdown()
    }

    @Test func badKeyLengthIsAskedAgain() async throws {
        let h = try Harness.make(.v33)
        let ui = ScriptedPairingInteraction([.confirm(true), .text(h.device.id), .text("too-short"), .text(Harness.key),
                                             .text("127.0.0.1"), .choice(3)])
        let paired = try await h.provider.pair(TuyaProvider.manualPlaceholder(), using: ui)
        #expect(paired.metadata["version"] == "3.3")
        await h.shutdown()
    }

    @Test(arguments: [TuyaVersion.v33, .v35])
    func controlSendsOneCommandAndPushesUpdateState(_ version: TuyaVersion) async throws {
        let h = try Harness.make(version)
        _ = try await h.pairManually(versionChoice: version == .v35 ? 1 : 3)
        _ = try await h.provider.loadLights()
        #expect(await h.waitOnline())

        try await h.provider.send(LightCommand(brightness: 0.5, color: .kelvin(4600)), to: h.lightID)
        let controlCommand: TuyaCommand = version == .v35 ? .controlNew : .control
        #expect(await eventually { h.device.requests(controlCommand).count == 1 })
        let sent = try #require(h.device.requests(controlCommand).first)
        #expect(sent.dps == ["20": true, "21": "white", "22": 505, "23": 500])
        #expect(h.device.snapshot.dps["23"] == 500)

        try await h.provider.send(LightCommand(color: .hs(HS(h: 240, s: 1))), to: h.lightID)
        #expect(await eventually { h.device.requests(controlCommand).count == 2 })
        #expect(h.device.requests(controlCommand).last?.dps == ["21": "colour", "24": "00f003e801f9"])
        #expect(await h.events.wait(stateChanged(h.lightID) { $0.colorMode == .hs && $0.hs?.h == 240 }))

        // External change (wall switch / Smart Life) arrives as a STATUS push.
        h.events.clear()
        h.device.externalChange(["20": false])
        #expect(await h.events.wait(stateChanged(h.lightID) { !$0.isOn }))
        await h.shutdown()
    }

    @Test func discoveredDeviceNeedsOnlyTheKey() async throws {
        let udpPort = freeUDPPort()
        let h = try Harness.make(.v35) { config in
            config.discoveryPorts = [udpPort]
            config.broadcastAvailable = true
        }
        let announcement = try TuyaDiscovery.announcement(
            ["ip": "127.0.0.1", "gwId": .string(h.device.id), "active": 2, "encrypt": true, "productKey": "keyabc", "version": "3.5"],
            version: .v35)
        let sender = Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                sendUDP(announcement, port: udpPort)
            }
        }
        var found: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.broadcast], broadcastAvailable: true)) {
            found.append(d)
        }
        sender.cancel()
        let device = try #require(found.first { $0.id == h.device.id })
        #expect(found.filter { $0.id == h.device.id }.count == 1)
        #expect(device.method == .broadcast && device.host == "127.0.0.1" && device.port == Int(h.device.port))
        #expect(device.metadata["version"] == "3.5" && device.model == "keyabc")

        let ui = ScriptedPairingInteraction([.confirm(true), .text(Harness.key)])
        let paired = try await h.provider.pair(device, using: ui)
        #expect(paired.metadata["version"] == "3.5" && paired.model == "keyabc")
        #expect(await ui.prompts.count == 3) // explainer, key, status line
        await h.shutdown()
    }

    @Test func unicastFallbackProbesManualHosts() async throws {
        let h = try Harness.make(.v33)
        var found: [DiscoveredDevice] = []
        let options = DiscoveryOptions(timeout: .seconds(2), methods: [.manual, .broadcast], broadcastAvailable: false,
                                       manualHosts: ["127.0.0.1"])
        for await d in h.provider.discover(options: options) { found.append(d) }
        #expect(found.map(\.id) == ["ip:127.0.0.1"])
        #expect(found.first?.method == .manual)
        // Pairing a provisional device asks for the id but not the IP.
        let ui = ScriptedPairingInteraction([.confirm(true), .text(h.device.id), .text(Harness.key), .choice(0)])
        let paired = try await h.provider.pair(try #require(found.first), using: ui)
        #expect(paired.hostHint == "127.0.0.1")
        await h.shutdown()
    }

    @Test func reconnectsAfterTheConnectionDrops() async throws {
        let h = try Harness.make(.v33)
        _ = try await h.pairManually(versionChoice: 3)
        _ = try await h.provider.loadLights()
        #expect(await h.waitOnline())
        h.events.clear()
        h.device.disconnectClient()
        #expect(await h.events.wait(isReachable(h.lightID, false)))
        #expect(await h.events.wait(isReachable(h.lightID, true)))
        #expect(h.device.snapshot.acceptedConnections >= 3) // pairing probe, session, reconnect
        #expect(h.device.snapshot.rejectedConnections == 0)
        await h.shutdown()
    }

    @Test func heartbeatsKeepTheSessionAndMissedOnesResetIt() async throws {
        let h = try Harness.make(.v35) { $0.heartbeatInterval = .milliseconds(150) }
        _ = try await h.pairManually(versionChoice: 1)
        _ = try await h.provider.loadLights()
        #expect(await h.waitOnline())
        #expect(await eventually { h.device.snapshot.heartbeats >= 3 })
        #expect(h.device.snapshot.acceptedConnections == 2)

        h.events.clear()
        h.device.with { $0.ignoreHeartbeats = true }
        #expect(await h.events.wait(isReachable(h.lightID, false)))
        h.device.with { $0.ignoreHeartbeats = false }
        #expect(await h.events.wait(isReachable(h.lightID, true)))
        #expect(h.device.snapshot.rejectedConnections == 0)
        await h.shutdown()
    }

    @Test func neverOpensASecondConnection() async throws {
        let h = try Harness.make(.v35)
        _ = try await h.pairManually(versionChoice: 1)
        _ = try await h.provider.loadLights()
        #expect(await h.waitOnline())
        // Re-pairing (e.g. after a key change) pauses the running session first.
        _ = try await h.provider.addDevice(id: h.device.id, localKey: Harness.key, host: "127.0.0.1", versions: [.v35], name: "Desk")
        #expect(await h.waitOnline())
        // Discovery skips hosts we are connected to.
        for await _ in h.provider.discover(options: DiscoveryOptions(timeout: .seconds(1), methods: [.cached])) {}
        #expect(h.device.snapshot.rejectedConnections == 0)
        await h.shutdown()
    }

    @Test func stopClosesTheConnectionAndStartReopensIt() async throws {
        let h = try Harness.make(.v33)
        _ = try await h.pairManually(versionChoice: 3)
        _ = try await h.provider.loadLights()
        #expect(await h.waitOnline())
        await h.provider.stop()
        #expect(await eventually { !h.device.snapshot.clientConnected })
        await #expect(throws: LightCoreError.self) { try await h.provider.send(.turnOff, to: h.lightID) }
        await h.provider.start()
        #expect(await eventually { h.device.snapshot.clientConnected })
        #expect(await h.events.wait(isReachable(h.lightID, true)))
        try await h.provider.send(.turnOff, to: h.lightID)
        #expect(await eventually { h.device.snapshot.dps["20"] == false })
        await h.shutdown()
    }

    @Test func restoresFromTheSecretStore() async throws {
        let store = InMemorySecretStore()
        let first = try Harness.make(.v35, store: store)
        _ = try await first.pairManually(versionChoice: 1)
        await first.provider.stop()

        let second = TuyaProvider(secretStore: store, configuration: Harness.configuration(port: first.device.port))
        let events = EventLog(second.events)
        let lights = try await second.loadLights()
        #expect(lights.map(\.id) == [first.lightID])
        #expect(lights.first?.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(await events.wait(isReachable(first.lightID, true)))
        #expect(await second.deviceRecords.first?.version == .v35)
        await second.stop()
        first.device.stop()
    }

    @Test func device22FallbackIsDetectedAndStored() async throws {
        let h = try Harness.make(.v33)
        h.device.with { $0.device22 = true }
        let paired = try await h.pairManually(versionChoice: 3)
        #expect(paired.metadata["deviceType"] == "device22")
        #expect(h.device.requests(.controlNew).first?.dps?["20"]?.isNull == true)
        let light = try #require(try await h.provider.loadLights().first)
        #expect(light.capabilities.supportedColorModes == [.hs, .colorTemp])
        #expect(await h.waitOnline())
        await h.shutdown()
    }

    @Test func removeDeviceForgetsTheKey() async throws {
        let h = try Harness.make(.v33)
        _ = try await h.pairManually(versionChoice: 3)
        try await h.provider.removeDevice(id: h.device.id)
        #expect(try await h.provider.loadLights().isEmpty)
        let stored = try await h.store.string(for: SecretKey(brand: .tuya, owner: "local", item: "devices"))
        #expect(stored == "[]")
        #expect(await h.events.wait { if case .lightRemoved = $0 { true } else { false } })
        #expect(await h.provider.account == nil)
        await h.shutdown()
    }

    @Test func unknownLightAndEffectsAreErrors() async throws {
        let h = try Harness.make(.v33)
        _ = try await h.pairManually(versionChoice: 3)
        let other = LightID(brand: .tuya, stableId: "nope")!
        await #expect(throws: LightCoreError.lightNotFound(other)) { try await h.provider.send(.turnOn, to: other) }
        await #expect(throws: LightCoreError.self) { try await h.provider.send(LightCommand(effect: "party"), to: h.lightID) }
        await h.shutdown()
    }
}
