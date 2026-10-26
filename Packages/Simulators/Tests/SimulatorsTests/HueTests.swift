import Foundation
import NIOHTTP1
import Testing
import X509

@testable import Simulators

@Suite("FakeHueBridge")
struct HueTests {
    static let appKey = "simulator-app-key-0000000000000000000000"
    typealias S = FakeHueBridge.SeedID

    func withBridge(
        _ cfg: FakeHueBridge.Configuration = .init(appKeys: [HueTests.appKey: "00112233445566778899AABBCCDDEEFF"]),
        _ body: (FakeHueBridge, Int) async throws -> Void
    ) async throws {
        let runner = SimulatorRunner()
        let bridge = try await runner.start(try FakeHueBridge(cfg))
        do {
            try await body(bridge, bridge.httpsPort!)
        } catch {
            try await runner.stopAll()
            throw error
        }
        try await runner.stopAll()
    }

    var auth: [(String, String)] { [("hue-application-key", Self.appKey)] }

    @Test func configIsUnauthenticatedAndCertCNIsBridgeId() async throws {
        try await withBridge { bridge, port in
            let conn = try await HTTPTestConnection.connect(port: port, tls: true)
            try await conn.send(method: .GET, path: "/api/config", headers: [("Connection", "close")])
            let r = try await conn.readResponse()
            #expect(r.status == .ok)
            #expect(r.json?["bridgeid"] == "001788FFFE000001")
            #expect(r.json?["modelid"] == "BSB002")
            #expect(r.json?["swversion"]?.stringValue != nil)
            #expect(r.json?["apiversion"]?.stringValue != nil)

            let der = try #require(conn.peerCertificateDER.withLockedValue { $0 })
            #expect(der == bridge.certificate.certificateDER)
            let cert = try Certificate(derEncoded: der)
            #expect(String(describing: cert.subject).contains("CN=001788FFFE000001"))
            #expect(cert.subject == cert.issuer)  // self-signed like older bridges
            await conn.close()
        }
    }

    @Test func pairingNeedsLinkButton() async throws {
        try await withBridge(.init()) { bridge, port in
            let body = #"{"devicetype":"SmartLights#iphone","generateclientkey":true}"#
            let denied = try await HTTPTestConnection.request(.POST, port: port, path: "/api", body: body)
            #expect(denied.json == [["error": ["type": 101, "address": "", "description": "link button not pressed"]]])

            let press = try await HTTPTestConnection.request(.POST, port: port, path: "/_sim/linkbutton", body: "{}")
            #expect(press.status == .ok)
            #expect(bridge.linkButtonPressed)

            let ok = try await HTTPTestConnection.request(.POST, port: port, path: "/api", body: body)
            let success = try #require(ok.json?.arrayValue?.first?["success"])
            let username = try #require(success["username"]?.stringValue)
            let clientkey = try #require(success["clientkey"]?.stringValue)
            #expect(username.count == 40)
            #expect(clientkey.count == 32)
            let isHex = clientkey.allSatisfy { $0.isHexDigit }
            #expect(isHex)
            #expect(bridge.appKeys[username] == clientkey)

            // The new key works on CLIP v2.
            let lights = try await HTTPTestConnection.request(
                .GET, port: port, path: "/clip/v2/resource/light", headers: [("hue-application-key", username)])
            #expect(lights.status == .ok)

            bridge.releaseLinkButton()
            let again = try await HTTPTestConnection.request(.POST, port: port, path: "/api", body: body)
            #expect(again.json?.arrayValue?.first?["error"]?["type"] == 101)
        }
    }

