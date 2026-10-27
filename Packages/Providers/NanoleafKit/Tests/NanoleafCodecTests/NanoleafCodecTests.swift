import Foundation
import LightCore
import NetKit
import Testing
@testable import NanoleafCodec

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func json(_ data: Data?) -> String {
    data.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

@Suite("Models")
struct ModelTests {
    @Test func decodesShapesInfo() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_shapes.json"))
        #expect(info.name == "Shapes 4A2B")
        #expect(info.serialNo == "S19124C8036")
        #expect(info.model == "NL42")
        #expect(info.firmwareVersion == "9.2.4")
        #expect(info.state?.on?.value == true)
        #expect(info.state?.brightness == NanoleafRange(value: 65, min: 0, max: 100))
        #expect(info.state?.ct?.range == 1200...6500)
        #expect(info.state?.mode == .effect)
        #expect(info.effects?.select == "Northern Lights")
        #expect(info.effects?.effectsList?.count == 9)
        #expect(info.panelCount == 3)
        #expect(info.panelLayout?.layout?.positionData?.first == NanoleafPanelPosition(panelId: 7397, x: 100, y: 50, o: 60, shapeType: 7))
        #expect(info.panelLayout?.globalOrientation?.value == 120)
    }

    @Test func decodesOldLightPanelsInfo() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_lightpanels_old.json"))
        #expect(info.state?.brightness?.value == 100) // sent as 100.0
        #expect(info.state?.on?.value == false)
        #expect(info.panelLayout?.layout?.positionData?.first?.shapeType == nil)
        #expect(info.panelCount == 2)
    }

    @Test func decodesMinimalInfo() throws {
        let info = try NanoleafAPI.decodeInfo(Data("{}".utf8))
        #expect(info.name == nil)
        #expect(info.state == nil)
    }

    @Test func decodesAuthTokenAndEffectsList() throws {
        #expect(try NanoleafAPI.decodeAuthToken(fixture("auth_token.json")) == "dTgvbmZnaGVpZm9sZjNkeWQ1dDJ4YXlB")
        #expect(try NanoleafAPI.decodeEffectsList(fixture("effects_list.json")).count == 9)
        #expect(throws: NanoleafCodecError.invalidToken) {
            try NanoleafAPI.decodeAuthToken(Data(#"{"auth_token":"../evil"}"#.utf8))
        }
        #expect(throws: NanoleafCodecError.self) { try NanoleafAPI.decodeAuthToken(Data("{}".utf8)) }
    }
}

@Suite("Requests")
struct RequestTests {
    let token = "dTgvbmZnaGVpZm9sZjNkeWQ1dDJ4YXlB"

    @Test func paths() throws {
        #expect(NanoleafAPI.addUser() == NanoleafRequest(method: .post, path: "/api/v1/new"))
        #expect(try NanoleafAPI.info(token: token).path == "/api/v1/\(token)/")
        #expect(try NanoleafAPI.info(token: token).method == .get)
        #expect(try NanoleafAPI.deleteUser(token: token) == NanoleafRequest(method: .delete, path: "/api/v1/\(token)"))
        #expect(try NanoleafAPI.identify(token: token) == NanoleafRequest(method: .put, path: "/api/v1/\(token)/identify"))
        #expect(try NanoleafAPI.effectsList(token: token).path == "/api/v1/\(token)/effects/effectsList")
        #expect(try NanoleafAPI.events(token: token).path == "/api/v1/\(token)/events?id=1,2,3,4")
        #expect(try NanoleafAPI.events(token: token, types: [.touch, .state]).path == "/api/v1/\(token)/events?id=1,4")
    }

    @Test func rejectsUnsafeTokens() {
        for bad in ["", "a/b", "abc?x=1", "a b", "tok%2F"] {
            #expect(!NanoleafAPI.isValidToken(bad))
            #expect(throws: NanoleafCodecError.invalidToken) { try NanoleafAPI.info(token: bad) }
        }
        #expect(NanoleafAPI.isValidToken(token))
    }

