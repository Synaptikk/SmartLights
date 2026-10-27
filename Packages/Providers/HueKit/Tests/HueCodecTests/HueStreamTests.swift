import Foundation
import Testing

@testable import HueCodec

/// Expected bytes were produced independently (Python `struct.pack('>HHH', ...)`) from the layout in
/// research_hue.md §2.2, not from this encoder.
@Suite("HueStream v2 frames")
struct HueStreamTests {
    static let configID = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"

    static func hex(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            out.append(UInt8(text[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test func rgbFrameIsByteExact() throws {
        let frame = try HueStreamFrame(
            configurationID: Self.configID, sequence: 7, colorSpace: .rgb,
            channels: [
                HueStreamChannel(channelID: 0, raw: (0xFFFF, 0x0000, 0x8000)),
                .rgb(1, red: 1, green: 0.5, blue: 0),
            ])
        let expected = Self.hex(
            "48756553747265616d" + "0200" + "07" + "0000" + "00" + "00"
                + "31613864393963632d393637622d343466322d393230322d343366393736633066613662"
                + "00ffff00008000" + "01ffff80000000")
        #expect(frame.encoded() == expected)
        #expect(frame.encoded().count == 52 + 2 * 7)
        #expect(frame.data == Data(expected))
    }

    @Test func xyFrameIsByteExact() throws {
        let frame = try HueStreamFrame(
            configurationID: Self.configID, sequence: 0xFF, colorSpace: .xyBrightness,
            channels: [.xy(5, x: 0.3127, y: 0.3290, brightness: 1)])
        let expected = Self.hex(
            "48756553747265616d0200ff00000100"
                + "31613864393963632d393637622d343466322d393230322d343366393736633066613662"
                + "05500d5439ffff")
        #expect(frame.encoded() == expected)
    }

    @Test func headerFieldsAtDocumentedOffsets() throws {
        let bytes = try HueStreamFrame(configurationID: Self.configID, sequence: 42, colorSpace: .xyBrightness, channels: [])
            .encoded()
        #expect(bytes.count == HueStreamFrame.headerLength)
        #expect(String(decoding: bytes[0..<9], as: UTF8.self) == "HueStream")
        #expect(bytes[9] == 0x02 && bytes[10] == 0x00)
        #expect(bytes[11] == 42)
        #expect(bytes[12] == 0 && bytes[13] == 0)
        #expect(bytes[14] == 0x01)
        #expect(bytes[15] == 0)
        #expect(String(decoding: bytes[16..<52], as: UTF8.self) == Self.configID)
    }

    @Test func configurationIDIsLowerCasedAndValidated() throws {
        let frame = try HueStreamFrame(configurationID: Self.configID.uppercased(), colorSpace: .rgb, channels: [])
        #expect(frame.configurationID == Self.configID)
        #expect(String(decoding: frame.encoded()[16..<52], as: UTF8.self) == Self.configID)

        for bad in ["", "1a8d99cc", Self.configID + "0", "1a8d99cc-967b-44f2-9202_43f976c0fa6b", "za8d99cc-967b-44f2-9202-43f976c0fa6b"] {
            #expect(throws: HueStreamError.invalidConfigurationID(bad)) {
                try HueStreamFrame(configurationID: bad, colorSpace: .rgb, channels: [])
            }
        }
    }

    @Test func atMostTwentyChannelsPerFrame() throws {
        let twenty = (0..<20).map { HueStreamChannel.rgb(UInt8($0), red: 1, green: 1, blue: 1) }
        let frame = try HueStreamFrame(configurationID: Self.configID, colorSpace: .rgb, channels: twenty)
        #expect(frame.encoded().count == 52 + 20 * 7)
        #expect(throws: HueStreamError.tooManyChannels(21)) {
            try HueStreamFrame(
                configurationID: Self.configID, colorSpace: .rgb,
                channels: twenty + [.rgb(20, red: 0, green: 0, blue: 0)])
        }
    }

    @Test func framesSplitsIntoChunksOfTwenty() throws {
        let channels = (0..<45).map { HueStreamChannel.rgb(UInt8($0), red: 0, green: 0, blue: 1) }
        let frames = try HueStreamFrame.frames(configurationID: Self.configID, sequence: 3, colorSpace: .rgb, channels: channels)
        #expect(frames.map(\.channels.count) == [20, 20, 5])
        #expect(frames.allSatisfy { $0.sequence == 3 })
        #expect(frames.flatMap(\.channels) == channels)
        #expect(try HueStreamFrame.frames(configurationID: Self.configID, sequence: 0, colorSpace: .rgb, channels: []).count == 1)
    }

    @Test func quantizeClampsAndRounds() {
        #expect(HueStreamChannel.quantize(0) == 0)
        #expect(HueStreamChannel.quantize(1) == 0xFFFF)
        #expect(HueStreamChannel.quantize(0.5) == 0x8000)
        #expect(HueStreamChannel.quantize(-0.2) == 0)
        #expect(HueStreamChannel.quantize(7) == 0xFFFF)
        #expect(HueStreamChannel.quantize(.nan) == 0)
        #expect(HueStreamChannel.quantize(.infinity) == 0xFFFF)
    }

    @Test func decodeRoundTrips() throws {
        let frame = try HueStreamFrame(
            configurationID: Self.configID, sequence: 9, colorSpace: .xyBrightness,
            channels: [.xy(0, x: 0.7, y: 0.3, brightness: 0.25), .xy(3, x: 0.17, y: 0.7, brightness: 1)])
        #expect(try HueStreamFrame(decoding: frame.encoded()) == frame)
        #expect(try HueStreamFrame(decoding: frame.data) == frame)
    }

    @Test func decodeRejectsMalformedDatagrams() throws {
        let good = try HueStreamFrame(
            configurationID: Self.configID, colorSpace: .rgb, channels: [.rgb(0, red: 1, green: 0, blue: 0)]
        ).encoded()
        var badMagic = good
        badMagic[0] = UInt8(ascii: "h")
        var badVersion = good
        badVersion[9] = 0x01
        var badSpace = good
        badSpace[14] = 0x02
        for bytes in [Array(good.prefix(51)), badMagic, badVersion, badSpace, good + [0x00]] {
            #expect(throws: HueStreamError.self) { try HueStreamFrame(decoding: bytes) }
        }
    }

    @Test func clientKeyHexDecodesToPSK() {
        #expect(
            HueClientKey.psk(fromHex: "00112233445566778899AABBCCDDEEFF")
                == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(HueClientKey.psk(fromHex: "0a0B") == [0x0A, 0x0B])
        #expect(HueClientKey.psk(fromHex: "") == nil)
        #expect(HueClientKey.psk(fromHex: "abc") == nil)
        #expect(HueClientKey.psk(fromHex: "zz") == nil)
    }

    @Test func constants() {
        #expect(HueStreamFrame.port == 2100)
        #expect(HueStreamFrame.maxChannels == 20)
        #expect(HueStreamColorSpace.rgb.rawValue == 0x00)
        #expect(HueStreamColorSpace.xyBrightness.rawValue == 0x01)
    }
}

@Suite("Entertainment configuration")
struct HueEntertainmentConfigurationTests {
    static let json = #"""
    {"errors":[],"data":[{
      "id":"1a8d99cc-967b-44f2-9202-43f976c0fa6b","type":"entertainment_configuration",
      "metadata":{"name":"TV area"},"configuration_type":"screen","status":"active",
      "active_streamer":{"rid":"b1a2c3d4-0000-4000-8000-000000000001","rtype":"auth_v1"},
      "stream_proxy":{"mode":"auto","node":{"rid":"5b85f1dc-addf-2a26-720e-b21128d406b4","rtype":"entertainment"}},
      "channels":[
        {"channel_id":0,"position":{"x":-0.6,"y":0.8,"z":0},
         "members":[{"service":{"rid":"e0000000-0000-4000-8000-000000000001","rtype":"entertainment"},"index":0}]},
        {"channel_id":1,"position":{"x":0.6,"y":0.8,"z":0},
         "members":[{"service":{"rid":"e0000000-0000-4000-8000-000000000002","rtype":"entertainment"},"index":0}]}
      ],
      "light_services":[{"rid":"10000000-0000-4000-8000-000000000001","rtype":"light"}]
    }]}
    """#

    @Test func decodesChannelsAndStatus() throws {
        let envelope = try JSONDecoder().decode(
            ResourceEnvelope<[HueEntertainmentConfiguration]>.self, from: Data(Self.json.utf8))
        let config = try #require(envelope.data?.first)
        #expect(config.metadata?.name == "TV area")
        #expect(config.isActive)
        #expect(config.activeStreamer?.rtype == "auth_v1")
        #expect(config.streamProxy?.mode == "auto")
        #expect(config.channelIDs == [0, 1])
        #expect(config.channels?.first?.position == HueEntertainmentConfiguration.Position(x: -0.6, y: 0.8, z: 0))
        #expect(config.channels?.first?.members?.first?.service?.rtype == "entertainment")
    }

    @Test func aiohueFixtureStillDecodes() throws {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Fixture.data("v2_resources"))
        let store = HueResourceStore(resources: raw)
        let config = try #require(store.entertainmentConfigurations["410475f5-3bac-a03b-c9a2-5f33b8f386b6"])
        #expect(config.status == "inactive")
        #expect(!config.isActive)
        #expect(config.channelIDs.isEmpty)
        #expect(config.streamProxy?.node?.rtype == "entertainment")
    }

    @Test func actionBodies() throws {
        #expect(String(decoding: try HueEntertainmentAction.start.jsonData(), as: UTF8.self) == #"{"action":"start"}"#)
        #expect(String(decoding: try HueEntertainmentAction.stop.jsonData(), as: UTF8.self) == #"{"action":"stop"}"#)
    }
}
