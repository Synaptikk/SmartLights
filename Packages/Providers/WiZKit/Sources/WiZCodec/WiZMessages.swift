import Foundation

/// Method names of the WiZ local UDP protocol (research_wiz.md §1.2).
public enum WiZMethod {
    public static let getPilot = "getPilot"
    public static let setPilot = "setPilot"
    public static let setState = "setState"
    public static let getSystemConfig = "getSystemConfig"
    public static let getModelConfig = "getModelConfig"
    public static let getUserConfig = "getUserConfig"
    public static let getPower = "getPower"
    public static let registration = "registration"
    public static let pulse = "pulse"
    /// Bulb -> app push (state change / heartbeat) on UDP 38900.
    public static let syncPilot = "syncPilot"
    /// Bulb -> app push when it (re)joins the network.
    public static let firstBeat = "firstBeat"

    /// Methods that change the light and therefore need a signature on fw 1.34+ in
    /// "Only verified controls" mode.
    public static let writes: Set<String> = [setPilot, setState, pulse]
}

/// Well-known UDP ports.
public enum WiZPort {
    /// Requests and replies.
    public static let control: UInt16 = 38899
    /// Bulb-initiated `syncPilot` / `firstBeat`.
    public static let push: UInt16 = 38900
}

// MARK: - Request

/// One request datagram: `{"id":n,"method":"...","params":{...}}` (signed: `+ "env":"pro","hmac":"..."`).
public struct WiZRequest: Sendable, Hashable {
    public var id: WiZJSON?
    public var method: String
    public var params: WiZObject

    public init(id: Int? = nil, method: String, params: WiZObject = WiZObject()) {
        self.id = id.map { .int($0) }
        self.method = method
        self.params = params
    }

    public init(rawID: WiZJSON?, method: String, params: WiZObject) {
        self.id = rawID
        self.method = method
        self.params = params
    }

    /// Whether this request needs a signature on fw 1.34+ ("Only verified controls").
    public var isWrite: Bool { WiZMethod.writes.contains(method) }

    /// Unsigned envelope in protocol order: `id`, `method`, `params`.
    public var envelope: WiZObject {
        var o = WiZObject()
        if let id { o["id"] = id }
        o["method"] = .string(method)
        o["params"] = .object(params)
        return o
    }

    /// Unsigned datagram.
    public func encoded() -> Data { envelope.compactData }

    /// Signed envelope, built exactly like `tools/probe/wiz.mjs`: `sigTs` is added to (or
    /// replaced in) `params`, then `env:"pro"` and the base64 `hmac` are appended at top level:
    /// `{"id":1,"method":"setPilot","params":{...,"sigTs":N},"env":"pro","hmac":"..."}`.
    public func signedEnvelope(key: WiZSigningKey, sigTs: Int) -> WiZObject {
        let signed = WiZSigner.sign(params, key: key, sigTs: sigTs)
        var o = WiZObject()
        if let id { o["id"] = id }
        o["method"] = .string(method)
        o["params"] = .object(signed.params)
        o["env"] = "pro"
        o["hmac"] = .string(signed.hmac)
        return o
    }

    /// Signed datagram (see ``signedEnvelope(key:sigTs:)``).
    public func encoded(signingKey key: WiZSigningKey, sigTs: Int) -> Data {
        signedEnvelope(key: key, sigTs: sigTs).compactData
    }

    /// Parses a request datagram (used by tests and diagnostics).
    public static func parse(_ data: Data) throws -> WiZRequest {
        guard let object = try WiZJSON.parse(data).objectValue, let method = object.string("method") else {
            throw WiZCodecError.malformed("request without method")
        }
        return WiZRequest(rawID: object["id"], method: method, params: object.object("params") ?? WiZObject())
    }

    // MARK: Builders

    public static func getPilot(id: Int? = nil) -> WiZRequest { WiZRequest(id: id, method: WiZMethod.getPilot) }

    /// Dual-head devices: read one head (`{"devices":n}`).
    public static func getPilot(id: Int? = nil, head: Int) -> WiZRequest {
        WiZRequest(id: id, method: WiZMethod.getPilot, params: ["devices": .int(head)])
    }