    @Test func redactsToken() throws {
        #expect(try NanoleafAPI.setState(token: token, NanoleafStateUpdate(on: true)).redactedPath == "/api/v1/<token>/state")
        #expect(try NanoleafAPI.events(token: token).redactedPath == "/api/v1/<token>/events?id=1,2,3,4")
        #expect(NanoleafAPI.addUser().redactedPath == "/api/v1/new")
    }

    @Test func stateBodies() throws {
        #expect(json(try NanoleafAPI.setState(token: token, NanoleafStateUpdate(on: true)).body) == #"{"on":{"value":true}}"#)
        #expect(json(try NanoleafStateUpdate(brightness: 80, duration: 3).jsonData()) == #"{"brightness":{"duration":3,"value":80}}"#)
        #expect(json(try NanoleafStateUpdate(brightness: 80).jsonData()) == #"{"brightness":{"value":80}}"#)
        #expect(json(try NanoleafStateUpdate(hue: 120, sat: 100).jsonData()) == #"{"hue":{"value":120},"sat":{"value":100}}"#)
        #expect(json(try NanoleafStateUpdate(ct: 2700).jsonData()) == #"{"ct":{"value":2700}}"#)
        let all = NanoleafStateUpdate(on: true, brightness: 50, hue: 10, sat: 20)
        #expect(json(try all.jsonData()) == #"{"brightness":{"value":50},"hue":{"value":10},"on":{"value":true},"sat":{"value":20}}"#)
        #expect(all.split() == [
            NanoleafStateUpdate(on: true), NanoleafStateUpdate(brightness: 50), NanoleafStateUpdate(hue: 10, sat: 20),
        ])
    }

    @Test func effectBody() throws {
        let r = try NanoleafAPI.selectEffect(token: token, name: "Northern Lights")
        #expect(r.method == .put)
        #expect(r.path == "/api/v1/\(token)/effects")
        #expect(json(r.body) == #"{"select":"Northern Lights"}"#)
    }
}

@Suite("Events")
struct EventTests {
    @Test func decodesFixtureStream() throws {
        var parser = SSEParser()
        let events = NanoleafEventDecoder.feed(Array(try fixture("events_stream.txt")), into: &parser)
        #expect(events == [
            .state([.brightness(65), .on(true)]),
            .state([.colorMode("hs"), .hue(120), .saturation(90)]),
            .effects(selected: "Falling Whites"),
            .layout(attributes: [2]),
            .touch([NanoleafTouch(panelId: 7397, gesture: 0), NanoleafTouch(panelId: -1, gesture: 5)]),
        ])
        if case .touch(let touches) = events.last {
            #expect(touches.map(\.kind) == [.singleTap, .swipeRight])
        }
    }

    @Test func handlesChunkedAndCRLFInput() {
        var parser = SSEParser()
        let text = "id: 1\r\ndata: {\"events\":[{\"attr\":5,\"value\":3000}]}\r\n\r\n"
        var out: [NanoleafEvent] = []
        for byte in Array(text.utf8) { out += NanoleafEventDecoder.feed([byte], into: &parser) }
        #expect(out == [.state([.colorTemperature(3000)])])
    }

    @Test func unknownAndMalformed() throws {
        #expect(try NanoleafEventDecoder.decode(SSEEvent(id: "9", data: "{}")) == .unknown(id: "9", data: "{}"))
        #expect(throws: NanoleafCodecError.self) { try NanoleafEventDecoder.decode(SSEEvent(id: "1", data: "nope")) }
    }

    @Test func appliesChangesToState() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_shapes.json"))
        let next = try #require(info.state).applying([.on(false), .brightness(10), .colorMode("ct"), .colorTemperature(3000)])
        #expect(next.on?.value == false)
        #expect(next.brightness == NanoleafRange(value: 10, min: 0, max: 100))
        #expect(next.ct == NanoleafRange(value: 3000, min: 1200, max: 6500))
        #expect(next.mode == .ct)
        let fromWrite = NanoleafState().applying(NanoleafStateUpdate(brightness: 40, hue: 30, sat: 50))
        #expect(fromWrite.on?.value == true)
        #expect(fromWrite.mode == .hs)
        #expect(fromWrite.hue?.value == 30)
    }
}

