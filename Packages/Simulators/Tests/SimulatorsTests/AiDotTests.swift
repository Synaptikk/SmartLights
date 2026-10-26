import Foundation
import NIOHTTP1
import Testing

@testable import Simulators

@Suite("FakeAiDot")
struct AiDotTests {
    static let appIdHeader = ("Appid", "1383974540041977857")

    @Test func aesKnownAnswerAndPadding() throws {
        // FIPS-197 C.1: AES-128 single block.
        let key = SimCrypto.hexDecode("000102030405060708090a0b0c0d0e0f")!
        let pt = SimCrypto.hexDecode("00112233445566778899aabbccddeeff")!
        let ct = try SimCrypto.aesECBEncrypt(pt, key: key)
        #expect(SimCrypto.hexEncode(Array(ct.prefix(16))) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(ct.count == 32)  // full PKCS7 padding block
        #expect(try SimCrypto.aesECBDecrypt(ct, key: key) == pt)
        // FIPS-197 C.3: AES-256.
        let key256 = SimCrypto.hexDecode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let ct256 = try SimCrypto.aesECBEncrypt(pt, key: key256)
        #expect(SimCrypto.hexEncode(Array(ct256.prefix(16))) == "8ea2b7ca516745bfeafc49904b496089")
        #expect(SimCrypto.aidotDiscoveryKey.count == 32)
        #expect(Array(SimCrypto.aidotDiscoveryKey.prefix(12)) == Array("T54uednca587".utf8))
        #expect(AiDotConstants.packRGBW(r: 255, g: 0, b: 0, w: 0) == -16_777_216)
        #expect(AiDotConstants.unpackRGBW(-16_777_216) == (255, 0, 0, 0))
    }

    @Test func frameHeaderLayout() {
        let f = AiDotFrame(msgType: 2, body: [1, 2, 3])
        #expect(f.encoded() == [0x1E, 0xED, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 1, 2, 3])
    }