    public static func setPilot(_ params: WiZObject, id: Int? = nil) -> WiZRequest {
        WiZRequest(id: id, method: WiZMethod.setPilot, params: params)
    }

    public static func setState(_ params: WiZObject, id: Int? = nil) -> WiZRequest {
        WiZRequest(id: id, method: WiZMethod.setState, params: params)
    }

    public static func getSystemConfig(id: Int? = nil) -> WiZRequest { WiZRequest(id: id, method: WiZMethod.getSystemConfig) }
    public static func getModelConfig(id: Int? = nil) -> WiZRequest { WiZRequest(id: id, method: WiZMethod.getModelConfig) }
    public static func getUserConfig(id: Int? = nil) -> WiZRequest { WiZRequest(id: id, method: WiZMethod.getUserConfig) }

    /// Push subscription: the bulb sends `syncPilot` to `phoneIp:38900` (re-send every 20 s).
    /// `phoneMac` must be 12 hex characters.
    public static func registration(phoneIp: String, phoneMac: String, register: Bool = true, id: Int? = nil) -> WiZRequest {
        WiZRequest(id: id, method: WiZMethod.registration, params: [
            "phoneIp": .string(phoneIp), "phoneMac": .string(phoneMac), "register": .bool(register),
        ])
    }

    /// The broadcast discovery probe used by pywizlight and `wiz.mjs discover` (byte-identical).
    public static func discoveryRegistration() -> WiZRequest {
        WiZRequest(method: WiZMethod.registration, params: [
            "phoneMac": "AAAAAAAAAAAA", "register": false, "phoneIp": "1.2.3.4", "id": "1",
        ])
    }

    /// Brief dim pulse: `delta` in percent (negative dims), `duration` in ms.
    public static func pulse(delta: Int = -15, duration: Int = 300, id: Int? = nil) -> WiZRequest {
        WiZRequest(id: id, method: WiZMethod.pulse, params: ["delta": .int(delta), "duration": .int(duration)])
    }
}

// MARK: - Errors

public enum WiZCodecError: Error, Sendable, Hashable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let s): "Malformed WiZ message: \(s)"
        }
    }
}

/// `{"error":{"code":...,"message":...,"sigTs":...}}` from the bulb.
public struct WiZError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// -32601: unknown method (e.g. `getModelConfig` on fw <= 1.22).
        case methodNotFound
        /// -32602: invalid params. With `sigTs` present: an unsigned write on a bulb in
        /// "Only verified controls" mode (fw 1.34+).
        case invalidParams
        /// -32605: wrong signature or stale `sigTs`.
        case securityError
        /// -32700: the datagram was not JSON.
        case parseError
        case other(Int)
    }

    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let securityErrorCode = -32605
    public static let parseErrorCode = -32700

    public var code: Int
    public var message: String?
    /// The bulb's clock (unix seconds), sent by signing-capable firmware.
    public var sigTs: Int?

    public init(code: Int, message: String? = nil, sigTs: Int? = nil) {
        self.code = code
        self.message = message
        self.sigTs = sigTs
    }

    init?(_ object: WiZObject) {
        guard let code = object.int("code") else { return nil }
        self.init(code: code, message: object.string("message"), sigTs: object.int("sigTs"))
    }

    public var kind: Kind {
        switch code {
        case Self.methodNotFoundCode: .methodNotFound
        case Self.invalidParamsCode: .invalidParams
        case Self.securityErrorCode: .securityError
        case Self.parseErrorCode: .parseError
        default: .other(code)
        }
    }

    /// -32602 carrying `sigTs`: the bulb wants a signed write (or "Allow all controls").
    public var indicatesSigningRequired: Bool { code == Self.invalidParamsCode && sigTs != nil }

    public var description: String { "WiZ error \(code) \(message ?? "")".trimmingCharacters(in: .whitespaces) }
}

// MARK: - Response / push

/// A datagram received from a bulb: a reply (`result`/`error`) or a push (`params`).
public struct WiZResponse: Sendable, Hashable {
    public var method: String?
    public var env: String?
    public var id: WiZJSON?
    public var result: WiZObject?
    public var error: WiZError?
    /// Push payload (`syncPilot`, `firstBeat`).
    public var params: WiZObject?
    /// Top-level signature on signing-capable firmware (over `result`/`error`/`params`).
    public var hmac: String?
    /// The whole message.
    public var object: WiZObject
    /// Exact bytes of each top-level member value as received.
    public var rawMembers: [String: [UInt8]]