@Suite("Mapping")
struct MappingTests {
    @Test func capabilities() throws {
        let caps = NanoleafMapper.capabilities(for: try NanoleafAPI.decodeInfo(fixture("info_shapes.json")))
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(caps.minKelvin == 1200)
        #expect(caps.maxKelvin == 6500)
        #expect(caps.supportsTransition)
        #expect(caps.supportsEffects)
        // "*Solid*" and the duplicate "Flames" are dropped.
        #expect(caps.effects.map(\.id) == ["Fireworks", "Flames", "Forest", "Inner Peace", "Northern Lights", "Romantic", "Snowfall"])
        #expect(caps.effects.first { $0.id == "Fireworks" }?.isFast == true)
        #expect(caps.effects.first { $0.id == "Forest" }?.isFast == false)
    }

    @Test func bogusCtRangeFallsBack() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_lightpanels_old.json"))
        #expect(NanoleafMapper.kelvinRange(info.state) == 1200...6500)
        let state = NanoleafMapper.lightState(from: info)
        #expect(state.isOn == false)
        #expect(state.brightness == 1)
        #expect(state.colorMode == .colorTemp)
        #expect(state.kelvin == 2700)
        #expect(state.effect == nil)
    }

    @Test func effectModeState() throws {
        let state = NanoleafMapper.lightState(from: try NanoleafAPI.decodeInfo(fixture("info_shapes.json")))
        #expect(state.isOn)
        #expect(state.brightness == 0.65)
        #expect(state.colorMode == .hs)
        #expect(state.hs == HS(h: 210, s: 0.8))
        #expect(state.effect == "Northern Lights")
    }

    @Test func hsModeState() {
        let info = NanoleafInfo(state: NanoleafState(
            on: .init(value: true), brightness: .init(value: 50), hue: .init(value: 120), sat: .init(value: 100),
            ct: .init(value: 4000, min: 1200, max: 6500), colorMode: "hs"),
            effects: NanoleafEffects(select: "Flames"))
        let state = NanoleafMapper.lightState(from: info)
        #expect(state.colorMode == .hs)
        #expect(state.hs == HS(h: 120, s: 1))
        #expect(state.effect == nil)
        #expect(state.brightness == 0.5)
    }

    @Test func light() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_shapes.json"))
        let light = try #require(NanoleafMapper.light(info: info, stableID: "S19124C8036", host: "192.168.1.30", port: 16021))
        #expect(light.id.rawValue == "nanoleaf:S19124C8036")
        #expect(light.brand == .nanoleaf)
        #expect(light.name == "Shapes 4A2B")
        #expect(light.model == "NL42")
        #expect(light.manufacturer == "Nanoleaf")
        #expect(light.providerRef == "192.168.1.30:16021")
        let fallback = try #require(NanoleafMapper.light(info: nil, stableID: "X", fallbackName: "Canvas", host: nil, port: 16021, reachable: false))
        #expect(fallback.name == "Canvas")
        #expect(fallback.state.reachable == false)
        #expect(fallback.capabilities.kelvinRange == 1200...6500)
    }

    @Test func stableIDs() {
        #expect(NanoleafMapper.stableID(serialNo: "S19124C8036", bonjourID: "59:7E:43:1A:2B:3C") == "S19124C8036")
        #expect(NanoleafMapper.stableID(serialNo: nil, bonjourID: "59:7E:43:1A:2B:3C") == "59:7E:43:1A:2B:3C")
        #expect(NanoleafMapper.stableID(serialNo: " ", bonjourID: nil) == nil)
        #expect(NanoleafMapper.lightID(stableID: "59:7E:43:1A:2B:3C")?.rawValue == "nanoleaf:59:7E:43:1A:2B:3C")
    }

    @Test func brightnessScaling() {
        #expect(NanoleafMapper.deviceBrightness(0.5, in: 0...100) == 50)
        #expect(NanoleafMapper.deviceBrightness(1.4, in: 0...100) == 100)
        #expect(NanoleafMapper.deviceBrightness(0.333, in: 0...100) == 33)
        #expect(NanoleafMapper.brightness(fromDevice: 25, in: 0...100) == 0.25)
        #expect(NanoleafMapper.brightness(fromDevice: 150, in: 0...100) == 1)
    }

    @Test func transitionSeconds() {
        #expect(NanoleafMapper.transitionSeconds(nil) == nil)
        #expect(NanoleafMapper.transitionSeconds(.milliseconds(400)) == 0)
        #expect(NanoleafMapper.transitionSeconds(.milliseconds(1600)) == 2)
        #expect(NanoleafMapper.transitionSeconds(.seconds(5)) == 5)
    }
}

