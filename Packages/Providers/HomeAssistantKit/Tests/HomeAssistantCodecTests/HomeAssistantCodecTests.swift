import Foundation
import LightCore
import Testing

@testable import HomeAssistantCodec

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func message(_ name: String) throws -> HAIncomingMessage {
        let messages = try HAIncomingMessage.parse(try data(name))
        return try #require(messages.first)
    }

    static func result(_ name: String) throws -> HAJSONValue {
        guard case .result(_, true, let result, _) = try message(name) else {
            Issue.record("\(name) is not a successful result")
            return .null
        }
        return result
    }

    static let instance = "inst1"

    static func registry() throws -> HARegistry {
        HARegistry(
            entities: HAEntityRegistryEntry.list(from: try result("entity_registry_list")),
            devices: HADeviceRegistryEntry.list(from: try result("device_registry_list")),
            areas: HAAreaRegistryEntry.list(from: try result("area_registry_list")))
    }

    static func states() throws -> [String: HAEntityState] {
        Dictionary(uniqueKeysWithValues: HAEntityState.list(from: try result("get_states")).map { ($0.entityID, $0) })
    }

    static func lights() throws -> [String: Light] {
        let registry = try registry()
        var out: [String: Light] = [:]
        for state in try states().values {
            if let light = HALightMapping.light(for: state, instanceID: instance, registry: registry) {
                out[state.entityID] = light
            }
        }
        return out
    }
}

// MARK: - Messages

@Suite("WebSocket messages")
struct HAMessageTests {
    @Test func authPhaseMessagesFromDocs() throws {
        #expect(try Fixture.message("auth_required") == .authRequired(haVersion: "2021.5.3"))
        #expect(try Fixture.message("auth_ok") == .authOK(haVersion: "2021.5.3"))
        #expect(try Fixture.message("auth_invalid") == .authInvalid(message: "Invalid password"))
    }

    @Test func authMessageEncoding() throws {
        #expect(try HAAuthMessage.auth(accessToken: "ABCDEFGH").jsonString() == #"{"access_token":"ABCDEFGH","type":"auth"}"#)
    }

    @Test func commandEncodings() throws {
        #expect(try HACommand.subscribeEvents(eventType: "state_changed").message(id: 18).jsonString()
            == #"{"event_type":"state_changed","id":18,"type":"subscribe_events"}"#)
        #expect(try HACommand.subscribeEvents(eventType: nil).message(id: 2).jsonString() == #"{"id":2,"type":"subscribe_events"}"#)
        #expect(try HACommand.unsubscribeEvents(subscription: 18).message(id: 19).jsonString()
            == #"{"id":19,"subscription":18,"type":"unsubscribe_events"}"#)
        #expect(try HACommand.getStates.message(id: 19).jsonString() == #"{"id":19,"type":"get_states"}"#)
        #expect(try HACommand.getConfig.message(id: 3).jsonString() == #"{"id":3,"type":"get_config"}"#)
        #expect(try HACommand.ping.message(id: 19).jsonString() == #"{"id":19,"type":"ping"}"#)
        #expect(try HACommand.entityRegistryList.message(id: 5).jsonString() == #"{"id":5,"type":"config/entity_registry/list"}"#)
        #expect(try HACommand.areaRegistryList.message(id: 6).jsonString() == #"{"id":6,"type":"config/area_registry/list"}"#)
        #expect(try HACommand.deviceRegistryList.message(id: 7).jsonString() == #"{"id":7,"type":"config/device_registry/list"}"#)
        #expect(try HACommand.supportedFeatures(coalesceMessages: true).message(id: 1).jsonString()
            == #"{"features":{"coalesce_messages":1},"id":1,"type":"supported_features"}"#)
    }

    @Test func callServiceEncodingMatchesDocsShape() throws {
        let call = HAServiceCall(
            domain: "light", service: "turn_on", serviceData: ["color_name": "beige", "brightness": "101"],
            target: HAServiceTarget(entityIDs: ["light.kitchen"]))
        #expect(try HACommand.callService(call).message(id: 24).jsonString()
            == #"{"domain":"light","id":24,"service":"turn_on","service_data":{"brightness":"101","color_name":"beige"},"target":{"entity_id":"light.kitchen"},"type":"call_service"}"#)
        // Several entities -> list; no data -> no service_data key.
        let off = HAServiceCall(domain: "light", service: "turn_off").targeting(["light.a", "light.b"])
        #expect(try HACommand.callService(off).message(id: 2).jsonString()
            == #"{"domain":"light","id":2,"service":"turn_off","target":{"entity_id":["light.a","light.b"]},"type":"call_service"}"#)
    }

