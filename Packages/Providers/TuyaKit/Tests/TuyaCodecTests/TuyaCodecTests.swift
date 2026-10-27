import Foundation
import LightCore
import Testing

@testable import TuyaCodec

/// Vectors in `Fixtures/tuya_fixtures.json` come from tinytuya 1.20.0 (`Fixtures/gen_fixtures.py`).
enum Fixture {
    static let json: TuyaJSON = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tuya_fixtures.json")
        return try! TuyaJSON.parse(try! Data(contentsOf: url))
    }()

    static subscript(_ path: String...) -> TuyaJSON {
        var node: TuyaJSON = json
        for key in path { node = node[key] ?? .null }
        return node
    }

    static func bytes(_ node: TuyaJSON) -> [UInt8] { TuyaCrypto.bytes(hex: node.stringValue ?? "") ?? [] }

    static let devId = "bf8d3e7a1c2b4f5e6a7b"
    static let localKey = "a1B2c3D4e5F6g7H8"
    static let t = 1_761_475_200
    static var localNonce: [UInt8] { bytes(json["localNonce"]!) }
    static var remoteNonce: [UInt8] { bytes(json["remoteNonce"]!) }
    /// tinytuya `SET_DPS` in the generator.
    static let setDPS: [String: TuyaJSON] = ["20": true, "21": "white", "22": 500, "23": 250]

    static func iv(_ n: UInt8) -> [UInt8] { [UInt8](repeating: n, count: 12) }

    static func codec(_ version: TuyaVersion, role: TuyaSessionCodec.Role = .client,
                      deviceType: TuyaDeviceType = .default) throws -> TuyaSessionCodec {
        try TuyaSessionCodec(version: version, deviceId: devId, localKey: localKey, role: role, deviceType: deviceType)
    }
}

@Suite("Crypto primitives")
struct CryptoTests {
    @Test func udpKeyIsMD5OfTheTuyaConstant() {
        #expect(TuyaCrypto.hex(TuyaCrypto.udpKey) == Fixture["udpKey"].stringValue)
        #expect(TuyaCrypto.hex(TuyaCrypto.udpKey) == "6c1ec8e2bb9bb59ab50b0daf649b410a")
    }

    @Test func crc32MatchesBinascii() throws {
        for item in try #require(Fixture["crc32"].arrayValue) {
            let data = Fixture.bytes(item["hex"]!)
            #expect(Int(TuyaCrypto.crc32(data)) == item["crc"]?.intValue)
        }
    }

    @Test func aesECBFips197() throws {
        // FIPS-197 C.1
        let key = try #require(TuyaCrypto.bytes(hex: "000102030405060708090a0b0c0d0e0f"))
        let plain = try #require(TuyaCrypto.bytes(hex: "00112233445566778899aabbccddeeff"))
        let cipher = try TuyaCrypto.ecbEncryptBlocks(plain, key: key)
        #expect(TuyaCrypto.hex(cipher) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(try TuyaCrypto.ecbDecryptBlocks(cipher, key: key) == plain)
        #expect(try TuyaCrypto.ecbDecrypt(try TuyaCrypto.ecbEncrypt(Array("hello".utf8), key: key), key: key) == Array("hello".utf8))
        #expect(TuyaCrypto.pkcs7Pad([UInt8](repeating: 1, count: 16)).count == 32)
        #expect(throws: TuyaCrypto.Failure.badPadding) { try TuyaCrypto.pkcs7Unpad([0, 0, 0, 0x20]) }
    }

    @Test func gcmRoundTripAndTamperDetection() throws {
        let key = [UInt8](repeating: 7, count: 16)
        let sealed = try TuyaCrypto.gcmSeal(Array("tuya".utf8), key: key, iv: Fixture.iv(1), aad: [1, 2, 3])
        #expect(try TuyaCrypto.gcmOpen(sealed.ciphertext, tag: sealed.tag, key: key, iv: Fixture.iv(1), aad: [1, 2, 3]) == Array("tuya".utf8))
        #expect(throws: TuyaCrypto.Failure.authenticationFailed) {
            try TuyaCrypto.gcmOpen(sealed.ciphertext, tag: sealed.tag, key: key, iv: Fixture.iv(1), aad: [1, 2, 4])
        }
    }

    @Test func localKeyValidation() {
        #expect(TuyaCrypto.keyBytes(Fixture.localKey)?.count == 16)
        #expect(TuyaCrypto.keyBytes("short") == nil)
        #expect(TuyaCrypto.keyBytes("0123456789abcdef0") == nil)
        #expect(throws: TuyaSessionCodec.Failure.badLocalKey) { try TuyaSessionCodec(version: .v33, deviceId: "x", localKey: "nope") }
    }
}

