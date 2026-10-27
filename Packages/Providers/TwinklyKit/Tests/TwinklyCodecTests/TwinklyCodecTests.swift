import Foundation
import LightCore
import Testing
@testable import TwinklyCodec

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Twinkly discovery datagrams")
struct TwinklyDiscoveryTests {
    @Test func requestIsVersionByteAndDiscover() {
        #expect(TwinklyDiscovery.request == Data([0x01, 0x64, 0x69, 0x73, 0x63, 0x6F, 0x76, 0x65, 0x72]))
        #expect(TwinklyDiscovery.port == 5555)
    }

    @Test func replyCarriesReversedIPAndDeviceID() throws {
        // 192.168.4.1 reversed, "OK", "Twinkly_33AAFF", NUL (xled-docs "Discovery protocol").
        let bytes: [UInt8] = [1, 4, 168, 192] + Array("OK".utf8) + Array("Twinkly_33AAFF".utf8) + [0]
        let reply = try #require(TwinklyDiscovery.parseReply(Data(bytes)))
        #expect(reply.ip == "192.168.4.1")
        #expect(reply.deviceID == "Twinkly_33AAFF")
        #expect(TwinklyDiscovery.makeReply(ip: "192.168.4.1", deviceID: "Twinkly_33AAFF") == Data(bytes))
    }

    @Test func ourOwnBroadcastAndGarbageAreRejected() {
        #expect(TwinklyDiscovery.parseReply(TwinklyDiscovery.request) == nil)
        #expect(TwinklyDiscovery.parseReply(Data([1, 2, 3, 4, 0x4F, 0x4B])) == nil) // no id
        #expect(TwinklyDiscovery.parseReply(Data([1, 2, 3, 4, 0x4E, 0x4F, 0x41])) == nil) // "NO"
    }

    @Test func replyWithoutTrailingZeroStillParses() {
        let data = Data([10, 0, 168, 192] + Array("OKTwinkly_ABC".utf8))
        #expect(TwinklyDiscovery.parseReply(data) == .init(ip: "192.168.0.10", deviceID: "Twinkly_ABC"))
    }
}

@Suite("Twinkly models and requests")
struct TwinklyModelTests {
    @Test func gestaltFamilyD() throws {
        let g = try TwinklyAPI.decode(TwinklyGestalt.self, from: try fixture("gestalt_family_d"))
        #expect(g.stableID == "5ccf7f33aaff")
        #expect(g.deviceName == "Twinkly_33AAFF")
        #expect(g.productCode == "TW105SEUP06")
        #expect(g.ledProfile == "RGB")
        #expect(g.firmwareFamily == nil)
        #expect(g.uuid == nil)
    }

    @Test func gestaltFamilyG() throws {
        let g = try TwinklyAPI.decode(TwinklyGestalt.self, from: try fixture("gestalt_family_g"))
        #expect(g.stableID == "98f4ab1cc190")
        #expect(g.firmwareFamily == "G")
        #expect(g.numberOfLED == 190)
        #expect(g.ledProfile == "RGBW")
    }

    @Test func loginResponseFromDocs() throws {
        let login = try TwinklyAPI.decode(TwinklyLoginResponse.self, from: try fixture("login"))
        #expect(login.authenticationToken == "5jPe+ONhwUY=")
        #expect(login.expiresIn == 14400)
        #expect(login.challengeResponse == "8d87f080947e343180da3f411df3997e3e9ae0cc")
    }

