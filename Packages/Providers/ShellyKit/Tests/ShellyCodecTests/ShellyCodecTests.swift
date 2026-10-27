import Foundation
import LightCore
import Testing
@testable import ShellyCodec

@Suite("JSON value")
struct ShellyJSONTests {
    @Test func parsesAndEncodesDeterministically() throws {
        let j = try ShellyJSON.parse(#"{"b":true,"a":[1,2.5,"x\né"],"n":null,"o":{"z":-3e2}}"#)
        #expect(j["b"]?.bool == true)
        #expect(j["a"]?[1]?.double == 2.5)
        #expect(j["a"]?[2]?.string == "x\né")
        #expect(j["n"]?.isNull == true)
        #expect(j["o"]?["z"]?.int == -300)
        #expect(j.jsonString == #"{"a":[1,2.5,"x\né"],"b":true,"n":null,"o":{"z":-300}}"#)
        // Booleans never become numbers (Linux and Apple alike).
        #expect(try ShellyJSON.parse("[true,1,0,false]") == [true, 1, 0, false])
    }

    @Test func rejectsInvalid() {
        #expect(throws: ShellyJSONError.self) { try ShellyJSON.parse("{\"a\":}") }
        #expect(throws: ShellyJSONError.self) { try ShellyJSON.parse("[1,2") }
        #expect(throws: ShellyJSONError.self) { try ShellyJSON.parse("1 2") }
    }

    @Test func mergesPatches() {
        let base: ShellyJSON = ["light:0": ["id": 0, "output": false, "brightness": 40], "sys": ["uptime": 1]]
        let merged = base.merging(["light:0": ["output": true]])
        #expect(merged["light:0"]?["output"]?.bool == true)
        #expect(merged["light:0"]?["brightness"]?.int == 40)
        #expect(merged["sys"]?["uptime"]?.int == 1)
    }
}

@Suite("Device info")
struct ShellyDeviceInfoTests {
    @Test func gen1() throws {
        let info = try #require(ShellyDeviceInfo.parse(Data(#"{"type":"SHBDUO-1","mac":"A4CF12F3F1B2","auth":true,"fw":"20230913-114008/v1.14.0-gcb84623","num_outputs":1}"#.utf8)))
        #expect(info == ShellyDeviceInfo(mac: "a4cf12f3f1b2", generation: 1, model: "SHBDUO-1",
                                         firmware: "20230913-114008/v1.14.0-gcb84623", authRequired: true))
        #expect(!info.usesRPC)
        #expect(info.displayModel == "Shelly Duo (SHBDUO-1)")
    }

    @Test func gen2() throws {
        let json = #"{"name":"Desk","id":"shellyplusrgbwpm-a0a3b3c4d5e6","mac":"A0A3B3C4D5E6","slot":0,"model":"SNDC-0D4P10WW","gen":2,"fw_id":"20241011-114455/1.4.4-g6d2a586","ver":"1.4.4","app":"PlusRGBWPM","auth_en":true,"auth_domain":"shellyplusrgbwpm-a0a3b3c4d5e6"}"#
        let info = try #require(ShellyDeviceInfo.parse(Data(json.utf8)))
        #expect(info.mac == "a0a3b3c4d5e6")
        #expect(info.generation == 2)
        #expect(info.usesRPC)
        #expect(info.app == "PlusRGBWPM")
        #expect(info.deviceID == "shellyplusrgbwpm-a0a3b3c4d5e6")
        #expect(info.authRequired)
        #expect(info.authDomain == "shellyplusrgbwpm-a0a3b3c4d5e6")
        #expect(info.name == "Desk")
        #expect(info.displayModel == "Shelly PlusRGBWPM")
        // auth_domain null -> realm falls back to the device id.
        let open = try #require(ShellyDeviceInfo.parse(Data(#"{"id":"shellyduobulbg3-aabbccddeeff","mac":"AABBCCDDEEFF","model":"S3BL-D010009AEU","gen":3,"app":"DuoBulbG3","auth_en":false,"auth_domain":null}"#.utf8)))
        #expect(open.generation == 3 && !open.authRequired && open.authDomain == "shellyduobulbg3-aabbccddeeff")
    }

    @Test func rejectsNonShelly() {
        #expect(ShellyDeviceInfo.parse(Data(#"{"name":"router"}"#.utf8)) == nil)
        #expect(ShellyDeviceInfo.parse(Data("<html>".utf8)) == nil)
        #expect(ShellyDeviceInfo.isShellyServiceName("ShellyBulbDuo-F3F1B2"))
        #expect(!ShellyDeviceInfo.isShellyServiceName("Printer"))
    }
}