@Suite("JSON formatting")
struct JSONTests {
    @Test func compactLikeTinytuya() throws {
        let json: TuyaJSON = ["devId": "a b", "t": "1", "dps": ["20": true, "22": 10, "x": nil, "f": .double(1)]]
        #expect(json.compactString() == #"{"devId":"ab","t":"1","dps":{"20":true,"22":10,"x":null,"f":1.0}}"#)
        #expect(TuyaJSON.string("\u{e9}\"\n").compactString() == "\"\\u00e9\\\"\\n\"")
    }

    @Test func parsesNestedAndKeepsOrder() throws {
        let json = try TuyaJSON.parse(#"{"b": [1, 2.5, -3e2, "xé"], "a": {"c": false, "d": null}}"#)
        #expect(json.members?.map(\.0) == ["b", "a"])
        #expect(json["b"]?.arrayValue == [1, .double(2.5), .double(-300), "xé"])
        #expect(json["a"]?["c"]?.boolValue == false)
        #expect(json["a"]?["d"]?.isNull == true)
        #expect(throws: (any Error).self) { try TuyaJSON.parse("{\"a\":1} x") }
        #expect(throws: (any Error).self) { try TuyaJSON.parse("{\"a\":") }
    }
}

@Suite("Request frames match tinytuya byte for byte")
struct RequestTests {
    /// Client frames in the order the generator encoded them (seqno 1, 2, 3...).
    func check(_ version: TuyaVersion, _ name: String, _ codec: inout TuyaSessionCodec, _ request: TuyaRequest,
               iv: [UInt8]? = nil) throws {
        let node = Fixture[name, request.fixtureKey]
        let (command, json) = TuyaPayload.build(request, version: version, deviceType: codec.deviceType,
                                                deviceId: Fixture.devId, time: Fixture.t, dpsToRequest: codec.dpsToRequest)
        #expect(Int(command.rawValue) == node["cmd"]?.intValue, "\(name) \(request) command")
        #expect(json.compactString() == node["json"]?.stringValue, "\(name) \(request) json")
        let frame = try codec.encode(request, time: Fixture.t, iv: iv)
        #expect(TuyaCrypto.hex(frame) == node["frame"]?.stringValue, "\(name) \(request) frame")
    }

    @Test func v31() throws {
        var c = try Fixture.codec(.v31)
        try check(.v31, "v31", &c, .control(Fixture.setDPS))
        try check(.v31, "v31", &c, .dpQuery)
        try check(.v31, "v31", &c, .heartbeat)
    }

    @Test func v33() throws {
        var c = try Fixture.codec(.v33)
        try check(.v33, "v33", &c, .control(Fixture.setDPS))
        try check(.v33, "v33", &c, .dpQuery)
        try check(.v33, "v33", &c, .heartbeat)
        try check(.v33, "v33", &c, .updateDps([20, 21, 22]))
    }

    @Test func v33Device22Query() throws {
        var c = try Fixture.codec(.v33, deviceType: .device22)
        c.dpsToRequest = ["20", "1"]
        let node = Fixture["v33", "device22Query"]
        let frame = try c.encode(.dpQuery, time: Fixture.t)
        #expect(node["cmd"]?.intValue == 13)
        #expect(node["json"]?.stringValue == #"{"devId":"bf8d3e7a1c2b4f5e6a7b","uid":"bf8d3e7a1c2b4f5e6a7b","t":"1761475200","dps":{"1":null,"20":null}}"#)
        #expect(TuyaCrypto.hex(frame) == node["frame"]?.stringValue)
    }