    @Test func resultsFromDocs() throws {
        guard case .result(24, true, let result, nil) = try Fixture.message("result_call_service") else {
            Issue.record("bad call_service result"); return
        }
        #expect(result["context"]?["id"]?.stringValue == "326ef27d19415c60c492fe330945f954")
        #expect(result["response"] == .null)
        #expect(try Fixture.message("result_subscribe") == .result(id: 18, success: true, result: .null, error: nil))
        #expect(try Fixture.message("pong") == .pong(id: 19))
        #expect(try Fixture.message("result_error")
            == .result(id: 12, success: false, result: .null, error: HAErrorInfo(code: "not_found", message: "Service light.explode not found.")))
    }

    @Test func stateChangedEventFromDocs() throws {
        guard case .event(18, let event) = try Fixture.message("event_state_changed") else {
            Issue.record("not an event"); return
        }
        #expect(event.eventType == "state_changed")
        #expect(event.origin == "LOCAL")
        let change = try #require(event.stateChanged)
        #expect(change.entityID == "light.bed_light")
        #expect(change.oldState?.state == "off")
        let new = try #require(change.newState)
        #expect(new.state == "on")
        #expect(new.friendlyName == "Bed Light")
        let updated = try #require(new.lastUpdated)
        #expect(abs(updated.timeIntervalSince(try #require(HADate.parse("2016-11-26T01:37:24.265+00:00")))) < 0.001)

        // Pre-colour-mode attributes (legacy supported_features 147 = brightness|color_temp|color|white).
        let caps = HALightMapping.capabilities(for: new)
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(!caps.supportsTransition)
        #expect(!caps.supportsEffects)
        let state = HALightMapping.lightState(for: new)
        #expect(state.isOn)
        #expect(state.brightness == 180.0 / 255)
        #expect(state.colorMode == .colorTemp)
        #expect(state.kelvin == ColorMath.miredToKelvin(380))
        #expect(state.rgb == RGB(r: 254, g: 208, b: 0))
        #expect(state.xy == XY(x: 0.5, y: 0.5))
    }

    @Test func coalescedFrameYieldsEveryMessage() throws {
        let messages = try HAIncomingMessage.parse(try Fixture.data("coalesced"))
        #expect(messages.count == 3)
        #expect(messages[0] == .result(id: 2, success: true, result: .null, error: nil))
        guard case .event(2, let event) = messages[1] else { Issue.record("expected event"); return }
        #expect(event.stateChanged?.oldState == nil)
        #expect(event.stateChanged?.newState?.state == "off")
        #expect(messages[2] == .pong(id: 3))
    }

    @Test func unknownMessagesAreKept() throws {
        let messages = try HAIncomingMessage.parse(#"{"id":4,"type":"something_new","x":1}"#)
        guard case .unknown("something_new", _) = messages.first else { Issue.record("expected unknown"); return }
        #expect(throws: (any Error).self) { try HAIncomingMessage.parse("not json") }
    }
}

// MARK: - Registries and states

@Suite("Registries and get_states")
struct HARegistryTests {
    @Test func registryListsDecode() throws {
        let entities = HAEntityRegistryEntry.list(from: try Fixture.result("entity_registry_list"))
        #expect(entities.count == 10)
        let bed = try #require(entities.first { $0.entityID == "light.bed_light" })
        #expect(bed.id == "0f3a6b5e4c3d2b1a09f8e7d6c5b4a301")
        #expect(bed.uniqueID == "light_1")
        #expect(bed.areaID == "bedroom")
        #expect(bed.platform == "demo")
        #expect(entities.first { $0.entityID == "light.disabled_strip" }?.isDisabled == true)

        let areas = HAAreaRegistryEntry.list(from: try Fixture.result("area_registry_list"))
        #expect(areas.map(\.name) == ["Bedroom", "Garage", "Hallway", "Kitchen", "Living Room"])
        #expect(areas.first?.floorID == "first_floor")

        let devices = HADeviceRegistryEntry.list(from: try Fixture.result("device_registry_list"))
        #expect(devices.count == 6)
        #expect(devices[1].manufacturer == "Signify Netherlands B.V.")
    }

