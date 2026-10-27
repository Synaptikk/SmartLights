import Foundation
import LightCore
import NetKit
import Simulators
import Testing
import WiZCodec

@testable import WiZKit

private let keyHex = "00112233445566778899aabbccddeeff"
private let keyBytes: [UInt8] = Array(WiZSigningKey(hex: keyHex)!.bytes)
private let otherKeyHex = "ffeeddccbbaa99887766554433221100"
private let ip2 = IPv4Addr(10, 0, 0, 2)
private let ip3 = IPv4Addr(10, 0, 0, 3)
private let mac2 = "a8bb5006033d"
private let mac3 = "a8bb50aabbcc"

private func fastConfig() -> WiZProvider.Configuration {
    var c = WiZProvider.Configuration()
    c.retrySchedule = [.milliseconds(100), .milliseconds(200)]
    c.requestTimeout = .seconds(2)
    c.writeRetrySchedule = [.milliseconds(150)]
    c.writeTimeout = .seconds(1)
    c.quickRetrySchedule = [.milliseconds(100)]
    c.quickTimeout = .milliseconds(800)
    c.sweepTimeout = .milliseconds(400)
    c.broadcastWindow = .milliseconds(600)
    c.broadcastInterval = .milliseconds(150)
    c.registrationInterval = .milliseconds(400)
    c.monitorTick = .milliseconds(50)
    c.autoRelocate = false
    c.relocateTimeout = .seconds(3)
    return c
}

private func bulbConfig(mac: String = mac2, module: String = "ESP01_SHRGB_03", signed: Bool = false) -> FakeWiZBulb.Configuration {
    var c = FakeWiZBulb.Configuration(port: 0, moduleName: module, signingKey: signed ? keyBytes : nil)
    c.mac = mac
    return c
}

/// A provider wired to fake bulbs on a virtual network.
struct Harness {
    let runner: SimulatorRunner
    let network: VirtualWiZNetwork
    let secrets: InMemorySecretStore
    let provider: WiZProvider
    let recorder: EventRecorder
    let bulbs: [FakeWiZBulb]
    let pump: Task<Void, Never>

    static func with(
        _ bulbs: [(IPv4Addr, FakeWiZBulb.Configuration)],
        config: WiZProvider.Configuration = fastConfig(),
        broadcastStatus: BroadcastCapabilityStatus = .notEntitled,
        secrets: InMemorySecretStore = InMemorySecretStore(),
        _ body: (Harness) async throws -> Void
    ) async throws {
        let runner = SimulatorRunner()
        let network = VirtualWiZNetwork(broadcastStatus: broadcastStatus)
        var started: [FakeWiZBulb] = []
        for (ip, cfg) in bulbs {
            let bulb = try await runner.start(FakeWiZBulb(cfg))
            network.route(ip, toPort: bulb.port!)
            started.append(bulb)
        }
        let provider = WiZProvider(secrets: secrets, transport: network, configuration: config)
        let recorder = EventRecorder()
        let events = provider.events
        let pump = Task { for await e in events { await recorder.append(e) } }
        let h = Harness(runner: runner, network: network, secrets: secrets, provider: provider, recorder: recorder, bulbs: started, pump: pump)
        do {
            try await body(h)
        } catch {
            await h.teardown()
            throw error
        }
        await h.teardown()
    }

    func teardown() async {
        await provider.stop()
        pump.cancel()
        for e in network.endpoints { e.close() }
        try? await runner.stopAll()
    }

    func discover(_ options: DiscoveryOptions) async -> [DiscoveredDevice] {
        var out: [DiscoveredDevice] = []
        for await d in await provider.discover(options: options) { out.append(d) }
        return out
    }

    func device(_ ip: IPv4Addr, mac: String) -> DiscoveredDevice {
        DiscoveredDevice(id: mac, brand: .wiz, name: "WiZ light \(mac.suffix(4).uppercased())", host: ip.description,
                         port: 38899, macAddress: mac, method: .manual)
    }

