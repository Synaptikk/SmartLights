import Foundation
import Testing
@testable import TPLinkCodec

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func bytes(_ hex: String) -> Data {
    let clean = hex.filter { !$0.isWhitespace }
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

// Vectors: Fixtures/tplink_vectors.json, produced by Fixtures/gen_vectors.py with python-kasa 0.12.0.

@Suite("XOR autokey (legacy Kasa)")
struct TPLinkXORTests {
    static let sysinfo = #"{"system":{"get_sysinfo":{}}}"#
    static let sysinfoFramed = "0000001dd0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08bf68bf6"

    static let transition = #"{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"on_off":1,"brightness":42,"hue":120,"saturation":75,"color_temp":0,"transition_period":500,"ignore_default":1}}}"#
    static let transitionFramed = """
        000000b7d0f281ec8dff8be78ee88da3caa5d1ff8ce180f286e491fd9fb1ddb4d3bbcfa6c8afdcb9cbbdd4b7d2f0cab193e795f49ae9
        80f49df29cc3afc6a1c9bde291e584f095b78df6d4bbd58ae583e5c7fdcce0c2a0d2bbdcb4c0aecbb8cbe9d3e7d5f9dbb3c6a381bb8a
        b888a486f594e095e786f29bf49ab882b580ac8eed82ee81f3acd8bdd0a082b888a486f280e18ffc95e188e789d6a6c3b1d8b7d3f1cb
        fecefed2f099fe90ff8de8b7d3b6d0b1c4a8dcfec4f588f588
        """

    @Test func framesMatchPythonKasa() {
        #expect(hex(TPLinkXOR.frame(Data(Self.sysinfo.utf8))) == Self.sysinfoFramed)
        #expect(hex(TPLinkXOR.frame(Data(Self.transition.utf8))) == Self.transitionFramed.filter { !$0.isWhitespace })
        #expect(hex(TPLinkXOR.frame(Data())) == "00000000")
    }

    @Test func unframeRoundTrips() throws {
        #expect(String(decoding: try TPLinkXOR.unframe(bytes(Self.sysinfoFramed)), as: UTF8.self) == Self.sysinfo)
        #expect(String(decoding: try TPLinkXOR.unframe(bytes(Self.transitionFramed)), as: UTF8.self) == Self.transition)
        let random = Data((0..<300).map { _ in UInt8.random(in: 0...255) })
        #expect(TPLinkXOR.decrypt(TPLinkXOR.encrypt(random)) == random)
    }

    @Test func deframeHandlesSplitAndMergedReads() throws {
        let a = TPLinkXOR.frame(Data("{\"a\":1}".utf8))
        let b = TPLinkXOR.frame(Data("{\"b\":2}".utf8))
        var buffer = a + b.prefix(3)
        var out = try TPLinkXOR.deframe(&buffer)
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}"])
        #expect(buffer.count == 3)
        buffer.append(b.dropFirst(3))
        out = try TPLinkXOR.deframe(&buffer)
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["{\"b\":2}"])
        #expect(buffer.isEmpty)
    }

    @Test func rejectsTruncatedAndOversizedFrames() {
        #expect(throws: TPLinkCodecError.self) { try TPLinkXOR.unframe(bytes("000000")) }
        #expect(throws: TPLinkCodecError.self) { try TPLinkXOR.unframe(bytes("0000000aabcd")) }
        #expect(throws: TPLinkCodecError.self) { try TPLinkXOR.unframe(bytes("7fffffff00")) }
    }
}

@Suite("KLAP (python-kasa vectors)")
struct TPLinkKLAPTests {
    static let username = "User@Example.com"
    static let password = "Pa55word!"
    static let localSeed = bytes("000102030405060708090a0b0c0d0e0f")
    static let remoteSeed = bytes("101112131415161718191a1b1c1d1e1f")