    @Test func versionParsing() {
        #expect(TuyaVersion(string: "3.3") == .v33)
        #expect(TuyaVersion(string: "v3.5") == .v35)
        #expect(TuyaVersion(string: "3.40") == .v34)
        #expect(TuyaVersion(string: "3.2") == nil)
        #expect(TuyaVersion.v33.versionHeader.count == 15)
        #expect(TuyaCommand.withoutVersionHeader.contains(TuyaCommand.dpQuery.rawValue))
        #expect(!TuyaCommand.withoutVersionHeader.contains(TuyaCommand.control.rawValue))
    }
}

extension TuyaRequest {
    var fixtureKey: String {
        switch self {
        case .control: "control"
        case .dpQuery: "dpQuery"
        case .heartbeat: "heartbeat"
        case .updateDps: "updateDps"
        }
    }
}

@Suite("Device frames decode like tinytuya")
struct ResponseTests {
    func expectDecoded(_ codec: TuyaSessionCodec, _ node: TuyaJSON, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let response = try codec.decode(Fixture.bytes(node["frame"]!))
        #expect(Int(response.seqno) == node["seqno"]?.intValue, sourceLocation: sourceLocation)
        #expect(Int(response.command) == node["cmd"]?.intValue, sourceLocation: sourceLocation)
        #expect(response.retcode.map(Int.init) == node["retcode"]?.intValue, sourceLocation: sourceLocation)
        if let expected = node["json"], !expected.isNull {
            // tinytuya copies data.dps to dps; compare the dps and the original body.
            #expect(response.dps == expected["dps"]?.dictionary, sourceLocation: sourceLocation)
            var body = expected
            if expected["data"] != nil, case .object(let m) = expected { body = .object(m.filter { $0.0 != "dps" }) }
            #expect(response.json == body, sourceLocation: sourceLocation)
        } else {
            #expect(response.json == nil, sourceLocation: sourceLocation)
        }
    }

    @Test func v31() throws {
        let c = try Fixture.codec(.v31)
        try expectDecoded(c, Fixture["v31", "dpQueryResponse"])
        try expectDecoded(c, Fixture["v31", "statusPush"])
    }

    @Test func v33() throws {
        let c = try Fixture.codec(.v33)
        try expectDecoded(c, Fixture["v33", "dpQueryResponse"])
        try expectDecoded(c, Fixture["v33", "statusPush"])
        try expectDecoded(c, Fixture["v33", "controlAck"])
        try expectDecoded(c, Fixture["v33", "heartbeatResponse"])
        let push = try c.decode(Fixture.bytes(Fixture["v33", "statusPush", "frame"]))
        #expect(push.dps?["24"]?.stringValue == "00f003e803e8")
    }

    @Test func v33DataUnvalidSwitchesToDevice22() throws {
        let c = try Fixture.codec(.v33)
        let r = try c.decode(Fixture.bytes(Fixture["v33", "dataUnvalid", "frame"]))
        #expect(r.isDataUnvalid)
        #expect(r.json == nil)
    }

    @Test func corruptTrailerIsRejected() throws {
        let c = try Fixture.codec(.v33)
        var frame = Fixture.bytes(Fixture["v33", "dpQueryResponse", "frame"])
        frame[frame.count - 6] ^= 0xFF
        #expect(throws: TuyaSessionCodec.Failure.badTrailer) { try c.decode(frame) }
    }

