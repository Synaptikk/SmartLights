import Foundation
import LightCore
import ShellyCodec
import Testing
@testable import ShellyProvider

// MARK: - Helpers

private func testConfig() -> ShellyProvider.Configuration {
    ShellyProvider.Configuration(
        requestTimeout: .milliseconds(300),
        retries: 1,
        sweepTimeout: .milliseconds(100),
        sweepDelay: .milliseconds(100),
        pollInterval: .milliseconds(100),
        clientID: "smartlights-test"
    )
}

private func collect(_ stream: AsyncStream<DiscoveredDevice>) async -> [DiscoveredDevice] {
    var out: [DiscoveredDevice] = []
    for await d in stream { out.append(d) }
    return out
}

private func discoverManual(_ provider: ShellyProvider, _ ip: String) async throws -> DiscoveredDevice {
    let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: [ip])))
    return try #require(found.first)
}

private func rgbwPlus(_ ip: String = "10.0.1.10", mac: String = "a0a3b3c4d5e6", password: String? = nil) -> FakeShellyDevice {
    FakeShellyDevice(gen2: ip, mac: mac, password: password,
                     components: ["rgbw:0": ["id": 0, "source": "init", "output": true, "brightness": 40, "rgb": [255, 0, 0], "white": 0]],
                     config: ["rgbw:0": ["id": 0, "name": "Kitchen strip"]])
}

private func duo(_ ip: String = "10.0.1.20", mac: String = "a4cf12f3f1b2", password: String? = nil) -> FakeShellyDevice {
    FakeShellyDevice(gen1: ip, mac: mac, type: "SHBDUO-1", password: password,
                     settings: ["name": "Hall", "lights": [["name": ""]]],
                     lights: [["ison": false, "brightness": 60, "white": 0, "temp": 2700, "transition": 0]])
}

/// Collects provider events in the background.
private actor EventLog {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { for await e in stream { self.append(e) } }
    }

    private func append(_ e: ProviderEvent) { events.append(e) }

    func waitFor(timeout: Duration = .seconds(3), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if events.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events.contains(where: predicate)
    }
}

// MARK: - Tests

