import Foundation
import LightCore
import Testing

@testable import WiZCodec

private func data(_ s: String) -> Data { Data(s.utf8) }
private func compact(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

@Suite("JSON")
struct WiZJSONTests {
    @Test func compactKeepsOrderAndEscapesLikeJSONStringify() throws {
        let o: WiZObject = ["z": 1, "a": "x\"y\\\n\u{1}é", "arr": [true, nil, 1.5, 2.0], "o": [:]]
        #expect(o.compactString == #"{"z":1,"a":"x\"y\\\n\u0001é","arr":[true,null,1.5,2],"o":{}}"#)
        let parsed = try WiZJSON.parse(o.compactString)
        #expect(parsed == .object(o) || parsed.compactString == o.compactString)
    }

    @Test func settingExistingKeyKeepsPosition() {
        var o: WiZObject = ["state": true, "sigTs": 1, "dimming": 50]
        o["sigTs"] = 2
        #expect(o.keys == ["state", "sigTs", "dimming"])
        o["sigTs"] = nil
        #expect(o.keys == ["state", "dimming"])
    }

    @Test func rejectsGarbage() {
        #expect(throws: WiZJSONParseError.self) { try WiZJSON.parse("not json{") }
        #expect(throws: WiZJSONParseError.self) { try WiZJSON.parse(#"{"a":1} x"#) }
    }

    @Test func toleratesTrailingNULPadding() throws {
        var d = data(#"{"method":"getPilot"}"#)
        d.append(contentsOf: [0, 0])
        #expect(try WiZJSON.parse(d)["method"]?.stringValue == "getPilot")
    }
}

/// Fixtures from research_wiz.md §1.3 (pywizlight fake_bulb.py, Rogozin blog).
@Suite("Requests and responses")
struct WiZMessageTests {
    static let requestFixtures = [
        #"{"id":1,"method":"setPilot","params":{"r":0,"g":0,"b":255,"dimming":100}}"#,
        #"{"id":1,"method":"setPilot","params":{"temp":3000,"dimming":75}}"#,
        #"{"id":1,"method":"setPilot","params":{"sceneId":23,"speed":145,"dimming":100}}"#,
        #"{"id":1,"method":"setState","params":{"state":false}}"#,
        #"{"method":"getPilot","params":{}}"#,
        #"{"method":"registration","id":105,"params":{"phoneIp":"192.168.1.20","phoneMac":"aabbccddeeff","register":true}}"#,
        #"{"method":"pulse","params":{"delta":-15,"duration":300}}"#,
    ]

    @Test(arguments: requestFixtures)
    func requestFixturesRoundTripByteExact(_ fixture: String) throws {
        let parsed = try WiZJSON.parse(fixture)
        #expect(parsed.compactString == fixture)
        let request = try WiZRequest.parse(data(fixture))
        #expect(!request.method.isEmpty)
    }

    @Test func builders() {
        #expect(compact(WiZRequest.getPilot().encoded()) == #"{"method":"getPilot","params":{}}"#)
        #expect(compact(WiZRequest.getPilot(id: 1).encoded()) == #"{"id":1,"method":"getPilot","params":{}}"#)
        #expect(compact(WiZRequest.getPilot(head: 2).encoded()) == #"{"method":"getPilot","params":{"devices":2}}"#)
        #expect(compact(WiZRequest.setPilot(["temp": 3000, "dimming": 75], id: 1).encoded())
            == #"{"id":1,"method":"setPilot","params":{"temp":3000,"dimming":75}}"#)
        #expect(compact(WiZRequest.setState(["state": false], id: 1).encoded()) == #"{"id":1,"method":"setState","params":{"state":false}}"#)
        #expect(compact(WiZRequest.getSystemConfig().encoded()) == #"{"method":"getSystemConfig","params":{}}"#)
        #expect(compact(WiZRequest.getModelConfig().encoded()) == #"{"method":"getModelConfig","params":{}}"#)
        #expect(compact(WiZRequest.getUserConfig().encoded()) == #"{"method":"getUserConfig","params":{}}"#)
        #expect(compact(WiZRequest.registration(phoneIp: "192.168.1.20", phoneMac: "aabbccddeeff").encoded())
            == #"{"method":"registration","params":{"phoneIp":"192.168.1.20","phoneMac":"aabbccddeeff","register":true}}"#)
        // Byte-identical to wiz.mjs discover / pywizlight discovery.py.
        #expect(compact(WiZRequest.discoveryRegistration().encoded())
            == #"{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}"#)
        #expect(compact(WiZRequest.pulse().encoded()) == #"{"method":"pulse","params":{"delta":-15,"duration":300}}"#)
        #expect(WiZRequest.setPilot([:]).isWrite && WiZRequest.setState([:]).isWrite && !WiZRequest.getPilot().isWrite)
    }

    @Test func setPilotSuccess() throws {
        let fixture = #"{"method":"setPilot","env":"pro","result":{"success":true}}"#
        let r = try WiZResponse.parse(data(fixture))
        #expect(r.method == "setPilot" && r.env == "pro" && r.isSuccess && r.error == nil)
        #expect(r.object.compactString == fixture)
    }

    @Test func getPilot() throws {
        let fixture = #"{"method":"getPilot","env":"pro","result":{"mac":"6c29906a1b2c","rssi":-46,"src":"","state":true,"sceneId":0,"r":255,"g":238,"b":0,"c":0,"w":0,"dimming":100}}"#
        let r = try WiZResponse.parse(data(fixture))
        #expect(r.object.compactString == fixture)
        let p = try #require(r.pilot)
        #expect(p.mac == "6c29906a1b2c" && r.mac == "6c29906a1b2c")
        #expect(p.state == true && p.r == 255 && p.g == 238 && p.b == 0 && p.dimming == 100 && p.sceneId == 0 && p.rssi == -46)
        #expect(p.temp == nil && p.hasRGB)
    }

    @Test func getSystemConfig() throws {
        let fixture = #"{"method":"getSystemConfig","env":"pro","result":{"mac":"a8bb5006033d","homeId":653906,"roomId":989983,"moduleName":"ESP01_SHRGB_03","fwVersion":"1.25.0","groupId":0,"drvConf":[30,1],"ewf":[255,0,255,255,0,0,0],"ewfHex":"ff00ffff000000","ping":0}}"#
        let r = try WiZResponse.parse(data(fixture))
        #expect(r.object.compactString == fixture)
        let s = try #require(r.systemConfig)
        #expect(s.mac == "a8bb5006033d" && s.homeId == 653906 && s.roomId == 989983 && s.groupId == 0)
        #expect(s.moduleName == "ESP01_SHRGB_03" && s.fwVersion == "1.25.0" && s.drvConf == [30, 1] && s.ping == 0)
        #expect(s.moduleInfo?.kind == .rgb)
    }

    @Test func getModelConfig() throws {
        let fixture = #"{"method":"getModelConfig","env":"pro","result":{"ps":1,"pwmFreq":2000,"pwmRange":[0,100],"wcr":20,"nowc":2,"cctRange":[2200,2700,6500,6500],"renderFactor":[200,255,255,150,0,0,40,0,0,0],"hasAdjMinDim":0,"hasTapSensor":1,"pm":0,"fanSpeed":0}}"#
        let r = try WiZResponse.parse(data(fixture))
        #expect(r.object.compactString == fixture)
        let m = try #require(r.modelConfig)
        #expect(m.cctRange == [2200, 2700, 6500, 6500] && m.nowc == 2 && m.wcr == 20 && m.pwmRange == [0, 100])
        #expect(m.hasTapSensor == 1 && m.fanSpeed == 0 && m.renderFactor?.count == 10)
    }

    @Test func getUserConfig() throws {
        let fixture = #"{"method":"getUserConfig","env":"pro","result":{"fadeIn":450,"fadeOut":500,"dftDim":100,"whiteRange":[2700,6500],"extRange":[2700,6500],"opMode":0,"po":false}}"#
        let r = try WiZResponse.parse(data(fixture))
        let u = try #require(r.userConfig)
        #expect(u.fadeIn == 450 && u.fadeOut == 500 && u.dftDim == 100 && u.whiteRange == [2700, 6500] && u.po == false && u.opMode == 0)
    }

    @Test func registrationReply() throws {
        let r = try WiZResponse.parse(data(#"{"method":"registration","env":"pro","result":{"mac":"a8bb5006033d","success":true}}"#))
        #expect(r.registrationResult?.mac == "a8bb5006033d" && r.registrationResult?.success == true)
    }

    @Test func errors() throws {
        let notFound = try WiZResponse.parse(data(#"{"method":"getModelConfig","env":"pro","error":{"code":-32601,"message":"Method not found"}}"#))
        #expect(notFound.error?.kind == .methodNotFound && !notFound.isSuccess)

        let parse = try WiZResponse.parse(data(#"{"env":"pro","error":{"code":-32700,"message":"Parse error"}}"#))
        #expect(parse.error?.kind == .parseError && parse.method == nil)

        let signing = try WiZResponse.parse(data(#"{"method":"setPilot","env":"pro","error":{"code":-32602,"message":"Invalid params","sigTs":1788786272}}"#))
        #expect(signing.error?.kind == .invalidParams)
        #expect(signing.error?.sigTs == 1788786272 && signing.sigTs == 1788786272)
        #expect(signing.error?.indicatesSigningRequired == true)

        let plainInvalid = try WiZResponse.parse(data(#"{"method":"setPilot","env":"pro","error":{"code":-32602,"message":"Invalid params"}}"#))
        #expect(plainInvalid.error?.indicatesSigningRequired == false)

        let security = try WiZResponse.parse(data(#"{"method":"setPilot","env":"pro","error":{"code":-32605,"message":"Security error"}}"#))
        #expect(security.error?.kind == .securityError)

        #expect(WiZError(code: -1).kind == .other(-1))
    }

    @Test func pushMessages() throws {
        let sync = try WiZResponse.parse(data(#"{"method":"syncPilot","id":12,"env":"pro","params":{"mac":"a8bb5006033d","rssi":-60,"src":"wizmote","state":true,"sceneId":0,"temp":2700,"dimming":40}}"#))
        #expect(sync.isPush && sync.mac == "a8bb5006033d")
        #expect(sync.pilot?.temp == 2700 && sync.pilot?.src == "wizmote" && sync.pilot?.dimming == 40)

        let beat = try WiZResponse.parse(data(#"{"method":"firstBeat","env":"pro","params":{"mac":"a8bb5006033d","homeId":653906,"fwVersion":"1.25.0"}}"#))
        #expect(beat.isPush && beat.method == WiZMethod.firstBeat && beat.mac == "a8bb5006033d")
    }

    @Test func macNormalisation() {
        #expect(WiZMAC.normalize("A8:BB:50:06:03:3D") == "a8bb5006033d")
        #expect(WiZMAC.normalize("a8bb5006033") == nil)
        #expect(WiZMAC.normalize("zzbb5006033d") == nil)
        #expect(WiZMAC.hasWiZOUI("6c29906a1b2c") && !WiZMAC.hasWiZOUI("001122334455"))
    }
}

@Suite("Signing")
struct WiZSigningTests {
    static let keyHex = "00112233445566778899aabbccddeeff"
    static var key: WiZSigningKey { WiZSigningKey(hex: keyHex)! }

    /// Test vector from tools/probe/wiz.mjs / docs/HARDWARE-NOTES.md (matches Python hmac).
    @Test func probeVector() {
        let signed = WiZSigner.sign(["state": true], key: Self.key, sigTs: 1_790_000_000)
        #expect(signed.params.compactString == #"{"state":true,"sigTs":1790000000}"#)
        #expect(signed.hmac == "oVfeexiMeoOHVfY6lr7GA4t1kPID+9ioR/s8JDyLv6k=")
    }

    /// pywizlight PR #216 vector (also used by FakeWiZBulb's tests).
    @Test func pywizlightVector() {
        #expect(WiZSigner.sign(["state": true], key: Self.key, sigTs: 1_790_441_723).hmac
            == "vARMv4JpVsxYabcBovABd25ISBzYT8+71v0CUtpU1sg=")
    }

    /// Computed with node:crypto exactly as wiz.mjs signParams does: sigTs appended last.
    @Test func multiKeyVectorKeepsParamOrder() {
        let signed = WiZSigner.sign(["r": 0, "g": 0, "b": 255, "dimming": 100], key: Self.key, sigTs: 1_790_000_000)
        #expect(signed.params.compactString == #"{"r":0,"g":0,"b":255,"dimming":100,"sigTs":1790000000}"#)
        #expect(signed.hmac == "hxCcuDZiGDMvgtK6HW44App3X8D3MJvVTX1sDhVYLMo=")
    }

    @Test func existingSigTsIsReplacedInPlace() {
        let signed = WiZSigner.sign(["sigTs": 1, "state": true], key: Self.key, sigTs: 5)
        #expect(signed.params.compactString == #"{"sigTs":5,"state":true}"#)
    }

    @Test func signedEnvelopeMirrorsProbe() {
        let wire = WiZRequest.setPilot(["state": true], id: 1).encoded(signingKey: Self.key, sigTs: 1_790_000_000)
        #expect(String(decoding: wire, as: UTF8.self)
            == #"{"id":1,"method":"setPilot","params":{"state":true,"sigTs":1790000000},"env":"pro","hmac":"oVfeexiMeoOHVfY6lr7GA4t1kPID+9ioR/s8JDyLv6k="}"#)
    }

    @Test func replySignatureVerification() throws {
        let body = #"{"mac":"a8bb5006033d","state":true,"sigTs":1790000000}"#
        let mac = WiZSigner.hmac(Array(body.utf8), key: Self.key)
        let reply = try WiZResponse.parse(Data(#"{"method":"getPilot","env":"pro","result":\#(body),"hmac":"\#(mac)"}"#.utf8))
        #expect(reply.verifySignature(key: Self.key) == true)
        #expect(reply.verifySignature(key: WiZSigningKey(hex: String(repeating: "f", count: 32))!) == false)
        let unsigned = try WiZResponse.parse(Data(#"{"method":"getPilot","result":{}}"#.utf8))
        #expect(unsigned.verifySignature(key: Self.key) == nil)
    }

    @Test func keyValidation() {
        #expect(WiZSigningKey(hex: Self.keyHex)?.bytes.count == 16)
        #expect(WiZSigningKey(hex: "  00112233445566778899AABBCCDDEEFF\n")?.hexString == Self.keyHex)
        #expect(WiZSigningKey(hex: "0011223344556677889900") == nil)
        #expect(WiZSigningKey(hex: "00112233445566778899aabbccddeefg") == nil)
        #expect(WiZSigningKey(hex: "00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff") == nil)
        #expect(!Self.key.description.contains("0011"))
    }

    @Test func importFormats() throws {
        #expect(try WiZSigningKey.parseImport(Data(#"{"home_id":653906,"udp_signing_key":"00112233445566778899aabbccddeeff"}"#.utf8)) == Self.key)
        #expect(try WiZSigningKey.parseImport(#"{"homes":[{"name":"Home","integration":{"udp_signing_key":"00112233445566778899AABBCCDDEEFF"}}]}"#) == Self.key)
        #expect(try WiZSigningKey.parseImport("\u{FEFF}00112233445566778899aabbccddeeff\n") == Self.key)
        #expect(try WiZSigningKey.parseImport(#""00112233445566778899aabbccddeeff""#) == Self.key)
        #expect(throws: WiZSigningKey.ImportError.keyNotFound) { try WiZSigningKey.parseImport(#"{"other":"x"}"#) }
        #expect(throws: WiZSigningKey.ImportError.invalidKey) { try WiZSigningKey.parseImport(#"{"udp_signing_key":"short"}"#) }
        #expect(throws: WiZSigningKey.ImportError.invalidKey) { try WiZSigningKey.parseImport("hello") }
        #expect(throws: WiZSigningKey.ImportError.empty) { try WiZSigningKey.parseImport("  ") }
    }
}

@Suite("Module info, capabilities, scenes")
struct WiZModuleTests {
    @Test(arguments: [
        ("ESP01_SHRGB_03", WiZModuleInfo.Kind.rgb, false, true),
        ("ESP01_SHRGB1C_31", .rgb, false, true),
        ("ESP20_SHRGB_01ABI", .rgb, false, true),
        ("ESP20_SHRGBC_01", .rgb, false, true),
        ("ESP20_DHRGB_01B", .rgb, true, false),
        ("ESP25_SHORGB_01", .rgb, false, true),
        ("ESP03_SHRGB3_01ABI", .rgb, false, true),
        ("ESP21_SHTW_01", .tunableWhite, false, true),
        ("ESP14_SHTW1C_01", .tunableWhite, false, true),
        ("ESP05_SHTW_21", .tunableWhite, false, true),
        ("ESP05_SHDW_21", .dimmable, false, true),
        ("ESP06_SHDW9_01", .dimmable, false, true),
        ("ESP01_DIMTRIACS_01", .dimmable, false, false),
        ("ESP10_SOCKET_06", .socket, false, false),
        ("ESP25_SOCKET_01", .socket, false, false),
        ("ESP03_FANDIMS_31", .fanDimmable, false, false),
        ("ESP20_DDTW_01", .fanTunableWhite, false, false),
    ])
    func moduleNames(_ name: String, _ kind: WiZModuleInfo.Kind, _ dual: Bool, _ single: Bool) throws {
        let info = try #require(WiZModuleInfo(moduleName: name))
        #expect(info.kind == kind)
        #expect(info.isDualHead == dual)
        #expect(info.isSingleHead == single)
        #expect(info.chip?.hasPrefix("ESP") == true)
    }

    @Test func moduleParts() throws {
        let info = try #require(WiZModuleInfo(moduleName: "ESP20_SHRGB_01BT"))
        #expect(info.chip == "ESP20" && info.identifier == "SHRGB" && info.revision == "01BT")
        #expect(WiZModuleInfo(moduleName: "") == nil)
        #expect(WiZModuleInfo(moduleName: "ESP03_FANDIMS_31")?.hasFan == true)
    }

    @Test func fallbackKindFromPilot() {
        #expect(WiZModuleInfo.fallbackKind(pilot: WiZPilot(["r": 1, "g": 2, "b": 3])) == .rgb)
        #expect(WiZModuleInfo.fallbackKind(pilot: WiZPilot(["temp": 2700, "dimming": 50])) == .tunableWhite)
        #expect(WiZModuleInfo.fallbackKind(pilot: WiZPilot(["dimming": 50])) == .dimmable)
        #expect(WiZModuleInfo.fallbackKind(pilot: WiZPilot(["state": true])) == .socket)
    }

    @Test func capabilitiesFromModelConfig() {
        let model = WiZModelConfig(["cctRange": [2200, 2700, 6500, 6500], "nowc": 2, "wcr": 20])
        let caps = WiZCapabilities.make(kind: .rgb, modelConfig: model)
        #expect(caps.supportedColorModes == [.rgb, .colorTemp])
        #expect(caps.minKelvin == 2200 && caps.maxKelvin == 6500)
        #expect(caps.effects.count == 48 && caps.supportsEffects && !caps.supportsTransition)

        let tw = WiZCapabilities.make(kind: .tunableWhite, modelConfig: WiZModelConfig(cctRange: [2700, 2700, 5000, 5000]))
        #expect(tw.supportedColorModes == [.colorTemp] && tw.minKelvin == 2700 && tw.maxKelvin == 5000)
    }

    @Test func capabilityFallbacks() {
        // fw <= 1.22: no getModelConfig -> user config whiteRange, else defaults.
        let user = WiZUserConfig(["whiteRange": [2700, 6500]])
        #expect(WiZCapabilities.make(kind: .tunableWhite, userConfig: user).minKelvin == 2700)
        #expect(WiZCapabilities.make(kind: .rgb).kelvinRange == 2200...6500)
        #expect(WiZCapabilities.make(kind: .tunableWhite).kelvinRange == 2700...6500)
        // Degenerate cctRange (all equal) is ignored.
        #expect(WiZCapabilities.make(kind: .tunableWhite, modelConfig: WiZModelConfig(cctRange: [2700, 2700, 2700, 2700])).kelvinRange == 2700...6500)
        let dw = WiZCapabilities.make(kind: .dimmable)
        #expect(dw.supportedColorModes == [.brightness] && dw.minKelvin == nil && dw.effects.count == 8)
        let plug = WiZCapabilities.make(kind: .socket)
        #expect(plug.supportedColorModes == [.onOff] && plug.effects.isEmpty && !plug.supportsEffects)
        #expect(WiZCapabilities.make(module: nil, modelConfig: nil, userConfig: nil, pilot: WiZPilot(["temp": 3000])).supportedColorModes == [.colorTemp])
    }

    @Test func sceneTable() {
        #expect(WiZScenes.all.count == 48)
        #expect(Set(WiZScenes.all.map(\.id)) == Set(Array(1...36) + [40] + Array(256...265) + [1000]))
        #expect(WiZScenes.name(for: 1) == "Ocean" && WiZScenes.name(for: 23) == "Deep dive")
        #expect(WiZScenes.name(for: 40) == "Dim-to-warm" && WiZScenes.name(for: 256) == "Custom Mode 1")
        #expect(WiZScenes.name(for: 265) == "Custom Mode 10" && WiZScenes.name(for: 1000) == "Rhythm")
        #expect(WiZScenes.name(for: 37) == nil)
        #expect(WiZScenes.scene(id: 4)?.isFast == true && WiZScenes.scene(id: 6)?.isFast == false)
    }

    @Test func sceneSubsets() {
        let tw = WiZScenes.effects(for: .tunableWhite).map(\.id)
        #expect(tw.count == 17)
        #expect(tw == ["6", "9", "10", "11", "12", "13", "14", "15", "16", "18", "29", "30", "31", "32", "33", "35", "40"])
        let dw = WiZScenes.effects(for: .dimmable).map(\.id)
        #expect(dw == ["9", "10", "14", "29", "31", "32", "34", "35"])
        #expect(WiZScenes.effects(for: .fanTunableWhite).count == 17)
        #expect(WiZScenes.effects(for: .socket).isEmpty)
        #expect(WiZScenes.effects(for: .rgb).first == EffectDescriptor(id: "1", name: "Ocean"))
    }
}

@Suite("State mapping and command encoding")
struct WiZMappingTests {
    static let rgbCaps = WiZCapabilities.make(kind: .rgb, modelConfig: WiZModelConfig(cctRange: [2200, 2700, 6500, 6500]))
    static let twCaps = WiZCapabilities.make(kind: .tunableWhite, modelConfig: WiZModelConfig(cctRange: [2700, 2700, 5000, 5000]))
    static let dwCaps = WiZCapabilities.make(kind: .dimmable)
    static let plugCaps = WiZCapabilities.make(kind: .socket)

    @Test func dimmingMapping() {
        #expect(WiZStateMapping.brightness(fromDimming: 100) == 1)
        #expect(WiZStateMapping.dimming(fromBrightness: 1) == 100)
        #expect(WiZStateMapping.dimming(fromBrightness: 0.001) == 10)
        #expect(WiZStateMapping.dimming(fromBrightness: 0.5) == 55)
        for d in 10...100 {
            #expect(WiZStateMapping.dimming(fromBrightness: WiZStateMapping.brightness(fromDimming: d)) == d)
        }
        #expect(WiZStateMapping.brightness(fromDimming: 5) == WiZStateMapping.brightness(fromDimming: 10))
    }

    @Test func rgbPilot() {
        let s = WiZStateMapping.state(from: WiZPilot(["state": true, "sceneId": 0, "r": 255, "g": 238, "b": 0, "c": 0, "w": 0, "dimming": 100]),
                                      capabilities: Self.rgbCaps)
        #expect(s.isOn && s.brightness == 1 && s.colorMode == .rgb && s.rgb == RGB(r: 255, g: 238, b: 0))
        #expect(s.kelvin == nil && s.effect == nil && s.rgbww == nil && s.reachable)
        #expect(s.colorAttribute == .rgb(RGB(r: 255, g: 238, b: 0)))
    }

    @Test func whiteChannelsReportedAsHint() {
        let s = WiZStateMapping.state(from: WiZPilot(["state": true, "r": 10, "g": 0, "b": 0, "c": 20, "w": 30]), capabilities: Self.rgbCaps)
        #expect(s.colorMode == .rgb && s.rgbww == RGBWW(r: 10, g: 0, b: 0, cw: 20, ww: 30))
    }

    @Test func tempModeWinsOverRGB() {
        let s = WiZStateMapping.state(from: WiZPilot(["state": true, "temp": 3000, "r": 1, "g": 2, "b": 3, "dimming": 10]), capabilities: Self.rgbCaps)
        #expect(s.colorMode == .colorTemp && s.kelvin == 3000 && s.rgb == nil)
        #expect(s.brightness == WiZStateMapping.brightness(fromDimming: 10))
    }

    @Test func scenePilot() {
        let s = WiZStateMapping.state(from: WiZPilot(["state": true, "sceneId": 23, "speed": 145, "dimming": 100]), capabilities: Self.rgbCaps)
        #expect(s.effect == "23" && s.colorAttribute == nil)
        let tw = WiZStateMapping.state(from: WiZPilot(["state": false, "sceneId": 11, "dimming": 50]), capabilities: Self.twCaps)
        #expect(!tw.isOn && tw.effect == "11" && tw.colorMode == nil)
    }

    @Test func dimmableAndPlug() {
        #expect(WiZStateMapping.state(from: WiZPilot(["state": true, "dimming": 50]), capabilities: Self.dwCaps).colorMode == .brightness)
        let plug = WiZStateMapping.state(from: WiZPilot(["state": true, "dimming": 100]), capabilities: Self.plugCaps)
        #expect(plug.colorMode == .onOff && plug.brightness == nil)
    }

    private func params(_ c: LightCommand, _ caps: LightCapabilities = rgbCaps) -> String {
        WiZCommandEncoder.params(for: c, capabilities: caps).compactString
    }

    @Test func onOff() {
        #expect(params(.turnOn) == #"{"state":true}"#)
        #expect(params(.turnOff) == #"{"state":false}"#)
        #expect(params(LightCommand(on: false, brightness: 0.5, color: .rgb(.white))) == #"{"state":false}"#)
        #expect(params(LightCommand(brightness: 0)) == #"{"state":false}"#)
        #expect(params(LightCommand()) == "{}")
        #expect(WiZCommandEncoder.request(for: LightCommand(), capabilities: Self.rgbCaps) == nil)
    }

    @Test func combinesColorAndBrightnessInOneMessage() {
        #expect(params(LightCommand(brightness: 1, color: .rgb(RGB(r: 0, g: 0, b: 255))))
            == #"{"state":true,"r":0,"g":0,"b":255,"dimming":100}"#)
        #expect(params(LightCommand(on: true, brightness: 0.75, color: .kelvin(3000)))
            == #"{"state":true,"temp":3000,"dimming":78}"#)
        #expect(params(LightCommand(brightness: 0.5)) == #"{"state":true,"dimming":55}"#)
        let req = WiZCommandEncoder.request(for: LightCommand(brightness: 1, color: .kelvin(3000)), capabilities: Self.rgbCaps, id: 1)
        #expect(req.map { String(decoding: $0.encoded(), as: UTF8.self) } == #"{"id":1,"method":"setPilot","params":{"state":true,"temp":3000,"dimming":100}}"#)
    }

    @Test func kelvinClampedToCCTRange() {
        #expect(params(LightCommand(color: .kelvin(9000))) == #"{"state":true,"temp":6500}"#)
        #expect(params(LightCommand(color: .kelvin(1000))) == #"{"state":true,"temp":2200}"#)
        #expect(params(LightCommand(color: .kelvin(6000)), Self.twCaps) == #"{"state":true,"temp":5000}"#)
    }

    @Test func hsAndXYBecomeRGB() {
        #expect(params(LightCommand(color: .hs(HS(h: 240, s: 1)))) == #"{"state":true,"r":0,"g":0,"b":255}"#)
        #expect(params(LightCommand(color: .hs(HS(h: 0, s: 1)))) == #"{"state":true,"r":255,"g":0,"b":0}"#)
        let xyRed = WiZCommandEncoder.params(for: LightCommand(color: .xy(XY(x: 0.7, y: 0.299))), capabilities: Self.rgbCaps)
        #expect(xyRed.keys == ["state", "r", "g", "b"])
        #expect((xyRed.int("r") ?? 0) > 200 && (xyRed.int("g") ?? 255) < 60)
    }

    @Test func colorOnWhiteOnlyBulbBecomesKelvin() {
        let p = WiZCommandEncoder.params(for: LightCommand(color: .rgb(RGB(r: 255, g: 180, b: 100))), capabilities: Self.twCaps)
        #expect(p.keys == ["state", "temp"])
        #expect((2700...5000).contains(p.int("temp") ?? 0))
    }

    @Test func dimmableAndPlugDropUnsupported() {
        #expect(params(LightCommand(brightness: 1, color: .kelvin(3000)), Self.dwCaps) == #"{"state":true,"dimming":100}"#)
        #expect(params(LightCommand(brightness: 0.5, color: .rgb(.white)), Self.plugCaps) == "{}")
        #expect(params(LightCommand(on: true, brightness: 0.5), Self.plugCaps) == #"{"state":true}"#)
    }

    @Test func effects() {
        #expect(params(LightCommand(brightness: 1, effect: "23")) == #"{"state":true,"sceneId":23,"dimming":100}"#)
        // Scene wins over a colour in the same command.
        #expect(params(LightCommand(color: .rgb(.white), effect: "4")) == #"{"state":true,"sceneId":4}"#)
        // Unsupported for the bulb type (Party on a dimmable bulb) -> dropped.
        #expect(params(LightCommand(effect: "4"), Self.dwCaps) == "{}")
        #expect(params(LightCommand(effect: "14"), Self.dwCaps) == #"{"state":true,"sceneId":14}"#)
        #expect(params(LightCommand(effect: "999")) == "{}")
    }

    @Test func rgbwwChannelsPassThroughWhenGiven() {
        var p = WiZObject()
        WiZCommandEncoder.appendColor(.rgbww(RGBWW(r: 1, g: 2, b: 3, cw: 4, ww: 5)), capabilities: Self.rgbCaps, to: &p)
        #expect(p.compactString == #"{"r":1,"g":2,"b":3,"c":4,"w":5}"#)
    }
}