    @Test func entityRegistryEntryShapeFromCoreTests() throws {
        // Verbatim shape of `config/entity_registry/list` from HA core's
        // tests/components/config/test_entity_registry.py (timestamps filled in).
        let json = #"""
            [{"area_id":null,"categories":{},"config_entry_id":null,"config_subentry_id":null,"created_at":1729960000.0,
              "device_id":null,"disabled_by":null,"entity_category":null,"entity_id":"test_domain.name","hidden_by":null,
              "icon":null,"id":"5a1b2c","labels":[],"modified_at":1729960000.0,"name":"Hello World","next_name_part":null,
              "options":{},"original_name":null,"platform":"test_platform","translation_key":null,"unique_id":"1234"}]
            """#
        let entries = HAEntityRegistryEntry.list(from: try HAJSONValue.parse(json))
        #expect(entries == [HAEntityRegistryEntry(entityID: "test_domain.name", id: "5a1b2c", uniqueID: "1234", platform: "test_platform", name: "Hello World")])
    }

    @Test func roomsComeFromEntityThenDeviceArea() throws {
        let registry = try Fixture.registry()
        #expect(registry.areaName(for: "light.bed_light") == "Bedroom")  // entity area
        #expect(registry.areaName(for: "light.ceiling_lights") == "Living Room")  // device area
        #expect(registry.areaName(for: "light.entrance_color_white_lights") == "Hallway")
        #expect(registry.areaName(for: "light.office_rgbw_lights") == nil)  // neither
        #expect(registry.areaName(for: "light.porch") == nil)  // not registered
        #expect(registry.key(for: "light.bed_light") == "0f3a6b5e4c3d2b1a09f8e7d6c5b4a301")
        #expect(registry.key(for: "light.porch") == "light.porch")
        #expect(registry.isHidden("light.all_lights"))
        #expect(registry.isHidden("light.disabled_strip"))
        #expect(!registry.isHidden("light.porch"))
    }

    @Test func getStatesMapsLightsOnly() throws {
        let lights = try Fixture.lights()
        #expect(Set(lights.keys) == [
            "light.bed_light", "light.ceiling_lights", "light.kitchen_lights", "light.office_rgbw_lights",
            "light.living_room_rgbww_lights", "light.entrance_color_white_lights", "light.porch", "light.garage",
        ])
        let bed = try #require(lights["light.bed_light"])
        #expect(bed.id.rawValue == "homeassistant:inst1/0f3a6b5e4c3d2b1a09f8e7d6c5b4a301")
        #expect(bed.brand == .homeAssistant)
        #expect(bed.providerRef == "inst1/light.bed_light")
        #expect(bed.name == "Bed Light")
        #expect(bed.roomHint == "Bedroom")
        #expect(lights["light.porch"]?.id.rawValue == "homeassistant:inst1/light.porch")
        #expect(lights["light.ceiling_lights"]?.manufacturer == "Signify Netherlands B.V.")
        #expect(lights["light.ceiling_lights"]?.model == "Hue color lamp")
    }

    @Test func capabilitiesFromAttributes() throws {
        let lights = try Fixture.lights()
        let bed = try #require(lights["light.bed_light"]).capabilities
        #expect(bed.supportedColorModes == [.colorTemp, .hs])
        #expect(bed.minKelvin == 2000)
        #expect(bed.maxKelvin == 6535)
        #expect(bed.supportsEffects)
        #expect(bed.effects == [EffectDescriptor(id: "rainbow", name: "rainbow")])  // "off" is not an effect
        #expect(!bed.supportsTransition)

        let office = try #require(lights["light.office_rgbw_lights"]).capabilities
        #expect(office.supportedColorModes == [.rgbw])
        #expect(office.minKelvin == nil)
        #expect(try #require(lights["light.living_room_rgbww_lights"]).capabilities.supportedColorModes == [.rgbww])
        #expect(try #require(lights["light.entrance_color_white_lights"]).capabilities.supportedColorModes == [.hs, .white])
        #expect(try #require(lights["light.porch"]).capabilities.supportedColorModes == [.onOff])
        let garage = try #require(lights["light.garage"]).capabilities
        #expect(garage.supportedColorModes == [.brightness])
        #expect(garage.supportsTransition)  // supported_features 32
    }

    @Test func statesFromAttributes() throws {
        let lights = try Fixture.lights()
        let bed = try #require(lights["light.bed_light"]).state
        #expect(!bed.isOn)
        #expect(bed.reachable)
        #expect(bed.brightness == nil)
        #expect(bed.colorMode == nil)
        #expect(bed.updatedAt == HADate.parse("2026-10-26T17:59:58.123456+00:00"))

        let ceiling = try #require(lights["light.ceiling_lights"]).state
        #expect(ceiling.isOn)
        #expect(ceiling.brightness == 180.0 / 255)
        #expect(ceiling.colorMode == .colorTemp)
        #expect(ceiling.kelvin == 2631)
        #expect(ceiling.colorAttribute == .kelvin(2631))

        let kitchen = try #require(lights["light.kitchen_lights"]).state
        #expect(kitchen.colorMode == .hs)
        #expect(kitchen.colorAttribute == .hs(HS(h: 345, s: 0.75)))
        #expect(kitchen.rgb == RGB(r: 255, g: 64, b: 112))

        #expect(try #require(lights["light.office_rgbw_lights"]).state.colorAttribute == .rgbw(RGBW(r: 255, g: 0, b: 0, w: 255)))
        #expect(try #require(lights["light.living_room_rgbww_lights"]).state.colorAttribute
            == .rgbww(RGBWW(r: 255, g: 0, b: 0, cw: 255, ww: 0)))
        let porch = try #require(lights["light.porch"]).state
        #expect(porch.isOn)
        #expect(porch.colorMode == .onOff)
        #expect(porch.brightness == nil)
        let garage = try #require(lights["light.garage"]).state
        #expect(!garage.reachable)
        #expect(!garage.isOn)
    }

    @Test func effectIsReportedWhileRunning() {
        let state = HAEntityState(entityID: "light.strip", state: "on", attributes: [
            "supported_color_modes": ["hs"], "color_mode": "brightness", "brightness": 255,
            "effect_list": ["off", "Strobe Mega", "Rainbow"], "effect": "Strobe Mega", "supported_features": 36,
        ])
        let caps = HALightMapping.capabilities(for: state)
        #expect(caps.effects.map(\.id) == ["Strobe Mega", "Rainbow"])
        #expect(caps.effects.first?.isFast == true)
        #expect(caps.effects.last?.isFast == false)
        #expect(caps.supportsTransition)
        let light = HALightMapping.lightState(for: state)
        #expect(light.effect == "Strobe Mega")
        #expect(light.colorMode == .brightness)
        var off = state
        off.attributes["effect"] = "off"
        #expect(HALightMapping.lightState(for: off).effect == nil)
    }

    @Test func sceneMapping() throws {
        let registry = try Fixture.registry()
        let state = try #require(try Fixture.states()["scene.movie_night"])
        let scene = try #require(HALightMapping.scene(for: state, instanceID: "inst1", registry: registry))
        #expect(scene.id == "homeassistant:inst1/scene.movie_night")
        #expect(scene.name == "Movie night")
        #expect(scene.kind == .vendor)
        #expect(scene.brand == .homeAssistant)
        #expect(scene.roomHint == "Living Room")
        #expect(scene.lightIDs.map(\.rawValue) == [
            "homeassistant:inst1/0f3a6b5e4c3d2b1a09f8e7d6c5b4a302", "homeassistant:inst1/0f3a6b5e4c3d2b1a09f8e7d6c5b4a303",
        ])
        #expect(try HACommand.callService(HALightMapping.sceneCall(entityID: "scene.movie_night", transition: .seconds(2)))
            .message(id: 9).jsonString()
            == #"{"domain":"scene","id":9,"service":"turn_on","service_data":{"transition":2},"target":{"entity_id":"scene.movie_night"},"type":"call_service"}"#)
    }

    @Test func identifiersRoundTrip() throws {
        let id = try #require(HAIdentifiers.lightID(instanceID: "abc", key: "light.porch"))
        #expect(id.rawValue == "homeassistant:abc/light.porch")
        #expect(HAIdentifiers.split(id.stableId)! == ("abc", "light.porch"))
        #expect(HAIdentifiers.split("homeassistant:abc/scene.x")! == ("abc", "scene.x"))
        #expect(HAIdentifiers.split("noslash") == nil)
    }

    @Test func timestamps() {
        let micro = HADate.parse("2016-11-26T01:37:24.265390+00:00")
        let milli = HADate.parse("2016-11-26T01:37:24.265+00:00")
        #expect(micro != nil)
        #expect(abs(micro!.timeIntervalSince(milli!)) < 0.001)
        #expect(HADate.parse("2016-11-26T01:37:24+00:00") != nil)
        #expect(HADate.parse("yesterday") == nil)
    }
}

// MARK: - Commands

@Suite("LightCommand -> call_service")
struct HAServiceCallTests {
    static func caps(_ entity: String) throws -> LightCapabilities {
        try #require(try Fixture.lights()[entity]).capabilities
    }

    static func wire(_ command: LightCommand, _ entity: String) throws -> String? {
        try HALightMapping.serviceCall(for: command, entityID: entity, capabilities: try caps(entity))
            .map { try HACommand.callService($0).message(id: 1).jsonString() }
    }

    @Test func turnOffWithTransition() throws {
        // The ceiling light does not support transitions: the transition is dropped.
        #expect(try Self.wire(LightCommand(on: false, transition: .milliseconds(1500)), "light.ceiling_lights")
            == #"{"domain":"light","id":1,"service":"turn_off","target":{"entity_id":"light.ceiling_lights"},"type":"call_service"}"#)
        #expect(try Self.wire(LightCommand(on: false, transition: .milliseconds(1500)), "light.garage")
            == #"{"domain":"light","id":1,"service":"turn_off","service_data":{"transition":1.5},"target":{"entity_id":"light.garage"},"type":"call_service"}"#)
        #expect(try Self.wire(LightCommand(brightness: 0), "light.garage")?.contains(#""service":"turn_off""#) == true)
    }

    @Test func brightnessAndTemperatureInOneCall() throws {
        #expect(try Self.wire(LightCommand(on: true, brightness: 0.5, color: .kelvin(3000)), "light.ceiling_lights")
            == #"{"domain":"light","id":1,"service":"turn_on","service_data":{"brightness_pct":50,"color_temp_kelvin":3000},"target":{"entity_id":"light.ceiling_lights"},"type":"call_service"}"#)
        #expect(try Self.wire(.turnOn, "light.porch")
            == #"{"domain":"light","id":1,"service":"turn_on","target":{"entity_id":"light.porch"},"type":"call_service"}"#)
    }

    func data(_ command: LightCommand, _ entity: String) throws -> [String: HAJSONValue] {
        try #require(HALightMapping.serviceCall(for: command, entityID: entity, capabilities: try Self.caps(entity))).serviceData
    }

    @Test func colourAttributes() throws {
        #expect(try data(LightCommand(color: .hs(HS(h: 345, s: 0.75))), "light.kitchen_lights") == ["hs_color": [345.0, 75.0]])
        #expect(try data(LightCommand(color: .rgbw(RGBW(r: 1, g: 2, b: 3, w: 4))), "light.office_rgbw_lights")
            == ["rgbw_color": [1, 2, 3, 4]])
        #expect(try data(LightCommand(color: .rgbww(RGBWW(r: 1, g: 2, b: 3, cw: 4, ww: 5))), "light.living_room_rgbww_lights")
            == ["rgbww_color": [1, 2, 3, 4, 5]])
        let rgbLight = LightCapabilities(supportedColorModes: [.rgb])
        #expect(HALightMapping.serviceCall(for: LightCommand(color: .rgb(RGB(r: 10, g: 20, b: 30))), entityID: "light.x", capabilities: rgbLight)?
            .serviceData == ["rgb_color": [10, 20, 30]])
        let xyLight = LightCapabilities(supportedColorModes: [.xy])
        #expect(HALightMapping.serviceCall(for: LightCommand(color: .xy(XY(x: 0.31271, y: 0.32902))), entityID: "light.x", capabilities: xyLight)?
            .serviceData == ["xy_color": [0.3127, 0.329]])
    }

    @Test func colourIsConvertedToASupportedMode() throws {
        // Out-of-range temperature is clamped to the light's range.
        #expect(try data(LightCommand(color: .kelvin(9000)), "light.ceiling_lights") == ["color_temp_kelvin": 6535])
        // RGB on an RGBW light becomes rgbw_color (exactly one colour attribute).
        let rgbw = try data(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), "light.office_rgbw_lights")
        #expect(Array(rgbw.keys) == ["rgbw_color"])
        // Kelvin on an hs+white light becomes hs_color.
        #expect(Array(try data(LightCommand(color: .kelvin(2700)), "light.entrance_color_white_lights").keys) == ["hs_color"])
        // Brightness and colour on an on/off light are dropped: nothing left to send...
        #expect(HALightMapping.serviceCall(
            for: LightCommand(brightness: 0.3, color: .kelvin(2700)), entityID: "light.porch", capabilities: try Self.caps("light.porch")) == nil)
        // ...unless the command also turns it on.
        let porch = try #require(HALightMapping.serviceCall(
            for: LightCommand(on: true, brightness: 0.3, color: .kelvin(2700)), entityID: "light.porch", capabilities: try Self.caps("light.porch")))
        #expect(porch.service == "turn_on")
        #expect(porch.serviceData.isEmpty)
    }

    @Test func brightnessPercentRounding() throws {
        #expect(try data(LightCommand(brightness: 0.333333), "light.garage") == ["brightness_pct": 33.33])
        #expect(try data(LightCommand(brightness: 0.001), "light.garage") == ["brightness_pct": 1.0])  // never 0 (= off)
        #expect(try data(LightCommand(brightness: 1), "light.garage") == ["brightness_pct": 100.0])
        #expect(try data(LightCommand(brightness: 0.4, transition: .seconds(2)), "light.garage")
            == ["brightness_pct": 40.0, "transition": 2.0])
    }

    @Test func effects() throws {
        #expect(try data(LightCommand(effect: "rainbow"), "light.bed_light") == ["effect": "rainbow"])
        // Unknown effects and effects on lights without effect support are dropped -> empty command.
        #expect(HALightMapping.serviceCall(for: LightCommand(effect: "disco"), entityID: "light.bed_light", capabilities: try Self.caps("light.bed_light")) == nil)
        #expect(HALightMapping.serviceCall(for: LightCommand(effect: "rainbow"), entityID: "light.porch", capabilities: try Self.caps("light.porch")) == nil)
        #expect(HALightMapping.serviceCall(for: LightCommand(), entityID: "light.porch", capabilities: .onOff) == nil)
    }
}

// MARK: - URLs

@Suite("URLs")
struct HAURLTests {
    @Test(arguments: [
        ("homeassistant.local", "http://homeassistant.local:8123"),
        ("192.168.1.10", "http://192.168.1.10:8123"),
        ("192.168.1.10:8124", "http://192.168.1.10:8124"),
        ("http://ha.lan:8123/", "http://ha.lan:8123"),
        ("http://ha.lan/lovelace/0?edit=1", "http://ha.lan"),
        ("https://abcdef0123456789.ui.nabu.casa/", "https://abcdef0123456789.ui.nabu.casa"),
        ("HTTPS://ha.example.com:443", "https://ha.example.com"),
        ("wss://ha.example.com/api/websocket", "https://ha.example.com"),
        ("  http://[fd00::10]:8123  ", "http://[fd00::10]:8123"),
    ])
    func normalize(input: String, expected: String) {
        #expect(HAURL.normalize(input)?.absoluteString == expected)
    }

    @Test func rejectsGarbage() {
        #expect(HAURL.normalize("") == nil)
        #expect(HAURL.normalize("ftp://ha.lan") == nil)
        #expect(HAURL.normalize("my home") == nil)
    }

    @Test func websocketURL() throws {
        #expect(HAURL.websocketURL(for: try #require(HAURL.normalize("homeassistant.local")))?.absoluteString
            == "ws://homeassistant.local:8123/api/websocket")
        #expect(HAURL.websocketURL(for: try #require(HAURL.normalize("https://x.ui.nabu.casa")))?.absoluteString
            == "wss://x.ui.nabu.casa/api/websocket")
        #expect(HAURL.isNabuCasa(try #require(HAURL.normalize("https://x.ui.nabu.casa"))))
        #expect(!HAURL.isNabuCasa(try #require(HAURL.normalize("homeassistant.local"))))
    }
}
