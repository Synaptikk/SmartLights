import Foundation
import HueCodec
import LightCore
import NetKit
import Synchronization
import Testing

@testable import HueKit

/// Provider logic against `MockTransport` (runs on Linux and macOS).
@Suite("HueProvider (mock transport)")
struct HueProviderTests {
    typealias M = MockTransport
    static let sofa = "10000000-0000-4000-8000-000000000001"
    static let desk = "10000000-0000-4000-8000-000000000002"
    static let hall = "10000000-0000-4000-8000-000000000003"
    static let livingGroup = "40000000-0000-4000-8000-000000000001"
    static let relax = "60000000-0000-4000-8000-000000000001"

    static func lightID(_ rid: String) -> LightID { HueIdentifiers.lightID(bridgeID: M.bridgeID, resourceID: rid)! }

    static func config(_ tweak: (inout HueProvider.Configuration) -> Void = { _ in }) -> HueProvider.Configuration {
        var c = HueProvider.Configuration()
        c.autoConnectEvents = false
        c.pairingPollInterval = .milliseconds(10)
        c.busyRetryBase = .milliseconds(1)
        c.eventStreamBackoff = ExponentialBackoff(initial: .milliseconds(10), maximum: .milliseconds(50))
        tweak(&c)
        return c
    }

    /// A provider with the mock bridge already paired.
    static func pairedProvider(
        transport: MockTransport = MockTransport(), _ tweak: (inout HueProvider.Configuration) -> Void = { _ in }
    ) async throws -> (HueProvider, MockTransport, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        try await secrets.set(M.appKey, for: HueProvider.appKeySecret(bridgeID: M.bridgeID))
        let provider = HueProvider(secrets: secrets, transport: transport, configuration: config(tweak))
        await provider.addBridge(PairedDevice(id: M.bridgeID, brand: .hue, name: "Test Bridge", hostHint: M.host))
        return (provider, transport, secrets)
    }

    static func discovered() -> DiscoveredDevice {
        DiscoveredDevice(id: M.bridgeID, brand: .hue, name: "Test Bridge", host: M.host, method: .manual)
    }

    // MARK: Pairing

