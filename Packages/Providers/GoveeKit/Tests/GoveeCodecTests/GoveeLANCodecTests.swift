import Foundation
import LightCore
import Testing
@testable import GoveeCodec

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func json(_ data: Data) throws -> GoveeJSONValue {
        try JSONDecoder().decode(GoveeJSONValue.self, from: data)
    }
}

@Suite("Govee LAN codec")
struct GoveeLANCodecTests {

    @Test func scanRequestMatchesWireFormat() throws {
        let data = GoveeLANCommand.scan.encoded()
        #expect(String(decoding: data, as: UTF8.self) == #"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#)
        #expect(GoveeLANCommand.scan.port == 4001)
        #expect(GoveeLAN.multicastAddress == "239.255.255.250")
        #expect(GoveeLAN.listenPort == 4002)
    }

    @Test func commandEncodings() throws {
        #expect(String(decoding: GoveeLANCommand.turn(true).encoded(), as: UTF8.self) == #"{"msg":{"cmd":"turn","data":{"value":1}}}"#)
        #expect(String(decoding: GoveeLANCommand.turn(false).encoded(), as: UTF8.self) == #"{"msg":{"cmd":"turn","data":{"value":0}}}"#)
        #expect(String(decoding: GoveeLANCommand.brightness(55).encoded(), as: UTF8.self) == #"{"msg":{"cmd":"brightness","data":{"value":55}}}"#)
        #expect(String(decoding: GoveeLANCommand.brightness(0).encoded(), as: UTF8.self) == #"{"msg":{"cmd":"brightness","data":{"value":1}}}"#)
        #expect(String(decoding: GoveeLANCommand.brightness(300).encoded(), as: UTF8.self) == #"{"msg":{"cmd":"brightness","data":{"value":100}}}"#)
        #expect(String(decoding: GoveeLANCommand.devStatus.encoded(), as: UTF8.self) == #"{"msg":{"cmd":"devStatus","data":{}}}"#)
        #expect(String(decoding: GoveeLANCommand.color(RGB(r: 255, g: 12, b: 7)).encoded(), as: UTF8.self)
            == #"{"msg":{"cmd":"colorwc","data":{"color":{"b":7,"g":12,"r":255},"colorTemInKelvin":0}}}"#)
        #expect(String(decoding: GoveeLANCommand.colorTemperature(3000).encoded(), as: UTF8.self)
            == #"{"msg":{"cmd":"colorwc","data":{"color":{"b":0,"g":0,"r":0},"colorTemInKelvin":3000}}}"#)
        #expect(GoveeLANCommand.turn(true).port == 4003)
    }

    @Test func commandsRoundTrip() {
        let all: [GoveeLANCommand] = [.scan, .devStatus, .turn(true), .turn(false), .brightness(42),
                                      .color(RGB(r: 1, g: 2, b: 3)), .colorTemperature(6500)]
        for command in all {
            #expect(GoveeLANCommand.decode(command.encoded()) == command)
        }
    }

    @Test func decodesScanResponseFixture() throws {
        let message = try #require(GoveeLANResponse.decode(try Fixture.data("lan_scan_response")))
        guard case .scan(let scan) = message else { Issue.record("expected scan"); return }
        #expect(scan.ip == "192.168.1.23")
        #expect(scan.device == "1F:80:C5:32:32:36:72:4E")
        #expect(scan.deviceID == "1F:80:C5:32:32:36:72:4E")
        #expect(scan.sku == "H618A")
        #expect(scan.bleVersionHard == "3.01.01")
        #expect(scan.bleVersionSoft == "1.03.01")
        #expect(scan.wifiVersionHard == "1.00.10")
        #expect(scan.wifiVersionSoft == "1.02.03")
        #expect(scan.metadata["wifiVersionSoft"] == "1.02.03")
        // Round trip through the fake-device encoder.
        #expect(GoveeLANResponse.decode(message.encoded()) == message)
    }

    @Test func decodesDevStatusFixtures() throws {
        let rgb = try #require(GoveeLANResponse.decode(try Fixture.data("lan_devstatus_rgb")))
        #expect(rgb == .devStatus(GoveeDevStatus(onOff: 1, brightness: 100, color: GoveeRGB(r: 255, g: 0, b: 0), colorTemInKelvin: 0)))
        let white = try #require(GoveeLANResponse.decode(try Fixture.data("lan_devstatus_white")))
        guard case .devStatus(let status) = white else { Issue.record("expected devStatus"); return }
        #expect(!status.isOn)
        #expect(status.brightness == 42)
        #expect(status.colorTemInKelvin == 7200)
    }

    @Test func lenientDevStatus() throws {
        let data = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":"1","brightness":55.0,"color":{"r":"10","g":20,"b":30}}}}"#.utf8)
        let message = try #require(GoveeLANResponse.decode(data))
        #expect(message == .devStatus(GoveeDevStatus(onOff: 1, brightness: 55, color: GoveeRGB(r: 10, g: 20, b: 30), colorTemInKelvin: 0)))
    }

    @Test func ignoresNoiseAndOwnRequests() {
        #expect(GoveeLANResponse.decode(Data("M-SEARCH * HTTP/1.1\r\n".utf8)) == nil)
        #expect(GoveeLANResponse.decode(Data(#"{"foo":1}"#.utf8)) == nil)
        #expect(GoveeLANResponse.decode(GoveeLANCommand.scan.encoded()) == nil)
        #expect(GoveeLANResponse.decode(GoveeLANCommand.devStatus.encoded()) == nil)
        #expect(GoveeLANResponse.decode(Data(#"{"msg":{"cmd":"turn","data":{"value":1}}}"#.utf8)) == nil)
        #expect(GoveeLANResponse.decode(Data([0xFF, 0x00, 0x7B])) == nil)
    }

    @Test func deviceIDNormalisation() {
        #expect(GoveeDeviceID.normalize(" 1f-80-c5-32-32-36-72-4e\n") == "1F:80:C5:32:32:36:72:4E")
        #expect(GoveeDeviceID.lightID("1f:80:c5:32:32:36:72:4e")?.rawValue == "govee:1F:80:C5:32:32:36:72:4E")
        #expect(GoveeDeviceID.lightID("") == nil)
    }

    @Test func skuAllowList() {
        #expect(GoveeSKUCatalog.allSKUs.count >= 250)
        #expect(GoveeSKUCatalog.isLANCapable("H6076"))
        #expect(GoveeSKUCatalog.isLANCapable("h618a"))
        #expect(!GoveeSKUCatalog.isLANCapable("H6001")) // BLE-only bulb
        #expect(!GoveeSKUCatalog.isLANCapable("H7143")) // humidifier
        let h6076 = GoveeSKUCatalog.lanModel(for: "H6076")
        #expect(h6076?.kelvinRange == 2700...6500)
        let tvBars = GoveeSKUCatalog.lanModel(for: "H6043")
        #expect(tvBars?.rgb == true && tvBars?.colorTemperature == false)
        let white = GoveeSKUCatalog.lanModel(for: "H6093")
        #expect(white?.rgb == false && white?.colorTemperature == true)
        #expect(GoveeSKUCatalog.modelForLANDevice(sku: "H9999") == .basic("H9999"))
    }
}