    func pair(_ ip: IPv4Addr = ip2, mac: String = mac2, _ answers: [ScriptedPairingInteraction.Answer] = []) async throws
        -> (PairedDevice, ScriptedPairingInteraction)
    {
        let ui = ScriptedPairingInteraction(answers)
        return (try await provider.pair(device(ip, mac: mac), using: ui), ui)
    }
}

/// Answers the signing prompt with "Allow all controls" and flips the fake bulb's setting on confirm.
struct AllowAllControlsUser: PairingInteraction {
    let bulb: FakeWiZBulb
    func confirm(_ message: String) async throws -> Bool {
        #expect(message.contains("Allow all controls"))
        bulb.setSigningMode(false)
        return true
    }
    func text(_ prompt: String) async throws -> String { throw LightCoreError.userCancelled }
    func secureText(_ prompt: String) async throws -> String { throw LightCoreError.userCancelled }
    func importFile(_ prompt: String, allowedTypes: [String]) async throws -> Data { throw LightCoreError.userCancelled }
    func choose(_ prompt: String, options: [String]) async throws -> Int { 2 }
}

@Suite("WiZProvider against FakeWiZBulb", .serialized)
struct WiZProviderTests {
    let lightID2 = LightID(brand: .wiz, stableId: mac2)!
    let lightID3 = LightID(brand: .wiz, stableId: mac3)!

    // MARK: Discovery

    @Test func sweepFindsBulbsByMAC() async throws {
        try await Harness.with([(ip2, bulbConfig()), (ip3, bulbConfig(mac: mac3))]) { h in
            let found = await h.discover(DiscoveryOptions(timeout: .seconds(5), methods: [.broadcast, .sweep]))
            #expect(Set(found.map(\.id)) == [mac2, mac3])
            #expect(found.allSatisfy { $0.method == .sweep && $0.brand == .wiz && $0.port == 38899 })
            #expect(found.first { $0.id == mac2 }?.host == "10.0.0.2")
            #expect(found.first { $0.id == mac2 }?.metadata["state"] == "off")
            // Never broadcast without the entitlement.
            #expect(!h.network.sent.contains { $0.host == h.network.broadcast })
        }
    }

    @Test func broadcastWhenEntitled() async throws {
        try await Harness.with([(ip2, bulbConfig()), (ip3, bulbConfig(mac: mac3))], broadcastStatus: .entitled) { h in
            let found = await h.discover(DiscoveryOptions(timeout: .seconds(5), methods: [.broadcast, .sweep]))
            #expect(Set(found.map(\.id)) == [mac2, mac3])
            #expect(found.allSatisfy { $0.method == .broadcast })
            let broadcasts = h.network.sent.filter { $0.host == h.network.broadcast }.map(\.payload)
            #expect(broadcasts.contains(#"{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}"#))
            #expect(broadcasts.contains(#"{"method":"getPilot","params":{}}"#))
            #expect(broadcasts.count >= 4) // re-sent during the window
        }
    }

    @Test func broadcastAvailableOptionSkipsDetection() async throws {
        try await Harness.with([(ip2, bulbConfig())], broadcastStatus: .unknown) { h in
            let found = await h.discover(DiscoveryOptions(timeout: .seconds(5), methods: [.broadcast], broadcastAvailable: true))
            #expect(found.map(\.id) == [mac2])
            #expect(found.first?.method == .broadcast)
        }
    }

    @Test func manualAndCachedHosts() async throws {
        try await Harness.with([(ip2, bulbConfig()), (ip3, bulbConfig(mac: mac3))]) { h in
            let found = await h.discover(DiscoveryOptions(
                timeout: .seconds(3), methods: [.manual, .cached], manualHosts: ["10.0.0.2", "not-an-ip"], cachedHosts: ["10.0.0.3"]))
            #expect(found.first { $0.id == mac2 }?.method == .manual)
            #expect(found.first { $0.id == mac3 }?.method == .cached)
            #expect(found.count == 2)
        }
    }