@Suite("Commands")
struct CommandTests {
    let caps = NanoleafMapper.capabilities(for: NanoleafInfo(
        state: NanoleafState(ct: NanoleafRange(value: 4000, min: 1200, max: 6500)),
        effects: NanoleafEffects(effectsList: ["Flames", "Forest"])))

    private func plan(_ command: LightCommand) -> NanoleafCommandPlan {
        NanoleafMapper.plan(for: command.normalized(for: caps), capabilities: caps)
    }

    @Test func onOff() {
        #expect(plan(.turnOn) == NanoleafCommandPlan(stateUpdate: NanoleafStateUpdate(on: true)))
        #expect(plan(.turnOff) == NanoleafCommandPlan(stateUpdate: NanoleafStateUpdate(on: false)))
        // Off ignores everything else.
        #expect(plan(LightCommand(on: false, brightness: 0.5, color: .kelvin(3000))).stateUpdate == NanoleafStateUpdate(on: false))
    }

    @Test func brightness() {
        #expect(plan(LightCommand(brightness: 0.8)).stateUpdate == NanoleafStateUpdate(on: true, brightness: 80))
        #expect(plan(LightCommand(brightness: 0)).stateUpdate == NanoleafStateUpdate(on: false))
        #expect(plan(LightCommand(on: true, brightness: 0)).stateUpdate == NanoleafStateUpdate(on: true, brightness: 0))
        // With a fade, brightness+duration only (turns on and fades).
        #expect(plan(LightCommand(brightness: 0.3, transition: .seconds(2))).stateUpdate
            == NanoleafStateUpdate(brightness: 30, duration: 2))
    }

    @Test func colour() {
        #expect(plan(LightCommand(color: .hs(HS(h: 359.6, s: 0.5)))).stateUpdate == NanoleafStateUpdate(hue: 0, sat: 50))
        #expect(plan(LightCommand(color: .kelvin(9000))).stateUpdate == NanoleafStateUpdate(ct: 6500))
        #expect(plan(LightCommand(color: .kelvin(1000))).stateUpdate == NanoleafStateUpdate(ct: 1200))
        // RGB is normalised to hs (pure red).
        #expect(plan(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0)))).stateUpdate == NanoleafStateUpdate(hue: 0, sat: 100))
        // xy is normalised to hs too.
        let xy = plan(LightCommand(color: .xy(XY(x: 0.17, y: 0.7)))).stateUpdate
        #expect(xy?.hue != nil && xy?.sat != nil && xy?.ct == nil)
        // Combined command: one write.
        #expect(plan(LightCommand(on: true, brightness: 1, color: .hs(HS(h: 240, s: 1)))).stateUpdate
            == NanoleafStateUpdate(on: true, brightness: 100, hue: 240, sat: 100))
    }

    @Test func effects() {
        #expect(plan(LightCommand(effect: "Flames")) == NanoleafCommandPlan(effect: "Flames"))
        #expect(plan(LightCommand(effect: "Unknown")).isEmpty) // normalisation drops unknown effects
        #expect(plan(LightCommand(on: true, effect: "Forest")) == NanoleafCommandPlan(stateUpdate: NanoleafStateUpdate(on: true), effect: "Forest"))
    }
}