    @Test func loginAndVerifyBodies() throws {
        let login = TwinklyAPI.login(challenge: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(login.method == "POST")
        #expect(login.path == "/xled/v1/login")
        #expect(!login.authenticated)
        #expect(login.bodyText == #"{"challenge":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}"#)
        let verify = TwinklyAPI.verify(challengeResponse: "8d87f080947e343180da3f411df3997e3e9ae0cc")
        #expect(verify.authenticated)
        #expect(verify.bodyText == #"{"challenge-response":"8d87f080947e343180da3f411df3997e3e9ae0cc"}"#)
    }

    @Test func challengeIs32RandomBytes() throws {
        let challenge = TwinklyAPI.makeChallenge()
        #expect(try #require(Data(base64Encoded: challenge)).count == 32)
        #expect(TwinklyAPI.makeChallenge() != challenge)
    }

    @Test func writeBodies() throws {
        #expect(TwinklyAPI.setMode(.off).bodyText == #"{"mode":"off"}"#)
        #expect(TwinklyAPI.setMode(.effect, effectID: 2).bodyText == #"{"effect_id":2,"mode":"effect"}"#)
        #expect(TwinklyAPI.setColor(.hsv(hue: 300, saturation: 255, value: 255)).bodyText == #"{"hue":300,"saturation":255,"value":255}"#)
        #expect(TwinklyAPI.setColor(.rgb(red: 1, green: 2, blue: 3)).bodyText == #"{"blue":3,"green":2,"red":1}"#)
        #expect(TwinklyAPI.setBrightness(percent: 140).bodyText == #"{"mode":"enabled","type":"A","value":100}"#)
        #expect(TwinklyAPI.setCurrentEffect(4).bodyText == #"{"effect_id":4}"#)
        #expect(TwinklyAPI.getMode.authenticated)
        #expect(!TwinklyAPI.gestalt.authenticated)
        #expect(!TwinklyAPI.firmwareVersion.authenticated)
    }

    @Test func applicationErrorCodesThrow() {
        #expect(throws: TwinklyError.application(code: 1101)) {
            try TwinklyAPI.checkCode(Data(#"{"code":1101}"#.utf8))
        }
        #expect(throws: Never.self) { try TwinklyAPI.checkCode(Data(#"{"code":1107}"#.utf8)) }
        #expect(throws: Never.self) { try TwinklyAPI.checkCode(Data(#"{}"#.utf8)) }
        #expect(throws: TwinklyError.self) { try TwinklyAPI.checkCode(Data("Invalid Token.".utf8)) }
        #expect(TwinklyError.unauthorized.lightCoreError == .authenticationRequired(.twinkly))
    }

    @Test func modeDecodesKnownAndUnknownValues() throws {
        let effect = try TwinklyAPI.decode(TwinklyModeResponse.self, from: Data(#"{"mode":"effect","shop_mode":0,"code":1000}"#.utf8))
        #expect(effect.mode == .effect)
        let future = try TwinklyAPI.decode(TwinklyModeResponse.self, from: Data(#"{"mode":"musicreactive","code":1000}"#.utf8))
        #expect(future.mode == .other("musicreactive"))
        #expect(future.mode.rawValue == "musicreactive")
    }

    @Test func brightnessDisabledMeansFull() throws {
        #expect(TwinklyBrightnessResponse(value: 30, mode: "disabled").brightness == 1)
        #expect(TwinklyBrightnessResponse(value: 30, mode: "enabled").brightness == 0.3)
        let decoded = try TwinklyAPI.decode(TwinklyBrightnessResponse.self, from: Data(#"{"value":100,"mode":"enabled","code":1000}"#.utf8))
        #expect(decoded.brightness == 1)
    }

    @Test func effectsCountUsesUniqueIDsWhenLarger() throws {
        let old = try TwinklyAPI.decode(TwinklyEffectsResponse.self, from: Data(#"{"effects_number":5,"code":1000}"#.utf8))
        #expect(old.count == 5)
        let new = TwinklyEffectsResponse(effectsNumber: nil, uniqueIDs: ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"])
        #expect(new.count == 2)
    }

    @Test func firmwareVersionsCompareNumerically() throws {
        let v = try #require(TwinklyFirmwareVersion("2.10.0"))
        #expect(v > TwinklyFirmwareVersion(2, 7, 1))
        #expect(TwinklyFirmwareVersion("2.7") ?? v < .colorEndpoint)
        #expect(TwinklyFirmwareVersion("2.7.1") == .colorEndpoint)
        #expect(TwinklyFirmwareVersion("2.x") == nil)
    }

    @Test func macAndEndpointParsing() {
        #expect(TwinklyIdentifiers.normalizeMAC("98:F4:AB:1C:C1:90") == "98f4ab1cc190")
        #expect(TwinklyIdentifiers.normalizeMAC("98f4ab1cc190") == "98f4ab1cc190")
        #expect(TwinklyIdentifiers.normalizeMAC("00:00:00:00:00:00") == nil)
        #expect(TwinklyIdentifiers.normalizeMAC("Twinkly_1CC190") == nil)
        #expect(TwinklyIdentifiers.lightID(mac: "98:f4:ab:1c:c1:90")?.rawValue == "twinkly:98f4ab1cc190")
        #expect(TwinklyEndpoint.parse("192.168.1.5") == ("192.168.1.5", nil))
        #expect(TwinklyEndpoint.parse("http://192.168.1.5:8080/") == ("192.168.1.5", 8080))
        #expect(TwinklyEndpoint.parse(" twinkly.local ") == ("twinkly.local", nil))
        #expect(TwinklyEndpoint.parse("[fe80::1]:80") == ("fe80::1", 80))
        #expect(TwinklyEndpoint.url(host: "10.0.0.2", port: nil, path: "/xled/v1/gestalt")?.absoluteString == "http://10.0.0.2/xled/v1/gestalt")
        #expect(TwinklyEndpoint.url(host: "10.0.0.2", port: 80, path: "/x")?.absoluteString == "http://10.0.0.2/x")
        #expect(TwinklyEndpoint.url(host: "127.0.0.1", port: 8080, path: "/x")?.absoluteString == "http://127.0.0.1:8080/x")
    }
}

@Suite("Twinkly mapping and command planning")
struct TwinklyMappingTests {
    static let recent = TwinklyDeviceInfo(gestalt: TwinklyGestalt(mac: "98:f4:ab:1c:c1:90"), firmware: "2.8.3", effectCount: 15)
    static var caps: LightCapabilities { TwinklyMapping.capabilities(recent) }

    @Test func capabilitiesByFirmware() {
        #expect(Self.caps.supportedColorModes == [.hs])
        #expect(Self.caps.effects.map(\.id).prefix(3) == ["movie", "effect:0", "effect:1"])
        #expect(Self.caps.effects.count == 16)
        #expect(!Self.caps.supportsTransition)
        let older = TwinklyDeviceInfo(gestalt: TwinklyGestalt(), firmware: "2.5.6", effectCount: 15)
        #expect(TwinklyMapping.capabilities(older).supportedColorModes == [.brightness])
        let ancient = TwinklyDeviceInfo(gestalt: TwinklyGestalt(), firmware: "1.99.20", effectCount: 5)
        #expect(TwinklyMapping.capabilities(ancient).supportedColorModes == [.onOff])
        let unknown = TwinklyDeviceInfo(gestalt: TwinklyGestalt(), firmware: nil, effectCount: 0)
        #expect(TwinklyMapping.capabilities(unknown).supportedColorModes == [.hs])
    }

    @Test func stateFromColorMode() throws {
        let color = try TwinklyAPI.decode(TwinklyColorResponse.self, from: try fixture("led_color"))
        let state = TwinklyMapping.state(mode: .color, color: color, brightness: TwinklyBrightnessResponse(value: 80), effectID: nil)
        #expect(state.isOn)
        #expect(state.colorMode == .hs)
        #expect(state.hs?.h == 56)
        #expect(abs((state.hs?.s ?? 0) - 105.0 / 255) < 1e-9)
        #expect(state.brightness == 0.8)
        #expect(state.effect == nil)
    }

    @Test func stateFromOtherModes() {
        #expect(!TwinklyMapping.state(mode: .off, color: nil, brightness: nil, effectID: nil).isOn)
        #expect(TwinklyMapping.state(mode: .movie, color: nil, brightness: nil, effectID: nil).effect == "movie")
        #expect(TwinklyMapping.state(mode: .effect, color: nil, brightness: nil, effectID: 4).effect == "effect:4")
        #expect(TwinklyMapping.state(mode: .playlist, color: nil, brightness: nil, effectID: nil).effect == "playlist")
        let demo = TwinklyMapping.state(mode: .demo, color: nil, brightness: nil, effectID: nil)
        #expect(demo.isOn && demo.effect == nil)
    }

    @Test func offIsOneModeRequest() {
        let plan = TwinklyMapping.plan(.turnOff, current: TwinklyLiveState(mode: .movie), capabilities: Self.caps)
        #expect(plan.requests.map(\.bodyText) == [#"{"mode":"off"}"#])
        #expect(plan.resultingMode == .off)
        let zero = TwinklyMapping.plan(LightCommand(brightness: 0), current: TwinklyLiveState(mode: .color), capabilities: Self.caps)
        #expect(zero.resultingMode == .off)
        let already = TwinklyMapping.plan(.turnOff, current: TwinklyLiveState(mode: .off), capabilities: Self.caps)
        #expect(already.requests.isEmpty)
    }

    @Test func colorThenBrightnessThenMode() {
        let plan = TwinklyMapping.plan(LightCommand(on: true, brightness: 0.5, color: .hs(HS(h: 359.6, s: 1))),
                                       current: TwinklyLiveState(mode: .off), capabilities: Self.caps)
        #expect(plan.requests.map(\.path) == ["/xled/v1/led/color", "/xled/v1/led/out/brightness", "/xled/v1/led/mode"])
        #expect(plan.requests[0].bodyText == #"{"hue":0,"saturation":255,"value":255}"#)
        #expect(plan.requests[1].bodyText == #"{"mode":"enabled","type":"A","value":50}"#)
        #expect(plan.requests[2].bodyText == #"{"mode":"color"}"#)
        #expect(plan.resultingMode == .color)
    }

    @Test func kelvinBecomesHueSaturation() {
        let plan = TwinklyMapping.plan(LightCommand(color: .kelvin(2700)), current: TwinklyLiveState(mode: .color), capabilities: Self.caps)
        #expect(plan.requests.map(\.path) == ["/xled/v1/led/color"])
    }

    @Test func bareOnRestoresLastMode() {
        var live = TwinklyLiveState(mode: .effect, effectID: 7)
        live.apply(mode: .off)
        #expect(live.lastOnMode == .effect)
        let plan = TwinklyMapping.plan(.turnOn, current: live, capabilities: Self.caps)
        #expect(plan.requests.map(\.bodyText) == [#"{"effect_id":7,"mode":"effect"}"#])
        let fresh = TwinklyMapping.plan(.turnOn, current: TwinklyLiveState(mode: .off), capabilities: Self.caps)
        #expect(fresh.requests.map(\.bodyText) == [#"{"mode":"movie"}"#])
        let alreadyOn = TwinklyMapping.plan(.turnOn, current: TwinklyLiveState(mode: .movie), capabilities: Self.caps)
        #expect(alreadyOn.requests.isEmpty)
    }

    @Test func effects() {
        let effect = TwinklyMapping.plan(LightCommand(effect: "effect:2"), current: TwinklyLiveState(mode: .color), capabilities: Self.caps)
        #expect(effect.requests.map(\.bodyText) == [#"{"effect_id":2}"#, #"{"effect_id":2,"mode":"effect"}"#])
        #expect(effect.resultingEffectID == 2)
        let movie = TwinklyMapping.plan(LightCommand(effect: "movie"), current: TwinklyLiveState(mode: .off), capabilities: Self.caps)
        #expect(movie.requests.map(\.bodyText) == [#"{"mode":"movie"}"#])
        let unknown = TwinklyMapping.plan(LightCommand(effect: "effect:99"), current: TwinklyLiveState(mode: .movie), capabilities: Self.caps)
        #expect(unknown.requests.isEmpty) // dropped by normalisation (not in the effect list)
        #expect(TwinklyEffects.effectNumber("effect:-1") == nil)
    }
}
