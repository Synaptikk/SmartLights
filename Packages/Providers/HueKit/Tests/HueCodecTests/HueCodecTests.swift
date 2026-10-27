import Foundation
import LightCore
import Testing

@testable import HueCodec

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func mini() throws -> HueResourceStore { try HueResourceStore(envelopeData: data("mini_resources")) }

    static let bridgeID = "001788FFFE4A2B3C"
    static let sofa = "10000000-0000-4000-8000-000000000001"
    static let desk = "10000000-0000-4000-8000-000000000002"
    static let hall = "10000000-0000-4000-8000-000000000003"
    static let livingGroup = "40000000-0000-4000-8000-000000000001"
    static let zoneGroup = "40000000-0000-4000-8000-000000000003"
    static let homeGroup = "40000000-0000-4000-8000-000000000009"
    static let relax = "60000000-0000-4000-8000-000000000001"

    static func lightID(_ rid: String) -> LightID { HueIdentifiers.lightID(bridgeID: bridgeID, resourceID: rid)! }
}

@Suite("Resource decoding")
struct DecodingTests {
    @Test func aiohueFixtureDecodes() throws {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Fixture.data("v2_resources"))
        let store = HueResourceStore(resources: raw)
        #expect(store.lights.count == 8)
        #expect(store.groupedLights.count == 4)
        #expect(store.rooms.count == 11)
        #expect(store.zones.count == 9)
        #expect(store.scenes.count == 6)
        #expect(store.bridges.count == 1)
        #expect(store.zigbee.count == 4)
        #expect(store.entertainmentConfigurations.count == 1)
        #expect(store.geofenceClients.count == 2)
        #expect(store.raw["motion"]?.count == 1)

        let light = try #require(store.lights["01b1da1b-2cb1-eb71-5391-63b5ae1ceb6c"])
        #expect(light.metadata?.name == "Light 1")
        #expect(light.on?.on == false)
        #expect(light.dimming?.brightness == 81.03)
        #expect(light.colorTemperature?.mirek == nil)
        #expect(light.colorTemperature?.mirekSchema?.mirekMinimum == 50)
        #expect(light.color?.gamutType == "C")
        #expect(light.effects?.effectValues?.contains("candle") == true)

        let caps = HueMapping.capabilities(for: light)
        #expect(caps.supportedColorModes == [.xy, .colorTemp])
        #expect(caps.gamut == .hueC)
        #expect(caps.minKelvin == 1000)
        #expect(caps.maxKelvin == 20000)
        #expect(caps.effects.first?.id == "no_effect")
        #expect(caps.supportsTransition)

        let state = HueMapping.state(for: light, reachable: true)
        #expect(state.isOn == false)
        #expect(abs((state.brightness ?? 0) - 0.8103) < 1e-9)
        #expect(state.colorMode == .xy)
        #expect(state.xy == XY(x: 0.5974, y: 0.36))

