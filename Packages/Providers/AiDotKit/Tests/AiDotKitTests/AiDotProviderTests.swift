import AiDotCodec
import Foundation
import LightCore
import NetKit
import Simulators
import Synchronization
import Testing

@testable import AiDotKit

/// Collects provider events (single consumer) for assertions.
final class EventLog: Sendable {
    private let storage = SendableBox()
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

    deinit { task.cancel() }
}

final class SendableBox: Sendable {
    private let m = Mutex<[ProviderEvent]>([])
    func append(_ e: ProviderEvent) { m.withLock { $0.append(e) } }
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

struct Harness {
    let runner: SimulatorRunner
    let device: FakeAiDotDevice
    let cloud: FakeAiDotCloud
    let store: InMemorySecretStore
    let provider: AiDotProvider
    let events: EventLog

    static let usIndex = AiDotCountry.sortedByName.firstIndex { $0.code == "US" }!

    static func make(cloudConfig: FakeAiDotCloud.Configuration = .init(), ping: Duration = .seconds(30)) async throws -> Harness {
        let runner = SimulatorRunner()
        let device = try await runner.start(FakeAiDotDevice())
        let cloud = try await runner.start(FakeAiDotCloud(cloudConfig, devices: [device]))
        var config = AiDotProvider.Configuration()
        config.baseURLOverride = URL(string: try #require(cloud.baseURL))
        config.tcpPort = UInt16(try #require(device.tcpPort))
        config.discoveryPort = UInt16(try #require(device.discoveryPort))
        config.reconnectBackoff = ExponentialBackoff(initial: .milliseconds(100), multiplier: 2, maximum: .seconds(1))
        config.pingInterval = ping
        config.maintenanceInterval = .seconds(3600)
        let store = InMemorySecretStore()
        let provider = AiDotProvider(secretStore: store, configuration: config)
        return Harness(runner: runner, device: device, cloud: cloud, store: store, provider: provider,
                       events: EventLog(provider.events))
    }

    func signIn(username: String = "user@example.com", password: String = "s3cret-pw") async throws -> PairedDevice {
        let ui = ScriptedPairingInteraction([.choice(Self.usIndex), .text(username), .text(password)])
        return try await provider.pair(AiDotProvider.accountPlaceholder(), using: ui)
    }

    var lightID: LightID { LightID(brand: .aidot, stableId: device.info.id)! }

    func shutdown() async {
        await provider.stop()
        try? await runner.stopAll()
    }
}

@Suite("AiDotProvider against FakeAiDotCloud/FakeAiDotDevice", .serialized)
struct AiDotProviderTests {
    @Test func signInStoresTokensNotPassword() async throws {
        let h = try await Harness.make()
        let paired = try await h.signIn()
        #expect(paired.lightIDs == [h.lightID])
        #expect(paired.accountID == "user@example.com")
        let account = try #require(await h.provider.account)
        #expect(account.displayName == "us***@example.com")
        #expect(account.region == "US")
        func secret(_ item: String) async throws -> String? {
            try await h.store.string(for: SecretKey(brand: .aidot, owner: "user@example.com", item: item))
        }
        #expect(try await secret("accessToken") == h.cloud.currentAccessToken)
        #expect(try await secret("refreshToken") == h.cloud.currentRefreshToken)
        #expect(try await secret("userId") == h.device.info.ownerUserId)
        #expect(try await secret("password") == nil)
        let cache = try #require(try await secret("deviceCache"))
        #expect(cache.contains(h.device.info.id))
        for item in AiDotProvider.SecretItem.all {
            #expect(!(try await secret(item) ?? "").contains("s3cret-pw"))
        }
        // Pairing a discovered light returns that light.
        let one = try await h.provider.pair(
            DiscoveredDevice(id: h.device.info.id, brand: .aidot, name: "x", method: .broadcast),
            using: ScriptedPairingInteraction([]))
        #expect(one.id == h.device.info.id && one.lightIDs == [h.lightID])
        #expect(h.cloud.loginCount == 1)
        await h.shutdown()
    }

    @Test func wrongPasswordIsReported() async throws {
        let h = try await Harness.make()
        await #expect(throws: AiDotCloudError.badCredentials) { _ = try await h.signIn(username: "wrong@example.com") }
        #expect(await h.provider.account == nil)
        #expect(await h.store.count == 1) // only the terminal id
        await h.shutdown()
    }

    @Test func sharedHousesAreSkipped() async throws {
        var cfg = FakeAiDotCloud.Configuration()
        cfg.includeSharedHouse = true
        let h = try await Harness.make(cloudConfig: cfg)
        _ = try await h.signIn()
        #expect(h.cloud.requestLog.contains { $0.contains("houseId=h-0001") })
        #expect(!h.cloud.requestLog.contains { $0.contains("houseId=h-shared") })
        await h.shutdown()
    }

    @Test func loadLightsConnectsAndControlsOverTCP() async throws {
        let h = try await Harness.make()
        _ = try await h.signIn()
        let lights = try await h.provider.loadLights()
        let light = try #require(lights.first)
        #expect(lights.count == 1)
        #expect(light.id == h.lightID)
        #expect(light.capabilities.supportedColorModes == [.rgbw, .colorTemp])
        #expect(light.capabilities.kelvinRange == 2700...6500)
        #expect(light.model == "LK.light.A001493")
        let id = h.lightID
        #expect(await h.events.wait { $0 == .reachabilityChanged(id, reachable: true) })
        #expect(await eventually { h.device.loggedInSessionCount == 1 })

        // Brightness + colour in one setDevAttrReq.
        try await h.provider.send(LightCommand(brightness: 0.4, color: .rgb(RGB(r: 0, g: 0, b: 255))), to: id)
        #expect(await eventually { h.device.lightState.dimming == 40 })
        #expect(h.device.lightState.rgbw == AiDotConstants.packRGBW(r: 0, g: 0, b: 255, w: 0))
        let sets = h.device.receivedMessages.filter { $0.json["method"]?.stringValue == "setDevAttrReq" }
        #expect(sets.count == 1)

        try await h.provider.send(LightCommand(color: .kelvin(9000)), to: id)
        #expect(await eventually { h.device.lightState.cct == 6500 }) // clamped to the product range

        // Status push from the device (AiDot app / wall switch).
        h.device.externalChange(["OnOff": 0])
        #expect(await h.events.wait {
            if case .stateChanged(let lid, let state) = $0 { return lid == id && !state.isOn }
            return false
        })

        // Session drop -> unreachable -> reconnect.
        h.device.disconnectAll()
        #expect(await h.events.wait { $0 == .reachabilityChanged(id, reachable: false) })
        #expect(await eventually { h.device.loggedInSessionCount == 1 })
        #expect(await h.events.wait(timeout: .seconds(10)) { _ in
            h.events.all.filter { $0 == .reachabilityChanged(id, reachable: true) }.count >= 2
        })
        try await h.provider.send(.turnOn, to: id)
        #expect(await eventually { h.device.lightState.onOff == 1 })
        await h.shutdown()
    }