@Suite("Digest authentication")
struct ShellyDigestTests {
    /// RFC 7616 section 3.9.1 examples (MD5 and SHA-256).
    @Test func rfc7616Vectors() {
        var challenge = ShellyDigestChallenge(realm: "http-auth@example.org", nonce: "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
                                              qop: "auth", algorithm: .md5)
        let args = (method: "GET", uri: "/dir/index.html", user: "Mufasa", pass: "Circle of Life",
                    cnonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ", nc: "00000001")
        #expect(ShellyDigest.response(challenge: challenge, method: args.method, uri: args.uri, username: args.user,
                                      password: args.pass, cnonce: args.cnonce, nc: args.nc) == "8ca523f5e9506fed4657c9700eebdbec")
        challenge.algorithm = .sha256
        #expect(ShellyDigest.response(challenge: challenge, method: args.method, uri: args.uri, username: args.user,
                                      password: args.pass, cnonce: args.cnonce, nc: args.nc)
                == "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1")
    }

    @Test func parsesShellyChallengeHeader() throws {
        let c = try #require(ShellyDigestChallenge(header: #"Digest qop="auth", realm="shellypro4pm-f008d1d8b8b8", nonce="60dc59c6", algorithm=SHA-256"#))
        #expect(c == ShellyDigestChallenge(realm: "shellypro4pm-f008d1d8b8b8", nonce: "60dc59c6", qop: "auth", algorithm: .sha256))
        #expect(ShellyDigestChallenge(header: #"Basic realm="x""#) == nil)
        #expect(ShellyDigestChallenge(header: #"Digest realm="r", nonce="n", algorithm=SHA-512-256"#) == nil)
        let md5 = try #require(ShellyDigestChallenge(header: #"Digest realm="r, with comma", nonce="n", opaque="o", stale=TRUE"#))
        #expect(md5.algorithm == .md5 && md5.realm == "r, with comma" && md5.opaque == "o" && md5.stale && md5.qop == nil)
    }

    /// Authorization header for `POST /rpc`; response cross-checked with Python hashlib.
    @Test func authorizationHeader() {
        let c = ShellyDigestChallenge(realm: "shellypro4pm-f008d1d8b8b8", nonce: "60dc59c6")
        let h = ShellyDigest.authorization(challenge: c, method: "POST", uri: "/rpc", password: "pass", cnonce: "0a4f113b", nonceCount: 1)
        #expect(h == #"Digest username="admin", realm="shellypro4pm-f008d1d8b8b8", nonce="60dc59c6", uri="/rpc", algorithm=SHA-256, response="8dc9345a6f14dd90ac9ffe378d91ba40aec93685d96ba7648f5859d31ffd386e", qop=auth, nc=00000001, cnonce="0a4f113b""#)
    }

    /// RPC `auth` object (aioshelly `AuthData.get_auth` formula), cross-checked with Python hashlib.
    @Test func rpcAuthObject() throws {
        let challenge = try #require(ShellyDigestChallenge(rpcErrorMessage: #"{"auth_type": "digest", "nonce": 1625038762, "nc": 1, "realm": "shellyplus1-e86beae9e1c0", "algorithm": "SHA-256"}"#))
        #expect(challenge.nonce == "1625038762" && challenge.nc == 1)
        let auth = ShellyDigest.rpcAuth(challenge: challenge, password: "secret", cnonce: "abc", nonceCount: 1)
        #expect(auth["response"]?.string == "ff7aa59e8c325af5b131f6824dff56c006370d82ff8e68cc5ee86b674539c557")
        #expect(auth["username"]?.string == "admin")
        #expect(auth["nc"]?.int == 1)
        #expect(auth["algorithm"]?.string == "SHA-256")
    }

    @Test func basicAuth() {
        #expect(ShellyDigest.basicAuthorization(username: "admin", password: "pw") == "Basic YWRtaW46cHc=")
        #expect(ShellyDigest.makeCnonce().count == 32)
    }
}

@Suite("RPC frames")
struct ShellyRPCTests {
    @Test func requestFrame() {
        let r = ShellyRPCRequest(id: 7, src: "smartlights-1", method: "Light.Set", params: ["id": 0, "on": true, "brightness": 50])
        #expect(String(decoding: r.encoded(), as: UTF8.self)
                == #"{"id":7,"method":"Light.Set","params":{"brightness":50,"id":0,"on":true},"src":"smartlights-1"}"#)
    }

    @Test func parsesFrames() {
        #expect(ShellyRPCFrame.parse(Data(#"{"id":7,"src":"shellyplus","dst":"smartlights-1","result":{"restart_required":false}}"#.utf8))
                == .result(id: 7, result: ["restart_required": false]))
        #expect(ShellyRPCFrame.parse(Data(#"{"id":8,"src":"x","error":{"code":401,"message":"{\"auth_type\":\"digest\"}"}}"#.utf8))
                == .error(id: 8, code: 401, message: #"{"auth_type":"digest"}"#))
        let n = ShellyRPCFrame.parse(Data(#"{"src":"shellyplusrgbwpm-a0a3b3c4d5e6","dst":"smartlights-1","method":"NotifyStatus","params":{"ts":1.7e9,"rgb:0":{"id":0,"output":false}}}"#.utf8))
        guard case .notification(let method, let src, let params) = n else { Issue.record("expected notification"); return }
        #expect(method == "NotifyStatus")
        #expect(src == "shellyplusrgbwpm-a0a3b3c4d5e6")
        #expect(params["rgb:0"]?["output"]?.bool == false)
        #expect(ShellyRPCFrame.parse(Data("[]".utf8)) == nil)
    }

    @Test func gen1Query() {
        let r = ShellyGen1Request(path: "/light/0", query: [("turn", "on"), ("brightness", "50"), ("x", "a b&c")])
        #expect(r.uri == "/light/0?turn=on&brightness=50&x=a%20b%26c")
        #expect(ShellyGen1Request.parse(uri: r.uri) == r)
        #expect(ShellyGen1Request(path: "/status").uri == "/status")
    }
}
