import Foundation
import Testing
@testable import YeelightCodec

/// Search response from the Yeelight Inter-Operation Spec (§3.2), CRLF line endings.
let specSearchResponse = [
    "HTTP/1.1 200 OK",
    "Cache-Control: max-age=3600",
    "Date: ",
    "Ext: ",
    "Location: yeelight://192.168.1.239:55443",
    "Server: POSIX UPnP/1.0 YGLC/1",
    "id: 0x000000000015243f",
    "model: color",
    "fw_ver: 18",
    "support: get_prop set_default set_power toggle set_bright start_cf stop_cf set_scene cron_add cron_get cron_del set_ct_abx set_rgb",
    "power: on",
    "bright: 100",
    "color_mode: 2",
    "ct: 4000",
    "rgb: 16711680",
    "hue: 100",
    "sat: 35",
    "name: my_bulb",
    "",
].joined(separator: "\r\n")

@Suite("SSDP")
struct SSDPTests {
    @Test func searchRequestBytesMatchSpec() {
        let text = String(decoding: YeelightSSDP.searchRequest(), as: UTF8.self)
        #expect(text == "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n")
        let unicast = YeelightSSDP.searchRequestText(host: "192.168.1.50")
        #expect(unicast.contains("HOST: 192.168.1.50:1982\r\n"))
    }

    @Test func parsesSpecSearchResponse() throws {
        let adv = try #require(YeelightSSDP.parse(Data(specSearchResponse.utf8)))
        #expect(adv.id == "0x000000000015243f")
        #expect(adv.host == "192.168.1.239")
        #expect(adv.port == 55443)
        #expect(adv.model == "color")
        #expect(adv.firmwareVersion == "18")
        #expect(adv.name == "my_bulb")
        #expect(adv.isNotify == false)
        #expect(adv.support.contains("set_rgb"))
        #expect(adv.support.contains("set_scene"))
        #expect(adv.support.count == 13)
        #expect(adv.properties["power"] == .string("on"))
        #expect(adv.properties["bright"]?.intValue == 100)
        #expect(adv.properties["color_mode"]?.intValue == 2)
        #expect(adv.properties["ct"]?.intValue == 4000)
        #expect(adv.properties["rgb"]?.intValue == 16_711_680)
        #expect(adv.properties["hue"]?.intValue == 100)
        #expect(adv.properties["sat"]?.intValue == 35)
    }

    @Test func parsesNotifyAdvertisementWithLFAndMixedCase() throws {
        let text = "NOTIFY * HTTP/1.1\nHost: 239.255.255.250:1982\nCache-Control: max-age=3600\nLocation: yeelight://10.0.0.7:55443\nNTS: ssdp:alive\nServer: POSIX, UPnP/1.0 YGLC/1\nid: 0x00000000037073D2\nmodel: ceiling4\nfw_ver: 45\nsupport: get_prop set_power set_ct_abx\npower: off\nbright: 50\ncolor_mode: 2\nct: 2700\nrgb: 0\nhue: 0\nsat: 0\nname: \n"
        let adv = try #require(YeelightSSDP.parse(text))
        #expect(adv.isNotify)
        #expect(adv.id == "0x00000000037073d2")
        #expect(adv.host == "10.0.0.7")
        #expect(adv.model == "ceiling4")
        #expect(adv.name == nil)
        #expect(adv.support == ["get_prop", "set_power", "set_ct_abx"])
    }

    @Test func ignoresOwnSearchEchoAndForeignSSDP() {
        #expect(YeelightSSDP.parse(YeelightSSDP.searchRequest()) == nil)
        let upnp = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:5000/rootDesc.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:abc\r\n"
        #expect(YeelightSSDP.parse(upnp) == nil)
        #expect(YeelightSSDP.parse("HTTP/1.1 200 OK\r\nLocation: yeelight://1.2.3.4:55443\r\n") == nil) // no id
    }

    @Test func locationParsing() {
        #expect(YeelightSSDP.parseLocation("yeelight://192.168.1.239:55443")! == ("192.168.1.239", 55443))
        #expect(YeelightSSDP.parseLocation("YEELIGHT://10.0.0.2")! == ("10.0.0.2", 55443))
        #expect(YeelightSSDP.parseLocation("yeelight://10.0.0.2:1234/")! == ("10.0.0.2", 1234))
        #expect(YeelightSSDP.parseLocation("http://10.0.0.2:55443") == nil)
        #expect(YeelightSSDP.parseLocation("yeelight://10.0.0.2:notaport") == nil)
    }

    @Test func idNormalisation() {
        #expect(YeelightSSDP.normalizeID("0x00000000037073D2") == "0x00000000037073d2")
        #expect(YeelightSSDP.normalizeID("37073d2") == "0x37073d2")
    }

