import Foundation
import LightCore
import Testing

@testable import MerossCodec

/// Vectors from `Fixtures/gen_fixtures.py` (meross_lan / MerossIot formulas, emulator traces).
enum Fixtures {
    static let all: MerossJSON = {
        let url = Bundle.module.url(forResource: "meross_fixtures", withExtension: "json", subdirectory: "Fixtures")!
        return try! MerossJSON.decode(try! Data(contentsOf: url))
    }()

    static subscript(_ key: String) -> MerossJSON { all[key]! }

    static func data(_ key: String) -> Data { all[key]!.encoded() }
}

@Suite("Meross local message signing")
struct MerossMessageTests {
    @Test func signaturesMatchMerossLan() {
        for v in Fixtures["signatures"].arrayValue! {
            let sign = MerossRequest.signature(messageId: v["messageId"]!.stringValue!, key: v["key"]!.stringValue!,
                                               timestamp: v["timestamp"]!.intValue!)
            #expect(sign == v["sign"]!.stringValue!)
        }
    }

    @Test func requestEnvelope() throws {
        let request = MerossRequest(namespace: MerossNamespace.systemAll, method: .get, payload: ["all": [:]],
                                    messageId: "5c3a4f1e9b2d8c7a6e5f4d3c2b1a0918", timestamp: 1670762076)
        let json = try MerossJSON.decode(request.encoded(key: "0123456789abcdef0123456789abcdef"))
        let header = try #require(json["header"])
        #expect(header["namespace"]?.stringValue == "Appliance.System.All")
        #expect(header["method"]?.stringValue == "GET")
        #expect(header["messageId"]?.stringValue == "5c3a4f1e9b2d8c7a6e5f4d3c2b1a0918")
        #expect(header["timestamp"]?.intValue == 1670762076)
        #expect(header["payloadVersion"]?.intValue == 1)
        #expect(header["from"]?.stringValue == "MerossClient")
        #expect(header["sign"]?.stringValue == Fixtures["signatures"].arrayValue![0]["sign"]!.stringValue)
        #expect(json["payload"] == ["all": [:]])
    }

    @Test func messageIdShape() {
        let id = MerossRequest.newMessageId()
        #expect(id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(id != MerossRequest.newMessageId())
    }

    @Test func togglePayloads() {
        #expect(MerossRequest.toggleX(on: true).payload == ["togglex": ["channel": 0, "onoff": 1]])
        #expect(MerossRequest.toggleX(on: false).namespace == "Appliance.Control.ToggleX")
        #expect(MerossRequest.toggle(on: false).payload == ["channel": 0, "toggle": ["channel": 0, "onoff": 0]])
        #expect(MerossRequest.getAbility().payload == ["ability": [:]])
    }

    @Test func parsesReplyAndUUIDFromTopic() throws {
        let response = try MerossResponse.parse(Fixtures.data("msl320_all"))
        #expect(response.namespace == "Appliance.System.All")
        #expect(response.method == .getAck)
        #expect(response.uuid == "2106040981431251802148e1e9a1b2c3")
        #expect(response.isSigned(with: "0123456789abcdef0123456789abcdef"))
        #expect(!response.isSigned(with: "wrong"))
        #expect(try response.checked() == response)
    }

    @Test func invalidKeyReply() throws {
        let response = try MerossResponse.parse(Fixtures.data("invalid_key_reply"))
        #expect(response.method == .error)
        #expect(response.uuid == "2106040981431251802148e1e9a1b2c3")
        #expect(throws: MerossDeviceError.invalidKey) { try response.checked() }
        let other = MerossResponse(namespace: "x", method: .error, payload: ["error": ["code": 5000, "detail": "busy"]])
        #expect(throws: MerossDeviceError.deviceError(code: 5000, detail: "busy")) { try other.checked() }
    }

    @Test func malformedReplies() {
        #expect(throws: MerossDeviceError.malformed("not JSON")) { try MerossResponse.parse(Data("<html>".utf8)) }
        #expect(throws: MerossDeviceError.malformed("missing header.namespace")) { try MerossResponse.parse(Data("{}".utf8)) }
    }

    @Test func merossMACPrefixes() {
        #expect(MerossConstants.isMerossMAC("48:e1:e9:01:02:03"))
        #expect(MerossConstants.isMerossMAC("C4E7AE010203"))
        #expect(MerossConstants.isMerossMAC("34:29:8f:12:34:56"))
        #expect(!MerossConstants.isMerossMAC("34:29:8f:22:34:56"))
        #expect(!MerossConstants.isMerossMAC("a8:bb:50:00:00:00"))
        #expect(MerossSystemInfo.macAddress(fromUUID: "2106040981431251802148e1e9a1b2c3") == "48:e1:e9:a1:b2:c3")
    }
}