    @Test func wrongKeyFailsToDecrypt() throws {
        let c = try TuyaSessionCodec(version: .v33, deviceId: Fixture.devId, localKey: "0000000000000000")
        #expect(throws: (any Error).self) { try c.decode(Fixture.bytes(Fixture["v33", "dpQueryResponse", "frame"])) }
    }
}

@Suite("Session key negotiation (3.4 / 3.5)")
struct NegotiationTests {
    @Test(arguments: [TuyaVersion.v34, .v35])
    func clientFlowMatchesTinytuya(_ version: TuyaVersion) throws {
        let name = version == .v34 ? "v34" : "v35"
        let gcm = version == .v35
        var c = try Fixture.codec(version)
        #expect(throws: TuyaSessionCodec.Failure.notNegotiated) { _ = try c.encode(.dpQuery, time: Fixture.t) }
        let step1 = try c.negotiationStart(localNonce: Fixture.localNonce, iv: gcm ? Fixture.iv(1) : nil)
        #expect(TuyaCrypto.hex(step1) == Fixture[name, "step1", "frame"].stringValue)
        let step3 = try c.negotiationFinish(response: Fixture.bytes(Fixture[name, "step2", "frame"]), iv: gcm ? Fixture.iv(3) : nil)
        #expect(TuyaCrypto.hex(step3) == Fixture[name, "step3", "frame"].stringValue)
        #expect(c.sessionKey.map(TuyaCrypto.hex) == Fixture[name, "sessionKey"].stringValue)

        let control = try c.encode(.control(Fixture.setDPS), time: Fixture.t, iv: gcm ? Fixture.iv(4) : nil)
        #expect(TuyaCrypto.hex(control) == Fixture[name, "control", "frame"].stringValue)
        #expect(Fixture[name, "control", "cmd"].intValue == 13)
        let query = try c.encode(.dpQuery, time: Fixture.t, iv: gcm ? Fixture.iv(5) : nil)
        #expect(TuyaCrypto.hex(query) == Fixture[name, "dpQuery", "frame"].stringValue)
        let heartbeat = try c.encode(.heartbeat, time: Fixture.t, iv: gcm ? Fixture.iv(6) : nil)
        #expect(TuyaCrypto.hex(heartbeat) == Fixture[name, "heartbeat", "frame"].stringValue)

        let push = try c.decode(Fixture.bytes(Fixture[name, "statusPush", "frame"]))
        #expect(push.command == TuyaCommand.status.rawValue)
        #expect(push.dps == ["20": false, "22": 10])
        #expect(push.json?["protocol"]?.intValue == 4)
        let response = try c.decode(Fixture.bytes(Fixture[name, "dpQueryResponse", "frame"]))
        #expect(response.command == TuyaCommand.dpQueryNew.rawValue)
        #expect(response.dps?["21"]?.stringValue == "colour")
        let ack = try c.decode(Fixture.bytes(Fixture[name, "controlAck", "frame"]))
        #expect(ack.command == TuyaCommand.controlNew.rawValue && ack.json == nil && ack.retcode == 0)
    }

    @Test(arguments: [TuyaVersion.v34, .v35])
    func wrongLocalKeyIsDetected(_ version: TuyaVersion) throws {
        let name = version == .v34 ? "v34" : "v35"
        var c = try TuyaSessionCodec(version: version, deviceId: Fixture.devId, localKey: "ZZZZZZZZZZZZZZZZ")
        _ = try c.negotiationStart(localNonce: Fixture.localNonce)
        #expect(throws: TuyaSessionCodec.Failure.self) {
            _ = try c.negotiationFinish(response: Fixture.bytes(Fixture[name, "step2", "frame"]))
        }
        #expect(c.sessionKey == nil)
    }

    @Test(arguments: [TuyaVersion.v34, .v35])
    func deviceSideReproducesTheDeviceFrames(_ version: TuyaVersion) throws {
        let name = version == .v34 ? "v34" : "v35"
        let gcm = version == .v35
        var device = try Fixture.codec(version, role: .device)
        let step2 = try device.deviceNegotiationResponse(to: Fixture.bytes(Fixture[name, "step1", "frame"]),
                                                         remoteNonce: Fixture.remoteNonce, iv: gcm ? Fixture.iv(2) : nil,
                                                         seqno: gcm ? 100 : 1)
        #expect(TuyaCrypto.hex(step2) == Fixture[name, "step2", "frame"].stringValue)
        try device.deviceNegotiationFinish(Fixture.bytes(Fixture[name, "step3", "frame"]))
        #expect(device.sessionKey.map(TuyaCrypto.hex) == Fixture[name, "sessionKey"].stringValue)
        // The device reads the client's CONTROL_NEW.
        let control = try device.decode(Fixture.bytes(Fixture[name, "control", "frame"]))
        #expect(control.command == TuyaCommand.controlNew.rawValue)
        #expect(control.dps == Fixture.setDPS)
        #expect(control.retcode == nil)
    }