    @Test func pairingPollsUntilLinkButtonPressed() async throws {
        let transport = MockTransport { r, previous in
            if r.method == "POST", r.url.path == "/api" {
                let attempts = previous.filter { $0.method == "POST" && $0.url.path == "/api" }.count
                if attempts < 2 {
                    return M.json(#"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#)
                }
                return M.json(#"[{"success":{"username":"new-app-key","clientkey":"00112233445566778899AABBCCDDEEFF"}}]"#)
            }
            return M.defaultRoute(r)
        }
        let secrets = InMemorySecretStore()
        let provider = HueProvider(secrets: secrets, transport: transport, configuration: Self.config())
        let ui = ScriptedPairingInteraction([.confirm(true)])

        let paired = try await provider.pair(Self.discovered(), using: ui)

        #expect(paired.id == M.bridgeID)
        #expect(paired.brand == .hue)
        #expect(paired.name == "Test Bridge")
        #expect(paired.model == "BSB002")
        #expect(paired.hostHint == M.host)
        #expect(paired.metadata["scheme"] == "https")
        #expect(try await secrets.string(for: HueProvider.appKeySecret(bridgeID: M.bridgeID)) == "new-app-key")
        #expect(try await secrets.string(for: HueProvider.clientKeySecret(bridgeID: M.bridgeID)) == "00112233445566778899AABBCCDDEEFF")
        #expect(HueProvider.appKeySecret(bridgeID: M.bridgeID) == SecretKey(brand: .hue, owner: M.bridgeID, item: "appkey"))

        let posts = transport.requests("POST", "/api")
        #expect(posts.count == 3)
        #expect(posts.allSatisfy { $0.trust == .bridge(id: M.bridgeID) && $0.url.scheme == "https" })
        let body = try JSONDecoder().decode(HuePairingRequest.self, from: try #require(posts.first?.body))
        #expect(body == HuePairingRequest(devicetype: "SmartLights#iphone", generateclientkey: true))
        #expect(transport.requests("GET", "/api/config").first?.trust == .probe)

        let prompts = await ui.prompts
        #expect(prompts.first == "Press the round button on the Hue Bridge, then tap Continue")
        #expect(prompts.contains { $0.hasPrefix("Waiting for the link button") })
        #expect(await provider.bridgeIDs == [M.bridgeID])
        #expect(await provider.account?.id == M.bridgeID)
        #expect(await provider.account?.secretKeys.count == 2)
    }

    @Test func pairingDeclinedSendsNothing() async throws {
        let transport = MockTransport()
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await provider.pair(Self.discovered(), using: ScriptedPairingInteraction([.confirm(false)]))
        }
        #expect(transport.requests("POST", "/api").isEmpty)
    }

    @Test func pairingTimesOutWithoutLinkButton() async throws {
        let transport = MockTransport { r, _ in
            if r.method == "POST" { return M.json(#"[{"error":{"type":101,"description":"link button not pressed"}}]"#) }
            return M.defaultRoute(r)
        }
        let provider = HueProvider(
            secrets: InMemorySecretStore(), transport: transport,
            configuration: Self.config { $0.pairingTimeout = .milliseconds(80) })
        await #expect(throws: LightCoreError.timeout) {
            _ = try await provider.pair(Self.discovered(), using: ScriptedPairingInteraction([.confirm(true)]))
        }
        #expect(transport.requests("POST", "/api").count >= 2)
    }

    @Test func pairingRejectsADifferentBridge() async throws {
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: MockTransport(), configuration: Self.config())
        var device = Self.discovered()
        device.id = "001788FFFE999999"
        await #expect(throws: LightCoreError.self) {
            _ = try await provider.pair(device, using: ScriptedPairingInteraction([.confirm(true)]))
        }
    }

    // MARK: Probe

    @Test func probeRejectsCertificateForAnotherBridge() async throws {
        let transport = MockTransport { r, _ in
            M.json(M.configJSON, cn: "001788FFFE000BAD")
        }
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        await #expect(throws: HueError.bridgeIdentityMismatch(expected: M.bridgeID, found: "001788FFFE000BAD")) {
            _ = try await provider.probe(host: M.host)
        }
    }

    @Test func probeFallsBackToHTTP() async throws {
        let transport = MockTransport { r, _ in
            if r.url.scheme == "https" { throw HueTransportError.connectionFailed("refused") }
            return M.defaultRoute(r)
        }
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        let result = try await provider.probe(host: M.host)
        #expect(result.scheme == "http")
        #expect(result.config.bridgeID == M.bridgeID)
    }

    // MARK: Discovery

    @Test func discoveryMergesSourcesAndRateLimitsCloud() async throws {
        let transport = MockTransport(
            bonjour: [
                HueBonjourRecord(name: "Hue Bridge - 4A2B3C", host: M.host, port: 443,
                                 txt: ["bridgeid": "001788fffe4a2b3c", "modelid": "BSB002"]),
            ],
            handler: { r, _ in
                if r.url.host == "discovery.meethue.com" {
                    return M.json(#"[{"id":"001788fffe4a2b3c","internalipaddress":"10.0.0.2","port":443},{"id":"001788fffe000002","internalipaddress":"10.0.0.3","port":443}]"#)
                }
                if r.url.host == "10.0.0.3" { throw HueTransportError.connectionFailed("unreachable") }
                return M.defaultRoute(r)
            })
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        let options = DiscoveryOptions(timeout: .milliseconds(300), manualHosts: [M.host])

        var found: [DiscoveredDevice] = []
        for await device in await provider.discover(options: options) { found.append(device) }
        #expect(Set(found.map(\.id)) == [M.bridgeID, "001788FFFE000002"])
        #expect(found.filter { $0.id == M.bridgeID }.count == 1)
        let unconfirmed = try #require(found.first { $0.id == "001788FFFE000002" })
        #expect(unconfirmed.method == .cloud)
        #expect(unconfirmed.metadata["confirmed"] == "false")

        for await _ in await provider.discover(options: options) {}
        let cloudCalls = transport.requests.filter { $0.url.host == "discovery.meethue.com" }
        #expect(cloudCalls.count == 1)
        #expect(cloudCalls.first?.trust == .publicInternet)
    }

    @Test func manualDiscoveryRespectsMethods() async throws {
        let transport = MockTransport()
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: transport, configuration: Self.config())
        let options = DiscoveryOptions(timeout: .seconds(2), methods: [.manual], manualHosts: ["10.0.0.2:8443"])
        var found: [DiscoveredDevice] = []
        for await device in await provider.discover(options: options) { found.append(device) }
        #expect(found.count == 1)
        #expect(found.first?.port == 8443)
        #expect(found.first?.metadata["swversion"] == "1967054020")
        #expect(transport.requests.allSatisfy { $0.url.port == 8443 })
    }