@Suite("Meross cloud API")
struct MerossCloudTests {
    @Test func cloudSignatureMatchesMerossLan() throws {
        let c = Fixtures["cloud"]
        let ts = c["timestamp"]!.intValue!
        let nonce = c["nonce"]!.stringValue!
        let params = c["params"]!.stringValue!
        #expect(MerossCrypto.md5Hex(MerossCloudAPI.secret + String(ts) + nonce + params) == c["sign"]!.stringValue!)
        #expect(MerossCrypto.md5Hex("s3cret-pw") == c["passwordMD5"]!.stringValue!)
    }

    @Test func signInRequest() throws {
        let request = MerossCloudAPI.signIn(email: "user@example.com", password: "s3cret-pw", region: .eu,
                                            timestamp: 1730000000123, nonce: "ABCDEFGHIJ012345")
        #expect(request.path == "/v1/Auth/signIn")
        #expect(request.headers["Authorization"] == "Basic")
        #expect(request.headers["vender"] == "meross")
        #expect(request.url(baseURL: MerossRegion.eu.baseURL)?.absoluteString == "https://iotx-eu.meross.com/v1/Auth/signIn")
        let body = try MerossJSON.decode(request.body)
        let encodedParams = try #require(body["params"]?.stringValue)
        #expect(body["timestamp"]?.intValue == 1730000000123)
        #expect(body["nonce"]?.stringValue == "ABCDEFGHIJ012345")
        #expect(body["sign"]?.stringValue == MerossCrypto.md5Hex(MerossCloudAPI.secret + "1730000000123" + "ABCDEFGHIJ012345" + encodedParams))
        let params = try MerossJSON.decode(try #require(Data(base64Encoded: encodedParams)))
        // Same fields and values as meross_lan's async_cloudapi_signin (key order differs, the sign covers our string).
        let expected = try MerossJSON.decode(try #require(Data(base64Encoded: Fixtures["cloud"]["params"]!.stringValue!)))
        #expect(params == expected)
        #expect(!request.body.contains(Data("s3cret-pw".utf8)))
    }

    @Test func mfaCodeIsAdded() throws {
        let request = MerossCloudAPI.signIn(email: "a@b.c", password: "p", region: .us, mfaCode: "123456")
        let body = try MerossJSON.decode(request.body)
        let params = try MerossJSON.decode(Data(base64Encoded: body["params"]!.stringValue!)!)
        #expect(params["mfaCode"]?.stringValue == "123456")
        #expect(params["accountCountryCode"]?.stringValue == "us")
    }

    @Test func authenticatedHeaders() {
        let r = MerossCloudAPI.deviceList(token: "tok-abc")
        #expect(r.headers["Authorization"] == "Basic tok-abc")
        #expect(r.path == "/v1/Device/devList")
        #expect(MerossCloudAPI.newNonce().count == 16)
    }

    @Test func decodesSignIn() throws {
        let creds = try MerossCloudAPI.decodeSignIn(status: 200, body: Fixtures.data("signin_ok"))
        #expect(creds == MerossCredentials(userId: "1234567", email: "user@example.com", key: "0123456789abcdef0123456789abcdef",
                                           token: "tok-abc", domain: "https://iotx-eu.meross.com", mqttDomain: "mqtt-eu.meross.com"))
    }

    @Test func classifiesErrors() {
        #expect(throws: MerossCloudError.redirect(domain: "https://iotx-eu.meross.com")) {
            try MerossCloudAPI.decodeSignIn(status: 200, body: Fixtures.data("signin_redirect"))
        }
        #expect(throws: MerossCloudError.wrongCredentials(1004)) {
            try MerossCloudAPI.decodeSignIn(status: 200, body: Fixtures.data("signin_wrong_password"))
        }
        #expect(throws: MerossCloudError.http(500)) { try MerossCloudAPI.decode(status: 500, body: Data()) }
        #expect(MerossCloudError.classify(apiStatus: 1033, data: nil, info: nil) == .mfaRequired)
        #expect(MerossCloudError.classify(apiStatus: 1200, data: nil, info: nil).requiresReauthentication)
        #expect(MerossCloudError.classify(apiStatus: 1028, data: nil, info: nil) == .rateLimited(1028))
        #expect(MerossCloudError.classify(apiStatus: 9999, data: nil, info: "x") == .api(9999, "x"))
    }

    @Test func decodesDeviceList() throws {
        let devices = try MerossCloudAPI.decodeDeviceList(status: 200, body: Fixtures.data("devlist_ok"))
        #expect(devices.count == 2)
        #expect(devices[0].uuid == "2106040981431251802148e1e9a1b2c3")
        #expect(devices[0].name == "Desk lamp")
        #expect(devices[0].deviceType == "msl320cpr")
        #expect(devices[0].firmwareVersion == "4.3.5")
        #expect(devices[0].onlineStatus == 1)
        #expect(MerossDeviceProfile.guess(deviceType: devices[0].deviceType)?.lightCapacity == [.rgb, .temperature, .luminance])
        #expect(MerossDeviceProfile.guess(deviceType: devices[1].deviceType) == nil)
    }
}