        // Room membership through room -> device -> light service.
        let lights = store.makeLights(bridgeID: "001788FFFE000001")
        #expect(lights.count == 8)
        let light2 = try #require(lights.first { $0.name == "Light 2" })
        #expect(light2.roomHint == "Room 9")
        #expect(light2.capabilities.supportedColorModes == [.colorTemp])
        #expect(store.makeScenes(bridgeID: "001788FFFE000001").count == 6)
        #expect(store.entertainmentConfigurations.values.first?.configurationType == "screen")
    }

    @Test func miniFixtureMapsToLights() throws {
        let store = try Fixture.mini()
        #expect(store.bridgeID == Fixture.bridgeID)
        let lights = store.makeLights(bridgeID: Fixture.bridgeID)
        #expect(lights.count == 3)

        let sofa = try #require(lights.first { $0.id == Fixture.lightID(Fixture.sofa) })
        #expect(sofa.id.rawValue == "hue:001788FFFE4A2B3C/\(Fixture.sofa)")
        #expect(sofa.providerRef == "001788FFFE4A2B3C/\(Fixture.sofa)")
        #expect(sofa.roomHint == "Living room")
        #expect(sofa.model == "LCA001")
        #expect(sofa.manufacturer == nil)
        #expect(sofa.state.isOn)
        #expect(sofa.state.brightness == 0.8)
        #expect(sofa.state.colorMode == .xy)
        #expect(sofa.state.reachable)

        let desk = try #require(lights.first { $0.id == Fixture.lightID(Fixture.desk) })
        #expect(desk.state.colorMode == .colorTemp)
        #expect(desk.state.kelvin == 2732)
        #expect(desk.state.reachable == false)
        #expect(desk.manufacturer == "_TZ3210_abc")
        #expect(desk.capabilities.minKelvin == 2202)
        #expect(desk.capabilities.maxKelvin == 6535)
        #expect(desk.capabilities.gamut?.red == XY(x: 0.68, y: 0.31))

        let hall = try #require(lights.first { $0.id == Fixture.lightID(Fixture.hall) })
        #expect(hall.capabilities.supportedColorModes == [.brightness])
        #expect(hall.roomHint == "Hallway")
        #expect(hall.state.colorMode == .brightness)
    }

    @Test func unknownFieldsArePreservedInRawStore() throws {
        let store = try Fixture.mini()
        #expect(store.raw["light"]?[Fixture.sofa]?["some_future_field"]?["nested"] == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func scenesMapToVendorScenes() throws {
        let scenes = try Fixture.mini().makeScenes(bridgeID: Fixture.bridgeID)
        #expect(scenes.count == 1)
        let relax = try #require(scenes.first)
        #expect(relax.id == "hue:001788FFFE4A2B3C/\(Fixture.relax)")
        #expect(relax.kind == .vendor)
        #expect(relax.brand == .hue)
        #expect(relax.roomHint == "Living room")
        #expect(relax.lightIDs == [Fixture.lightID(Fixture.sofa), Fixture.lightID(Fixture.desk)])
    }

    @Test func envelopeErrorsAreReadable() throws {
        let body = Data(#"{"errors":[{"description":"device (light) has no dimming capability"}],"data":[]}"#.utf8)
        let env = try JSONDecoder().decode(ResourceEnvelope<[JSONValue]>.self, from: body)
        #expect(env.errorDescription == "device (light) has no dimming capability")
    }
}