    // MARK: Control

    @Test func loadLightsAndSendOnePut() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        let lights = try await provider.loadLights()
        #expect(lights.count == 3)
        #expect(lights.map(\.id).contains(Self.lightID(Self.desk)))
        let get = try #require(transport.requests("GET", "/clip/v2/resource").first)
        #expect(get.headers["hue-application-key"] == M.appKey)
        #expect(get.trust == .bridge(id: M.bridgeID))
        #expect(get.url.absoluteString == "https://10.0.0.2/clip/v2/resource")

        try await provider.send(
            LightCommand(brightness: 0.5, color: .kelvin(2700), transition: .milliseconds(400)), to: Self.lightID(Self.desk))
        let put = try #require(transport.requests("PUT", "/clip/v2/resource/light/\(Self.desk)").first)
        let body = try JSONDecoder().decode(HueLightUpdate.self, from: try #require(put.body))
        #expect(body == HueLightUpdate(on: true, brightness: 50, mirek: 370, durationMilliseconds: 400))
        #expect(put.headers["Content-Type"] == "application/json")
    }

    @Test func sendLoadsLazilyAndRejectsUnknownLights() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        try await provider.send(.turnOff, to: Self.lightID(Self.hall))
        #expect(transport.requests("GET", "/clip/v2/resource").count == 1)
        await #expect(throws: LightCoreError.lightNotFound(Self.lightID("nope"))) {
            try await provider.send(.turnOn, to: Self.lightID("nope"))
        }
    }

    @Test func sendGroupUsesGroupedLightForWholeRoom() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        try await provider.sendGroup(LightCommand(on: true, brightness: 0.3), to: [Self.lightID(Self.sofa), Self.lightID(Self.desk)])
        let groupPuts = transport.requests.filter { $0.method == "PUT" && $0.url.path.contains("grouped_light") }
        #expect(groupPuts.map(\.url.path) == ["/clip/v2/resource/grouped_light/\(Self.livingGroup)"])
        #expect(transport.requests.filter { $0.method == "PUT" && $0.url.path.contains("/light/") }.isEmpty)
        let body = try JSONDecoder().decode(HueLightUpdate.self, from: try #require(groupPuts.first?.body))
        #expect(body == HueLightUpdate(on: true, brightness: 30))
    }

    @Test func sendGroupFansOutForPartialRooms() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        try await provider.sendGroup(.turnOff, to: [Self.lightID(Self.desk), Self.lightID(Self.hall)])
        let puts = transport.requests.filter { $0.method == "PUT" }.map(\.url.path).sorted()
        #expect(puts == ["/clip/v2/resource/light/\(Self.desk)", "/clip/v2/resource/light/\(Self.hall)"])
    }

    @Test func busyBridgeIsRetried() async throws {
        let transport = MockTransport { r, previous in
            if r.method == "PUT", previous.filter({ $0.method == "PUT" }).isEmpty {
                return M.json(#"{"errors":[{"description":"Too many requests"}],"data":[]}"#, status: 429)
            }
            return M.defaultRoute(r)
        }
        let (provider, _, _) = try await Self.pairedProvider(transport: transport)
        try await provider.send(.turnOn, to: Self.lightID(Self.hall))
        #expect(transport.requests("PUT", "/clip/v2/resource/light/\(Self.hall)").count == 2)
    }

    @Test func busyBridgeGivesUpAfterRetries() async throws {
        let transport = MockTransport { r, _ in
            r.method == "PUT" ? M.json("{}", status: 503) : M.defaultRoute(r)
        }
        let (provider, _, _) = try await Self.pairedProvider(transport: transport) { $0.maxBusyRetries = 2 }
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOn, to: Self.lightID(Self.hall)) }
        #expect(transport.requests.filter { $0.method == "PUT" }.count == 3)
    }

    @Test func unauthorizedAsksForReauthentication() async throws {
        let transport = MockTransport { r, _ in
            M.json(#"{"errors":[{"description":"unauthorized user"}],"data":[]}"#, status: 403)
        }
        let (provider, _, _) = try await Self.pairedProvider(transport: transport)
        let events = EventCollector(provider.events)
        await #expect(throws: LightCoreError.authenticationRequired(.hue)) { _ = try await provider.loadLights() }
        let hit = await events.wait { $0 == .needsReauthentication(accountID: M.bridgeID) }
        #expect(hit != nil)
    }

    @Test func missingAppKeyMeansAuthenticationRequired() async throws {
        let provider = HueProvider(secrets: InMemorySecretStore(), transport: MockTransport(), configuration: Self.config())
        await provider.addBridge(PairedDevice(id: M.bridgeID, brand: .hue, name: "B", hostHint: M.host))
        await #expect(throws: LightCoreError.authenticationRequired(.hue)) { _ = try await provider.loadLights() }
    }

    @Test func perLightRateLimit() async throws {
        let (provider, transport, _) = try await Self.pairedProvider { $0.lightRateLimit = .init(capacity: 1, refillPerSecond: 10) }
        let start = ContinuousClock.now
        for _ in 0..<3 { try await provider.send(.turnOn, to: Self.lightID(Self.hall)) }
        let elapsed = ContinuousClock.now - start
        #expect(transport.requests("PUT", "/clip/v2/resource/light/\(Self.hall)").count == 3)
        #expect(elapsed >= .milliseconds(150))
    }

    @Test func concurrentRequestsAreCapped() async throws {
        final class Gauge: Sendable {
            let state = Mutex((now: 0, max: 0))
        }
        let inFlight = Gauge()
        let transport = MockTransport { r, _ in
            inFlight.state.withLock { $0.now += 1; $0.max = max($0.max, $0.now) }
            Thread.sleep(forTimeInterval: 0.02)
            inFlight.state.withLock { $0.now -= 1 }
            return M.defaultRoute(r)
        }
        let (provider, _, _) = try await Self.pairedProvider(transport: transport)
        _ = try await provider.loadLights()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for rid in [Self.sofa, Self.desk, Self.hall] {
                for _ in 0..<3 { group.addTask { try await provider.send(.turnOn, to: Self.lightID(rid)) } }
            }
            try await group.waitForAll()
        }
        #expect(inFlight.state.withLock { $0.max } <= 3)
    }

    // MARK: Scenes

    @Test func scenesAndRecall() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        let scenes = try await provider.scenes()
        #expect(scenes.map(\.name) == ["Relax"])
        try await provider.recall(try #require(scenes.first).id)
        let put = try #require(transport.requests("PUT", "/clip/v2/resource/scene/\(Self.relax)").first)
        #expect(String(decoding: try #require(put.body), as: UTF8.self) == #"{"recall":{"action":"active"}}"#)
        try await provider.recall(scenes[0].id, action: .dynamicPalette)
        let last = try #require(transport.requests("PUT", "/clip/v2/resource/scene/\(Self.relax)").last)
        #expect(String(decoding: try #require(last.body), as: UTF8.self) == #"{"recall":{"action":"dynamic_palette"}}"#)
    }

    // MARK: Event stream

    @Test func eventStreamPushesStateAndKeepsAlive() async throws {
        let (provider, transport, _) = try await Self.pairedProvider { $0.keepaliveInterval = .milliseconds(50) }
        let events = EventCollector(provider.events)
        _ = try await provider.loadLights()
        await provider.connectEventStreams()
        #expect(await eventually { transport.streamCount == 1 })
        let streamRequest = try #require(transport.streamRequests.first)
        #expect(streamRequest.url.absoluteString == "https://10.0.0.2/eventstream/clip/v2")
        #expect(streamRequest.applicationKey == M.appKey)
        #expect(streamRequest.readTimeout == .seconds(90))

        transport.emit(.connected)
        #expect(await events.wait { $0 == .connectionChanged(connected: true, detail: nil) } != nil)
        let payload = #"[{"creationtime":"2026-10-26T12:00:00Z","id":"e1","type":"update","data":[{"id":"\#(Self.hall)","on":{"on":false},"type":"light"}]}]"#
        transport.emit(.message(id: "1730000000:1", data: payload))
        let changed = await events.wait {
            if case .stateChanged(let id, let state) = $0 { return id == Self.lightID(Self.hall) && !state.isOn }
            return false
        }
        #expect(changed != nil)

        // Keep-alive: find-or-create our geofence client, then rename it periodically.
        #expect(await eventually { !transport.requests("PUT", "/clip/v2/resource/geofence_client/geo-1").isEmpty })
        #expect(transport.requests("POST", "/clip/v2/resource/geofence_client").count == 1)
        let rename = try #require(transport.requests("PUT", "/clip/v2/resource/geofence_client/geo-1").first?.body)
        #expect(String(decoding: rename, as: UTF8.self).contains("smartlights_"))

        transport.emit(.disconnected(reason: "read timeout", retryIn: .seconds(1)))
        #expect(await events.wait { $0 == .connectionChanged(connected: false, detail: "read timeout") } != nil)
        #expect(await provider.isEventStreamConnected(bridgeID: M.bridgeID) == false)
        await provider.disconnectEventStreams()
    }

    @Test func reconnectAfterLongGapResyncs() async throws {
        let (provider, transport, _) = try await Self.pairedProvider { $0.resyncGap = .milliseconds(1) }
        let events = EventCollector(provider.events)
        _ = try await provider.loadLights()
        // The bridge changed while we were away.
        transport.setHandler { r, _ in
            if r.method == "GET", r.url.path == "/clip/v2/resource" {
                let text = String(decoding: M.fixture(), as: UTF8.self)
                    .replacingOccurrences(of: #""brightness": 50.0, "min_dim_level": 1.0"#,
                                          with: #""brightness": 10.0, "min_dim_level": 1.0"#)
                return M.json(text)
            }
            return M.defaultRoute(r)
        }
        try await Task.sleep(for: .milliseconds(5))
        await provider.connectEventStreams()
        #expect(await eventually { transport.streamCount == 1 })
        transport.emit(.connected)
        let changed = await events.wait {
            if case .stateChanged(let id, let state) = $0 { return id == Self.lightID(Self.hall) && state.brightness == 0.1 }
            return false
        }
        #expect(changed != nil)
        #expect(transport.requests("GET", "/clip/v2/resource").count == 2)
        await provider.disconnectEventStreams()
    }

    @Test func eventStream403StopsAndAsksForReauth() async throws {
        let (provider, transport, _) = try await Self.pairedProvider()
        let events = EventCollector(provider.events)
        _ = try await provider.loadLights()
        await provider.connectEventStreams()
        #expect(await eventually { transport.streamCount == 1 })
        transport.finishStream(throwing: HueError.unauthorized)
        #expect(await events.wait { $0 == .needsReauthentication(accountID: M.bridgeID) } != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.streamCount == 1)
    }

    // MARK: Roots

    @Test func bundledRootsContainSignifyCA() {
        let ders = HueRootCertificates.derCertificates
        #expect(ders.count == 1)
        // DER of CN=root-bridge contains the ASCII "root-bridge".
        #expect(ders.first.map { Data($0).range(of: Data("root-bridge".utf8)) != nil } == true)
        #expect(HueRootCertificates.pem.contains("PLACEHOLDER"))
    }
}