@Suite("ShellyProvider against in-process fake devices", .serialized)
struct ShellyProviderTests {
    @Test func bonjourDiscoveryFiltersHTTPServices() async {
        let strip = rgbwPlus()
        let bulb = duo()
        let net = FakeShellyNetwork([strip, bulb], bonjour: [
            ShellyBonjourHit(name: "shellyplusrgbwpm-a0a3b3c4d5e6", type: "_shelly._tcp", host: strip.ip, port: 80, txt: ["gen": "2"]),
            ShellyBonjourHit(name: "ShellyBulbDuo-F3F1B2", type: "_http._tcp", host: bulb.ip, port: 80),
            ShellyBonjourHit(name: "LaserJet", type: "_http._tcp", host: "10.0.1.99", port: 80),
        ], sweep: ["10.0.1.10", "10.0.1.20"])
        let provider = ShellyProvider(configuration: testConfig(), environment: net.environment)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2))))
        #expect(Set(found.map(\.id)) == ["a0a3b3c4d5e6", "a4cf12f3f1b2"])
        #expect(found.allSatisfy { $0.method == .bonjour })   // Bonjour answered: no sweep
        let s = found.first { $0.id == "a0a3b3c4d5e6" }
        #expect(s?.metadata["gen"] == "2" && s?.metadata["app"] == "PlusRGBWPM" && s?.model == "Shelly PlusRGBWPM")
        #expect(found.first { $0.id == "a4cf12f3f1b2" }?.model == "Shelly Duo (SHBDUO-1)")
    }

    @Test func sweepWhenBonjourIsSilent() async {
        let bulb = duo()
        let net = FakeShellyNetwork([bulb], bonjour: [], sweep: ["10.0.1.19", "10.0.1.20", "10.0.1.21"])
        let provider = ShellyProvider(configuration: testConfig(), environment: net.environment)
        let found = await collect(await provider.discover(options: DiscoveryOptions(timeout: .seconds(2))))
        #expect(found.map(\.id) == ["a4cf12f3f1b2"])
        #expect(found.first?.method == .sweep)
        #expect(bulb.requests == ["GET /shelly"])
    }

    @Test func pairGen2WithoutPassword() async throws {
        let strip = rgbwPlus()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let paired = try await provider.pair(try await discoverManual(provider, strip.ip), using: ScriptedPairingInteraction([]))
        #expect(paired.id == "a0a3b3c4d5e6")
        #expect(paired.lightIDs.map(\.rawValue) == ["shelly:a0a3b3c4d5e6"])
        #expect(paired.metadata["gen"] == "2")
        let light = try #require(try await provider.loadLights().first)
        #expect(light.name == "Kitchen strip")
        #expect(light.capabilities.supportedColorModes == [.rgbw])
        #expect(light.state.isOn && light.state.brightness == 0.4)
        #expect(light.state.rgbw == RGBW(r: 255, g: 0, b: 0, w: 0))
        #expect(strip.requests.contains("POST /rpc"))
    }

    @Test func sendsOneRPCSetWithBrightnessAndColour() async throws {
        let strip = rgbwPlus()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let paired = try await provider.pair(try await discoverManual(provider, strip.ip), using: ScriptedPairingInteraction([]))
        let id = try #require(paired.lightIDs.first)
        let before = strip.requests.count
        try await provider.send(LightCommand(brightness: 0.75, color: .rgbw(RGBW(r: 0, g: 0, b: 255, w: 30))), to: id)
        #expect(strip.requests.count == before + 1)
        let s = try #require(strip.status("rgbw:0"))
        #expect(s["output"]?.bool == true && s["brightness"]?.int == 75 && s["white"]?.int == 30)
        #expect(s["rgb"] == [0, 0, 255])
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let st) = e { return lid == id && st.brightness == 0.75 }
            return false
        })
        try await provider.send(.turnOff, to: id)
        #expect(strip.status("rgbw:0")?["output"]?.bool == false)
    }

    @Test func gen2DigestPasswordPromptRetryAndKeychain() async throws {
        let strip = rgbwPlus(password: "s3cret")
        let secrets = InMemorySecretStore()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment, secretStore: secrets)
        let device = try await discoverManual(provider, strip.ip)
        #expect(device.metadata["auth"] == "true")
        // First password wrong, second right.
        let ui = ScriptedPairingInteraction([.text("wrong"), .text("s3cret")])
        let paired = try await provider.pair(device, using: ui)
        let prompts = await ui.prompts
        #expect(prompts.filter { $0.hasPrefix("Password for") }.count == 2)
        #expect(prompts.contains { $0.contains("username admin") })
        #expect(strip.authFailures == 1)
        #expect(try await secrets.string(for: ShellyProvider.passwordKey(mac: "a0a3b3c4d5e6")) == "s3cret")
        #expect(paired.metadata["username"] == "admin")
        // Authenticated control.
        try await provider.send(LightCommand(brightness: 0.1), to: try #require(paired.lightIDs.first))
        #expect(strip.status("rgbw:0")?["brightness"]?.int == 10)
        #expect(strip.authFailures == 1)
    }

    @Test func gen2PairingGivesUpAfterThreeWrongPasswords() async throws {
        let strip = rgbwPlus(password: "right")
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let device = try await discoverManual(provider, strip.ip)
        let ui = ScriptedPairingInteraction([.text("a"), .text("b"), .text("c")])
        await #expect(throws: LightCoreError.authenticationRequired(.shelly)) { _ = try await provider.pair(device, using: ui) }
    }

    @Test func staleNonceIsRefreshedTransparently() async throws {
        let strip = rgbwPlus(password: "pw")
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let paired = try await provider.pair(try await discoverManual(provider, strip.ip), using: ScriptedPairingInteraction([.text("pw")]))
        strip.rotateNonce("7a1b2c3d")
        try await provider.send(LightCommand(brightness: 1), to: try #require(paired.lightIDs.first))
        #expect(strip.status("rgbw:0")?["brightness"]?.int == 100)
        #expect(strip.authFailures == 0)
    }

    @Test func gen1DuoWithBasicAuth() async throws {
        let bulb = duo(password: "pw1")
        let secrets = InMemorySecretStore()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([bulb]).environment, secretStore: secrets)
        let ui = ScriptedPairingInteraction([.text("admin"), .text("pw1")])
        let paired = try await provider.pair(try await discoverManual(provider, bulb.ip), using: ui)
        let prompts = await ui.prompts.filter { !$0.hasPrefix("Contacting") }
        #expect(prompts.first?.hasPrefix("Username for") == true)
        #expect(prompts.dropFirst().first?.hasPrefix("Password for") == true)
        let id = try #require(paired.lightIDs.first)
        #expect(paired.name == "Hall")
        let light = try #require(try await provider.loadLights().first)
        #expect(light.capabilities.supportedColorModes == [.colorTemp])
        #expect(light.capabilities.kelvinRange == 2700...6500)
        #expect(!light.state.isOn && light.state.kelvin == 2700)
        try await provider.send(LightCommand(brightness: 0.5, color: .kelvin(5000), transition: .milliseconds(400)), to: id)
        #expect(bulb.requests.last == "GET /light/0?turn=on&brightness=50&temp=5000&transition=400")
        #expect(bulb.gen1Light(0)?["ison"]?.bool == true && bulb.gen1Light(0)?["temp"]?.int == 5000)
        #expect(bulb.authFailures == 0)
    }

    @Test func gen1RGBW2WhiteModeExposesFourLights() async throws {
        let ctrl = FakeShellyDevice(gen1: "10.0.1.30", mac: "e8db84aabbcc", type: "SHRGBW2",
                                    settings: ["mode": "white", "lights": [["name": "A"], ["name": ""], ["name": ""], ["name": ""]]],
                                    lights: (0..<4).map { _ in ["ison": true, "brightness": 20] })
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([ctrl]).environment)
        let paired = try await provider.pair(try await discoverManual(provider, ctrl.ip), using: ScriptedPairingInteraction([]))
        #expect(paired.lightIDs.map(\.rawValue) == ["shelly:e8db84aabbcc", "shelly:e8db84aabbcc-white1",
                                                    "shelly:e8db84aabbcc-white2", "shelly:e8db84aabbcc-white3"])
        let lights = try await provider.loadLights()
        #expect(lights.map(\.name) == ["A", "Shelly RGBW2 (SHRGBW2) AABBCC 2", "Shelly RGBW2 (SHRGBW2) AABBCC 3", "Shelly RGBW2 (SHRGBW2) AABBCC 4"])
        try await provider.send(.turnOff, to: paired.lightIDs[2])
        #expect(ctrl.requests.last == "GET /white/2?turn=off")
        #expect(ctrl.gen1Light(2)?["ison"]?.bool == false)
    }

    @Test func webSocketNotificationsWithAuth() async throws {
        let strip = rgbwPlus(password: "pw")
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip], webSockets: true).environment)
        let log = EventLog()
        await log.start(provider.events)
        let paired = try await provider.pair(try await discoverManual(provider, strip.ip), using: ScriptedPairingInteraction([.text("pw")]))
        let id = try #require(paired.lightIDs.first)
        await provider.start()
        #expect(await log.waitFor { e in
            if case .connectionChanged(true, let detail) = e { return detail?.contains("notifications") == true }
            return false
        })
        // Wait until the authenticated GetStatus went through, then change the light from "the Shelly app".
        try await Task.sleep(for: .milliseconds(100))
        strip.externalChange("rgbw:0", ["output": false])
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let s) = e { return lid == id && !s.isOn }
            return false
        })
        #expect(await provider.hasNotificationSocket(id))
        let requestsBefore = strip.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(strip.requests.count == requestsBefore)   // no HTTP polling while the socket is live
        await provider.stop()
        #expect(strip.socketCount == 0)
    }

    @Test func pollingFallbackForGen1() async throws {
        let bulb = duo()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([bulb], webSockets: true).environment)
        let log = EventLog()
        await log.start(provider.events)
        let paired = try await provider.pair(try await discoverManual(provider, bulb.ip), using: ScriptedPairingInteraction([]))
        let id = try #require(paired.lightIDs.first)
        await provider.start()
        bulb.externalGen1Change(0, ["ison": true, "brightness": 90])
        #expect(await log.waitFor { e in
            if case .stateChanged(let lid, let s) = e { return lid == id && s.isOn && s.brightness == 0.9 }
            return false
        })
        await provider.stop()
    }

    @Test func offlineDeviceBecomesUnreachable() async throws {
        let strip = rgbwPlus()
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let log = EventLog()
        await log.start(provider.events)
        let paired = try await provider.pair(try await discoverManual(provider, strip.ip), using: ScriptedPairingInteraction([]))
        let id = try #require(paired.lightIDs.first)
        strip.setOffline(true)
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOn, to: id) }
        #expect(await log.waitFor { e in
            if case .reachabilityChanged(let lid, false) = e { return lid == id }
            return false
        })
        #expect(try await provider.loadLights().first?.state.reachable == false)
        strip.setOffline(false)
        #expect(try await provider.loadLights().first?.state.reachable == true)
    }

    @Test func restoreUsesStoredChannelsAndPassword() async throws {
        let strip = rgbwPlus(password: "pw")
        let secrets = InMemorySecretStore()
        let first = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment, secretStore: secrets)
        let paired = try await first.pair(try await discoverManual(first, strip.ip), using: ScriptedPairingInteraction([.text("pw")]))

        // App relaunch: new provider, same Keychain, device record from DeviceStore.
        let second = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment, secretStore: secrets)
        await second.restore([paired])
        let lights = try await second.loadLights()
        #expect(lights.map(\.id) == paired.lightIDs)
        #expect(lights.first?.state.reachable == true)
        try await second.send(LightCommand(brightness: 0.3), to: paired.lightIDs[0])
        #expect(strip.status("rgbw:0")?["brightness"]?.int == 30)
    }

    @Test func rejectedStoredPasswordAsksForReauthentication() async throws {
        let strip = rgbwPlus(password: "new")
        let secrets = InMemorySecretStore([ShellyProvider.passwordKey(mac: "a0a3b3c4d5e6"): Data("old".utf8)])
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment, secretStore: secrets)
        let log = EventLog()
        await log.start(provider.events)
        await provider.restore([PairedDevice(id: "a0a3b3c4d5e6", brand: .shelly, name: "Strip", hostHint: strip.ip, port: 80,
                                             metadata: ["gen": "2", "model": "SNDC-0D4P10WW", "auth": "true",
                                                        "deviceID": strip.deviceID])])
        _ = try await provider.loadLights()
        #expect(await log.waitFor { e in
            if case .needsReauthentication(let account) = e { return account == "a0a3b3c4d5e6" }
            return false
        })
    }

    @Test func addByIPAsksForAddress() async throws {
        let strip = rgbwPlus("10.0.1.77")
        let provider = ShellyProvider(configuration: testConfig(), environment: FakeShellyNetwork([strip]).environment)
        let paired = try await provider.pair(DiscoveredDevice(id: "manual", brand: .shelly, name: "Shelly", method: .manual),
                                             using: ScriptedPairingInteraction([.text("10.0.1.77")]))
        #expect(paired.id == "a0a3b3c4d5e6" && paired.hostHint == "10.0.1.77")
        await #expect(throws: LightCoreError.self) {
            _ = try await provider.pair(DiscoveredDevice(id: "manual", brand: .shelly, name: "Shelly", method: .manual),
                                        using: ScriptedPairingInteraction([.text("10.0.1.200")]))
        }
    }
}