@Suite("SSE merge")
struct EventMergeTests {
    func message(_ type: String, _ items: String) throws -> [HueEventMessage] {
        try HueEventMessage.decodeList(
            #"[{"creationtime":"2026-10-26T12:00:00Z","id":"e1","type":"\#(type)","data":[\#(items)]}]"#)
    }

    @Test func partialLightUpdateMergesAndEmitsState() throws {
        var store = try Fixture.mini()
        let events = store.apply(
            try message("update", #"{"id":"\#(Fixture.hall)","id_v1":"/lights/3","on":{"on":false},"dimming":{"brightness":12.5},"type":"light"}"#),
            bridgeID: Fixture.bridgeID)
        #expect(events.count == 1)
        guard case .stateChanged(let id, let state) = events.first else {
            Issue.record("expected stateChanged, got \(events)")
            return
        }
        #expect(id == Fixture.lightID(Fixture.hall))
        #expect(state.isOn == false)
        #expect(state.brightness == 0.125)
        // Untouched fields survive the merge.
        #expect(store.lights[Fixture.hall]?.dimming?.minDimLevel == 1.0)
        #expect(store.lights[Fixture.hall]?.metadata?.name == "Hall bulb")
    }

    @Test func colorTemperatureNullSwitchesToXY() throws {
        var store = try Fixture.mini()
        let events = store.apply(
            try message("update", #"{"id":"\#(Fixture.desk)","color":{"xy":{"x":0.3,"y":0.3}},"color_temperature":{"mirek":null,"mirek_valid":false},"type":"light"}"#),
            bridgeID: Fixture.bridgeID)
        guard case .stateChanged(_, let state)? = events.first else {
            Issue.record("expected stateChanged")
            return
        }
        #expect(state.colorMode == .xy)
        #expect(state.xy == XY(x: 0.3, y: 0.3))
        #expect(state.kelvin == nil)
        // mirek_schema kept after merging a partial color_temperature object.
        #expect(store.lights[Fixture.desk]?.colorTemperature?.mirekSchema?.mirekMaximum == 454)
    }

    @Test func noOpUpdateEmitsNothing() throws {
        var store = try Fixture.mini()
        let events = store.apply(
            try message("update", #"{"id":"\#(Fixture.sofa)","on":{"on":true},"type":"light"}"#), bridgeID: Fixture.bridgeID)
        #expect(events.isEmpty)
    }

    @Test func unknownResourceUpdateIsIgnored() throws {
        var store = try Fixture.mini()
        let before = store
        let events = store.apply(
            try message("update", #"{"id":"ffffffff-0000-4000-8000-000000000000","on":{"on":true},"type":"light"}"#),
            bridgeID: Fixture.bridgeID)
        #expect(events.isEmpty)
        #expect(store == before)
    }

    @Test func connectivityChangeEmitsReachability() throws {
        var store = try Fixture.mini()
        let events = store.apply(
            try message("update", #"{"id":"20000000-0000-4000-8000-000000000001","status":"disconnected","type":"zigbee_connectivity"}"#),
            bridgeID: Fixture.bridgeID)
        #expect(events == [.reachabilityChanged(Fixture.lightID(Fixture.sofa), reachable: false)])
    }

    @Test func addAndDeleteLight() throws {
        var store = try Fixture.mini()
        let newID = "10000000-0000-4000-8000-000000000004"
        let added = store.apply(
            try message("add", #"{"id":"\#(newID)","type":"light","metadata":{"name":"New bulb"},"on":{"on":true},"dimming":{"brightness":100}}"#),
            bridgeID: Fixture.bridgeID)
        guard case .lightAdded(let light)? = added.first else {
            Issue.record("expected lightAdded, got \(added)")
            return
        }
        #expect(light.name == "New bulb")
        let removed = store.apply(try message("delete", #"{"id":"\#(newID)","type":"light"}"#), bridgeID: Fixture.bridgeID)
        #expect(removed == [.lightRemoved(Fixture.lightID(newID))])
        #expect(store.lights[newID] == nil)
    }

    @Test func sceneChangesOnlyOnStructuralUpdates() throws {
        var store = try Fixture.mini()
        let status = store.apply(
            try message("update", #"{"id":"\#(Fixture.relax)","status":{"active":"static"},"type":"scene"}"#),
            bridgeID: Fixture.bridgeID)
        #expect(status.isEmpty)
        let renamed = store.apply(
            try message("update", #"{"id":"\#(Fixture.relax)","metadata":{"name":"Chill"},"type":"scene"}"#),
            bridgeID: Fixture.bridgeID)
        #expect(renamed == [.scenesChanged])
        let added = store.apply(
            try message("add", #"{"id":"60000000-0000-4000-8000-000000000002","type":"scene","metadata":{"name":"Bright"}}"#),
            bridgeID: Fixture.bridgeID)
        #expect(added == [.scenesChanged])
    }

    @Test func roomRenameUpdatesRoomHints() throws {
        var store = try Fixture.mini()
        let events = store.apply(
            try message("update", #"{"id":"30000000-0000-4000-8000-000000000002","metadata":{"name":"Entrance"},"type":"room"}"#),
            bridgeID: Fixture.bridgeID)
        guard case .lightUpdated(let light)? = events.first else {
            Issue.record("expected lightUpdated, got \(events)")
            return
        }
        #expect(light.roomHint == "Entrance")
    }

    @Test func errorEventsAndGarbageAreIgnored() throws {
        var store = try Fixture.mini()
        #expect(store.apply(try message("error", #"{"id":"x","type":"light"}"#), bridgeID: Fixture.bridgeID).isEmpty)
        #expect(throws: HueError.self) { try HueEventMessage.decodeList("not json") }
    }

    @Test func deepMergeSemantics() {
        let base: JSONValue = .object(["a": .object(["x": .int(1), "y": .int(2)]), "list": .array([.int(1)])])
        let merged = base.merging(.object(["a": .object(["y": .null]), "list": .array([])]))
        #expect(merged == .object(["a": .object(["x": .int(1), "y": .null]), "list": .array([])]))
    }

    @Test func resyncDiff() throws {
        let old = try Fixture.mini()
        var new = old
        new.merge(partial: .object(["id": .string(Fixture.hall), "type": .string("light"), "on": .object(["on": .bool(false)])]))
        new.remove(type: "light", id: Fixture.desk)
        new.remove(type: "scene", id: Fixture.relax)
        let events = HueResourceStore.diff(from: old, to: new, bridgeID: Fixture.bridgeID)
        #expect(events.contains(.lightRemoved(Fixture.lightID(Fixture.desk))))
        #expect(events.contains(.scenesChanged))
        let hallOff = events.contains { event in
            guard case .stateChanged(let id, let s) = event else { return false }
            return id == Fixture.lightID(Fixture.hall) && !s.isOn
        }
        #expect(hallOff)
    }
}

@Suite("Command bodies")
struct CommandTests {
    func body(_ command: LightCommand, _ rid: String) throws -> HueLightUpdate {
        let light = try #require(try Fixture.mini().lights[rid])
        return HueMapping.lightUpdate(
            for: command, capabilities: HueMapping.capabilities(for: light), mirekSchema: light.colorTemperature?.mirekSchema)
    }

    func json(_ update: HueLightUpdate) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: update.jsonData())
    }

    @Test func brightnessKelvinAndTransitionInOnePut() throws {
        let update = try body(LightCommand(brightness: 0.5, color: .kelvin(2700), transition: .milliseconds(400)), Fixture.desk)
        #expect(update == HueLightUpdate(on: true, brightness: 50, mirek: 370, durationMilliseconds: 400))
        let text = String(decoding: try update.jsonData(), as: UTF8.self)
        #expect(text.contains(#""color_temperature":{"mirek":370}"#))
        #expect(text.contains(#""dynamics":{"duration":400}"#))
        #expect(text.contains(#""on":{"on":true}"#))
        #expect(!text.contains("effects"))
    }

    @Test func kelvinClampedToSchema() throws {
        let warm = try body(LightCommand(color: .kelvin(1500)), Fixture.desk)
        #expect(warm.colorTemperature?.mirek == 454)
        let cold = try body(LightCommand(color: .kelvin(10000)), Fixture.desk)
        #expect(cold.colorTemperature?.mirek == 153)
        #expect(cold.on == nil)
    }

    @Test func rgbBecomesGamutClampedXY() throws {
        let update = try body(LightCommand(on: true, color: .rgb(RGB(r: 255, g: 0, b: 0))), Fixture.sofa)
        let xy = try #require(update.color?.xy)
        #expect(Gamut.hueC.contains(XY(x: xy.x, y: xy.y)) || abs(xy.x - 0.6915) < 0.01)
        #expect(xy.x > 0.6)
        #expect(update.colorTemperature == nil)
    }

    @Test func xyOutsideGamutIsClamped() throws {
        let update = try body(LightCommand(color: .xy(XY(x: 0.05, y: 0.9))), Fixture.sofa)
        let xy = try #require(update.color?.xy)
        let clamped = Gamut.hueC.clamp(XY(x: 0.05, y: 0.9))
        #expect(abs(xy.x - clamped.x) < 1e-3 && abs(xy.y - clamped.y) < 1e-3)
    }

    @Test func kelvinOnColorLightUsesMirek() throws {
        let update = try body(LightCommand(color: .kelvin(4000)), Fixture.sofa)
        #expect(update.colorTemperature?.mirek == 250)
        #expect(update.color == nil)
    }

    @Test func brightnessZeroTurnsOff() throws {
        let update = try body(LightCommand(brightness: 0), Fixture.hall)
        #expect(update == HueLightUpdate(on: false))
    }

    @Test func colorDroppedOnDimmableOnlyLight() throws {
        let update = try body(LightCommand(brightness: 0.25, color: .rgb(RGB(r: 0, g: 0, b: 255))), Fixture.hall)
        #expect(update == HueLightUpdate(on: true, brightness: 25))
    }

    @Test func effectsAreValidated() throws {
        #expect(try body(LightCommand(effect: "candle"), Fixture.sofa).effects?.effect == "candle")
        #expect(try body(LightCommand(effect: "disco"), Fixture.sofa).isEmpty)
        #expect(try body(LightCommand(effect: "candle"), Fixture.hall).isEmpty)
    }

    @Test func groupBodyDropsEffectsAndGamut() throws {
        let store = try Fixture.mini()
        let caps = [Fixture.sofa, Fixture.desk].compactMap { store.lights[$0] }.map(HueMapping.capabilities(for:))
        let update = HueMapping.groupUpdate(for: LightCommand(on: true, color: .kelvin(3000), effect: "candle"), members: caps)
        #expect(update == HueLightUpdate(on: true, mirek: 333))
    }

    @Test func sceneRecallBody() throws {
        let text = String(decoding: try HueSceneRecall(action: .dynamicPalette).jsonData(), as: UTF8.self)
        #expect(text == #"{"recall":{"action":"dynamic_palette"}}"#)
        let active = String(decoding: try HueSceneRecall(action: .active, durationMilliseconds: 1000).jsonData(), as: UTF8.self)
        #expect(active == #"{"recall":{"action":"active","duration":1000}}"#)
    }

    @Test func geofenceBodies() throws {
        let name = HueGeofenceClientBody.randomName()
        #expect(name.hasPrefix("smartlights_"))
        #expect(name.count == 22)
        let create = String(decoding: try JSONEncoder().encode(HueGeofenceClientBody.create(name: "smartlights_x")), as: UTF8.self)
        #expect(create.contains(#""type":"geofence_client""#))
        let rename = String(decoding: try JSONEncoder().encode(HueGeofenceClientBody.rename(name: "smartlights_y")), as: UTF8.self)
        #expect(!rename.contains("type"))
    }
}

@Suite("Colour math")
struct ColorTests {
    @Test func mirekKelvin() {
        #expect(HueMapping.kelvin(fromMirek: 153) == 6535)
        #expect(HueMapping.kelvin(fromMirek: 500) == 2000)
        #expect(HueMapping.mirek(fromKelvin: 2700) == 370)
        #expect(HueMapping.mirek(fromKelvin: 6500) == 153)
        #expect(HueMapping.mirek(fromKelvin: 20000) == 153)
        #expect(HueMapping.mirek(fromKelvin: 1000) == 500)
        let wide = HueMirekSchema(mirekMinimum: 50, mirekMaximum: 1000)
        #expect(HueMapping.mirek(fromKelvin: 1000, schema: wide) == 1000)
        #expect(HueMapping.kelvinRange(wide) == 1000...20000)
        #expect(HueMapping.kelvinRange(nil) == 2000...6535)
    }

    @Test func gamutTypes() {
        #expect(HueMapping.gamut(for: HueColor(gamutType: "A")) == .hueA)
        #expect(HueMapping.gamut(for: HueColor(gamutType: "B")) == .hueB)
        #expect(HueMapping.gamut(for: HueColor(gamutType: "c")) == .hueC)
        let degenerate = HueGamut(red: HueXY(x: 0.1, y: 0.1), green: HueXY(x: 0.1, y: 0.1), blue: HueXY(x: 0.1, y: 0.1))
        #expect(HueMapping.gamut(for: HueColor(gamut: degenerate, gamutType: "other")) == nil)
        #expect(HueMapping.gamut(for: nil) == nil)
    }

    @Test func gamutClampKeepsInsidePoints() {
        let inside = XY(x: 0.4, y: 0.4)
        #expect(Gamut.hueB.clamp(inside) == inside)
        let outside = XY(x: 0.7, y: 0.3)
        let clamped = Gamut.hueB.clamp(outside)
        #expect(clamped != outside)
        #expect(Gamut.hueB.contains(clamped) || abs(clamped.x - 0.675) < 0.01)
    }
}

@Suite("v1, discovery, errors")
struct V1Tests {
    @Test func pairingSuccess() throws {
        let data = Data(#"[{"success":{"username":"83b7780291a6ceffbe0bd049104df","clientkey":"33DDBFA2C8D2AB2E3F1E2D3C4B5A6978"}}]"#.utf8)
        #expect(try HuePairing.parse(data) == .success(username: "83b7780291a6ceffbe0bd049104df", clientKey: "33DDBFA2C8D2AB2E3F1E2D3C4B5A6978"))
    }

    @Test func pairingLinkButton() throws {
        let data = Data(#"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#.utf8)
        #expect(try HuePairing.parse(data) == .linkButtonNotPressed)
    }

    @Test func pairingOtherErrorsAndGarbage() throws {
        let data = Data(#"[{"error":{"type":7,"address":"/devicetype","description":"invalid value"}}]"#.utf8)
        #expect(try HuePairing.parse(data) == .error(type: 7, description: "invalid value"))
        #expect(throws: HueError.self) { try HuePairing.parse(Data("<html>".utf8)) }
        #expect(throws: HueError.self) { try HuePairing.parse(Data("[]".utf8)) }
    }

    @Test func pairingRequestBody() throws {
        let text = String(decoding: try JSONEncoder().encode(HuePairingRequest()), as: UTF8.self)
        #expect(text.contains(#""devicetype":"SmartLights#iphone""#))
        #expect(text.contains(#""generateclientkey":true"#))
    }

    @Test func bridgeConfig() throws {
        let data = Data(#"{"name":"Hue Bridge Pro","datastoreversion":"172","swversion":"2071127010","apiversion":"1.72.0","mac":"c4:29:96:0a:0b:0c","bridgeid":"c42996fffe0a0b0c","factorynew":false,"replacesbridgeid":null,"modelid":"BSB003","starterkitid":""}"#.utf8)
        let config = try JSONDecoder().decode(HueBridgeConfig.self, from: data)
        #expect(config.bridgeID == "C42996FFFE0A0B0C")
        #expect(config.isBridgePro)
        #expect(config.modelName == "Hue Bridge Pro")
        #expect(config.apiversion == "1.72.0")
        let v2 = try JSONDecoder().decode(HueBridgeConfig.self, from: Data(#"{"bridgeid":"001788FFFE000001","modelid":"BSB002"}"#.utf8))
        #expect(!v2.isBridgePro)
        #expect(v2.modelName == "Hue Bridge")
    }

    @Test func discoveryResponse() throws {
        let data = Data(#"[{"id":"001788fffe4a2b3c","internalipaddress":"192.168.1.20","port":443},{"id":"bad"},{"id":"001788fffe000002","internalipaddress":"192.168.1.21"}]"#.utf8)
        let entries = try HueDiscoveryEntry.parseList(data)
        #expect(entries.count == 2)
        #expect(entries[0].bridgeID == "001788FFFE4A2B3C")
        #expect(entries[0].port == 443)
        #expect(try HueDiscoveryEntry.parseList(Data("[]".utf8)).isEmpty)
    }

    @Test func bridgeIDs() {
        #expect(HueBridgeID.normalize("001788fffe4a2b3c") == "001788FFFE4A2B3C")
        #expect(HueBridgeID.normalize("aabbccddeeffggh") == nil)
        #expect(HueBridgeID.normalize("ip:192.168.1.2") == nil)
    }

    @Test func errorMapping() {
        let none = Data()
        #expect(HueError.from(status: 200, body: none, path: "/x") == nil)
        #expect(HueError.from(status: 207, body: none, path: "/x") == nil)
        #expect(HueError.from(status: 403, body: none, path: "/x") == .unauthorized)
        #expect(HueError.from(status: 401, body: none, path: "/x") == .unauthorized)
        #expect(HueError.from(status: 404, body: none, path: "/clip/v2/resource", isCollectionRequest: true) == .v2Unsupported)
        #expect(HueError.from(status: 404, body: none, path: "/clip/v2/resource/light/x") == .resourceNotFound("/clip/v2/resource/light/x"))
        #expect(HueError.from(status: 429, body: none, path: "/x") == .bridgeBusy)
        #expect(HueError.from(status: 503, body: none, path: "/x") == .bridgeBusy)
        #expect(HueError.isBusyStatus(429) && HueError.isBusyStatus(503) && !HueError.isBusyStatus(500))
        let body = Data(#"{"errors":[{"description":"body contains invalid JSON"}],"data":[]}"#.utf8)
        #expect(HueError.from(status: 400, body: body, path: "/x") == .requestRejected(status: 400, description: "body contains invalid JSON"))
        #expect(HueError.unauthorized.lightCoreError == .authenticationRequired(.hue))
        #expect(HueError.linkButtonNotPressed.lightCoreError == .timeout)
    }
}

@Suite("Identifiers, endpoints, group planning")
struct MiscTests {
    @Test func identifiers() throws {
        let id = try #require(HueIdentifiers.lightID(bridgeID: "001788FFFE000001", resourceID: "abc-123"))
        #expect(id.rawValue == "hue:001788FFFE000001/abc-123")
        let parts = try #require(HueIdentifiers.split(id))
        #expect(parts.bridgeID == "001788FFFE000001")
        #expect(parts.resourceID == "abc-123")
        let scene = try #require(HueIdentifiers.split(stableID: "hue:001788fffe000001/s-1"))
        #expect(scene.bridgeID == "001788FFFE000001")
        #expect(HueIdentifiers.split(stableID: "nonsense") == nil)
    }

    @Test func endpoints() {
        #expect(HueEndpoint.parseHost("192.168.1.2") == ("192.168.1.2", nil))
        #expect(HueEndpoint.parseHost("192.168.1.2:8443") == ("192.168.1.2", 8443))
        #expect(HueEndpoint.parseHost("https://192.168.1.2/") == ("192.168.1.2", nil))
        #expect(HueEndpoint.parseHost("[fe80::1]:443") == ("fe80::1", 443))
        #expect(HueEndpoint.parseHost("fe80::1") == ("fe80::1", nil))
        #expect(HueEndpoint.authority(host: "fe80::1%en0", port: nil) == "[fe80::1%25en0]")
        #expect(HueEndpoint.url(scheme: "https", host: "10.0.0.2", port: 4433, path: "api/config")?.absoluteString == "https://10.0.0.2:4433/api/config")
    }

    @Test func groupPlanUsesWholeRoomsOnly() throws {
        let store = try Fixture.mini()
        let living = HueGroupPlan.make(targets: [Fixture.sofa, Fixture.desk], store: store)
        #expect(living.grouped.map(\.groupedLightID) == [Fixture.livingGroup])
        #expect(living.individual.isEmpty)

        let all = HueGroupPlan.make(targets: [Fixture.sofa, Fixture.desk, Fixture.hall], store: store)
        #expect(all.grouped.map(\.groupedLightID) == [Fixture.homeGroup])

        let zone = HueGroupPlan.make(targets: [Fixture.sofa, Fixture.hall], store: store)
        #expect(zone.grouped.map(\.groupedLightID) == [Fixture.zoneGroup])

        let partial = HueGroupPlan.make(targets: [Fixture.desk, Fixture.hall], store: store)
        #expect(partial.grouped.isEmpty)
        #expect(partial.individual == [Fixture.desk, Fixture.hall])

        // Single-light room (Hallway) is never used: 1/s group limit is worse than 10/s per light.
        let single = HueGroupPlan.make(targets: [Fixture.hall], store: store)
        #expect(single.grouped.isEmpty)
    }

    @Test func memberships() throws {
        let store = try Fixture.mini()
        #expect(store.memberLightIDs(ofGroupedLight: Fixture.livingGroup) == [Fixture.sofa, Fixture.desk])
        #expect(store.memberLightIDs(ofGroupedLight: Fixture.homeGroup).count == 3)
        #expect(store.zones(forLight: Fixture.hall).map { $0.metadata?.name } == ["Reading"])
        #expect(store.lightIDs(ofDevice: "d0000000-0000-4000-8000-000000000001") == [Fixture.sofa])
    }
}