    @Test func keepalivePingsAreSentAndAnswered() async throws {
        let h = try await Harness.make(ping: .milliseconds(200))
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()
        #expect(await eventually {
            h.device.receivedMessages.filter { $0.msgType == 2 && $0.json["method"]?.stringValue == "pingreq" }.count >= 4
        })
        // Pings are answered, so the session stays up (no reset after 3 pings).
        #expect(!h.events.all.contains(.reachabilityChanged(h.lightID, reachable: false)))
        await h.shutdown()
    }

    @Test func stopAndStartCloseAndReopenSessions() async throws {
        let h = try await Harness.make()
        _ = try await h.signIn()
        _ = try await h.provider.loadLights()
        #expect(await eventually { h.device.loggedInSessionCount == 1 })
        await h.provider.stop()
        #expect(await eventually { h.device.loggedInSessionCount == 0 })
        await #expect(throws: LightCoreError.self) { try await h.provider.send(.turnOff, to: h.lightID) }
        await h.provider.start()
        #expect(await eventually { h.device.loggedInSessionCount == 1 })
        await h.shutdown()
    }

    @Test func unicastDiscoveryFindsDevice() async throws {
        let h = try await Harness.make()
        _ = try await h.signIn()
        let options = DiscoveryOptions(timeout: .seconds(3), methods: [.cached, .manual], broadcastAvailable: false,
                                       manualHosts: ["127.0.0.1"])
        var found: [DiscoveredDevice] = []
        for await d in h.provider.discover(options: options) { found.append(d) }
        let d = try #require(found.first)
        #expect(found.count == 1)
        #expect(d.id == h.device.info.id)
        #expect(d.host == "127.0.0.1")
        #expect(d.method == .manual)
        #expect(d.name == "Bedroom bulb")
        #expect(d.metadata["productModel"] == "LK.light.A001493")
        #expect(h.device.discoveryRequestCount >= 1)
        await h.shutdown()
    }

    @Test func tokenRefreshAndReauthentication() async throws {
        let h = try await Harness.make()
        _ = try await h.signIn()
        h.cloud.expireAccessTokens()
        try await h.provider.refreshDeviceList() // 21026 -> refresh -> retry
        #expect(h.cloud.loginCount == 1)
        #expect(try await h.store.string(for: SecretKey(brand: .aidot, owner: "user@example.com", item: "accessToken"))
            == h.cloud.currentAccessToken)

        h.cloud.expireAccessTokens()
        h.cloud.invalidateRefreshTokens()
        await #expect(throws: LightCoreError.authenticationRequired(.aidot)) { try await h.provider.refreshDeviceList() }
        #expect(await h.events.wait { $0 == .needsReauthentication(accountID: "user@example.com") })

        // Cached keys keep LAN control working while signed out of the cloud.
        let lights = try await h.provider.loadLights()
        #expect(lights.count == 1)
        #expect(await eventually { h.device.loggedInSessionCount == 1 })
        await h.shutdown()
    }

    @Test func restoresFromKeychainWithoutCloud() async throws {
        let h = try await Harness.make()
        _ = try await h.signIn()
        let account = try #require(await h.provider.account)
        var config = AiDotProvider.Configuration()
        config.baseURLOverride = URL(string: "http://127.0.0.1:9/v35") // cloud unreachable
        config.tcpPort = UInt16(try #require(h.device.tcpPort))
        let restored = AiDotProvider(account: account, secretStore: h.store, configuration: config)
        let lights = try await restored.loadLights()
        #expect(lights.map(\.id) == [h.lightID])
        #expect(await eventually { h.device.loggedInSessionCount == 1 })
        try await restored.send(LightCommand(brightness: 0.25), to: h.lightID)
        #expect(await eventually { h.device.lightState.dimming == 25 })
        await restored.stop()
        await h.shutdown()
    }
}