    @Test func randomNegotiationRoundTrip() throws {
        for version in [TuyaVersion.v34, .v35] {
            var client = try Fixture.codec(version)
            var device = try Fixture.codec(version, role: .device)
            let s1 = try client.negotiationStart()
            let s2 = try device.deviceNegotiationResponse(to: s1, remoteNonce: TuyaCrypto.randomNonce())
            let s3 = try client.negotiationFinish(response: s2)
            try device.deviceNegotiationFinish(s3)
            #expect(client.sessionKey != nil && client.sessionKey == device.sessionKey)
            let push = try device.encode(command: TuyaCommand.status.rawValue,
                                         payload: Array(#"{"protocol":4,"t":1,"data":{"dps":{"20":true}}}"#.utf8))
            #expect(try client.decode(push).dps == ["20": true])
        }
    }
}

@Suite("Stream decoder")
struct FrameDecoderTests {
    @Test func splitsCoalescedAndPartialFrames() throws {
        let a = Fixture.bytes(Fixture["v33", "controlAck", "frame"])
        let b = Fixture.bytes(Fixture["v35", "statusPush", "frame"])
        var decoder = TuyaFrameDecoder()
        let stream = [0x13, 0x37] + a + b
        #expect(try decoder.append(stream.prefix(10)).isEmpty)
        let frames = try decoder.append(stream.dropFirst(10).prefix(a.count))
        #expect(frames == [a])
        #expect(try decoder.append(stream.dropFirst(10 + a.count)) == [b])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func rejectsOversizedHeader() throws {
        var decoder = TuyaFrameDecoder()
        let bogus: [UInt8] = [0, 0, 0x55, 0xAA, 0, 0, 0, 1, 0, 0, 0, 7, 0x7F, 0, 0, 0]
        #expect(throws: TuyaFrameError.oversized(0x7F00_0000)) { try decoder.append(bogus) }
    }

    @Test func packUnpackRoundTrip() throws {
        let m = TuyaMessage(seqno: 9, command: 8, retcode: 0, payload: Array("{}".utf8))
        let crc = try TuyaFrame.pack(m)
        #expect(try TuyaFrame.unpack(crc) == m)
        let key = [UInt8](repeating: 3, count: 16)
        let hmac = try TuyaFrame.pack(m, hmacKey: key)
        #expect(try TuyaFrame.unpack(hmac, hmacKey: key).trailerValid)
        #expect(try TuyaFrame.unpack(hmac, hmacKey: [UInt8](repeating: 4, count: 16)).trailerValid == false)
        var gcm = m
        gcm.prefix = .p6699
        let packed = try TuyaFrame.pack(gcm, hmacKey: key, iv: Fixture.iv(9))
        let back = try TuyaFrame.unpack(packed, hmacKey: key)
        #expect(back.payload == m.payload && back.retcode == 0 && back.iv == Fixture.iv(9))
        #expect(try TuyaFrame.unpack(packed, hmacKey: [UInt8](repeating: 4, count: 16)).trailerValid == false)
    }
}

@Suite("UDP discovery")
struct DiscoveryTests {
    @Test(arguments: ["plain6666", "ecb6667", "gcm6667"])
    func decodesAnnouncements(_ name: String) throws {
        let node = Fixture["discovery", name]
        let json = try TuyaDiscovery.decode(Fixture.bytes(node["frame"]!))
        #expect(json == node["json"])
        let info = try #require(TuyaDiscovery.parse(datagram: Fixture.bytes(node["frame"]!)))
        #expect(info.deviceId == Fixture.devId)
        #expect(info.ip == "192.168.1.42")
        #expect(info.productKey == "keyabcdefgh12345")
        #expect(info.version == TuyaVersion(string: node["json"]?["version"]?.stringValue ?? ""))
    }

    @Test func deviceInfoRequestMatchesTinytuya() throws {
        let node = Fixture["discovery", "reqDevInfo"]
        let frame = try TuyaDiscovery.deviceInfoRequest(localIP: "192.168.1.5", iv: Fixture.iv(11))
        #expect(TuyaCrypto.hex(frame) == node["frame"]?.stringValue)
        // Our own app broadcast is not a device.
        #expect(TuyaDiscovery.parse(datagram: frame) == nil)
    }

    @Test(arguments: TuyaVersion.allCases)
    func announcementRoundTrip(_ version: TuyaVersion) throws {
        let json: TuyaJSON = ["ip": "10.0.0.9", "gwId": "abc123", "version": .string(version.rawValue)]
        let info = try #require(TuyaDiscovery.parse(datagram: try TuyaDiscovery.announcement(json, version: version)))
        #expect(info.deviceId == "abc123" && info.version == version)
    }

    @Test func junkIsIgnored() {
        #expect(TuyaDiscovery.parse(datagram: [1, 2, 3]) == nil)
        #expect(TuyaDiscovery.parse(datagram: [UInt8](repeating: 0, count: 32)) == nil)
    }
}