@Suite("Meross crypto and HTTP framing")
struct MerossCryptoTests {
    @Test func encryptionKeyMatchesMerossLan() {
        let e = Fixtures["encryption"]
        let key = MerossCrypto.encryptionKey(uuid: e["uuid"]!.stringValue!, key: e["key"]!.stringValue!, mac: e["mac"]!.stringValue!)
        #expect(String(decoding: key, as: UTF8.self) == e["derivedKey"]!.stringValue!)
        // Python slicing of short strings.
        #expect(String(decoding: MerossCrypto.encryptionKey(uuid: "abc", key: "k", mac: "m"), as: UTF8.self) == e["shortKeyDerived"]!.stringValue!)
    }

    @Test func encryptedBodyMatchesMerossLan() throws {
        let e = Fixtures["encryption"]
        let key = Array(e["derivedKey"]!.stringValue!.utf8)
        let cipher = try MerossCrypto.encryptBody(Data(e["plaintext"]!.stringValue!.utf8), key: key)
        #expect(String(decoding: cipher, as: UTF8.self) == e["ciphertext"]!.stringValue!)
        let plain = try MerossCrypto.decryptBody(Data(e["ciphertext"]!.stringValue!.utf8), key: key)
        #expect(String(decoding: plain, as: UTF8.self) == e["plaintext"]!.stringValue!)
    }