    public init(object: WiZObject, rawMembers: [String: [UInt8]] = [:]) {
        self.object = object
        self.rawMembers = rawMembers
        method = object.string("method")
        env = object.string("env")
        id = object["id"]
        result = object.object("result")
        error = object.object("error").flatMap(WiZError.init)
        params = object.object("params")
        hmac = object.string("hmac")
    }

    public static func parse(_ data: Data) throws -> WiZResponse {
        let (value, raw) = try WiZJSON.parseDocument(Array(data))
        guard let object = value.objectValue else { throw WiZCodecError.malformed("not a JSON object") }
        return WiZResponse(object: object, rawMembers: raw)
    }

    public var isPush: Bool { method == WiZMethod.syncPilot || method == WiZMethod.firstBeat }

    /// `result.success` for write replies.
    public var isSuccess: Bool { error == nil && (result?.bool("success") ?? (result != nil)) }

    /// The body carrying data: `result`, else `params` (pushes).
    public var body: WiZObject? { result ?? params }

    /// Normalised MAC (12 lower-case hex) from the body.
    public var mac: String? { body?.string("mac").flatMap(WiZMAC.normalize) }

    /// Bulb clock from `result`/`error`/`params` if present.
    public var sigTs: Int? { result?.int("sigTs") ?? error?.sigTs ?? params?.int("sigTs") }

    /// Verifies the bulb's `hmac` over the raw bytes of `result`/`error`/`params`
    /// (falling back to the re-serialised compact JSON). `nil` if the message is unsigned.
    public func verifySignature(key: WiZSigningKey) -> Bool? {
        guard let hmac else { return nil }
        for member in ["result", "error", "params"] {
            guard let value = object[member] else { continue }
            if let raw = rawMembers[member], WiZSigner.hmac(raw, key: key) == hmac { return true }
            return WiZSigner.hmac(Array(value.compactString.utf8), key: key) == hmac
        }
        return false
    }

    // Typed views.
    public var pilot: WiZPilot? { body.map(WiZPilot.init) }
    public var systemConfig: WiZSystemConfig? { result.map(WiZSystemConfig.init) }
    public var modelConfig: WiZModelConfig? { result.map(WiZModelConfig.init) }
    public var userConfig: WiZUserConfig? { result.map(WiZUserConfig.init) }
    public var registrationResult: WiZRegistrationResult? { result.map(WiZRegistrationResult.init) }
}

/// MAC helpers. WiZ uses 12 lower-case hex characters without separators (`a8bb5006033d`).
public enum WiZMAC {
    /// Strips `:`/`-`/`.` separators and lower-cases; nil unless exactly 12 hex digits remain.
    public static func normalize(_ mac: String) -> String? {
        let hex = mac.lowercased().filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Known WiZ OUIs (Home Assistant DHCP matcher).
    public static let ouis: Set<String> = ["a8bb50", "d8a011", "444f8e", "6c2990"]

    public static func hasWiZOUI(_ mac: String) -> Bool {
        guard let m = normalize(mac) else { return false }
        return ouis.contains(String(m.prefix(6)))
    }
}

// MARK: - Typed results

/// `getPilot` result / `syncPilot` params.
public struct WiZPilot: Sendable, Hashable {
    public var mac: String?
    public var state: Bool?
    public var r: Int?
    public var g: Int?
    public var b: Int?
    /// Cold white channel.
    public var c: Int?
    /// Warm white channel.
    public var w: Int?
    /// Kelvin (white mode).
    public var temp: Int?
    /// 10...100 %.
    public var dimming: Int?
    /// 0 = no scene.
    public var sceneId: Int?
    public var speed: Int?
    public var ratio: Int?
    public var rssi: Int?
    /// "udp", "app", "pir", "wizmote", "" ...
    public var src: String?
    public var schdPsetId: Int?
    public var raw: WiZObject