    @Test func clipV2RequiresKeyAndListsSeed() async throws {
        try await withBridge { _, port in
            let noKey = try await HTTPTestConnection.request(.GET, port: port, path: "/clip/v2/resource/light")
            #expect(noKey.status == .forbidden)
            let badKey = try await HTTPTestConnection.request(
                .GET, port: port, path: "/clip/v2/resource/light", headers: [("hue-application-key", "nope")])
            #expect(badKey.status == .forbidden)
            let root = try await HTTPTestConnection.request(.GET, port: port, path: "/clip/v2/resource")
            #expect(root.status == .forbidden)

            let expected = ["light": 3, "room": 2, "zone": 1, "scene": 2, "device": 4, "bridge": 1, "grouped_light": 3]
            for (type, n) in expected {
                let r = try await HTTPTestConnection.request(.GET, port: port, path: "/clip/v2/resource/\(type)", headers: auth)
                #expect(r.status == .ok)
                #expect(r.json?["errors"] == [])
                #expect(r.json?["data"]?.arrayValue?.count == n, "\(type)")
            }
            let one = try await HTTPTestConnection.request(
                .GET, port: port, path: "/clip/v2/resource/light/\(S.colorLight)", headers: auth)
            let light = try #require(one.json?["data"]?.arrayValue?.first)
            #expect(light["type"] == "light")
            #expect(light["color"]?["gamut_type"] == "C")
            #expect(light["owner"]?["rid"]?.stringValue == S.colorDevice)

            let bridge = try await HTTPTestConnection.request(.GET, port: port, path: "/clip/v2/resource/bridge", headers: auth)
            #expect(bridge.json?["data"]?.arrayValue?.first?["bridge_id"] == "001788fffe000001")

            let missing = try await HTTPTestConnection.request(
                .GET, port: port, path: "/clip/v2/resource/light/does-not-exist", headers: auth)
            #expect(missing.status == .notFound)
        }
    }