    @Test func cbcKnownAnswer() throws {
        // NIST SP 800-38A F.2.5 (CBC-AES256.Encrypt), first block.
        let key = [UInt8](Data(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"))
        let iv = [UInt8](Data(hex: "000102030405060708090a0b0c0d0e0f"))
        let plain = [UInt8](Data(hex: "6bc1bee22e409f96e93d7e117393172a"))
        let cipher = try MerossCrypto.cbc(plain, key: key, iv: iv, decrypt: false)
        #expect(cipher == [UInt8](Data(hex: "f58c4c04d6e5f1ba779eabfb5f7bfbd6")))
        #expect(try MerossCrypto.cbc(cipher, key: key, iv: iv, decrypt: true) == plain)
        #expect(throws: MerossCrypto.Failure.badKeyLength(3)) { try MerossCrypto.cbc(plain, key: [1, 2, 3], iv: iv, decrypt: false) }
        #expect(throws: MerossCrypto.Failure.notBase64) { try MerossCrypto.decryptBody(Data("%%%".utf8), key: key) }
    }

    @Test func http1RequestAndResponse() throws {
        let request = MerossHTTP1.request(host: "192.168.1.50", body: Data("{}".utf8), contentType: "application/json")
        let text = String(decoding: request, as: UTF8.self)
        #expect(text.hasPrefix("POST /config HTTP/1.1\r\nHost: 192.168.1.50\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n\r\n{}"))

        let full = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{\"a\"".utf8)
        #expect(try MerossHTTP1.parse(full.prefix(full.count - 2), complete: false) == nil)
        let parsed = try #require(try MerossHTTP1.parse(full, complete: false))
        #expect(parsed.status == 200 && parsed.body == Data("{\"a\"".utf8))
        #expect(parsed.headers["content-type"] == "application/json")

        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
        #expect(try MerossHTTP1.parse(chunked, complete: false)?.body == Data("abcde".utf8))
        let noLength = Data("HTTP/1.0 500 Oops\r\n\r\nbody".utf8)
        #expect(try MerossHTTP1.parse(noLength, complete: false) == nil)
        #expect(try MerossHTTP1.parse(noLength, complete: true)?.status == 500)
        #expect(throws: MerossHTTP1.Failure.malformedStatusLine) { try MerossHTTP1.parse(Data("garbage\r\n\r\n".utf8), complete: true) }
    }
}

@Suite("Meross light mapping")
struct MerossLightTests {
    let rgbProfile = MerossDeviceProfile(lightCapacity: [.rgb, .temperature, .luminance], hasToggleX: true, hasToggle: false)

    @Test func abilityProfile() {
        let p = MerossDeviceProfile(ability: Fixtures["msl320_ability"])
        #expect(p.lightCapacity == [.rgb, .temperature, .luminance, .effect])
        #expect(p.hasToggleX && !p.hasToggle && !p.encrypted && p.isLight)
        #expect(p.capabilities.supportedColorModes == [.rgb, .colorTemp])
        #expect(p.capabilities.minKelvin == 2700 && p.capabilities.maxKelvin == 6500)

        let enc = MerossDeviceProfile(ability: ["ability": ["Appliance.Control.Light": [:], "Appliance.Encrypt.ECDHE": [:]]])
        #expect(enc.encrypted && enc.lightCapacity == .luminance)
        #expect(enc.capabilities.supportedColorModes == [.brightness])
        let plug = MerossDeviceProfile(ability: ["Appliance.Control.ToggleX": [:]])
        #expect(!plug.isLight)
        #expect(MerossDeviceProfile(lightCapacity: [], hasToggleX: false, hasToggle: true).capabilities.supportedColorModes == [.onOff])
    }

    @Test func scales() {
        #expect(MerossLightScale.kelvinToNative(2700) == 1)
        #expect(MerossLightScale.kelvinToNative(6500) == 100)
        #expect(MerossLightScale.kelvinToNative(1000) == 1)
        #expect(MerossLightScale.kelvinToNative(4600) == 50) // Python round(50.5) == 50
        #expect(MerossLightScale.nativeToKelvin(51) == 4619) // meross_lan native_to_kelvin(51)
        #expect(MerossLightScale.nativeToKelvin(1) == 2700 && MerossLightScale.nativeToKelvin(100) == 6500)
        #expect(MerossLightScale.luminance(fromBrightness: 0.49) == 49)
        #expect(MerossLightScale.luminance(fromBrightness: 0.001) == 1)
        #expect(MerossLightScale.luminance(fromBrightness: 2) == 100)
        #expect(MerossLightScale.rgbInt(RGB(r: 255, g: 0, b: 0)) == 16711680)
        #expect(MerossLightScale.rgb(fromInt: 62719) == RGB(r: 0, g: 244, b: 255))
    }

    @Test func systemAllToState() throws {
        var model = MerossLightModel(profile: MerossDeviceProfile(ability: Fixtures["msl320_ability"]))
        let response = try MerossResponse.parse(Fixtures.data("msl320_all"))
        let info = model.apply(all: response.payload)
        #expect(info.type == "msl320cpr" && info.innerIp == "192.168.1.50" && info.firmwareVersion == "4.3.5")
        #expect(info.macAddress == "48:e1:e9:a1:b2:c3" && info.onlineStatus == 1)
        let state = model.lightState(reachable: true)
        #expect(state.isOn)
        #expect(state.brightness == 0.49)
        #expect(state.colorMode == .colorTemp) // capacity 6 = temperature + luminance
        #expect(state.kelvin == 4619)
        #expect(state.rgb == RGB(r: 255, g: 0, b: 0))
    }

    @Test func lightAndToggleXPushes() {
        var model = MerossLightModel(profile: rgbProfile)
        model.apply(namespace: MerossNamespace.controlLight, payload: Fixtures["msl450_light_getack"])
        #expect(model.colorMode == .rgb) // capacity 13 includes rgb
        #expect(model.light.luminance == 1)
        model.apply(namespace: MerossNamespace.controlToggleX, payload: Fixtures["msl450_togglex_getack"])
        #expect(model.isOn)
        model.apply(namespace: MerossNamespace.controlToggleX, payload: ["togglex": [["channel": 0, "onoff": 0]]])
        #expect(!model.isOn)
        // Light "onoff" is ignored on devices with ToggleX...
        model.apply(light: ["channel": 0, "onoff": 1])
        #expect(!model.isOn)
        // ...and authoritative without toggles.
        var bare = MerossLightModel(profile: MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: false, hasToggle: false))
        bare.apply(light: ["channel": 0, "onoff": 1, "luminance": 80, "capacity": 4])
        #expect(bare.isOn && bare.lightState(reachable: true).colorMode == .brightness)
        // Other channels are ignored.
        bare.apply(light: ["channel": 1, "onoff": 0])
        #expect(bare.isOn)
    }

    @Test func plannerOff() {
        var model = MerossLightModel(profile: rgbProfile)
        model.isOn = true
        let plain = MerossCommandPlanner.requests(for: .turnOff, model: model)
        #expect(plain == [MerossRequest.toggleX(on: false).withSameIDs(as: plain[0])])
        let off = MerossCommandPlanner.requests(for: LightCommand(brightness: 0), model: model)
        #expect(off.count == 1 && off[0].namespace == MerossNamespace.controlToggleX && off[0].payload["togglex"]?["onoff"] == 0)
        let legacy = MerossLightModel(profile: MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: false, hasToggle: true))
        #expect(MerossCommandPlanner.requests(for: .turnOff, model: legacy)[0].payload == ["channel": 0, "toggle": ["channel": 0, "onoff": 0]])
        let bare = MerossLightModel(profile: MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: false, hasToggle: false))
        #expect(MerossCommandPlanner.requests(for: .turnOff, model: bare)[0].payload == ["light": ["channel": 0, "onoff": 0]])
    }

    @Test func plannerColourWhileOn() {
        var model = MerossLightModel(profile: rgbProfile)
        model.isOn = true
        model.light.luminance = 30
        let r = MerossCommandPlanner.requests(for: LightCommand(color: .rgb(RGB(r: 0, g: 0, b: 255))), model: model)
        #expect(r.count == 1)
        #expect(r[0].namespace == MerossNamespace.controlLight && r[0].method == .set)
        #expect(r[0].payload == ["light": ["channel": 0, "capacity": 5, "rgb": 255, "luminance": 30, "gradual": 0]])

        let t = MerossCommandPlanner.requests(for: LightCommand(brightness: 0.8, color: .kelvin(6500)), model: model)
        #expect(t[0].payload == ["light": ["channel": 0, "capacity": 6, "temperature": 100, "luminance": 80, "gradual": 0]])

        let b = MerossCommandPlanner.requests(for: LightCommand(brightness: 0.5), model: model)
        #expect(b[0].payload == ["light": ["channel": 0, "capacity": 4, "luminance": 50, "gradual": 0]])

        // hs is converted to the supported rgb mode.
        let hs = MerossCommandPlanner.requests(for: LightCommand(color: .hs(HS(h: 120, s: 1))), model: model)
        #expect(hs[0].payload["light"]?["rgb"] == .int(0x00FF00))
    }

    @Test func plannerColourWhileOffAddsToggleX() {
        var model = MerossLightModel(profile: rgbProfile)
        model.isOn = false
        let r = MerossCommandPlanner.requests(for: LightCommand(on: true, brightness: 0.2, color: .kelvin(2700)), model: model)
        #expect(r.map(\.namespace) == [MerossNamespace.controlLight, MerossNamespace.controlToggleX])
        #expect(r[0].payload["light"]?["luminance"] == 20)
        #expect(r[1].payload == ["togglex": ["channel": 0, "onoff": 1]])
        // Luminance 100 when the current one is unknown.
        let c = MerossCommandPlanner.requests(for: LightCommand(color: .rgb(.white)), model: model)
        #expect(c[0].payload["light"]?["luminance"] == 100)
        // Without toggles the light payload itself carries onoff.
        let bare = MerossLightModel(profile: MerossDeviceProfile(lightCapacity: [.luminance], hasToggleX: false, hasToggle: false))
        let on = MerossCommandPlanner.requests(for: LightCommand(brightness: 1), model: bare)
        #expect(on.count == 1 && on[0].payload["light"]?["onoff"] == 1)
    }

    @Test func plannerOnOnlyAndEffects() {
        let model = MerossLightModel(profile: rgbProfile)
        let on = MerossCommandPlanner.requests(for: .turnOn, model: model)
        #expect(on.count == 1 && on[0].payload == ["togglex": ["channel": 0, "onoff": 1]])
        #expect(MerossCommandPlanner.requests(for: LightCommand(effect: "party"), model: model).isEmpty)
    }

    @Test func sentRequestsUpdateModel() {
        var model = MerossLightModel(profile: rgbProfile)
        for r in MerossCommandPlanner.requests(for: LightCommand(on: true, brightness: 0.4, color: .rgb(RGB(r: 1, g: 2, b: 3))), model: model) {
            model.applySent(r)
        }
        let s = model.lightState(reachable: true)
        #expect(s.isOn && s.brightness == 0.4 && s.colorMode == .rgb && s.rgb == RGB(r: 1, g: 2, b: 3))
    }
}

extension MerossRequest {
    /// Copies message id and timestamp so requests built at different times compare equal.
    func withSameIDs(as other: MerossRequest) -> MerossRequest {
        var copy = self
        copy.messageId = other.messageId
        copy.timestamp = other.timestamp
        return copy
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }
}
