import Crypto
import Foundation
import Testing

@testable import Simulators

@Suite("FakeWiZBulb")
struct WiZTests {
    static let keyHex = "00112233445566778899aabbccddeeff"
    static var key: [UInt8] { SimCrypto.hexDecode(keyHex)! }

    func withBulb(
        _ cfg: FakeWiZBulb.Configuration = .init(), _ body: (FakeWiZBulb, UDPTestClient) async throws -> Void
    ) async throws {
        let runner = SimulatorRunner()
        let bulb = try await runner.start(FakeWiZBulb(cfg))
        let client = try await UDPTestClient.make()
        do {
            try await body(bulb, client)
        } catch {
            await client.close()
            try await runner.stopAll()
            throw error
        }
        await client.close()
        try await runner.stopAll()
    }

    /// Signs like pywizlight PR #216: HMAC-SHA256 over compact params (incl. sigTs), base64.
    static func signed(_ method: String, params: String, sigTs: Int, key: [UInt8]) -> String {
        let p = "{\(params)\(params.isEmpty ? "" : ",")\"sigTs\":\(sigTs)}"
        let mac = HMAC<SHA256>.authenticationCode(for: Array(p.utf8), using: SymmetricKey(data: key))
        return #"{"method":"\#(method)","env":"pro","params":\#(p),"hmac":"\#(Data(mac).base64EncodedString())"}"#
    }

