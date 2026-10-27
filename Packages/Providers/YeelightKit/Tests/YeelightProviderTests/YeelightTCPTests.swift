import Foundation
import LightCore
import Testing
import YeelightCodec
@testable import YeelightProvider

/// Provider against `FakeYeelightTCPServer` over real loopback TCP. Runs on Linux with the POSIX test
/// connector and, on Apple platforms, additionally with the production `NWYeelightConnector`.
@Suite("YeelightProvider over TCP", .serialized)
struct YeelightTCPTests {
    static var connectors: [(String, any YeelightConnector)] {
        var out: [(String, any YeelightConnector)] = [("posix", POSIXYeelightConnector())]
        #if canImport(Network)
        out.append(("network", NWYeelightConnector()))
        #endif
        return out
    }

    @Test(arguments: connectors.map(\.0))
    func pairControlAndNotifications(connectorName: String) async throws {
        let connector = try #require(Self.connectors.first { $0.0 == connectorName }?.1)
        let bulb = FakeYeelightBulb(state: .init(power: false, bright: 40, ct: 3500, colorMode: 2, name: "tcp"))
        let server = try FakeYeelightTCPServer(bulb: bulb)
        defer { server.stop() }
        let provider = YeelightProvider(connector: connector, configuration: .test())
        let recorder = EventRecorder()
        await recorder.start(provider.events)

        let device = DiscoveredDevice(id: bulb.id, brand: .yeelight, name: "TCP bulb", model: "color", host: "127.0.0.1", port: Int(server.port), method: .manual)
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(paired.name == "tcp")
        let id = try #require(paired.lightIDs.first)

        // Off -> on with colour: one set_scene on the wire.
        bulb.clearLog()
        try await provider.send(LightCommand(on: true, brightness: 0.75, color: .hs(HS(h: 200, s: 0.6))), to: id)
        #expect(bulb.receivedMethods == ["set_scene"])
        #expect(bulb.received.first?.params == ["hsv", 200, 60, 75])
        #expect(bulb.state.power)

        // Request ids increase and replies are matched.
        try await provider.send(LightCommand(color: .kelvin(5000), transition: .milliseconds(400)), to: id)
        let ids = bulb.received.map(\.id)
        #expect(ids == ids.sorted())
        #expect(bulb.state.ct == 5000)

        // Change made "in the Yeelight app" arrives as a props notification.
        bulb.externalChange { $0.bright = 5 }
        let event = await recorder.waitFor { if case .stateChanged(id, let s) = $0 { s.brightness == 0.05 } else { false } }
        #expect(event != nil)

        // Server drops the connection; provider reconnects and keeps working.
        server.dropClients()
        #expect(await recorder.waitFor { $0 == .reachabilityChanged(id, reachable: false) } != nil)
        #expect(await recorder.waitFor { $0 == .reachabilityChanged(id, reachable: true) } != nil)
        try await provider.send(.turnOff, to: id)
        #expect(bulb.state.power == false)
        await provider.disconnectAll()
    }

    @Test(arguments: connectors.map(\.0))
    func refusedConnectionMeansLANControlOff(connectorName: String) async throws {
        let connector = try #require(Self.connectors.first { $0.0 == connectorName }?.1)
        let port = unusedLoopbackPort()
        await #expect(throws: YeelightTransportError.connectionRefused) {
            _ = try await connector.connect(host: "127.0.0.1", port: port, timeout: .seconds(2))
        }
        let provider = YeelightProvider(connector: connector, configuration: .test())
        let ui = ScriptedPairingInteraction([.confirm(false)])
        let device = DiscoveredDevice(id: "0x0000000000000001", brand: .yeelight, name: "Off", host: "127.0.0.1", port: Int(port), method: .manual)
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await provider.pair(device, using: ui)
        }
        #expect(await ui.prompts.contains(YeelightProvider.lanControlGuidance))
    }

    @Test func sessionMatchesOutOfOrderRepliesById() async throws {
        let bulb = FakeYeelightBulb(state: .init(power: true))
        let server = try FakeYeelightTCPServer(bulb: bulb)
        defer { server.stop() }
        let session = YeelightSession(host: "127.0.0.1", port: server.port, connector: POSIXYeelightConnector(),
                                      options: .init(requestTimeout: .seconds(2), keepAlive: false))
        async let a = session.perform(YeelightCommands.getProp(["power"]))
        async let b = session.perform(YeelightCommands.getProp(["bright"]))
        async let c = session.perform(YeelightCall(method: "bogus_method"))
        let (ra, rb) = try await (a, b)
        #expect(ra == ["on"])
        #expect(rb == ["50"])
        do {
            _ = try await c
            Issue.record("expected device error")
        } catch let error as YeelightRPCError {
            #expect(error == YeelightRPCError(code: -1, message: "method not supported"))
        }
        await session.close()
        await #expect(throws: YeelightTransportError.closed) { try await session.perform(YeelightCommands.toggle()) }
    }
}
