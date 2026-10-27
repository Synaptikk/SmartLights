import Foundation
import LightCore
import Testing
import _CryptoExtras

@testable import AiDotCodec

/// Vectors in `Fixtures/aidot_fixtures.json` come from python-aidot 0.3.59 (`Fixtures/gen_fixtures.py`).
enum Fixture {
    static let json: AiDotJSON = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/aidot_fixtures.json")
        let data = try! Data(contentsOf: url)
        return try! AiDotJSON.parse(data)
    }()

    static subscript(_ key: String) -> AiDotJSON { json[key] ?? .null }

    static func bytes(_ hex: String?) -> [UInt8] { AiDotCrypto.bytes(hex: hex ?? "") ?? [] }

    static let userId = "1840000000000000001"
    static let devId = "8a040e2233a243e7a07eb6a1b7a210a7"
    static let devPassword = "devpass-0001"
    static let tst: Int64 = 1_761_475_200_123
}

@Suite("AiDot constants and cloud")
struct CloudTests {
    @Test func constantsMatchUpstream() {
        #expect(Fixture["appId"].stringValue == AiDotConstants.appId)
        #expect(Fixture["apiUrlUS"].stringValue == AiDotRegion.us.baseURL.absoluteString)
        #expect(AiDotRegion.eu.baseURL.absoluteString == "https://prod-eu-api.arnoo.com/v35")
        let norm = { (s: String) in s.filter { !$0.isWhitespace } }
        #expect(norm(Fixture["publicKeyPem"].stringValue ?? "") == norm(AiDotCrypto.publicKeyPEM))
        #expect(Fixture["errorCodes"]["TOKEN_EXPIRED"]?.intValue == AiDotServerCode.tokenExpired)
        #expect(Fixture["errorCodes"]["LOGIN_INVALID"]?.intValue == AiDotServerCode.loginInvalid)
        #expect(Fixture["errorCodes"]["USER_PWD_INCORRECT"]?.intValue == AiDotServerCode.userPasswordIncorrect)
    }

    @Test func regionMapMatchesUpstream() throws {
        let upstream = try #require(Fixture["countries"].arrayValue)
        #expect(upstream.count == AiDotCountry.all.count)
        for (u, c) in zip(upstream, AiDotCountry.all) {
            #expect(u["id"]?.stringValue == c.code)
            #expect(u["name"]?.stringValue == c.name)
            #expect(u["region"]?.stringValue == c.region.rawValue)
        }
        #expect(AiDotCountry.region(forCountryCode: "us") == .us)
        #expect(AiDotCountry.region(forCountryCode: "DE") == .eu)
        #expect(AiDotCountry.region(forCountryCode: "AU") == .jp)
        #expect(AiDotCountry.region(forCountryCode: "GB") == .eu)
        #expect(AiDotCountry.region(forCountryCode: "XX") == nil)
        #expect(AiDotCountry.named(code: "US")?.countryKey == "region:United States")
        #expect(AiDotCountry.sortedByName.first?.name == "Afghanistan")
    }

    @Test func headersAndRequests() throws {
        #expect(AiDotAPI.headers() == ["Appid": "1383974540041977857", "Terminal": "app"])
        #expect(AiDotAPI.headers(token: "t")["Token"] == "t")
        #expect(AiDotAPI.headers(token: "t")["Authorization"] == nil)

        let login = AiDotAPI.login(country: try #require(AiDotCountry.named(code: "US")), username: "a@b.c",
                                   encryptedPassword: "RSA==", terminalId: "tid")
        #expect(login.method == "POST")
        #expect(login.path == "/users/loginWithFreeVerification")
        #expect(login.headers["Token"] == nil)
        // Field names/order/values as python-aidot client.async_post_login.
        #expect(String(decoding: login.body ?? Data(), as: UTF8.self)
            == #"{"countryKey": "region:United States", "username": "a@b.c", "password": "RSA==", "terminalId": "tid", "webVersion": "0.5.0", "area": "Asia/Shanghai", "UTC": "UTC+8"}"#)
        #expect(login.url(baseURL: AiDotRegion.us.baseURL)?.absoluteString == "https://prod-us-api.arnoo.com/v35/users/loginWithFreeVerification")

        let refresh = AiDotAPI.refreshToken("r1")
        #expect(refresh.path == "/users/refreshToken")
        #expect(String(decoding: refresh.body ?? Data(), as: UTF8.self) == #"{"refreshToken": "r1"}"#)
        #expect(AiDotAPI.houses(token: "t").path == "/houses")
        #expect(AiDotAPI.devices(houseId: "h 1", token: "t").path == "/devices?houseId=h%201")
        #expect(AiDotAPI.products(ids: ["1", "2", "1"], token: "t").path == "/products/1,2,1")
        #expect(AiDotAPI.terminalId(rawId: AiDotConstants.fallbackTerminalRawId) == Fixture["terminalIdFallbackMd5"].stringValue)
    }