/// A device that accepts the login and then never answers again (keepalive test).
struct SilentAfterLoginConnector: AiDotTCPConnector {
    let codec: AiDotSessionCodec
    let pings = SendableCounter()

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any AiDotTCPConnection {
        SilentConnection(codec: codec, pings: pings)
    }
}

final class SendableCounter: Sendable {
    private let m = Mutex(0)
    func increment() { m.withLock { $0 += 1 } }
    var value: Int { m.withLock { $0 } }
}

final class SilentConnection: AiDotTCPConnection {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let codec: AiDotSessionCodec
    private let pings: SendableCounter
    private let sent = Mutex(0)

    init(codec: AiDotSessionCodec, pings: SendableCounter) {
        self.codec = codec
        self.pings = pings
        (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func send(_ data: Data) async throws {
        let n = sent.withLock { $0 += 1; return $0 }
        if n == 1 {
            let ack: AiDotJSON = .obj(["service": "device", "method": "loginResp", "ack": .obj(["code": 200]),
                                       "payload": .obj(["ascNumber": 3])])
            continuation.yield(try codec.frame(ack))
        } else if data.count > 3, data[data.startIndex + 3] == 2 {
            pings.increment()
        }
    }

    func close() { continuation.finish() }
}

@Suite("AiDot session keepalive")
struct KeepaliveTests {
    @Test func threeMissedPingsMarkUnreachable() async throws {
        let runner = SimulatorRunner()
        let device = try await runner.start(FakeAiDotDevice())
        let cloud = try await runner.start(FakeAiDotCloud(devices: [device]))
        var config = AiDotProvider.Configuration()
        config.baseURLOverride = URL(string: try #require(cloud.baseURL))
        config.pingInterval = .milliseconds(100)
        config.reconnectBackoff = ExponentialBackoff(initial: .seconds(30))
        let connector = SilentAfterLoginConnector(codec: AiDotSessionCodec(aesKey: device.info.aesKey))
        config.tcp = connector
        let provider = AiDotProvider(secretStore: InMemorySecretStore(), configuration: config)
        let events = EventLog(provider.events)
        _ = try await provider.pair(AiDotProvider.accountPlaceholder(), using: ScriptedPairingInteraction(
            [.choice(Harness.usIndex), .text("user@example.com"), .text("pw")]))
        _ = try await provider.loadLights()
        let id = LightID(brand: .aidot, stableId: device.info.id)!
        #expect(await events.wait { $0 == .reachabilityChanged(id, reachable: true) })
        #expect(await events.wait(timeout: .seconds(5)) { $0 == .reachabilityChanged(id, reachable: false) })
        #expect(connector.pings.value == 3)
        await provider.stop()
        try await runner.stopAll()
    }
}

@Suite("AiDotProvider helpers")
struct ProviderHelperTests {
    @Test func masking() {
        #expect(AiDotProvider.mask("john@example.com") == "jo***@example.com")
        #expect(AiDotProvider.mask("x") == "x***")
    }
}