    @Test func putLightAndValidation() async throws {
        try await withBridge { bridge, port in
            let path = "/clip/v2/resource/light/\(S.colorLight)"
            let put = try await HTTPTestConnection.request(
                .PUT, port: port, path: path, headers: auth,
                body: #"{"on":{"on":false},"dimming":{"brightness":42.5},"color":{"xy":{"x":0.3,"y":0.3}},"dynamics":{"duration":400}}"#)
            #expect(put.status == .ok)
            #expect(put.json == ["data": [["rid": .string(S.colorLight), "rtype": "light"]], "errors": []])
            let light = try #require(bridge.resource(type: "light", id: S.colorLight))
            #expect(light["on"]?["on"] == false)
            #expect(light["dimming"]?["brightness"] == 42.5)
            #expect(light["color"]?["xy"] == ["x": 0.3, "y": 0.3])
            #expect(bridge.lastTransitionDuration(lightId: S.colorLight) == 400)

            _ = try await HTTPTestConnection.request(
                .PUT, port: port, path: path, headers: auth, body: #"{"color_temperature":{"mirek":250}}"#)
            let ct = bridge.resource(type: "light", id: S.colorLight)?["color_temperature"]
            #expect(ct?["mirek"] == 250)
            #expect(ct?["mirek_valid"] == true)

            let badMirek = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/light/\(S.ambianceLight)", headers: auth,
                body: #"{"color_temperature":{"mirek":600}}"#)
            #expect(badMirek.status == .badRequest)
            let noColor = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/light/\(S.whiteLight)", headers: auth,
                body: #"{"color":{"xy":{"x":0.3,"y":0.3}}}"#)
            #expect(noColor.status == .badRequest)
            let badBri = try await HTTPTestConnection.request(
                .PUT, port: port, path: path, headers: auth, body: #"{"dimming":{"brightness":150}}"#)
            #expect(badBri.status == .badRequest)
            let unknown = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/light/nope", headers: auth, body: #"{"on":{"on":true}}"#)
            #expect(unknown.status == .notFound)
        }
    }

    @Test func groupedLightAndSceneRecall() async throws {
        try await withBridge { bridge, port in
            let g = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/grouped_light/\(S.livingRoomGroup)", headers: auth,
                body: #"{"on":{"on":true},"dimming":{"brightness":20}}"#)
            #expect(g.status == .ok)
            for id in [S.colorLight, S.ambianceLight] {
                #expect(bridge.resource(type: "light", id: id)?["on"]?["on"] == true)
                #expect(bridge.resource(type: "light", id: id)?["dimming"]?["brightness"] == 20.0)
            }
            #expect(bridge.resource(type: "light", id: S.whiteLight)?["dimming"]?["brightness"] == 50.0)

            let r = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/scene/\(S.relaxScene)", headers: auth,
                body: #"{"recall":{"action":"active","duration":1000}}"#)
            #expect(r.status == .ok)
            #expect(bridge.resource(type: "light", id: S.ambianceLight)?["color_temperature"]?["mirek"] == 447)
            #expect(bridge.resource(type: "light", id: S.colorLight)?["dimming"]?["brightness"] == 56.3)
            #expect(bridge.resource(type: "scene", id: S.relaxScene)?["status"]?["active"] == "static")
            #expect(bridge.lastTransitionDuration(lightId: S.colorLight) == 1000)
        }
    }

    @Test func eventStreamEmitsUpdates() async throws {
        try await withBridge { bridge, port in
            let denied = try await HTTPTestConnection.request(.GET, port: port, path: "/eventstream/clip/v2",
                headers: [("Accept", "text/event-stream")])
            #expect(denied.status == .forbidden)

            let sse = try await HTTPTestConnection.connect(port: port, tls: true)
            try await sse.send(method: .GET, path: "/eventstream/clip/v2", headers: auth + [("Accept", "text/event-stream")])
            let head = try await sse.readHead()
            #expect(head.status == .ok)
            #expect(head.headers.first(name: "content-type")?.hasPrefix("text/event-stream") == true)
            #expect(try await sse.readChunk() == ": hi\n\n")
            #expect(bridge.eventStreamCount == 1)

            _ = try await HTTPTestConnection.request(
                .PUT, port: port, path: "/clip/v2/resource/light/\(S.whiteLight)", headers: auth,
                body: #"{"dimming":{"brightness":75}}"#)
            let chunk = try #require(try await sse.readChunk())
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            #expect(lines.first?.hasPrefix("id: ") == true)
            let dataLine = try #require(lines.first { $0.hasPrefix("data: ") })
            let events = try JSON.parse(String(dataLine.dropFirst(6)))
            let event = try #require(events.arrayValue?.first)
            #expect(event["type"] == "update")
            #expect(event["creationtime"]?.stringValue != nil)
            let datas = try #require(event["data"]?.arrayValue)
            let lightEvent = try #require(datas.first { $0["type"] == "light" })
            #expect(lightEvent["id"]?.stringValue == S.whiteLight)
            #expect(lightEvent["dimming"]?["brightness"] == 75.0)
            #expect(datas.contains { $0["type"] == "grouped_light" })

            // External change (e.g. a dimmer switch) also streams.
            try bridge.externalUpdate(type: "light", id: S.whiteLight, body: ["on": ["on": false]])
            let chunk2 = try #require(try await sse.readChunk())
            #expect(chunk2.contains(#""on":{"on":false}"#))
            await sse.close()
        }
    }

    @Test func tooManyConcurrentRequestsGets429() async throws {
        try await withBridge { bridge, port in
            bridge.setLimits(maxConcurrentRequests: 1, responseDelayMs: 400)
            let statuses = try await withThrowingTaskGroup(of: HTTPResponseStatus.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        try await HTTPTestConnection.request(
                            .GET, port: port, path: "/clip/v2/resource/light", headers: auth
                        ).status
                    }
                }
                return try await group.reduce(into: [HTTPResponseStatus]()) { $0.append($1) }
            }
            #expect(statuses.contains(.tooManyRequests))
            #expect(statuses.contains(.ok))
        }
    }

    @Test func plainHTTPListener() async throws {
        var cfg = FakeHueBridge.Configuration(appKeys: [Self.appKey: ""])
        cfg.httpPort = 0
        try await withBridge(cfg) { bridge, _ in
            let http = try #require(bridge.httpPort)
            let r = try await HTTPTestConnection.request(.GET, port: http, path: "/api/config", tls: false)
            #expect(r.json?["bridgeid"] == "001788FFFE000001")
            #expect(bridge.boundPorts["http"] == http)
        }
    }
}