    @Test func authHashes() {
        #expect(hex(TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v1)) == "3650ba565334637dad2eabb75397ff2a")
        #expect(hex(TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2))
            == "5f9e01a453e24aa640205aaa45beee8942fbd7b2e09c04dd70803685ec938af3")
        #expect(hex(TPLinkKLAP.authHash(username: "", password: "", version: .v1)) == "5873dd45edd01f09c1ef2e7819369e8e")
        #expect(hex(TPLinkKLAP.authHash(username: "", password: "", version: .v2))
            == "b8628ab91c74f531603f6d5b45e730e54c123a7247b8978272c03f1e13560cea")
    }

    /// The email is case-sensitive: a lowercased email gives a different hash.
    @Test func emailIsCaseSensitive() {
        let lower = TPLinkKLAP.authHash(username: Self.username.lowercased(), password: Self.password, version: .v2)
        #expect(hex(lower) == "b9c7f04232693d9672231bf4867484761ac2ef7010c28b76c8db89b1e7c96fa5")
        #expect(lower != TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2))
    }

    @Test func handshakeHashes() {
        let v1 = TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v1)
        let v2 = TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2)
        #expect(hex(TPLinkKLAP.handshake1Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: v1, version: .v1))
            == "223667d2d8d2da8366422a8c6f8c2b54573144df30c3586ba958de28cce29f61")
        #expect(hex(TPLinkKLAP.handshake2Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: v1, version: .v1))
            == "6d227b2fb63324d992c0c555f555eccfcaf57be043b2fc9e5c9e77f1adf34f4f")
        #expect(hex(TPLinkKLAP.handshake1Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: v2, version: .v2))
            == "a7548b5fbe08c66f66117445e53ba078655f7b04b260dc446a799210cbb5c2b7")
        #expect(hex(TPLinkKLAP.handshake2Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: v2, version: .v2))
            == "8f8d200a5a821a9f5d4d4e0ff26b19275986db339421e21bc0ffe5f8fd4b856e")
    }

    @Test func candidateMatching() throws {
        let candidates = TPLinkKLAP.candidateHashes(username: Self.username, password: Self.password, version: .v2)
        #expect(candidates.count == 4) // account, two vendor defaults, blank
        let server = bytes("a7548b5fbe08c66f66117445e53ba078655f7b04b260dc446a799210cbb5c2b7")
        #expect(TPLinkKLAP.matchCandidate(candidates, localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, serverHash: server, version: .v2) == 0)
        // Blank credentials (a device never bound to a cloud account).
        let blank = TPLinkKLAP.authHash(username: "", password: "", version: .v2)
        let blankServer = TPLinkKLAP.handshake1Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: blank, version: .v2)
        #expect(TPLinkKLAP.matchCandidate(candidates, localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, serverHash: blankServer, version: .v2) == 3)
        // Wrong password: no match.
        let other = TPLinkKLAP.authHash(username: Self.username, password: "nope", version: .v2)
        let otherServer = TPLinkKLAP.handshake1Hash(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: other, version: .v2)
        #expect(TPLinkKLAP.matchCandidate(candidates, localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, serverHash: otherServer, version: .v2) == nil)
    }

    @Test func parseHandshake1() throws {
        let body = Self.remoteSeed + bytes("a7548b5fbe08c66f66117445e53ba078655f7b04b260dc446a799210cbb5c2b7")
        let (remote, hash) = try TPLinkKLAP.parseHandshake1(body)
        #expect(remote == Self.remoteSeed)
        #expect(hash.count == 32)
        #expect(throws: TPLinkCodecError.self) { try TPLinkKLAP.parseHandshake1(Data(count: 47)) }
    }

    @Test func sessionDerivation() {
        let auth = TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2)
        let s = TPLinkKLAPSession(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: auth)
        #expect(hex(s.key) == "abdd604e4bd522d7d060d10d3a92be5b")
        #expect(hex(s.ivPrefix) == "f941fa90cdc20a470c137f1e")
        #expect(s.sequence == -35_070_835)
        #expect(hex(s.signature) == "59027941a11f6f78265fbd2837f3de74b03c6fd8cb4d534c06ba0f6f")
    }

    @Test func encryptAndDecryptMatchPythonKasa() throws {
        let auth = TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2)
        var s = TPLinkKLAPSession(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: auth)
        let response = #"{"error_code":0,"result":{"device_on":true}}"#

        let (p1, seq1) = try s.encrypt(Data(#"{"method":"get_device_info"}"#.utf8))
        #expect(seq1 == -35_070_834)
        #expect(hex(p1) == "31b275dcdc6c71ffb98c96120d1e9ec44f0a9c5f4bf6dd18204eb2fe08bac4305cdcbbcbb4b46ed699301fd941d2ae9f6946038453923189859d448f625f2681")
        let r1 = bytes("fedbf3b476a5b4e11ebb023f77ef1e498ece6e976c80aa0f4d0be9ed8dc1ccae3db39896186cf66f6843ee74d2cfee04783145635f1d6befbfc0abfd10a604f95b4e5275aafa57151a035bde20fdeea9")
        #expect(String(decoding: try s.decryptResponse(r1), as: UTF8.self) == response)

        let (p2, seq2) = try s.encrypt(Data(#"{"method":"set_device_info","params":{"device_on":true,"brightness":50}}"#.utf8))
        #expect(seq2 == -35_070_833)
        #expect(hex(p2) == """
            a5000029d4a4c0b0224e5f1c92117d3bad36a9dd8ccbf48558c8d5a74e448719bed648c1bba89b3737937ce0dfe28ee0766fdbadfcf523ca8dd77902b77f334281340bd4a808977026b4ce6a3a71ada3b9491a7b85f65ec2fa2d746bc5018c73d3c492633bc59c3e17787d39cf6acbe9
            """)
        let r2 = bytes("237fa6bccf573fd1fd024539193a19113c088e0ef4f274570bba19a048c7c5639f3935afb03838c3e2919a51e732141d1fd4398a5466bfa95824c95d44af60aa9b406bf9cb370daebd5fc8eff38ae62c")
        #expect(String(decoding: try s.decryptResponse(r2), as: UTF8.self) == response)
        // The device side opens what the client sealed.
        #expect(String(decoding: try s.open(p2, sequence: seq2), as: UTF8.self).contains("\"brightness\":50"))
    }

    @Test func tamperedBodyIsRejected() throws {
        let auth = TPLinkKLAP.authHash(username: Self.username, password: Self.password, version: .v2)
        var s = TPLinkKLAPSession(localSeed: Self.localSeed, remoteSeed: Self.remoteSeed, authHash: auth)
        var (body, seq) = try s.encrypt(Data("{}".utf8))
        body[40] ^= 0x01
        #expect(throws: TPLinkCodecError.self) { try s.open(body, sequence: seq) }
        #expect(throws: TPLinkCodecError.self) { try s.open(Data(count: 20), sequence: seq) }
    }

    @Test func sequenceIsSignedBigEndianAndWraps() {
        #expect(hex(TPLinkKLAPSession.sequenceBytes(Int32.min)) == "80000000")
        #expect(hex(TPLinkKLAPSession.sequenceBytes(-1)) == "ffffffff")
        #expect(hex(TPLinkKLAPSession.sequenceBytes(0)) == "00000000")
        #expect(hex(TPLinkKLAPSession.sequenceBytes(1)) == "00000001")
        #expect(hex(TPLinkKLAPSession.sequenceBytes(Int32.max)) == "7fffffff")
    }

    @Test func aesCBCRoundTripAndPadding() throws {
        let key = Data(repeating: 7, count: 16)
        let iv = Data(repeating: 9, count: 16)
        for length in [0, 1, 15, 16, 17, 100] {
            let plain = Data((0..<length).map { UInt8($0 & 0xFF) })
            let ct = try TPLinkAESCBC.encrypt(plain, key: key, iv: iv)
            #expect(ct.count == (length / 16 + 1) * 16)
            #expect(try TPLinkAESCBC.decrypt(ct, key: key, iv: iv) == plain)
        }
        // FIPS-197 / SP 800-38A F.2.1 CBC-AES128 first block (no padding involved in the block itself).
        let nistKey = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let nistIV = bytes("000102030405060708090a0b0c0d0e0f")
        let block = bytes("6bc1bee22e409f96e93d7e117393172a")
        let ct = try TPLinkAESCBC.encrypt(block, key: nistKey, iv: nistIV)
        #expect(hex(ct.prefix(16)) == "7649abac8119b246cee98e9b12e9197d")
    }

    @Test func cookies() {
        let c = TPLinkKLAP.parseCookies(["TP_SESSIONID=ABCDEF0123;TIMEOUT=86400", "Path=/"])
        #expect(c["TP_SESSIONID"] == "ABCDEF0123")
        #expect(c["TIMEOUT"] == "86400")
        #expect(c["Path"] == "/")
        #expect(TPLinkKLAP.parseCookies(["TP_SESSIONID=X, TIMEOUT=1440"])["TIMEOUT"] == "1440")
    }
}

@Suite("Discovery datagrams")
struct TPLinkDiscoveryTests {
    @Test func legacyQueryMatchesPythonKasa() {
        // python-kasa sends json.dumps(...) with spaces; our compact JSON differs, so compare the
        // XOR of python's exact text and check ours decodes to the same request.
        let pythonText = #"{"system": {"get_sysinfo": {}}}"#
        #expect(hex(TPLinkXOR.encrypt(Data(pythonText.utf8))) == "d0f281f88bff9af7d5efcfb496f194e0bfccb5c6afc1a7c8ead0f08bf68bf6")
        let ours = try? TPLinkJSON.parse(TPLinkXOR.decrypt(TPLinkDiscovery.legacyQuery))
        #expect(ours == TPLinkIOT.getSysinfo)
    }

    @Test func headerOnlyQueryIsDiscoveryQuery2() {
        #expect(hex(TPLinkDiscovery.query()) == "020000010000000000000000463cb5d3")
    }

    @Test func keyedQueryMatchesPythonKasa() {
        let payload = Data(#"{"params": {"rsa_key": "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"}}"#.utf8)
        let q = TPLinkDiscovery.query(payload: payload, serial: 0x0102_0304, flags: 17)
        #expect(hex(q) == "0200000100571100010203040c3b73317b22706172616d73223a207b227273615f6b6579223a20222d2d2d2d2d424547494e205055424c4943204b45592d2d2d2d2d5c6e544553545c6e2d2d2d2d2d454e44205055424c4943204b45592d2d2d2d2d5c6e227d7d")
    }

    @Test func crc32() {
        #expect(TPLinkDiscovery.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func probeKeyIsAPublicKeyPEM() throws {
        let pem = try TPLinkDiscovery.makeProbeKeyPEM()
        #expect(pem.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        let payload = try TPLinkJSON.parse(TPLinkDiscovery.rsaKeyPayload(publicKeyPEM: pem))
        #expect(payload["params"]?["rsa_key"]?.stringValue == pem)
    }

    static let tapoAnswerJSON = """
        {"error_code":0,"result":{"device_id":"8022A1B2C3D4E5F60718293A4B5C6D7E","owner":"0011","device_type":"SMART.TAPOBULB",
        "device_model":"L530E(EU)","ip":"192.168.1.42","mac":"5C-E9-31-12-34-56","is_support_iot_cloud":true,"obd_src":"tplink",
        "factory_default":false,"mgt_encrypt_schm":{"is_support_https":false,"encrypt_type":"KLAP","http_port":80,"lv":2}}}
        """

    @Test func parsesTapoAnswer() throws {
        let datagram = Data(count: 16) + Data(Self.tapoAnswerJSON.utf8)
        let r = try TPLinkDiscovery.parse(datagram, fromPort: 20002, host: "192.168.1.42")
        #expect(r.deviceID == "8022A1B2C3D4E5F60718293A4B5C6D7E")
        #expect(r.model == "L530E(EU)")
        #expect(r.deviceType == "SMART.TAPOBULB")
        #expect(r.stableID == "5ce931123456")
        #expect(r.isLight)
        #expect(r.connection == TPLinkConnection(transport: .klap, family: .smart, klapVersion: .v2, port: 80))
        #expect(r.connection?.descriptor == "klap2-smart:80")
    }

    @Test func parsesKasaKLAPAndAESAnswers() throws {
        let kasaV1 = #"{"error_code":0,"result":{"device_id":"abc","device_type":"IOT.SMARTBULB","device_model":"KL125(US)","ip":"10.0.0.5","mac":"50-91-E3-00-11-22","mgt_encrypt_schm":{"is_support_https":false,"encrypt_type":"KLAP","http_port":80}}}"#
        let r1 = try TPLinkDiscovery.parseNew(Data(count: 16) + Data(kasaV1.utf8), host: "10.0.0.5")
        #expect(r1.connection == TPLinkConnection(transport: .klap, family: .iot, klapVersion: .v1, port: 80))
        let kasaV2 = kasaV1.replacingOccurrences(of: #""http_port":80"#, with: #""http_port":80,"lv":2"#)
        #expect(try TPLinkDiscovery.parseNew(Data(count: 16) + Data(kasaV2.utf8), host: "x").connection?.klapVersion == .v2)
        let aes = #"{"error_code":0,"result":{"device_id":"d","device_type":"SMART.TAPOBULB","device_model":"L510E(US)","ip":"10.0.0.6","mac":"AA-BB-CC-00-11-22","mgt_encrypt_schm":{"is_support_https":false,"encrypt_type":"AES","http_port":80,"lv":2}}}"#
        let r3 = try TPLinkDiscovery.parseNew(Data(count: 16) + Data(aes.utf8), host: "10.0.0.6")
        #expect(r3.connection?.transport == .aes)
        #expect(r3.connection?.isSupported == false)
        let plug = #"{"error_code":0,"result":{"device_id":"p","device_type":"SMART.TAPOPLUG","device_model":"P110(EU)","ip":"10.0.0.7","mac":"AA-BB-CC-00-11-23","mgt_encrypt_schm":{"is_support_https":false,"encrypt_type":"KLAP","http_port":80,"lv":2}}}"#
        #expect(try TPLinkDiscovery.parseNew(Data(count: 16) + Data(plug.utf8), host: "10.0.0.7").isLight == false)
    }

    static let kl130Sysinfo = """
        {"system":{"get_sysinfo":{"sw_ver":"1.8.11 Build 191113 Rel.105336","hw_ver":"1.0","model":"KL130(US)",
        "description":"Smart Wi-Fi LED Bulb with Color Changing","alias":"Desk","mic_type":"IOT.SMARTBULB",
        "dev_state":"normal","mic_mac":"1C3BF3112233","deviceId":"801200AABBCCDDEEFF00112233445566778899AA",
        "is_factory":false,"disco_ver":"1.0","ctrl_protocols":{"name":"Linkie","version":"1.0"},"active_mode":"none",
        "is_dimmable":1,"is_color":1,"is_variable_color_temp":1,
        "light_state":{"on_off":1,"mode":"normal","hue":0,"saturation":0,"color_temp":2700,"brightness":50},
        "rssi":-52,"err_code":0}}}
        """

    @Test func parsesLegacyAnswer() throws {
        let datagram = TPLinkXOR.encrypt(Data(Self.kl130Sysinfo.utf8))
        let r = try TPLinkDiscovery.parse(datagram, fromPort: 9999, host: "192.168.1.30")
        #expect(r.host == "192.168.1.30")
        #expect(r.connection == .legacy)
        #expect(r.model == "KL130(US)")
        #expect(r.name == "Desk")
        #expect(r.stableID == "1c3bf3112233")
        #expect(r.sysinfo?.lightState?.colorTemp == 2700)
        #expect(r.isLight)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try TPLinkDiscovery.parse(Data([1, 2, 3]), fromPort: 20002, host: "h") }
        #expect(throws: (any Error).self) { try TPLinkDiscovery.parse(Data([1, 2, 3]), fromPort: 9999, host: "h") }
    }

    @Test func identity() {
        #expect(TPLinkIdentity.normalizedMAC("5C-E9-31-12-34-56") == "5ce931123456")
        #expect(TPLinkIdentity.normalizedMAC("E8:48:B8:00:11:22") == "e848b8001122")
        #expect(TPLinkIdentity.normalizedMAC("000000000000") == nil)
        #expect(TPLinkIdentity.stableID(mac: "00:00:00:00:00:00", deviceID: "80AB") == "80ab")
        #expect(TPLinkIdentity.stableID(mac: nil, deviceID: "0000") == nil)
        #expect(TPLinkIdentity.displayMAC("5ce931123456") == "5C:E9:31:12:34:56")
    }

    @Test func connectionDescriptorRoundTrip() {
        let all: [TPLinkConnection] = [
            .legacy, .tapo,
            TPLinkConnection(transport: .klap, family: .iot, klapVersion: .v1, port: 80),
            TPLinkConnection(transport: .klap, family: .smart, klapVersion: .v2, port: 4433, https: true),
            TPLinkConnection(transport: .aes, family: .smart, port: 80),
        ]
        for c in all {
            #expect(TPLinkConnection(descriptor: c.descriptor) == c)
        }
        #expect(TPLinkConnection(descriptor: "nonsense") == nil)
    }
}
