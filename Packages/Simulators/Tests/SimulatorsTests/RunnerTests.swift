import Testing

@testable import Simulators

@Suite("SimulatorRunner")
struct RunnerTests {
    @Test func startsQueriesAndStopsEverything() async throws {
        let runner = SimulatorRunner()
        let bulb = try await runner.start(FakeWiZBulb())
        let bridge = try await runner.start(try FakeHueBridge(.init(httpPort: 0)))
        let device = try await runner.start(FakeAiDotDevice())
        let cloud = try await runner.start(FakeAiDotCloud(devices: [device]))

        #expect(runner.simulators.count == 4)
        #expect(runner.port(of: "wiz", role: "udp") == bulb.port)
        #expect(runner.port(of: "hue", role: "https") == bridge.httpsPort)
        #expect(runner.port(of: "hue", role: "http") == bridge.httpPort)
        #expect(runner.port(of: "aidot-device", role: "tcp") == device.tcpPort)
        #expect(runner.port(of: "aidot-device", role: "udp") == device.discoveryPort)
        #expect(runner.port(of: "aidot-cloud", role: "http") == cloud.port)
        #expect(cloud.baseURL?.hasSuffix("/v35") == true)

        let r = try await HTTPTestConnection.request(.GET, port: bridge.httpsPort!, path: "/api/config")
        #expect(r.status == .ok)

        try await runner.stopAll()
        #expect(runner.simulators.isEmpty)
        #expect(bulb.port == nil)
        #expect(bridge.boundPorts.isEmpty)
        #expect(device.boundPorts.isEmpty)
        #expect(cloud.port == nil)
    }

    @Test func jsonRoundTripPreservesOrderAndCompactness() throws {
        let text = #"{"method":"setPilot","params":{"r":1,"b":2.5,"s":"a\"b","n":null,"l":[true,false]}}"#
        let v = try JSON.parse(text)
        #expect(v.compact == text)
        let (_, raw) = try JSON.parseWithRawMembers(Array(#"{"params": {"state":true, "sigTs":1}, "hmac":"x"}"#.utf8))
        #expect(String(decoding: raw["params"]!, as: UTF8.self) == #"{"state":true, "sigTs":1}"#)
    }
}