    @Test func cloudLoginHousesDevicesProducts() async throws {
        let runner = SimulatorRunner()
        let device = try await runner.start(FakeAiDotDevice())
        let cloud = try await runner.start(FakeAiDotCloud(devices: [device]))
        defer { Task { try await runner.stopAll() } }
        let port = cloud.port!
        let rsaPassword = Data((0..<128).map { UInt8($0) }).base64EncodedString()
        func login(_ user: String) async throws -> HTTPTestResponse {
            try await HTTPTestConnection.request(
                .POST, port: port, path: "/v35/users/loginWithFreeVerification", tls: false,
                headers: [Self.appIdHeader, ("Terminal", "app"), ("Content-Type", "application/json")],
                body: #"{"countryKey":"region:United States","username":"\#(user)","password":"\#(rsaPassword)","terminalId":"abc","webVersion":"0.5.0","area":"Asia/Shanghai","UTC":"UTC+8"}"#
            )
        }

        let bad = try await login("wrong@example.com")
        #expect(bad.status == .badRequest)
        #expect(bad.json?["code"] == 560080)

        let noAppId = try await HTTPTestConnection.request(.GET, port: port, path: "/v35/houses", tls: false)
        #expect(noAppId.status == .badRequest)

        let ok = try await login("user@example.com")
        #expect(ok.status == .ok)
        let userId = try #require(ok.json?["id"]?.stringValue)
        let access = try #require(ok.json?["accessToken"]?.stringValue)
        let refresh = try #require(ok.json?["refreshToken"]?.stringValue)
        #expect(userId == device.info.ownerUserId)

        func get(_ path: String, token: String) async throws -> HTTPTestResponse {
            try await HTTPTestConnection.request(
                .GET, port: port, path: "/v35" + path, tls: false, headers: [Self.appIdHeader, ("Terminal", "app"), ("Token", token)])
        }
        let noAuth = try await get("/houses", token: "bogus")
        #expect(noAuth.status == .unauthorized)
        #expect(noAuth.json?["code"] == 21025)

        let houses = try await get("/houses", token: access)
        let house = try #require(houses.json?.arrayValue?.first)
        #expect(house["isOwner"] == true)
        let houseId = try #require(house["id"]?.stringValue)

        let devices = try await get("/devices?houseId=\(houseId)", token: access)
        let rec = try #require(devices.json?.arrayValue?.first)
        #expect(rec["id"]?.stringValue == device.info.id)
        #expect(rec["aesKey"] == [.string(device.info.aesKey)])
        #expect(rec["password"]?.stringValue == device.info.password)
        #expect(rec["type"] == "light")
        #expect(rec["properties"]?["ipAddress"] == "127.0.0.1")
        #expect(rec["properties"]?["OnOff"] == 1)
        let productId = try #require(rec["productId"]?.stringValue)

        let products = try await get("/products/\(productId)", token: access)
        let product = try #require(products.json?.arrayValue?.first)
        #expect(product["id"]?.stringValue == productId)
        let identities = product["serviceModules"]?.arrayValue?.compactMap { $0["identity"]?.stringValue } ?? []
        #expect(identities.contains("control.light.rgbw"))
        #expect(identities.contains("control.light.cct"))

        // Expired token -> 21026, refresh -> new token works.
        cloud.expireAccessTokens()
        let expired = try await get("/houses", token: access)
        #expect(expired.status == .unauthorized)
        #expect(expired.json?["code"] == 21026)
        let refreshed = try await HTTPTestConnection.request(
            .POST, port: port, path: "/v35/users/refreshToken", tls: false, headers: [Self.appIdHeader],
            body: #"{"refreshToken":"\#(refresh)"}"#)
        let newAccess = try #require(refreshed.json?["accessToken"]?.stringValue)
        #expect(try await get("/houses", token: newAccess).status == .ok)

        cloud.invalidateRefreshTokens()
        let deadRefresh = try await HTTPTestConnection.request(
            .POST, port: port, path: "/v35/users/refreshToken", tls: false, headers: [Self.appIdHeader],
            body: #"{"refreshToken":"\#(refreshed.json?["refreshToken"]?.stringValue ?? "")"}"#)
        #expect(deadRefresh.status == .badRequest)
        #expect(deadRefresh.json?["code"] == 21025)
    }

    @Test func udpDiscovery() async throws {
        let runner = SimulatorRunner()
        let device = try await runner.start(FakeAiDotDevice())
        defer { Task { try await runner.stopAll() } }
        let client = try await UDPTestClient.make()
        defer { Task { await client.close() } }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let req: JSON = [
            "protocolVer": "2.0.0", "service": "device", "method": "devDiscoveryReq", "seq": .string(String(now)),
            "srcAddr": "0.1840000000000000001", "tst": .int(now),
            "payload": ["extends": [:], "localCtrFlag": 1, "timestamp": .string(String(now))],
        ]
        let enc = try SimCrypto.aesECBEncrypt(Array(req.compact.utf8), key: SimCrypto.aidotDiscoveryKey)
        try await client.send(enc, port: device.discoveryPort!)
        let reply = try JSON.parse(try SimCrypto.aesECBDecrypt(try await client.receive(), key: SimCrypto.aidotDiscoveryKey))
        #expect(reply["payload"]?["devId"]?.stringValue == device.info.id)
        #expect(reply["payload"]?["ip"] == "127.0.0.1")
        #expect(reply["payload"]?["mac"]?.stringValue == device.info.mac)
        #expect(reply["payload"]?["productModel"]?.stringValue == device.info.modelId)
        #expect(device.discoveryRequestCount == 1)

        // Garbage is ignored.
        try await client.send([1, 2, 3], port: device.discoveryPort!)
        #expect(await client.inbox.next(timeout: .milliseconds(300)) == nil)
    }

    @Test func tcpLoginControlAndPush() async throws {
        let runner = SimulatorRunner()
        let device = try await runner.start(FakeAiDotDevice())
        defer { Task { try await runner.stopAll() } }
        let info = device.info
        let key = SimCrypto.paddedKey(info.aesKey, length: 16)
        let port = device.tcpPort!

        func loginReq(_ userId: String) -> JSON {
            [
                "service": "device", "method": "loginReq", "seq": "123456789", "srcAddr": .string(userId),
                "deviceId": .string(info.id),
                "payload": [
                    "userId": .string(userId), "password": .string(info.password),
                    "timestamp": "2026-10-26 10:00:00.000000", "ascNumber": 1,
                ],
            ]
        }

        // Non-owner (shared-home member) is refused.
        let intruder = try await TCPFrameClient.connect(port: port, key: key)
        try await intruder.send(loginReq("1840000000000000999"))
        let (_, denied) = try await intruder.receive(label: "step2")
        let deniedCode = try #require(denied["ack"]?["code"]?.intValue)
        #expect((400..<500).contains(deniedCode))
        // Not logged in -> actions refused.
        try await intruder.send(["method": "getDevAttrReq", "service": "device", "seq": "1", "payload": ["attr": []]])
        #expect(try await intruder.receive(label: "step3").1["ack"]?["code"] == 401)
        await intruder.close()

        let c = try await TCPFrameClient.connect(port: port, key: key)
        try await c.send(loginReq(info.ownerUserId))
        let (lf, login) = try await c.receive(label: "step4")
        #expect(lf.magic == 0x1EED)
        #expect(lf.msgType == 1)
        #expect(login["ack"]?["code"] == 200)
        let asc = try #require(login["payload"]?["ascNumber"]?.intValue)

        try await c.send(["method": "getDevAttrReq", "service": "device", "seq": "ha9300002", "payload": ["attr": []]])
        let (_, attrs) = try await c.receive(label: "step5")
        #expect(attrs["ack"]?["code"] == 200)
        #expect(attrs["payload"]?["attr"]?["OnOff"] == 1)
        #expect(attrs["payload"]?["attr"]?["RGBW"] == -16_777_216)

        let set: JSON = [
            "method": "setDevAttrReq", "service": "device", "clientId": .string("ha-\(info.ownerUserId)"),
            "srcAddr": .string("0.\(info.ownerUserId)"), "seq": "ha9300003", "deviceId": .string(info.id),
            "tst": 1_790_000_000_000,
            "payload": [
                "devId": .string(info.id), "parentId": .string(info.id), "userId": .string(info.ownerUserId),
                "password": .string(info.password), "channel": "tcp", "ascNumber": .int(asc + 1),
                "attr": ["OnOff": 0, "Dimming": 40, "RGBW": .int(AiDotConstants.packRGBW(r: 0, g: 0, b: 255, w: 0))],
            ],
        ]
        try await c.send(set)
        let (_, ack) = try await c.receive(label: "step6")
        #expect(ack["ack"]?["code"] == 200)
        #expect(ack["seq"] == "ha9300003")
        let (_, push) = try await c.receive(label: "step7")
        #expect(push["payload"]?["attr"]?["OnOff"] == 0)
        #expect(push["payload"]?["attr"]?["Dimming"] == 40)
        #expect(device.lightState.onOff == 0)
        #expect(device.lightState.dimming == 40)
        #expect(AiDotConstants.unpackRGBW(device.lightState.rgbw) == (0, 0, 255, 0))

        // Ping uses msgtype 2.
        try await c.send(["service": "test", "method": "pingreq", "seq": "123456", "srcAddr": "123456", "payload": [:]], msgType: 2)
        let (pf, pong) = try await c.receive(label: "step8")
        #expect(pf.msgType == 2)
        #expect(pong["method"] == "pingresp")

        // Change from the app/wall switch is pushed.
        device.externalChange(["CCT": 4000])
        let (_, ext) = try await c.receive(label: "step9")
        #expect(ext["payload"]?["attr"]?["CCT"] == 4000)
        #expect(device.loggedInSessionCount == 1)
        await c.close()
    }
}