    @Test func hmacKnownAnswerFromPywizlightPR216() {
        let msg = Array(#"{"state":true,"sigTs":1790441723}"#.utf8)
        #expect(SimCrypto.hmacSHA256Base64(msg, key: Self.key) == "vARMv4JpVsxYabcBovABd25ISBzYT8+71v0CUtpU1sg=")
        let params: JSONObject = ["state": true, "sigTs": 1_790_441_723]
        #expect(params.compact == #"{"state":true,"sigTs":1790441723}"#)
    }

    @Test func readsMatchFakeBulbShapes() async throws {
        try await withBulb { bulb, c in
            let port = bulb.port!
            let pilot = try await c.request(#"{"method":"getPilot","params":{}}"#, port: port)
            #expect(pilot["method"] == "getPilot")
            #expect(pilot["env"] == "pro")
            #expect(pilot["result"]?["mac"] == "a8bb5006033d")
            #expect(pilot["result"]?["state"] == false)
            #expect(pilot["result"]?["dimming"] == 13)

            let sys = try await c.request(#"{"method":"getSystemConfig","params":{}}"#, port: port)
            #expect(sys["result"]?["moduleName"] == "ESP01_SHRGB_03")
            #expect(sys["result"]?["fwVersion"] == "1.25.0")
            #expect(sys["result"]?["homeId"] == 653906)

            let model = try await c.request(#"{"method":"getModelConfig","params":{}}"#, port: port)
            #expect(model["result"]?["cctRange"] == [2200, 2700, 4800, 6500])

            let user = try await c.request(#"{"method":"getUserConfig","params":{}}"#, port: port)
            #expect(user["result"]?["whiteRange"] == [2700, 6500])
        }
    }

    @Test func errorsForUnknownMethodAndBadJSON() async throws {
        var cfg = FakeWiZBulb.Configuration()
        cfg.moduleName = "ESP99_UNKNOWN_01"
        try await withBulb(cfg) { bulb, c in
            let port = bulb.port!
            let unknown = try await c.request(#"{"method":"frobnicate","params":{}}"#, port: port)
            #expect(unknown == ["method": "frobnicate", "env": "pro", "error": ["code": -32601, "message": "Method not found"]])
            let model = try await c.request(#"{"method":"getModelConfig","params":{}}"#, port: port)
            #expect(model["error"]?["code"] == -32601)
            try await c.send(Array("not json{".utf8), port: port)
            let raw = String(decoding: try await c.receive(), as: UTF8.self)
            #expect(raw == #"{"env":"pro","error":{"code":-32700,"message":"Parse error"}}"#)
        }
    }

    @Test func setPilotAppliesWithModeExclusivity() async throws {
        try await withBulb { bulb, c in
            let port = bulb.port!
            let ok = try await c.request(#"{"id":1,"method":"setPilot","params":{"temp":3000,"dimming":75}}"#, port: port)
            #expect(ok == ["method": "setPilot", "env": "pro", "result": ["success": true]])
            #expect(bulb.pilot["temp"] == 3000)
            #expect(bulb.pilot["r"] == nil)
            #expect(bulb.pilot["state"] == true)  // setPilot with light params turns the bulb on
            _ = try await c.request(#"{"method":"setPilot","params":{"r":0,"g":0,"b":255,"dimming":5}}"#, port: port)
            #expect(bulb.pilot["temp"] == nil)
            #expect(bulb.pilot["b"] == 255)
            #expect(bulb.pilot["dimming"] == 10)  // clamped
            _ = try await c.request(#"{"method":"setPilot","params":{"sceneId":23,"speed":145}}"#, port: port)
            #expect(bulb.pilot["sceneId"] == 23)
            #expect(bulb.pilot["speed"] == 145)
            _ = try await c.request(#"{"method":"setState","params":{"state":false}}"#, port: port)
            let pilot = try await c.request(#"{"method":"getPilot","params":{}}"#, port: port)
            #expect(pilot["result"]?["state"] == false)
            #expect(pilot["result"]?["sceneId"] == 23)
        }
    }

    @Test func registrationAndSyncPilotPush() async throws {
        let listener = try await UDPTestClient.make()
        defer { Task { await listener.close() } }
        var cfg = FakeWiZBulb.Configuration()
        cfg.pushPort = listener.port
        try await withBulb(cfg) { bulb, c in
            let port = bulb.port!
            // Discovery-style registration (register:false) must not subscribe.
            let disc = try await c.request(
                #"{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}"#,
                port: port)
            #expect(disc["result"]?["mac"] == "a8bb5006033d")
            #expect(bulb.registration == nil)

            let reg = try await c.request(
                #"{"method":"registration","id":105,"params":{"phoneIp":"127.0.0.1","phoneMac":"aabbccddeeff","register":true}}"#,
                port: port)
            #expect(reg["result"]?["success"] == true)
            #expect(bulb.registration?.phoneIp == "127.0.0.1")

            _ = try await c.request(#"{"method":"setPilot","params":{"state":true,"dimming":50}}"#, port: port)
            let push = try await listener.receiveJSON()
            #expect(push["method"] == "syncPilot")
            #expect(push["params"]?["dimming"] == 50)
            #expect(push["params"]?["mac"] == "a8bb5006033d")

            bulb.externalChange(["state": false], src: "wizmote")
            let push2 = try await listener.receiveJSON()
            #expect(push2["params"]?["state"] == false)
            #expect(push2["params"]?["src"] == "wizmote")

            // No push when nothing changed.
            _ = try await c.request(#"{"method":"setState","params":{"state":false}}"#, port: port)
            #expect(await listener.inbox.next(timeout: .milliseconds(300)) == nil)
        }
    }

    @Test func signingModeRejectsUnsignedAndWrongSignatures() async throws {
        let cfg = FakeWiZBulb.Configuration(signingKey: Self.key)
        try await withBulb(cfg) { bulb, c in
            let port = bulb.port!
            let now = Int(Date().timeIntervalSince1970)

            // Reads stay unsigned but replies carry sigTs + hmac.
            let pilot = try await c.request(#"{"method":"getPilot","params":{}}"#, port: port)
            #expect(pilot["result"]?["mac"] == "a8bb5006033d")
            #expect(pilot["result"]?["sigTs"]?.intValue != nil)
            if let result = pilot["result"]?.objectValue {
                #expect(pilot["hmac"]?.stringValue == SimCrypto.hmacSHA256Base64(Array(result.compact.utf8), key: Self.key))
            }

            let unsigned = try await c.request(#"{"method":"setPilot","params":{"state":true}}"#, port: port)
            #expect(unsigned["env"] == "pro")
            #expect(unsigned["error"]?["code"] == -32602)
            #expect(unsigned["error"]?["message"] == "Invalid params")
            #expect(unsigned["error"]?["sigTs"]?.intValue != nil)
            #expect(bulb.pilot["state"] == false)

            let wrongKey = Self.signed("setPilot", params: #""state":true"#, sigTs: now, key: [UInt8](repeating: 0xFF, count: 16))
            let wrong = try await c.request(wrongKey, port: port)
            #expect(wrong["error"]?["code"] == -32605)
            #expect(wrong["error"]?["message"] == "Security error")

            let stale = Self.signed("setPilot", params: #""state":true"#, sigTs: now - 120, key: Self.key)
            #expect(try await c.request(stale, port: port)["error"]?["code"] == -32605)

            let good = Self.signed("setPilot", params: #""state":true,"dimming":40"#, sigTs: now, key: Self.key)
            let ok = try await c.request(good, port: port)
            #expect(ok["result"]?["success"] == true)
            #expect(bulb.pilot["state"] == true)
            #expect(bulb.pilot["dimming"] == 40)
            #expect(bulb.pilot["sigTs"] == nil)

            let goodState = Self.signed("setState", params: #""state":false"#, sigTs: now, key: Self.key)
            #expect(try await c.request(goodState, port: port)["result"]?["success"] == true)

            // Registration remains unsigned.
            let reg = try await c.request(
                #"{"method":"registration","params":{"phoneIp":"127.0.0.1","phoneMac":"aabbccddeeff","register":true}}"#,
                port: port)
            #expect(reg["result"]?["success"] == true)

            // Toggle "Allow all controls" at runtime.
            bulb.setSigningMode(false)
            let open = try await c.request(#"{"method":"setPilot","params":{"state":true}}"#, port: port)
            #expect(open == ["method": "setPilot", "env": "pro", "result": ["success": true]])
        }
    }
}