@Suite("Scenes and discovery")
struct SceneDiscoveryTests {
    @Test func sceneIDsRoundTrip() {
        let id = NanoleafMapper.sceneID(stableID: "59:7E:43:1A:2B:3C", effect: "Northern Lights/2")
        #expect(id == "nanoleaf:59:7E:43:1A:2B:3C/Northern Lights/2")
        let parsed = NanoleafMapper.parseSceneID(id)
        #expect(parsed?.stableID == "59:7E:43:1A:2B:3C")
        #expect(parsed?.effect == "Northern Lights/2")
        #expect(NanoleafMapper.parseSceneID("hue:abc/x") == nil)
        #expect(NanoleafMapper.parseSceneID("nanoleaf:abc") == nil)
    }

    @Test func scenesFromEffects() throws {
        let info = try NanoleafAPI.decodeInfo(fixture("info_shapes.json"))
        let scenes = NanoleafMapper.scenes(info: info, stableID: "S19124C8036")
        #expect(scenes.count == 7)
        #expect(scenes.allSatisfy { $0.kind == .vendor && $0.brand == .nanoleaf })
        #expect(scenes.first?.id == "nanoleaf:S19124C8036/Fireworks")
        #expect(scenes.first?.lightIDs.map(\.rawValue) == ["nanoleaf:S19124C8036"])
    }

    @Test func bonjourRecord() throws {
        let record = NanoleafServiceRecord(
            name: "Shapes 4A2B", host: "192.168.1.30", port: 16021,
            txt: ["id": "59:7E:43:1A:2B:3C", "md": "NL42", "srcvers": "9.2.4"])
        let device = try #require(NanoleafMapper.discoveredDevice(from: record))
        #expect(device.id == "59:7E:43:1A:2B:3C")
        #expect(device.brand == .nanoleaf)
        #expect(device.model == "NL42")
        #expect(device.port == 16021)
        #expect(device.method == .bonjour)
        #expect(device.macAddress == "59:7e:43:1a:2b:3c")
        #expect(device.metadata["firmware"] == "9.2.4")
        #expect(device.metadata["id"] == "59:7E:43:1A:2B:3C")

        let noID = try #require(NanoleafMapper.discoveredDevice(from: NanoleafServiceRecord(name: "N", host: "10.0.0.2", port: nil, txt: [:])))
        #expect(noID.id == "ip:10.0.0.2")
        #expect(noID.port == 16021)
        // IPv6 is never used.
        #expect(NanoleafMapper.discoveredDevice(from: NanoleafServiceRecord(name: "N", host: "fe80::1%en0", port: 16021, txt: [:])) == nil)
        #expect(NanoleafMapper.discoveredDevice(from: NanoleafServiceRecord(name: "N", host: nil, port: 16021, txt: [:])) == nil)
    }

    @Test func manualHosts() {
        #expect(NanoleafMapper.parseManualHost("192.168.1.30")! == ("192.168.1.30", 16021))
        #expect(NanoleafMapper.parseManualHost(" 192.168.1.30:1234 ")! == ("192.168.1.30", 1234))
        #expect(NanoleafMapper.parseManualHost("http://nanoleaf.local:16021/")! == ("nanoleaf.local", 16021))
        #expect(NanoleafMapper.parseManualHost("fe80::1") == nil)
        #expect(NanoleafMapper.parseManualHost("[fe80::1]:16021") == nil)
        #expect(NanoleafMapper.parseManualHost("1.2.3.4:99999") == nil)
        #expect(NanoleafMapper.parseManualHost("") == nil)
    }
}