    public init(_ object: WiZObject) {
        raw = object
        mac = object.string("mac").flatMap(WiZMAC.normalize)
        state = object.bool("state")
        r = object.int("r")
        g = object.int("g")
        b = object.int("b")
        c = object.int("c")
        w = object.int("w")
        temp = object.int("temp")
        dimming = object.int("dimming")
        sceneId = object.int("sceneId")
        speed = object.int("speed")
        ratio = object.int("ratio")
        rssi = object.int("rssi")
        src = object.string("src")
        schdPsetId = object.int("schdPsetId")
    }

    public var hasRGB: Bool { r != nil || g != nil || b != nil }
}

/// `getSystemConfig` result.
public struct WiZSystemConfig: Sendable, Hashable {
    public var mac: String?
    public var homeId: Int?
    public var roomId: Int?
    public var groupId: Int?
    /// `ESPxx_<ID>_<rev>`; absent on fw 1.8.0 (use `typeId`).
    public var moduleName: String?
    public var fwVersion: String?
    public var typeId: Int?
    public var drvConf: [Int]?
    public var ping: Int?
    public var raw: WiZObject

    public init(_ object: WiZObject) {
        raw = object
        mac = object.string("mac").flatMap(WiZMAC.normalize)
        homeId = object.int("homeId")
        roomId = object.int("roomId")
        groupId = object.int("groupId")
        moduleName = object.string("moduleName")
        fwVersion = object.string("fwVersion")
        typeId = object.int("typeId")
        drvConf = object.ints("drvConf")
        ping = object.int("ping")
    }

    public var moduleInfo: WiZModuleInfo? { moduleName.flatMap { WiZModuleInfo(moduleName: $0) } }
}

/// `getModelConfig` result (fw > 1.22; -32601 before).
public struct WiZModelConfig: Sendable, Hashable {
    public var ps: Int?
    public var pwmFreq: Int?
    public var pwmRange: [Int]?
    /// White-to-colour ratio.
    public var wcr: Int?
    /// Number of white channels.
    public var nowc: Int?
    /// `[extMin, min, max, extMax]` Kelvin.
    public var cctRange: [Int]?
    public var extRange: [Int]?
    public var renderFactor: [Int]?
    public var hasAdjMinDim: Int?
    public var hasTapSensor: Int?
    public var pm: Int?
    public var fanSpeed: Int?
    public var raw: WiZObject

    public init(_ object: WiZObject) {
        raw = object
        ps = object.int("ps")
        pwmFreq = object.int("pwmFreq")
        pwmRange = object.ints("pwmRange")
        wcr = object.int("wcr")
        nowc = object.int("nowc")
        cctRange = object.ints("cctRange")
        extRange = object.ints("extRange")
        renderFactor = object.ints("renderFactor")
        hasAdjMinDim = object.int("hasAdjMinDim")
        hasTapSensor = object.int("hasTapSensor")
        pm = object.int("pm")
        fanSpeed = object.int("fanSpeed")
    }

    public init(cctRange: [Int]? = nil, nowc: Int? = nil, wcr: Int? = nil) {
        var o = WiZObject()
        if let wcr { o["wcr"] = .int(wcr) }
        if let nowc { o["nowc"] = .int(nowc) }
        if let cctRange { o["cctRange"] = .array(cctRange.map { .int($0) }) }
        self.init(o)
    }
}

/// `getUserConfig` result.
public struct WiZUserConfig: Sendable, Hashable {
    public var fadeIn: Int?
    public var fadeOut: Int?
    public var dftDim: Int?
    public var whiteRange: [Int]?
    public var extRange: [Int]?
    public var opMode: Int?
    /// Power-on behaviour.
    public var po: Bool?
    public var raw: WiZObject

    public init(_ object: WiZObject) {
        raw = object
        fadeIn = object.int("fadeIn")
        fadeOut = object.int("fadeOut")
        dftDim = object.int("dftDim")
        whiteRange = object.ints("whiteRange")
        extRange = object.ints("extRange")
        opMode = object.int("opMode")
        po = object.bool("po")
    }
}

/// `registration` result.
public struct WiZRegistrationResult: Sendable, Hashable {
    public var mac: String?
    public var success: Bool?

    public init(_ object: WiZObject) {
        mac = object.string("mac").flatMap(WiZMAC.normalize)
        success = object.bool("success")
    }
}
