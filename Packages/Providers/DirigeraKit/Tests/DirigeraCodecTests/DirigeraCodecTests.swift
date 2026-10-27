import Foundation
import LightCore
import Testing
@testable import DirigeraCodec

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func devices() throws -> [String: DirigeraDevice] {
    let list = try JSONDecoder().decode([DirigeraDevice].self, from: try fixture("devices"))
    return Dictionary(uniqueKeysWithValues: list.map { ($0.customNameKey, $0) })
}

extension DirigeraDevice {
    var customNameKey: String { attributes.customName ?? id }
}

func object(_ data: Data?) throws -> Any {
    try JSONSerialization.jsonObject(with: try #require(data))
}

@Suite("Dirigera PKCE and requests")
struct DirigeraRequestTests {
    @Test func challengeMatchesPythonReference() throws {
        let vector = try #require(try JSONSerialization.jsonObject(with: try fixture("pkce_vector")) as? [String: String])
        let verifier = try #require(vector["verifier"])
        #expect(DirigeraPKCE.challenge(for: verifier) == vector["challenge"])
    }

    @Test func verifierUsesTheUnreservedAlphabet() {
        let verifier = DirigeraPKCE.makeVerifier()
        #expect(verifier.count == 128)
        #expect(verifier.allSatisfy { DirigeraPKCE.alphabet.contains($0) })
        #expect(DirigeraPKCE.makeVerifier() != verifier)
        #expect(!DirigeraPKCE.challenge(for: verifier).contains("="))
    }

    @Test func authorizeAndTokenRequests() throws {
        let authorize = DirigeraAPI.authorize(challenge: "abc")
        #expect(authorize.method == "GET")
        #expect(authorize.path == "/v1/oauth/authorize")
        #expect(!authorize.authenticated)
        #expect(authorize.query.map { "\($0.name)=\($0.value ?? "")" }
            == ["audience=homesmart.local", "response_type=code", "code_challenge=abc", "code_challenge_method=S256"])
        let token = DirigeraAPI.token(code: "c0de+/=", verifier: "v-._~", name: "Sina's iPhone")
        #expect(token.method == "POST")
        #expect(token.contentType == "application/x-www-form-urlencoded")
        #expect(token.bodyText == "code=c0de%2B%2F%3D&name=Sina%27s%20iPhone&grant_type=authorization_code&code_verifier=v-._~")
        let decoded = try JSONDecoder().decode(DirigeraTokenResponse.self, from: Data(#"{"access_token":"eyJ.x.y"}"#.utf8))
        #expect(decoded.accessToken == "eyJ.x.y")
    }

    @Test func patchBodyIsAnArrayWithOneAttributesObject() throws {
        let patch = DirigeraAPI.patch(deviceID: "abc_1", attributes: ["isOn": true, "lightLevel": 40])
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/v1/devices/abc_1")
        #expect(patch.bodyText == #"[{"attributes":{"isOn":true,"lightLevel":40}}]"#)
        #expect(DirigeraAPI.triggerScene("s 1").path == "/v1/scenes/s%201/trigger")
    }

    @Test func endpointsAndIdentifiers() {
        #expect(DirigeraEndpoint.parse("192.168.1.20") == ("192.168.1.20", nil))
        #expect(DirigeraEndpoint.parse("https://gw2-abc123.local:8443/v1") == ("gw2-abc123.local", 8443))
        #expect(DirigeraEndpoint.url(scheme: "https", host: "10.0.0.5", port: nil, path: "/v1/devices")?.absoluteString
            == "https://10.0.0.5:8443/v1/devices")
        #expect(DirigeraEndpoint.url(scheme: "wss", host: "10.0.0.5", port: 9000, path: "/v1")?.absoluteString == "wss://10.0.0.5:9000/v1")
        #expect(DirigeraEndpoint.isHubHostname("gw2-58f3a1b2c3d4"))
        #expect(!DirigeraEndpoint.isHubHostname("hue-bridge"))
        let id = DirigeraIdentifiers.lightID(hubID: "hub_1", deviceID: "dev_1")
        #expect(id?.rawValue == "dirigera:hub_1/dev_1")
        #expect(DirigeraIdentifiers.split("hub_1/dev_1")! == ("hub_1", "dev_1"))
        #expect(DirigeraIdentifiers.split("dirigera:hub_1/scene-9")! == ("hub_1", "scene-9"))
        #expect(DirigeraIdentifiers.split("nohub") == nil)
        #expect(DirigeraError.unauthorized.lightCoreError == .authenticationRequired(.dirigera))
        #expect(DirigeraError.buttonNotPressed.lightCoreError == .timeout)
    }
}

@Suite("Dirigera models")
struct DirigeraModelTests {
    @Test func decodesDevicesFromLegginFixture() throws {
        let all = try JSONDecoder().decode([DirigeraDevice].self, from: try fixture("devices"))
        #expect(all.count == 7)
        #expect(all.filter(\.isLight).map { $0.attributes.customName } == ["Bed", "Sofa", "Ceiling", "Hall"])
        let bed = try #require(try devices()["Bed"])
        #expect(bed.id == "23taswdg-sdf-4eeb-99c2-23asdf2gw")
        #expect(bed.attributes.isOn == false)
        #expect(bed.attributes.lightLevel == 43)
        #expect(bed.attributes.colorTemperatureMin == 4000)
        #expect(bed.room?.name == "Bedroom")
        #expect(bed.canReceive == ["customName", "isOn", "lightLevel", "colorTemperature"])
        #expect(try devices()["Sofa"]?.attributes.colorHue == 120.5)
    }

    @Test func hubStatusAndScenes() throws {
        let status = try JSONDecoder().decode(DirigeraHubStatus.self, from: try fixture("hub_status"))
        #expect(status.id == "d7a1c2b3-0000-4000-8000-000000000001_1")
        #expect(status.attributes?.firmwareVersion == "2.866.3")
        let scenes = try JSONDecoder().decode([DirigeraScene].self, from: try fixture("scenes"))
        #expect(scenes.map(\.info.name) == ["Movie night"])
    }

    @Test func stateChangedEventMergesIntoDevice() throws {
        let text = String(decoding: try fixture("event_state_changed"), as: UTF8.self)
        let event = try #require(DirigeraEvent.parse(text))
        #expect(event.type == "deviceStateChanged")
        let update = try #require(event.deviceUpdate)
        #expect(update.id == "5f2b6a10-1111-4c3d-9e8f-0a1b2c3d4e5f_1")
        var sofa = try #require(try devices()["Sofa"])
        sofa.apply(update)
        #expect(sofa.attributes.isOn == false)
        #expect(sofa.attributes.lightLevel == 35)
        #expect(sofa.attributes.colorHue == 120.5) // untouched
        #expect(DirigeraEvent.parse("not json") == nil)
    }

    @Test func jsonNumbersRoundTripAsIntegersWhenIntegral() {
        let value: DirigeraJSON = ["a": 40, "b": 0.5, "c": [true, "x", .null]]
        #expect(String(decoding: value.encoded(), as: UTF8.self) == #"{"a":40,"b":0.5,"c":[true,"x",null]}"#)
    }
}

@Suite("Dirigera mapping")
struct DirigeraMappingTests {
    @Test func capabilitiesFromCanReceive() throws {
        let d = try devices()
        let bed = DirigeraMapping.capabilities(try #require(d["Bed"]))
        #expect(bed.supportedColorModes == [.colorTemp])
        #expect(bed.minKelvin == 2202 && bed.maxKelvin == 4000)
        #expect(DirigeraMapping.capabilities(try #require(d["Sofa"])).supportedColorModes == [.hs, .colorTemp])
        let ceiling = DirigeraMapping.capabilities(try #require(d["Ceiling"]))
        #expect(ceiling.minKelvin == 2203 && ceiling.maxKelvin == 6536) // mired bounds 454/153
        #expect(DirigeraMapping.capabilities(try #require(d["Hall"])).supportedColorModes == [.brightness])
        #expect(DirigeraMapping.capabilities(try #require(d["Plug"])).supportedColorModes == [.onOff])
    }

    @Test func stateFollowsColorMode() throws {
        let d = try devices()
        let bed = DirigeraMapping.state(try #require(d["Bed"]))
        #expect(!bed.isOn)
        #expect(bed.brightness == 0.43)
        #expect(bed.colorMode == .colorTemp && bed.kelvin == 2222)
        let sofa = DirigeraMapping.state(try #require(d["Sofa"]))
        #expect(sofa.colorMode == .hs)
        #expect(sofa.hs == HS(h: 120.5, s: 0.75))
        #expect(DirigeraMapping.state(try #require(d["Ceiling"])).reachable == false)
        let sofaDevice = try #require(d["Sofa"])
        let light = try #require(DirigeraMapping.light(sofaDevice, hubID: "hub"))
        #expect(light.id.rawValue == "dirigera:hub/5f2b6a10-1111-4c3d-9e8f-0a1b2c3d4e5f_1")
        #expect(light.roomHint == "Living room")
        #expect(light.manufacturer == "IKEA of Sweden")
    }

    @Test func offIsASingleIsOnFalse() throws {
        let sofa = try #require(try devices()["Sofa"])
        #expect(DirigeraMapping.plan(.turnOff, device: sofa, split: false) == [["isOn": false]])
        #expect(DirigeraMapping.plan(LightCommand(brightness: 0), device: sofa, split: false) == [["isOn": false]])
    }

    @Test func combinedAndSplitPlans() throws {
        let bed = try #require(try devices()["Bed"]) // off
        let command = LightCommand(brightness: 0.5, color: .kelvin(2700))
        #expect(DirigeraMapping.plan(command, device: bed, split: false) == [["isOn": true, "lightLevel": 50, "colorTemperature": 2700]])
        #expect(DirigeraMapping.plan(command, device: bed, split: true) == [["isOn": true], ["lightLevel": 50], ["colorTemperature": 2700]])
        // Out-of-range Kelvin is clamped to the bulb's range; tiny brightness becomes level 1.
        #expect(DirigeraMapping.plan(LightCommand(brightness: 0.001, color: .kelvin(9000)), device: bed, split: true)
            == [["isOn": true], ["lightLevel": 1], ["colorTemperature": 4000]])
    }

    @Test func colorOnOnLightDoesNotResendIsOn() throws {
        let sofa = try #require(try devices()["Sofa"]) // on
        #expect(DirigeraMapping.plan(LightCommand(color: .hs(HS(h: 30.04, s: 0.5))), device: sofa, split: false)
            == [["colorHue": 30, "colorSaturation": 0.5]])
        #expect(DirigeraMapping.plan(LightCommand(color: .rgb(RGB(r: 255, g: 0, b: 0))), device: sofa, split: false)
            == [["colorHue": 0, "colorSaturation": 1]])
    }

    @Test func unsupportedAttributesAreNeverSent() throws {
        let hall = try #require(try devices()["Hall"])
        #expect(DirigeraMapping.plan(LightCommand(on: true, color: .hs(HS(h: 10, s: 1))), device: hall, split: false) == [["isOn": true]])
        let plug = try #require(try devices()["Plug"])
        #expect(DirigeraMapping.plan(LightCommand(brightness: 0.3), device: plug, split: false) == [])
    }
}
