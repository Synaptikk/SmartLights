import Foundation
import LightCore
import Testing
@testable import ShellyCodec

@Suite("Shelly channels, state and commands")
struct ShellyMappingTests {
    @Test func rpcChannelsFromConfigAndStatus() throws {
        let config = try ShellyJSON.parse(#"{"sys":{},"cct:0":{"id":0,"name":"Bulb","ct_range":[2700,6500]},"light:1":{"id":1,"name":""},"light:0":{"id":0,"name":"Strip"},"switch:0":{"id":0}}"#)
        let channels = ShellyMapping.rpcChannels(config: config, status: nil)
        #expect(channels.map(\.key) == ["cct:0", "light:0", "light:1"])
        #expect(channels[0].name == "Bulb")
        #expect(channels[0].minKelvin == 2700 && channels[0].maxKelvin == 6500)
        #expect(channels[2].name == nil)
        #expect(channels[0].stableID(mac: "aabbccddeeff", primary: true) == "aabbccddeeff")
        #expect(channels[2].stableID(mac: "aabbccddeeff", primary: false) == "aabbccddeeff-light1")
    }

    @Test func gen1Channels() throws {
        #expect(ShellyMapping.gen1Channels(type: "SHBDUO-1", settings: nil).map(\.kind) == [.gen1CCT])
        #expect(ShellyMapping.gen1Channels(type: "SHVIN-1", settings: nil).map(\.kind) == [.gen1Dimmer])
        let bulb = ShellyMapping.gen1Channels(type: "SHBLB-1", settings: try ShellyJSON.parse(#"{"mode":"color","lights":[{"name":"Lamp"}]}"#))
        #expect(bulb.first?.kind == .gen1Bulb && bulb.first?.name == "Lamp" && bulb.first?.minKelvin == 3000)
        let white = ShellyMapping.gen1Channels(type: "SHRGBW2", settings: try ShellyJSON.parse(#"{"mode":"white","lights":[{},{},{},{}]}"#))
        #expect(white.map(\.key) == ["white/0", "white/1", "white/2", "white/3"])
        #expect(ShellyMapping.gen1Channels(type: "SHRGBW2", settings: try ShellyJSON.parse(#"{"mode":"color"}"#)).map(\.key) == ["color/0"])
    }

    @Test func rpcStateMapping() throws {
        let rgbw = ShellyChannel(kind: .rgbw, index: 0)
        let s = try #require(ShellyChannelStatus.parseRPC(try ShellyJSON.parse(#"{"id":0,"source":"init","output":true,"brightness":40,"rgb":[255,0,128],"white":10}"#)))
        let st = ShellyMapping.state(s, channel: rgbw)
        #expect(st.isOn && st.colorMode == .rgbw)
        #expect(st.brightness == 0.4)
        #expect(st.rgbw == RGBW(r: 255, g: 0, b: 128, w: 10))
        #expect(ShellyMapping.capabilities(for: rgbw).supportedColorModes == [.rgbw])

        let cct = ShellyChannel(kind: .cct, index: 0, minKelvin: 2700, maxKelvin: 6500)
        let cs = try #require(ShellyChannelStatus.parseRPC(try ShellyJSON.parse(#"{"id":0,"output":false,"brightness":100,"ct":3000}"#)))
        let cst = ShellyMapping.state(cs, channel: cct)
        #expect(!cst.isOn && cst.colorMode == .colorTemp && cst.kelvin == 3000)
        // Partial notification patch.
        #expect(cs.merging(rpcPatch: ["output": true]).isOn)
    }

    @Test func gen1StateMapping() throws {
        let bulb = ShellyChannel(kind: .gen1Bulb, index: 0, minKelvin: 3000, maxKelvin: 6500)
        let color = try #require(ShellyChannelStatus.parseGen1(try ShellyJSON.parse(#"{"ison":true,"mode":"color","red":0,"green":0,"blue":255,"white":0,"gain":80,"temp":4750,"brightness":30,"effect":0}"#)))
        let cs = ShellyMapping.state(color, channel: bulb)
        #expect(cs.colorMode == .rgbw && cs.brightness == 0.8 && cs.rgb == RGB(r: 0, g: 0, b: 255))
        var white = color
        white.mode = "white"
        let ws = ShellyMapping.state(white, channel: bulb)
        #expect(ws.colorMode == .colorTemp && ws.kelvin == 4750 && ws.brightness == 0.3)
        // /status lights[] -> per channel.
        let status = try ShellyJSON.parse(#"{"lights":[{"ison":true,"brightness":10},{"ison":false,"brightness":20}]}"#)
        let channels = ShellyMapping.gen1Channels(type: "SHRGBW2", settings: try ShellyJSON.parse(#"{"mode":"white","lights":[{},{}]}"#))
        let map = ShellyMapping.statuses(for: channels, gen1Status: status)
        #expect(map["white/1"]?.isOn == false && map["white/1"]?.brightness == 20)
    }

    @Test func rpcSetCombinesBrightnessAndColour() throws {
        let rgb = ShellyChannel(kind: .rgb, index: 0)
        let plan = try #require(ShellyMapping.plan(LightCommand(brightness: 0.5, color: .hs(HS(h: 0, s: 1)), transition: .milliseconds(200)),
                                                   channel: rgb, current: ShellyChannelStatus(isOn: false)))
        guard case .rpc(let method, let params) = plan.action else { Issue.record("expected rpc"); return }
        #expect(method == "RGB.Set")
        #expect(params.jsonString == #"{"brightness":50,"id":0,"on":true,"rgb":[255,0,0],"transition_duration":0.5}"#)
        #expect(plan.predicted.isOn && plan.predicted.brightness == 50)

        let off = try #require(ShellyMapping.plan(LightCommand(brightness: 0), channel: ShellyChannel(kind: .light, index: 2), current: nil))
        #expect(off.action == .rpc(method: "Light.Set", params: ["id": 2, "on": false]))

        let cct = ShellyChannel(kind: .cct, index: 0, minKelvin: 2700, maxKelvin: 6500)
        let warm = try #require(ShellyMapping.plan(LightCommand(color: .kelvin(2000)), channel: cct, current: ShellyChannelStatus(isOn: true)))
        #expect(warm.action == .rpc(method: "CCT.Set", params: ["id": 0, "on": true, "ct": 2700]))   // clamped

        let rgbcct = ShellyChannel(kind: .rgbcct, index: 0, minKelvin: 2700, maxKelvin: 6500)
        let mode = try #require(ShellyMapping.plan(LightCommand(color: .kelvin(4000)), channel: rgbcct, current: nil))
        guard case .rpc(_, let p) = mode.action else { Issue.record("expected rpc"); return }
        #expect(p["mode"]?.string == "cct" && p["ct"]?.int == 4000)

        #expect(ShellyMapping.plan(LightCommand(), channel: rgb, current: nil) == nil)
    }

    @Test func gen1Queries() throws {
        let duo = ShellyChannel(kind: .gen1CCT, index: 0, minKelvin: 2700, maxKelvin: 6500)
        let p = try #require(ShellyMapping.plan(LightCommand(brightness: 0.3, color: .kelvin(3000), transition: .seconds(9)), channel: duo, current: nil))
        #expect(p.action == .gen1(ShellyGen1Request(path: "/light/0", query: [("turn", "on"), ("brightness", "30"), ("temp", "3000"), ("transition", "5000")])))

        let bulb = ShellyChannel(kind: .gen1Bulb, index: 0, minKelvin: 3000, maxKelvin: 6500)
        let white = ShellyChannelStatus(isOn: true, brightness: 50, kelvin: 4000, mode: "white")
        let toColor = try #require(ShellyMapping.plan(LightCommand(brightness: 1, color: .rgb(RGB(r: 255, g: 0, b: 0))), channel: bulb, current: white))
        guard case .gen1(let r) = toColor.action else { Issue.record("expected gen1"); return }
        #expect(r.uri == "/light/0?turn=on&mode=color&gain=100&red=255&green=0&blue=0&white=0")
        #expect(toColor.predicted.mode == "color" && toColor.predicted.gain == 100)
        // Brightness-only change in white mode keeps white mode and uses `brightness`.
        let dim = try #require(ShellyMapping.plan(LightCommand(brightness: 0.1), channel: bulb, current: white))
        #expect(dim.action == .gen1(ShellyGen1Request(path: "/light/0", query: [("turn", "on"), ("brightness", "10")])))

        let rgbw2 = ShellyChannel(kind: .gen1White, index: 3)
        #expect(try #require(ShellyMapping.plan(.turnOff, channel: rgbw2, current: nil)).action
                == .gen1(ShellyGen1Request(path: "/white/3", query: [("turn", "off")])))
    }
}