    @Test func bonjourNames() throws {
        let name = try #require(YeelightBonjourName("yeelink-light-color1_miio1385535"))
        #expect(name.model == "color1")
        #expect(name.miioDeviceID == 1_385_535)
        #expect(name.derivedID == "0x000000000015243f")
        let lamp = try #require(YeelightBonjourName("Yeelink-light-ceiling4"))
        #expect(lamp.model == "ceiling4")
        #expect(lamp.derivedID == nil)
        #expect(YeelightBonjourName("rockrobo-vacuum-v1_miio123") == nil)
    }
}

@Suite("JSON-RPC")
struct RPCTests {
    private func line(_ call: YeelightCall, id: Int) -> String {
        String(decoding: call.request(id: id).encoded, as: UTF8.self)
    }

    @Test func requestBytesMatchSpec() {
        #expect(line(YeelightCommands.setPower(true, timing: YeelightTiming(effect: .smooth, duration: 500)), id: 1)
            == "{\"id\":1,\"method\":\"set_power\",\"params\":[\"on\",\"smooth\",500]}\r\n")
        #expect(line(YeelightCommands.getProp(["power", "not_exist", "bright"]), id: 1)
            == "{\"id\":1,\"method\":\"get_prop\",\"params\":[\"power\",\"not_exist\",\"bright\"]}\r\n")
        #expect(line(YeelightCommands.setCTAbx(3500, timing: YeelightTiming(effect: .smooth, duration: 500)), id: 1)
            == "{\"id\":1,\"method\":\"set_ct_abx\",\"params\":[3500,\"smooth\",500]}\r\n")
        #expect(line(YeelightCommands.setRGB(255, timing: YeelightTiming(effect: .smooth, duration: 500)), id: 1)
            == "{\"id\":1,\"method\":\"set_rgb\",\"params\":[255,\"smooth\",500]}\r\n")
        #expect(line(YeelightCommands.setHSV(hue: 255, saturation: 45, timing: YeelightTiming(effect: .smooth, duration: 500)), id: 1)
            == "{\"id\":1,\"method\":\"set_hsv\",\"params\":[255,45,\"smooth\",500]}\r\n")
        #expect(line(YeelightCommands.setBright(50, timing: YeelightTiming(effect: .smooth, duration: 500)), id: 1)
            == "{\"id\":1,\"method\":\"set_bright\",\"params\":[50,\"smooth\",500]}\r\n")
        #expect(line(YeelightCommands.toggle(), id: 1) == "{\"id\":1,\"method\":\"toggle\",\"params\":[]}\r\n")
        #expect(line(YeelightCommands.setScene(.color(rgb: 65280, brightness: 70)), id: 1)
            == "{\"id\":1,\"method\":\"set_scene\",\"params\":[\"color\",65280,70]}\r\n")
        #expect(line(YeelightCommands.setScene(.hsv(hue: 300, saturation: 70, brightness: 100)), id: 1)
            == "{\"id\":1,\"method\":\"set_scene\",\"params\":[\"hsv\",300,70,100]}\r\n")
        #expect(line(YeelightCommands.setScene(.colorTemperature(kelvin: 5400, brightness: 100)), id: 1)
            == "{\"id\":1,\"method\":\"set_scene\",\"params\":[\"ct\",5400,100]}\r\n")
        #expect(line(YeelightCommands.setScene(.autoDelayOff(brightness: 50, minutes: 5)), id: 1)
            == "{\"id\":1,\"method\":\"set_scene\",\"params\":[\"auto_delay_off\",50,5]}\r\n")
        #expect(line(YeelightCommands.setName("my_bulb"), id: 1) == "{\"id\":1,\"method\":\"set_name\",\"params\":[\"my_bulb\"]}\r\n")
        #expect(line(YeelightCommands.stopColorFlow(), id: 9) == "{\"id\":9,\"method\":\"stop_cf\",\"params\":[]}\r\n")
    }

    @Test func colorFlowExpression() {
        let steps = [
            YeelightFlowStep(duration: 1000, mode: .color, value: 2_000_000, brightness: 10),
            YeelightFlowStep(duration: 1000, mode: .colorTemperature, value: 4000, brightness: 50),
            YeelightFlowStep(duration: 10, mode: .sleep, value: 0, brightness: 0),
        ]
        #expect(line(YeelightCommands.startColorFlow(count: 4, action: .stay, steps: steps), id: 1)
            == "{\"id\":1,\"method\":\"start_cf\",\"params\":[4,1,\"1000,1,2000000,10,1000,2,4000,50,50,7,0,0\"]}\r\n")
    }

    @Test func clampingAndTiming() {
        #expect(YeelightCommands.setBright(0).params.first == .int(1))
        #expect(YeelightCommands.setBright(250).params.first == .int(100))
        #expect(YeelightCommands.setCTAbx(1000).params.first == .int(1700))
        #expect(YeelightCommands.setCTAbx(9000).params.first == .int(6500))
        #expect(YeelightCommands.setHSV(hue: 360, saturation: 120).params.prefix(2) == [.int(0), .int(100)])
        #expect(YeelightCommands.setRGB(-5).params.first == .int(0))
        #expect(YeelightTiming(effect: .smooth, duration: 5).duration == 30)
        #expect(YeelightTiming.forTransition(milliseconds: 0) == .sudden)
        #expect(YeelightTiming.forTransition(milliseconds: nil) == .default)
        #expect(YeelightTiming.forTransition(milliseconds: 1200) == YeelightTiming(effect: .smooth, duration: 1200))
        #expect(YeelightCommands.setPower(true, mode: .colorTemperature).params == ["on", "smooth", 300, 1])
        #expect(YeelightCommands.setPower(false, mode: .rgb).params == ["off", "smooth", 300])
    }

    @Test func nameEscapingAndTruncation() {
        let call = YeelightCommands.setName("Living \"room\"\\lamp")
        #expect(String(decoding: call.request(id: 2).encoded, as: UTF8.self)
            == "{\"id\":2,\"method\":\"set_name\",\"params\":[\"Living \\\"room\\\"\\\\lamp\"]}\r\n")
        let long = YeelightCommands.setName(String(repeating: "ä", count: 40)) // 80 bytes
        #expect(long.params.first?.stringValue?.utf8.count == 64)
    }

    @Test func parsesResults() {
        #expect(YeelightMessage.parse("{\"id\":1, \"result\":[\"ok\"]}\r\n") == .result(id: 1, values: ["ok"]))
        #expect(YeelightMessage.parse("{\"id\":1, \"result\":[\"on\", \"\", \"100\"]}")
            == .result(id: 1, values: ["on", "", "100"]))
        #expect(YeelightMessage.parse("{\"id\":3,\"result\":\"ok\"}") == .result(id: 3, values: ["ok"]))
    }

    @Test func parsesErrors() {
        #expect(YeelightMessage.parse("{\"id\":2, \"error\":{\"code\":-1, \"message\":\"unsupported method\"}}")
            == .error(id: 2, YeelightRPCError(code: -1, message: "unsupported method")))
        let quota = YeelightMessage.parse("{\"id\":5,\"error\":{\"code\":-1,\"message\":\"client quota exceeded\"}}")
        guard case .error(_, let e)? = quota else { Issue.record("expected error"); return }
        #expect(e.isQuotaExceeded)
    }

    @Test func parsesNotificationsWithStringAndNumberValues() {
        let msg = YeelightMessage.parse("{\"method\":\"props\",\"params\":{\"power\":\"on\", \"bright\":\"10\"}}\r\n")
        #expect(msg == .notification(method: "props", params: ["power": "on", "bright": "10"]))
        guard case .notification(_, let params)? = YeelightMessage.parse("{\"method\":\"props\",\"params\":{\"ct\":6500,\"flowing\":0}}") else {
            Issue.record("expected notification"); return
        }
        #expect(params["ct"]?.intValue == 6500)
        #expect(params["flowing"]?.intValue == 0)
        #expect(YeelightMessage.parse("{\"method\":\"props\",\"params\":{\"power\":\"on\"}}")?.id == nil)
    }

    @Test func rejectsGarbage() {
        #expect(YeelightMessage.parse("") == nil)
        #expect(YeelightMessage.parse("not json") == nil)
        #expect(YeelightMessage.parse("[1,2,3]") == nil)
        #expect(YeelightMessage.parse("{\"foo\":1}") == nil)
    }

    @Test func framerSplitsAcrossChunks() {
        var framer = YeelightLineFramer()
        #expect(framer.append(Data("{\"id\":1,\"res".utf8)).isEmpty)
        let lines = framer.append(Data("ult\":[\"ok\"]}\r\n{\"method\":\"props\",\"params\":{}}\n\r\n{\"id\":".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"id\":1,\"result\":[\"ok\"]}", "{\"method\":\"props\",\"params\":{}}"])
        #expect(framer.pendingByteCount == 6)
        let rest = framer.append(Data("2,\"result\":[\"ok\"]}\r\n".utf8))
        #expect(rest.count == 1)
        #expect(YeelightMessage.parse(rest[0]) == .result(id: 2, values: ["ok"]))
    }

    @Test func framerDropsRunawayLines() {
        var framer = YeelightLineFramer(maximumLineLength: 16)
        #expect(framer.append(Data(repeating: 0x41, count: 40)).isEmpty)
        #expect(framer.pendingByteCount == 0)
    }

    @Test func valueConversions() {
        #expect(YeelightValue.string(" 42 ").intValue == 42)
        #expect(YeelightValue.string("4.6").intValue == 5)
        #expect(YeelightValue.string("").intValue == nil)
        #expect(YeelightValue.double(3.0).jsonText == "3")
        #expect(YeelightValue.object(["b": 1, "a": .array([.null, true])]).jsonText == "{\"a\":[null,true],\"b\":1}")
        #expect(YeelightValue.string("a\u{1}").jsonText == "\"a\\u0001\"")
    }
}