    // MARK: Pairing

    @Test func pairUnsignedBulb() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            let (paired, ui) = try await h.pair()
            #expect(paired.id == mac2 && paired.brand == .wiz && paired.hostHint == "10.0.0.2")
            #expect(paired.model == "ESP01_SHRGB_03")
            #expect(paired.metadata["signing"] == "notRequired")
            #expect(paired.metadata["fwVersion"] == "1.25.0")
            #expect(paired.metadata["kelvinMin"] == "2200" && paired.metadata["kelvinMax"] == "6500")
            #expect(paired.lightIDs == [lightID2] && paired.accountID == nil)
            // No questions asked.
            #expect(await ui.prompts.allSatisfy { $0.hasPrefix("Reading") })
            #expect(await h.secrets.count == 0)
            // The probe was a setState to the current state.
            #expect(h.bulbs[0].receivedRequests.contains { $0.method == "setState" && $0.params?["state"] == false })
            #expect(await h.recorder.first { if case .lightAdded = $0 { true } else { false } } != nil)

            let lights = try await h.provider.loadLights()
            let light = try #require(lights.first)
            #expect(light.id == lightID2 && light.providerRef == "10.0.0.2" && light.model == "ESP01_SHRGB_03")
            #expect(light.capabilities.supportedColorModes == [.rgb, .colorTemp])
            #expect(light.capabilities.kelvinRange == 2200...6500)
            #expect(light.capabilities.effects.count == 48)
            #expect(light.state.isOn == false && light.state.rgb == RGB(r: 255, g: 127, b: 0) && light.state.reachable)
            #expect(light.state.brightness == WiZStateMapping.brightness(fromDimming: 13))
        }
    }

    @Test func pairSignedBulbWithKeyFile() async throws {
        try await Harness.with([(ip2, bulbConfig(signed: true))]) { h in
            let export = Data(#"{"home":{"id":653906,"udp_signing_key":"\#(keyHex)"}}"#.utf8)
            let (paired, ui) = try await h.pair(ip2, mac: mac2, [.choice(0), .file(export)])
            #expect(paired.metadata["signing"] == "required" && paired.metadata["signedReplies"] == "true")
            #expect(paired.accountID == WiZProvider.homeAccountID)
            #expect(try await h.secrets.string(for: WiZProvider.signingSecretKey) == keyHex)
            #expect(await h.provider.account?.secretKeys == [WiZProvider.signingSecretKey])
            #expect(await ui.prompts.contains(WiZPairingText.importFile))

            try await h.provider.send(LightCommand(brightness: 0.4, color: .kelvin(3000)), to: lightID2)
            let bulb = h.bulbs[0]
            #expect(bulb.pilot["state"] == true && bulb.pilot["temp"] == 3000 && bulb.pilot["dimming"] == 46)
            let last = try #require(bulb.receivedRequests.last { $0.method == "setPilot" })
            #expect(last.hmac != nil && last.params?["sigTs"] != nil)
            #expect(last.raw.hasSuffix(#""env":"pro","hmac":"\#(last.hmac!)"}"#))
            #expect(await h.provider.signingMode(for: lightID2) == .required)
        }
    }

    @Test func pairSignedBulbWithPastedKeyAfterMistakes() async throws {
        try await Harness.with([(ip2, bulbConfig(signed: true))]) { h in
            let (paired, ui) = try await h.pair(ip2, mac: mac2, [
                .choice(1), .text("not a key"),
                .choice(1), .text(otherKeyHex),
                .choice(1), .text(" \(keyHex.uppercased())\n"),
            ])
            #expect(paired.metadata["signing"] == "required")
            let prompts = await ui.prompts
            #expect(prompts.contains(WiZSigningKey.ImportError.invalidKey.description))
            #expect(prompts.contains(WiZPairingText.keyRejected))
            #expect(try await h.secrets.string(for: WiZProvider.signingSecretKey) == keyHex)
        }
    }

    @Test func pairSignedBulbViaAllowAllControls() async throws {
        try await Harness.with([(ip2, bulbConfig(signed: true))]) { h in
            let paired = try await h.provider.pair(h.device(ip2, mac: mac2), using: AllowAllControlsUser(bulb: h.bulbs[0]))
            #expect(paired.metadata["signing"] == "notRequired")
            #expect(await h.secrets.count == 0)
            try await h.provider.send(.turnOn, to: lightID2)
            #expect(h.bulbs[0].pilot["state"] == true)
        }
    }

    @Test func pairSignedBulbCancelled() async throws {
        try await Harness.with([(ip2, bulbConfig(signed: true))]) { h in
            await #expect(throws: LightCoreError.userCancelled) { _ = try await h.pair(ip2, mac: mac2, [.cancel]) }
            await #expect(throws: LightCoreError.userCancelled) { _ = try await h.pair(ip2, mac: mac2, [.choice(2), .confirm(false)]) }
        }
    }

    @Test func storedKeyIsReusedForTheNextBulb() async throws {
        let secrets = InMemorySecretStore([WiZProvider.signingSecretKey: Data(keyHex.utf8)])
        try await Harness.with([(ip2, bulbConfig(signed: true))], secrets: secrets) { h in
            let (paired, ui) = try await h.pair()
            #expect(paired.metadata["signing"] == "required")
            #expect(await ui.prompts.allSatisfy { $0.hasPrefix("Reading") })
        }
    }

    @Test func pairRejectsDifferentDeviceAtHost() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            let ui = ScriptedPairingInteraction([])
            await #expect(throws: LightCoreError.self) {
                _ = try await h.provider.pair(h.device(ip2, mac: mac3), using: ui)
            }
        }
    }

    // MARK: Commands

    @Test func sendCombinesStateColourAndDimming() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            _ = try await h.pair()
            try await h.provider.send(LightCommand(brightness: 1, color: .hs(HS(h: 240, s: 1))), to: lightID2)
            let bulb = h.bulbs[0]
            let req = try #require(bulb.receivedRequests.last { $0.method == "setPilot" })
            #expect(req.raw.contains(#""params":{"state":true,"r":0,"g":0,"b":255,"dimming":100}"#))
            #expect(req.hmac == nil)
            #expect(bulb.pilot["b"] == 255 && bulb.pilot["dimming"] == 100)
            let changed = await h.recorder.first {
                if case .stateChanged(_, let s) = $0, s.rgb == RGB(r: 0, g: 0, b: 255) { true } else { false }
            }
            #expect(changed != nil)

            try await h.provider.send(LightCommand(color: .kelvin(9000)), to: lightID2)
            #expect(bulb.pilot["temp"] == 6500)
            try await h.provider.send(LightCommand(effect: "4"), to: lightID2)
            #expect(bulb.pilot["sceneId"] == 4)
            try await h.provider.send(.turnOff, to: lightID2)
            #expect(bulb.pilot["state"] == false)
            // FakeWiZBulb does not implement `pulse` (-32601); the request must still go out.
            await #expect(throws: LightCoreError.protocolError("pulse: WiZ error -32601 Method not found")) {
                try await h.provider.identify(lightID2)
            }
            #expect(bulb.receivedRequests.last?.method == "pulse")
            await #expect(throws: LightCoreError.lightNotFound(LightID(brand: .wiz, stableId: "000000000000")!)) {
                try await h.provider.send(.turnOn, to: LightID(brand: .wiz, stableId: "000000000000")!)
            }
        }
    }

    @Test func sendGroupSendsBackToBack() async throws {
        try await Harness.with([(ip2, bulbConfig()), (ip3, bulbConfig(mac: mac3, module: "ESP21_SHTW_01"))]) { h in
            _ = try await h.pair()
            _ = try await h.pair(ip3, mac: mac3)
            let before = h.network.sent.count
            try await h.provider.sendGroup(LightCommand(brightness: 0.5, color: .kelvin(2700)), to: [lightID2, lightID3])
            #expect(h.bulbs[0].pilot["temp"] == 2700 && h.bulbs[1].pilot["temp"] == 2700)
            #expect(h.bulbs[0].pilot["dimming"] == 55 && h.bulbs[1].pilot["dimming"] == 55)
            // The two setPilot datagrams are the first two sent for the group.
            let groupSends = h.network.sent.dropFirst(before).prefix(2)
            #expect(Set(groupSends.map(\.host)) == [ip2, ip3])
            #expect(groupSends.allSatisfy { $0.payload.contains(#""method":"setPilot""#) })
        }
    }

    @Test func signingDiscoveredAfterPairingUsesStoredKey() async throws {
        let secrets = InMemorySecretStore([WiZProvider.signingSecretKey: Data(keyHex.utf8)])
        try await Harness.with([(ip2, bulbConfig())], secrets: secrets) { h in
            _ = try await h.pair()
            #expect(await h.provider.signingMode(for: lightID2) == .notRequired)
            h.bulbs[0].setSigningMode(true, key: keyBytes) // firmware update / setting changed
            try await h.provider.send(.turnOn, to: lightID2)
            #expect(h.bulbs[0].pilot["state"] == true)
            #expect(await h.provider.signingMode(for: lightID2) == .required)
        }
    }

    @Test func rotatedKeyAsksForReauthentication() async throws {
        let secrets = InMemorySecretStore([WiZProvider.signingSecretKey: Data(keyHex.utf8)])
        try await Harness.with([(ip2, bulbConfig(signed: true))], secrets: secrets) { h in
            _ = try await h.pair()
            h.bulbs[0].setSigningMode(true, key: Array(WiZSigningKey(hex: otherKeyHex)!.bytes))
            await #expect(throws: LightCoreError.authenticationRequired(.wiz)) {
                try await h.provider.send(.turnOn, to: lightID2)
            }
            let reauth = await h.recorder.first { $0 == .needsReauthentication(accountID: WiZProvider.homeAccountID) }
            #expect(reauth != nil)
        }
    }

    @Test func unsignedBulbTurnedSignedWithoutKeyNeedsReauth() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            _ = try await h.pair()
            h.bulbs[0].setSigningMode(true, key: keyBytes)
            await #expect(throws: LightCoreError.authenticationRequired(.wiz)) { try await h.provider.send(.turnOn, to: lightID2) }
        }
    }

    // MARK: Reliability

    @Test func retriesLostDatagramsAndIgnoresMismatchedReplies() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            _ = try await h.pair()
            h.network.drop(ip2, next: 1)
            let provider = h.provider
            let load = Task { try await provider.loadLights() }
            // While the first getPilot is lost, a late reply to another method arrives.
            try await Task.sleep(for: .milliseconds(30))
            let requestEndpoint = try #require(h.network.endpoints.first)
            requestEndpoint.inject(#"{"method":"getSystemConfig","env":"pro","result":{"mac":"ffffffffffff","moduleName":"X"}}"#, from: ip2)
            let lights = try await load.value
            #expect(lights.first?.state.reachable == true)
            #expect(lights.first?.state.rgb == RGB(r: 255, g: 127, b: 0))
            let getPilots = h.network.sent.filter { $0.host == ip2 && $0.payload.contains("getPilot") }
            #expect(getPilots.count >= 3) // pairing read + lost + re-send
        }
    }

    @Test func timeoutMarksUnreachable() async throws {
        try await Harness.with([(ip2, bulbConfig())]) { h in
            _ = try await h.pair()
            h.network.unroute(ip2)
            await #expect(throws: LightCoreError.unreachable("WiZ light 033D")) { try await h.provider.send(.turnOn, to: lightID2) }
            #expect(await h.recorder.first { $0 == .reachabilityChanged(lightID2, reachable: false) } != nil)
            let lights = try await h.provider.loadLights()
            #expect(lights.first?.state.reachable == false)
        }
    }

    @Test func relocatesBulbAfterIPChange() async throws {
        var config = fastConfig()
        config.autoRelocate = true
        try await Harness.with([(ip2, bulbConfig())], config: config) { h in
            _ = try await h.pair()
            let port = h.bulbs[0].port!
            h.network.unroute(ip2)
            let newIP = IPv4Addr(10, 0, 0, 7)
            h.network.route(newIP, toPort: port)
            _ = try await h.provider.loadLights()
            let moved = await h.recorder.first(within: .seconds(8)) {
                if case .lightUpdated(let l) = $0, l.providerRef == "10.0.0.7" { true } else { false }
            }
            #expect(moved != nil)
            #expect(await h.provider.host(for: lightID2) == "10.0.0.7")
            try await h.provider.send(.turnOn, to: lightID2)
            #expect(h.bulbs[0].pilot["state"] == true)
        }
    }

    @Test func restoreFromPairedDevice() async throws {
        try await Harness.with([(ip2, bulbConfig(module: "ESP21_SHTW_01"))]) { h in
            let paired = PairedDevice(id: mac2, brand: .wiz, name: "Desk", model: "ESP21_SHTW_01", hostHint: "10.0.0.2",
                                      lightIDs: [lightID2],
                                      metadata: ["moduleName": "ESP21_SHTW_01", "kelvinMin": "2700", "kelvinMax": "5000", "signing": "notRequired"])
            await h.provider.restore([paired])
            let light = try #require(try await h.provider.loadLights().first)
            #expect(light.name == "Desk" && light.capabilities.supportedColorModes == [.colorTemp])
            #expect(light.capabilities.kelvinRange == 2700...5000 && light.capabilities.effects.count == 17)
            #expect(light.state.reachable)
            await h.provider.remove(lightID2)
            #expect(try await h.provider.loadLights().isEmpty)
        }
    }

    // MARK: Push

    @Test func registersAndReceivesSyncPilotPushes() async throws {
        try await Harness.with([(ip2, bulbConfig(signed: true))], secrets: InMemorySecretStore([WiZProvider.signingSecretKey: Data(keyHex.utf8)])) { h in
            _ = try await h.pair()
            await h.provider.start()
            #expect(await h.provider.isRunning)
            let pushPort = try #require(h.network.boundPort(forRequested: WiZPort.push))
            h.bulbs[0].setPushPort(pushPort)
            let bulb = h.bulbs[0]
            #expect(await eventually { bulb.registration?.phoneIp == "127.0.0.1" })
            #expect(bulb.registration?.phoneMac.count == 12)
            #expect(await h.recorder.first { if case .connectionChanged(true, _) = $0 { true } else { false } } != nil)

            bulb.externalChange(["state": true, "temp": 2700, "dimming": 60], src: "wizmote")
            let pushed = await h.recorder.first {
                if case .stateChanged(_, let s) = $0, s.kelvin == 2700, s.isOn { true } else { false }
            }
            #expect(pushed != nil)

            // Re-registers periodically.
            let firstCount = bulb.receivedRequests.filter { $0.method == "registration" }.count
            #expect(await eventually(.seconds(3)) { bulb.receivedRequests.filter { $0.method == "registration" }.count > firstCount })

            await h.provider.stop()
            #expect(await !h.provider.isRunning)
        }
    }

    @Test func pollsWhenNoPushArrives() async throws {
        var config = fastConfig()
        config.pushTimeout = .milliseconds(300)
        config.pollInterval = .milliseconds(200)
        try await Harness.with([(ip2, bulbConfig())], config: config) { h in
            _ = try await h.pair()
            h.bulbs[0].setPushEnabled(false)
            await h.provider.start()
            h.bulbs[0].externalChange(["state": true, "r": 0, "g": 255, "b": 0], src: "app")
            let polled = await h.recorder.first {
                if case .stateChanged(_, let s) = $0, s.rgb == RGB(r: 0, g: 255, b: 0) { true } else { false }
            }
            #expect(polled != nil)
        }
    }
}