    @Test func errorCodeMapping() {
        func body(_ code: Int) -> Data { Data(#"{"code": \#(code), "desc": "x"}"#.utf8) }
        #expect(AiDotCloudError.classify(status: 401, body: body(21026)) == .tokenExpired)
        #expect(AiDotCloudError.classify(status: 400, body: body(21025)) == .loginInvalid)
        #expect(AiDotCloudError.classify(status: 400, body: body(560080)) == .badCredentials)
        #expect(AiDotCloudError.classify(status: 401, body: body(21027)) == .authenticationFailed(code: 21027))
        #expect(AiDotCloudError.classify(status: 401, body: body(21041)) == .authenticationFailed(code: 21041))
        #expect(AiDotCloudError.classify(status: 200, body: body(21026)) == .tokenExpired)
        #expect(AiDotCloudError.classify(status: 200, body: Data("[]".utf8)) == nil)
        #expect(AiDotCloudError.classify(status: 200, body: body(1)) == nil)
        #expect(AiDotCloudError.classify(status: 500, body: body(1)) == .server(status: 500, code: 1, message: "x"))
        #expect(AiDotCloudError.classify(status: 502, body: Data("<html>".utf8)) == .server(status: 502, code: nil, message: nil))
        #expect(AiDotCloudError.loginInvalid.requiresReauthentication)
        #expect(!AiDotCloudError.tokenExpired.requiresReauthentication)
    }

    @Test func responseModels() throws {
        let login = try AiDotAPI.decodeLogin(status: 200, body: Data(#"{"id": 1840000000000000001, "accessToken": "a", "refreshToken": "r", "username": "u"}"#.utf8))
        #expect(login.userId == "1840000000000000001")
        #expect(login.accessToken == "a")
        #expect(throws: AiDotCloudError.badCredentials) {
            try AiDotAPI.decodeLogin(status: 400, body: Data(#"{"code": 560080}"#.utf8))
        }
        let houses = try AiDotAPI.decodeHouses(status: 200, body: Data(#"[{"id": "h1", "isOwner": true}, {"id": "h2", "isOwner": false}, {"id": "h3"}]"#.utf8))
        #expect(AiDotAPI.ownedHouses(houses).map(\.id) == ["h1", "h3"])

        let devices = try AiDotAPI.decodeDevices(status: 200, body: Data("""
            [{"id": "d1", "name": "Lamp", "mac": "aa", "type": "light", "modelId": "LK.light.A001493", "productId": "p1",
              "aesKey": ["0123456789abcdef", null], "password": "pw", "online": true,
              "properties": {"ipAddress": "192.168.1.9", "OnOff": "1", "Dimming": "40", "CCT": "3000", "RGBW": "-16777216"}},
             {"id": "d2", "type": "light", "aesKey": [null]},
             {"id": "d3", "type": "plug", "aesKey": ["k"], "simpleVersion": "1"}]
            """.utf8))
        #expect(devices.count == 3)
        #expect(devices[0].isLANLight && !devices[1].isLANLight && !devices[2].isLANLight)
        #expect(devices[0].sessionKey == "0123456789abcdef")
        #expect(devices[0].cloudIPAddress == "192.168.1.9")
        #expect(devices[0].simpleVersion == nil && devices[2].simpleVersion == "1")
        let products = try AiDotAPI.decodeProducts(status: 200, body: Data("""
            [{"id": "p1", "serviceModules": [{"identity": "control.light.cct", "properties": [{"identifier": "CCT", "minValue": 2700, "maxValue": 6500}]}]}]
            """.utf8))
        let attached = AiDotAPI.attachProducts(products, to: devices)
        #expect(attached[0].product?.id == "p1")
        // Cache round-trip keeps the record.
        let back = try #require(AiDotDeviceRecord(json: try AiDotJSON.parse(attached[0].json.compactString())))
        #expect(back == attached[0])
    }
}

@Suite("AiDot crypto")
struct CryptoTests {
    @Test func aesKnownAnswerFIPS197() throws {
        // FIPS-197 Appendix C.1 (AES-128) and C.3 (AES-256).
        let pt = Fixture.bytes("00112233445566778899aabbccddeeff")
        let k128 = Fixture.bytes("000102030405060708090a0b0c0d0e0f")
        #expect(AiDotCrypto.hex(try AiDotCrypto.ecbEncryptBlocks(pt, key: k128)) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        let k256 = Fixture.bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        #expect(AiDotCrypto.hex(try AiDotCrypto.ecbEncryptBlocks(pt, key: k256)) == "8ea2b7ca516745bfeafc49904b496089")
        #expect(try AiDotCrypto.ecbDecryptBlocks(Fixture.bytes("69c4e0d86a7b0430d8cdb78070b4c55a"), key: k128) == pt)
    }

    @Test func pkcs7() throws {
        #expect(AiDotCrypto.pkcs7Pad([]).count == 16)
        #expect(AiDotCrypto.pkcs7Pad([UInt8](repeating: 1, count: 16)).count == 32)
        #expect(try AiDotCrypto.pkcs7Unpad(AiDotCrypto.pkcs7Pad([1, 2, 3])) == [1, 2, 3])
        #expect(throws: AiDotCrypto.Failure.badPadding) { try AiDotCrypto.pkcs7Unpad([UInt8](repeating: 0, count: 16)) }
    }

    @Test func deviceKeyPadding() throws {
        for k in try #require(Fixture["keys"].arrayValue) {
            #expect(AiDotCrypto.hex(AiDotCrypto.deviceKey(k["aesKey"]?.stringValue ?? "")) == k["keyHex"]?.stringValue)
        }
        #expect(AiDotCrypto.discoveryKey.count == 32)
        #expect(AiDotCrypto.deviceKey(String(repeating: "x", count: 20)).count == 16)
    }

    @Test func rsaPasswordEncryption() throws {
        let key = try AiDotCrypto.loginPublicKey()
        #expect(key.keySizeInBits == 1024)
        let a = try AiDotCrypto.encryptPassword("hunter2")
        let b = try AiDotCrypto.encryptPassword("hunter2")
        #expect(Data(base64Encoded: a)?.count == 128)
        #expect(a.count == 172)
        #expect(a != b) // random PKCS#1 v1.5 padding

        // Round-trip through a generated 1024-bit key proves the padding mode is PKCS#1 v1.5.
        let priv = try _RSA.Encryption.PrivateKey(unsafeKeySize: .init(bitCount: 1024))
        let ct = try AiDotCrypto.encryptPassword("pässword", with: priv.publicKey)
        let plain = try priv.decrypt(try #require(Data(base64Encoded: ct)), padding: ._WEAK_AND_INSECURE_PKCS_V1_5)
        #expect(String(decoding: plain, as: UTF8.self) == "pässword")
    }
}

@Suite("AiDot JSON")
struct JSONTests {
    @Test func pythonFormatting() throws {
        let v: AiDotJSON = .obj(["a": 1, "b": [true, nil, "x\"\n\u{e9}\u{1F600}"], "c": .object([])])
        let esc = #"\"\n\u00e9\ud83d\ude00"# // escaped quote, newline, e-acute, U+1F600
        #expect(v.pythonDumps() == #"{"a": 1, "b": [true, null, "x"# + esc + #""], "c": {}}"#)
        #expect(v.compactString() == #"{"a":1,"b":[true,null,"x"# + esc + #""],"c":{}}"#)
        let parsed = try AiDotJSON.parse(v.pythonDumps())
        #expect(parsed == v)
        #expect(try AiDotJSON.parse("-2.5e3") == .double(-2500))
        #expect(try AiDotJSON.parse("-16777216") == .int(-16_777_216))
        #expect(throws: (any Error).self) { try AiDotJSON.parse("{\"a\": }") }
    }
}

@Suite("AiDot discovery")
struct DiscoveryTests {
    @Test func requestMatchesPython() throws {
        let f = Fixture["discoveryRequest"]
        let req = AiDotDiscovery.request(userId: Fixture.userId, milliseconds: Fixture.tst)
        #expect(req.pythonDumps() == f["json"]?.stringValue)
        #expect(req["seq"]?.stringValue == f["seq"]?.stringValue)
        let datagram = try AiDotDiscovery.datagram(userId: Fixture.userId, milliseconds: Fixture.tst)
        #expect(AiDotCrypto.hex(datagram) == f["cipherHex"]?.stringValue)
        // Our own looped-back request is not a reply.
        #expect(AiDotDiscovery.parseReply(datagram) == nil)
    }

    @Test func parsesReply() throws {
        let f = Fixture["discoveryResponse"]
        let reply = try #require(AiDotDiscovery.parseReply(Data(Fixture.bytes(f["cipherHex"]?.stringValue))))
        #expect(reply.devId == Fixture.devId)
        #expect(reply.ip == "192.168.1.42")
        #expect(reply.mac == "a4:c1:38:00:00:01")
        #expect(reply.productModel == "LK.light.A001493")
        #expect(reply.ackCode == 200)
        #expect(reply.srvHost == "prod-us-mqtt.arnoo.com")
        #expect(reply.metadata["lanMode"] == "1")
        #expect(AiDotDiscovery.parseReply(Data([1, 2, 3])) == nil)
    }
}

@Suite("AiDot TCP frames")
struct FrameTests {
    let codec = AiDotSessionCodec(aesKey: "0123456789abcdef")

    @Test func loginFrameMatchesPython() throws {
        let f = Fixture["loginFrame"]
        let login = AiDotMessages.loginRequest(seq: "475200123", userId: Fixture.userId, deviceId: Fixture.devId,
                                               devicePassword: Fixture.devPassword, timestamp: "2026-10-26 12:34:56.789012")
        #expect(login.pythonDumps() == f["json"]?.stringValue)
        #expect(AiDotCrypto.hex(try codec.frame(login)) == f["frameHex"]?.stringValue)
        #expect(AiDotCrypto.hex(codec.key) == f["keyHex"]?.stringValue)
    }

    @Test func actionFramesMatchPython() throws {
        let full = Fixture["setDevAttrFull"]
        let attr = AiDotAttributes(onOff: 1, dimming: 40, rgbw: AiDotAttributes.packRGBW(RGBW(r: 255, g: 128, b: 0, w: 10)))
        #expect(attr.rgbw == -8_388_598)
        let set = AiDotMessages.setDevAttrRequest(userId: Fixture.userId, deviceId: Fixture.devId, devicePassword: Fixture.devPassword,
                                                  ascNumber: 5, attributes: attr, seq: "ha9300002", simpleVersion: "1", tst: Fixture.tst)
        #expect(set.pythonDumps() == full["json"]?.stringValue)
        #expect(AiDotCrypto.hex(try codec.frame(set)) == full["frameHex"]?.stringValue)

        let simple = Fixture["setDevAttrSimple"]
        let cct = AiDotMessages.setDevAttrRequest(userId: Fixture.userId, deviceId: Fixture.devId, devicePassword: Fixture.devPassword,
                                                  ascNumber: 9, attributes: AiDotAttributes(cct: 4000), seq: "ha9300003",
                                                  simpleVersion: nil, tst: Fixture.tst)
        #expect(AiDotCrypto.hex(try codec.frame(cct)) == simple["frameHex"]?.stringValue)

        for (key, props, seq) in [("getDevAttrEmpty", [String](), "ha9300004"),
                                  ("getDevAttrD0006", AiDotConstants.firstGenerationSyncProperties, "ha9300005")] {
            let get = AiDotMessages.getDevAttrRequest(userId: Fixture.userId, deviceId: Fixture.devId, devicePassword: Fixture.devPassword,
                                                      ascNumber: 2, properties: props, seq: seq, simpleVersion: nil, tst: Fixture.tst)
            #expect(AiDotCrypto.hex(try codec.frame(get)) == Fixture[key]["frameHex"]?.stringValue)
        }

        let ping = Fixture["pingFrame"]
        #expect(AiDotMessages.pingRequest.pythonDumps() == ping["json"]?.stringValue)
        #expect(AiDotCrypto.hex(try codec.frame(AiDotMessages.pingRequest, type: .ping)) == ping["frameHex"]?.stringValue)
        let shortCodec = AiDotSessionCodec(aesKey: "abc123")
        #expect(AiDotCrypto.hex(try shortCodec.frame(AiDotMessages.pingRequest, type: .ping)) == Fixture["shortKeyPingFrameHex"].stringValue)
    }

    @Test func decoderHandlesSplitAndCoalescedFrames() throws {
        let push = Data(Fixture.bytes(Fixture["statusPush"]["frameHex"]?.stringValue))
        let ping = Data(Fixture.bytes(Fixture["pingFrame"]["frameHex"]?.stringValue))
        var decoder = AiDotFrameDecoder()
        var all = push + ping
        var frames: [AiDotFrame] = []
        while !all.isEmpty {
            let chunk = all.prefix(7)
            all = all.dropFirst(7)
            frames += try decoder.append(Data(chunk))
        }
        #expect(frames.count == 2)
        #expect(frames.map(\.msgType) == [1, 2])
        #expect(decoder.bufferedByteCount == 0)

        let message = try codec.message(from: frames[0])
        #expect(message.ascNumber == 7)
        #expect(message.attributes == AiDotAttributes(onOff: 1, dimming: 55, cct: 4000, rgbw: 65280, effectUniqueID: "fx-1"))
        #expect(try codec.message(from: frames[1]).isPing)

        var bad = AiDotFrameDecoder()
        #expect(throws: AiDotFrameDecoder.Failure.badMagic(0xBEEF)) { try bad.append(Data([0xBE, 0xEF, 0, 1, 0, 0, 0, 0])) }
    }

    @Test func counters() {
        var c = AiDotSessionCounters()
        c.loggedIn(deviceAscNumber: 41)
        #expect(c.ascNumber == 42)
        #expect(c.nextActionSeq() == "ha9300002")
        #expect(c.nextActionSeq() == "ha9300003")
        c.observe(AiDotDeviceMessage(json: .obj(["payload": .obj(["ascNumber": 0])])))
        #expect(c.ascNumber == 42)
        c.observe(AiDotDeviceMessage(json: .obj(["payload": .obj(["ascNumber": 50])])))
        #expect(c.ascNumber == 50)
        #expect(AiDotMessages.loginSeq(milliseconds: 1_761_475_200_123, attempt: 0) == "475200123")
    }

    @Test func timestampFormat() {
        let d = Date(timeIntervalSince1970: 1_761_482_096.789012)
        #expect(AiDotTimestamp.string(from: d, timeZone: TimeZone(identifier: "UTC")!) == "2025-10-26 12:34:56.789011"
            || AiDotTimestamp.string(from: d, timeZone: TimeZone(identifier: "UTC")!) == "2025-10-26 12:34:56.789012")
        #expect(AiDotTimestamp.string(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!) == "1970-01-01 00:00:00.000000")
    }
}

@Suite("AiDot attribute mapping")
struct AttributeTests {
    @Test func rgbwPackingMatchesPython() throws {
        for c in try #require(Fixture["rgbw"].arrayValue) {
            let v = (c["rgbw"]?.arrayValue ?? []).compactMap(\.intValue).map(UInt8.init)
            let rgbw = RGBW(r: v[0], g: v[1], b: v[2], w: v[3])
            #expect(Int(AiDotAttributes.packRGBW(rgbw)) == c["packed"]?.intValue)
            let u = (c["unpacked"]?.arrayValue ?? []).compactMap(\.intValue).map(UInt8.init)
            #expect(AiDotAttributes.unpackRGBW(AiDotAttributes.packRGBW(rgbw)) == RGBW(r: u[0], g: u[1], b: u[2], w: u[3]))
        }
        // r >= 128 gives a negative int32.
        #expect(AiDotAttributes.packRGBW(RGBW(r: 128, g: 0, b: 0, w: 0)) == Int32.min)
        #expect(AiDotAttributes(json: .obj(["RGBW": .int(4_278_190_080)])).rgbw == -16_777_216)
    }

    @Test func capabilities() throws {
        let rgbwProduct = try #require(AiDotProduct(json: .obj(["id": "p", "serviceModules": [.obj(["identity": "control.light.rgbw"])]])))
        let f1 = AiDotFeatures(product: rgbwProduct, properties: .null)
        #expect(f1.capabilities.supportedColorModes == [.rgbw, .colorTemp])
        let cctProduct = try #require(AiDotProduct(json: try AiDotJSON.parse(
            #"{"id": "p", "serviceModules": [{"identity": "control.light.cct", "properties": [{"minValue": 2700, "maxValue": 6500}]}]}"#)))
        let f2 = AiDotFeatures(product: cctProduct, properties: .null)
        #expect(f2.capabilities.supportedColorModes == [.colorTemp])
        #expect(f2.capabilities.kelvinRange == 2700...6500)
        #expect(AiDotFeatures(product: nil, properties: .obj(["OnOff": 1, "Dimming": 50])).capabilities.supportedColorModes == [.brightness])
        #expect(AiDotFeatures(product: nil, properties: .obj(["RGBW": 0])).capabilities.supportedColorModes == [.rgbw, .colorTemp])
        #expect(AiDotFeatures(product: nil, properties: .obj(["CCT": "3000"])).capabilities.supportedColorModes == [.colorTemp])
    }

    @Test func stateFromPushes() {
        var m = AiDotLightModel(features: AiDotFeatures(rgbw: true, cct: true))
        m.apply(AiDotAttributes(onOff: 1, dimming: 55, cct: 4000, rgbw: 65280))
        var s = m.lightState(reachable: true)
        #expect(s.isOn && s.brightness == 0.55 && s.colorMode == .colorTemp && s.kelvin == 4000)
        #expect(s.rgbw == RGBW(r: 0, g: 0, b: 255, w: 0))
        m.apply(AiDotAttributes(rgbw: AiDotAttributes.packRGBW(RGBW(r: 255, g: 0, b: 0, w: 0))))
        s = m.lightState(reachable: true)
        #expect(s.colorMode == .rgbw)
        m.apply(AiDotAttributes(onOff: 0, cct: 2700))
        s = m.lightState(reachable: false)
        #expect(!s.isOn && s.colorMode == .colorTemp && !s.reachable)
    }

    @Test func commandMapping() {
        let rgbw = AiDotFeatures(rgbw: true, cct: true, minKelvin: 2700, maxKelvin: 6500)
        #expect(AiDotCommandMapper.attributes(for: .turnOff, features: rgbw, currentlyOn: true) == AiDotAttributes(onOff: 0))
        #expect(AiDotCommandMapper.attributes(for: .turnOn, features: rgbw, currentlyOn: false) == AiDotAttributes(onOff: 1))
        // One setDevAttrReq with every changed attribute; implicit OnOff when the light is off.
        let a = AiDotCommandMapper.attributes(for: LightCommand(brightness: 0.4, color: .kelvin(9000)), features: rgbw, currentlyOn: false)
        #expect(a == AiDotAttributes(onOff: 1, dimming: 40, cct: 6500))
        let b = AiDotCommandMapper.attributes(for: LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), features: rgbw, currentlyOn: true)
        #expect(b.rgbw == AiDotAttributes.packRGBW(RGBW(r: 255, g: 0, b: 0, w: 0)))
        #expect(b.onOff == nil)
        #expect(AiDotCommandMapper.attributes(for: LightCommand(brightness: 0), features: rgbw, currentlyOn: true) == AiDotAttributes(onOff: 0))
        #expect(AiDotCommandMapper.attributes(for: LightCommand(brightness: 0.001), features: rgbw, currentlyOn: true).dimming == 1)
        // CCT-only light: colour converted to a Kelvin estimate; white light: colour dropped.
        let cctOnly = AiDotFeatures(rgbw: false, cct: true, minKelvin: 2700, maxKelvin: 6500)
        #expect(AiDotCommandMapper.attributes(for: LightCommand(color: .rgb(.white)), features: cctOnly, currentlyOn: true).cct != nil)
        let white = AiDotFeatures(rgbw: false, cct: false)
        #expect(AiDotCommandMapper.attributes(for: LightCommand(color: .kelvin(3000)), features: white, currentlyOn: true).isEmpty)
        #expect(AiDotAttributes(onOff: 1, dimming: 40, cct: 3000, rgbw: -1).json.pythonDumps()
            == #"{"OnOff": 1, "Dimming": 40, "CCT": 3000, "RGBW": -1}"#)
    }
}
