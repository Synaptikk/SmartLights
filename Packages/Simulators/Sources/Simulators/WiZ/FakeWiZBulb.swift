// Fake WiZ bulb: JSON-over-UDP on 38899 (requests) with syncPilot pushes to 38900.
//
// Response shapes are modelled on pywizlight's tests/fake_bulb.py (ESP01_SHRGB_03 / 1.25.0)
// and the fw 1.34+ signing behaviour on pywizlight issue #213 / PR #216
// (research/research_wiz.md §1.7).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

public final class FakeWiZBulb: Simulator {
    public struct Configuration: Sendable {
        /// Interface to bind. Use "0.0.0.0" to receive broadcasts.
        public var host: String = "127.0.0.1"
        /// UDP port. 0 = ephemeral. Real bulbs: 38899.
        public var port: Int = 0
        public var mac: String = "a8bb5006033d"
        public var moduleName: String = "ESP01_SHRGB_03"
        public var fwVersion: String = "1.25.0"
        public var homeId: Int = 653906
        public var roomId: Int = 989983
        public var rssi: Int = -62
        /// "Only verified controls" (fw 1.34+): writes need a valid `hmac`.
        public var signingMode: Bool = false
        /// 16-byte key (hex-decoded 32-hex `udp_signing_key`). Required when `signingMode` is on.
        public var signingKey: [UInt8]? = nil
        /// Signatures whose `sigTs` is older than this many seconds are rejected (-32605).
        /// Real fw: 30 s accepted, 60 s rejected.
        public var maxSignatureAge: Int = 45
        /// Send `syncPilot` to the registered phoneIp when state changes.
        public var pushEnabled: Bool = true
        /// Destination port for pushes (real app listens on 38900).
        public var pushPort: Int = 38900
        /// `getModelConfig` result. nil = use the built-in table for `moduleName`, or -32601 if unknown.
        public var modelConfig: JSONObject? = nil
        /// Force `getModelConfig` to answer -32601 (fw <= 1.22 behaviour).
        public var modelConfigUnsupported: Bool = false
        /// `getUserConfig` result. nil = generic default.
        public var userConfig: JSONObject? = nil
        public var userConfigUnsupported: Bool = false
        /// Initial `getPilot` result (mac/rssi/src are filled in if missing).
        public var initialPilot: JSONObject? = nil

        public init() {}

        public init(
            host: String = "127.0.0.1", port: Int = 0, moduleName: String = "ESP01_SHRGB_03",
            fwVersion: String = "1.25.0", signingKey: [UInt8]? = nil, signingMode: Bool? = nil,
            pushEnabled: Bool = true, pushPort: Int = 38900
        ) {
            self.host = host
            self.port = port
            self.moduleName = moduleName
            self.fwVersion = fwVersion
            self.signingKey = signingKey
            self.signingMode = signingMode ?? (signingKey != nil)
            self.pushEnabled = pushEnabled
            self.pushPort = pushPort
        }
    }

    public struct Registration: Sendable, Equatable {
        public var phoneIp: String
        public var phoneMac: String
        public var registeredAt: Date
    }

    public struct ReceivedRequest: Sendable {
        public var method: String?
        public var params: JSONObject?
        public var hmac: String?
        public var from: String
        public var raw: String
    }

    struct State {
        var config: Configuration
        var pilot: JSONObject
        var registration: Registration?
        var log: [ReceivedRequest] = []
        var channel: (any Channel)?
        var pushesSent = 0
    }

    public let name: String
    public let group: any EventLoopGroup
    private let state: NIOLockedValueBox<State>

    public init(
        _ config: Configuration = Configuration(), name: String = "wiz",
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.name = name
        self.group = group
        var pilot: JSONObject = config.initialPilot ?? [
            "mac": .string(config.mac), "rssi": .int(config.rssi), "src": "", "state": false, "sceneId": 0,
            "r": 255, "g": 127, "b": 0, "c": 0, "w": 0, "dimming": 13,
        ]
        if pilot["mac"] == nil { pilot["mac"] = .string(config.mac) }
        self.state = NIOLockedValueBox(State(config: config, pilot: pilot))
    }

    // MARK: Simulator

    public func start() async throws {
        let cfg = state.withLockedValue { $0.config }
        if cfg.signingMode, cfg.signingKey?.count != 16 {
            throw SimulatorError.invalidConfiguration("signingMode needs a 16-byte signingKey")
        }
        guard state.withLockedValue({ $0.channel }) == nil else { throw SimulatorError.alreadyStarted }
        let channel = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(WiZUDPHandler(bulb: self))
                }
            }
            .bind(host: cfg.host, port: cfg.port).get()
        state.withLockedValue { $0.channel = channel }
    }

    public func stop() async throws {
        let ch = state.withLockedValue { s -> (any Channel)? in
            defer { s.channel = nil }
            return s.channel
        }
        try? await ch?.close()
    }

    public var boundPorts: [String: Int] {
        guard let p = port else { return [:] }
        return ["udp": p]
    }

    /// Bound UDP port (nil until started).
    public var port: Int? { state.withLockedValue { $0.channel?.localAddress?.port } }

    // MARK: Inspection / mutation for tests

    public var pilot: JSONObject { state.withLockedValue { $0.pilot } }
    public var registration: Registration? { state.withLockedValue { $0.registration } }
    public var receivedRequests: [ReceivedRequest] { state.withLockedValue { $0.log } }
    public var pushesSent: Int { state.withLockedValue { $0.pushesSent } }
    public var configuration: Configuration { state.withLockedValue { $0.config } }

    /// Turn "Only verified controls" on/off at runtime.
    public func setSigningMode(_ on: Bool, key: [UInt8]? = nil) {
        state.withLockedValue {
            $0.config.signingMode = on
            if let key { $0.config.signingKey = key }
        }
    }

    public func setPushEnabled(_ on: Bool) { state.withLockedValue { $0.config.pushEnabled = on } }
    public func setPushPort(_ port: Int) { state.withLockedValue { $0.config.pushPort = port } }

    /// Simulate a change made elsewhere (WiZ app, WiZmote, PIR...). Pushes syncPilot if registered.
    public func externalChange(_ params: JSONObject, src: String = "app") {
        let push = state.withLockedValue { s -> (SocketAddress, [UInt8], any Channel)? in
            let changed = Self.apply(params, to: &s.pilot, autoOn: false)
            s.pilot["src"] = .string(src)
            return changed ? Self.pushPacket(&s) : nil
        }
        if let push { send(push) }
    }

    // MARK: Protocol

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    struct Outcome {
        var replies: [[UInt8]] = []
        var push: (SocketAddress, [UInt8], any Channel)?
    }

    func process(_ bytes: [UInt8], from: SocketAddress) -> Outcome {
        state.withLockedValue { s in Self.process(bytes, from: from, state: &s) }
    }

    func send(_ push: (SocketAddress, [UInt8], any Channel)) {
        let (addr, bytes, channel) = push
        let buf = channel.allocator.buffer(bytes: bytes)
        channel.writeAndFlush(AddressedEnvelope(remoteAddress: addr, data: buf), promise: nil)
    }

    static let parseError: [UInt8] = Array(#"{"env":"pro","error":{"code":-32700,"message":"Parse error"}}"#.utf8)

    static func process(_ bytes: [UInt8], from: SocketAddress, state s: inout State) -> Outcome {
        var out = Outcome()
        let trimmed = Array(bytes.drop(while: { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }))
        let parsed = try? JSON.parseWithRawMembers(trimmed)
        let fromString = from.ipAddress ?? "\(from)"
        s.log.append(
            ReceivedRequest(
                method: parsed?.0["method"]?.stringValue, params: parsed?.0["params"]?.objectValue,
                hmac: parsed?.0["hmac"]?.stringValue, from: fromString, raw: String(decoding: bytes, as: UTF8.self)))
        if s.log.count > 500 { s.log.removeFirst(s.log.count - 500) }

        guard let (req, raw) = parsed, case .object = req, let method = req["method"]?.stringValue else {
            out.replies.append(parseError)
            return out
        }
        let cfg = s.config
        let params = req["params"]?.objectValue ?? JSONObject()

        func reply(_ body: JSONObject, key: String = "result") {
            var body = body
            var msg: JSONObject = ["method": .string(method), "env": "pro"]
            if cfg.signingMode, let k = cfg.signingKey {
                body["sigTs"] = .int(now())
                msg[key] = .object(body)
                msg["hmac"] = .string(SimCrypto.hmacSHA256Base64(body.compact.utf8.map { $0 }, key: k))
            } else {
                msg[key] = .object(body)
            }
            out.replies.append(Array(JSON.object(msg).compact.utf8))
        }
        func error(_ code: Int, _ message: String) {
            reply(["code": .int(code), "message": .string(message)], key: "error")
        }

        switch method {
        case "getPilot":
            reply(s.pilot)
        case "getSystemConfig":
            reply([
                "mac": .string(cfg.mac), "homeId": .int(cfg.homeId), "roomId": .int(cfg.roomId),
                "moduleName": .string(cfg.moduleName), "fwVersion": .string(cfg.fwVersion), "groupId": 0,
                "drvConf": [30, 1], "ewf": [255, 0, 255, 255, 0, 0, 0], "ewfHex": "ff00ffff000000", "ping": 0,
            ])
        case "getModelConfig":
            if !cfg.modelConfigUnsupported, let mc = cfg.modelConfig ?? WiZModelTable.modelConfig(for: cfg.moduleName) {
                reply(mc)
            } else {
                error(-32601, "Method not found")
            }
        case "getUserConfig":
            if cfg.userConfigUnsupported {
                error(-32601, "Method not found")
            } else {
                reply(
                    cfg.userConfig ?? [
                        "fadeIn": 450, "fadeOut": 500, "dftDim": 100, "pwmRange": [0, 100],
                        "whiteRange": [2700, 6500], "extRange": [2700, 6500], "opMode": 0, "po": false,
                    ])
            }
        case "registration":
            if params["register"]?.boolValue == true, let ip = params["phoneIp"]?.stringValue {
                s.registration = Registration(
                    phoneIp: ip, phoneMac: params["phoneMac"]?.stringValue ?? "", registeredAt: Date())
            }
            reply(["mac": .string(cfg.mac), "success": true])
        case "setPilot", "setState":
            if cfg.signingMode, let key = cfg.signingKey {
                guard let hmac = req["hmac"]?.stringValue, let sigTs = params["sigTs"]?.intValue else {
                    // Unsigned write on "Only verified controls".
                    error(-32602, "Invalid params")
                    return out
                }
                let rawParams = raw["params"] ?? []
                let expected = SimCrypto.hmacSHA256Base64(rawParams, key: key)
                let expectedCompact = SimCrypto.hmacSHA256Base64(params.compact.utf8.map { $0 }, key: key)
                guard hmac == expected || hmac == expectedCompact, now() - sigTs <= cfg.maxSignatureAge else {
                    error(-32605, "Security error")
                    return out
                }
            }
            guard req["params"]?.objectValue != nil else {
                error(-32602, "Invalid params")
                return out
            }
            var p = params
            p["sigTs"] = nil
            let changed = apply(p, to: &s.pilot, autoOn: method == "setPilot")
            if changed { s.pilot["src"] = "udp" }
            reply(["success": true])
            if changed { out.push = pushPacket(&s) }
        default:
            error(-32601, "Method not found")
        }
        return out
    }

    /// Applies setPilot params to the pilot with WiZ mode exclusivity (rgb / temp / scene).
    /// Returns true if anything changed.
    static func apply(_ params: JSONObject, to pilot: inout JSONObject, autoOn: Bool) -> Bool {
        let before = pilot
        let colorKeys = ["r", "g", "b", "c", "w"]
        let lightKeys = Set(colorKeys + ["temp", "sceneId", "dimming", "speed", "ratio"])
        if colorKeys.contains(where: { params[$0] != nil }) {
            pilot["temp"] = nil
            pilot["sceneId"] = 0
            pilot["speed"] = nil
            for k in colorKeys { pilot[k] = .int(params[k]?.intValue.map { max(0, min(255, $0)) } ?? 0) }
        } else if let t = params["temp"]?.intValue {
            for k in colorKeys { pilot[k] = nil }
            pilot["sceneId"] = 0
            pilot["speed"] = nil
            pilot["temp"] = .int(max(1000, min(10000, t)))
        } else if let scene = params["sceneId"]?.intValue {
            pilot["sceneId"] = .int(scene)
            if scene != 0 {
                for k in colorKeys { pilot[k] = nil }
                pilot["temp"] = nil
                pilot["speed"] = .int(params["speed"]?.intValue ?? pilot["speed"]?.intValue ?? 100)
            }
        }
        if let d = params["dimming"]?.intValue { pilot["dimming"] = .int(max(10, min(100, d))) }
        if let sp = params["speed"]?.intValue, pilot["sceneId"]?.intValue ?? 0 != 0 {
            pilot["speed"] = .int(max(10, min(200, sp)))
        }
        for m in params.members where !lightKeys.contains(m.key) && m.key != "state" && m.key != "src" {
            pilot[m.key] = m.value
        }
        if let st = params["state"]?.boolValue {
            pilot["state"] = .bool(st)
        } else if autoOn, params.keys.contains(where: { lightKeys.contains($0) }) {
            pilot["state"] = true
        }
        return pilot != before
    }

    static func pushPacket(_ s: inout State) -> (SocketAddress, [UInt8], any Channel)? {
        guard s.config.pushEnabled, let reg = s.registration, let ch = s.channel,
            let addr = try? SocketAddress(ipAddress: reg.phoneIp, port: s.config.pushPort)
        else { return nil }
        var params = s.pilot
        var msg: JSONObject = ["method": "syncPilot", "id": .int(s.pushesSent + 1), "env": "pro"]
        if s.config.signingMode, let k = s.config.signingKey {
            params["sigTs"] = .int(now())
            msg["params"] = .object(params)
            msg["hmac"] = .string(SimCrypto.hmacSHA256Base64(params.compact.utf8.map { $0 }, key: k))
        } else {
            msg["params"] = .object(params)
        }
        s.pushesSent += 1
        return (addr, Array(JSON.object(msg).compact.utf8), ch)
    }
}

final class WiZUDPHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let bulb: FakeWiZBulb
    init(bulb: FakeWiZBulb) { self.bulb = bulb }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let env = unwrapInboundIn(data)
        let outcome = bulb.process(Array(env.data.readableBytesView), from: env.remoteAddress)
        for r in outcome.replies {
            let buf = context.channel.allocator.buffer(bytes: r)
            context.write(wrapOutboundOut(AddressedEnvelope(remoteAddress: env.remoteAddress, data: buf)), promise: nil)
        }
        context.flush()
        if let push = outcome.push { bulb.send(push) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // UDP errors (e.g. ICMP port unreachable for a push) are not fatal for a bulb.
    }
}

/// `getModelConfig` results per moduleName (from pywizlight fake_bulb.py).
enum WiZModelTable {
    static func modelConfig(for module: String) -> JSONObject? {
        switch module {
        case "ESP01_SHRGB_03":
            return [
                "ps": 1, "pwmFreq": 1000, "pwmRange": [3, 100], "wcr": 30, "nowc": 1,
                "cctRange": [2200, 2700, 4800, 6500], "renderFactor": [171, 255, 75, 255, 43, 85, 0, 0, 0, 0],
            ]
        case "ESP20_DHRGB_01":
            return [
                "ps": 1, "pwmFreq": 2000, "pwmRange": [1, 100], "wcr": 20, "nowc": 2,
                "cctRange": [2200, 2700, 6500, 6500], "renderFactor": [255, 255, 170, 255, 0, 0, 42, 200, 255, 255],
            ]
        case "ESP05_SHDW_21":
            return [
                "ps": 1, "pwmFreq": 1000, "pwmRange": [5, 100], "wcr": 20, "nowc": 1,
                "cctRange": [2700, 2700, 2700, 2700], "renderFactor": [255, 0, 255, 255, 0, 0, 0, 0, 0, 0],
            ]
        case "ESP21_SHTW_01":
            return [
                "ps": 2, "pwmFreq": 5000, "pwmRange": [1, 100], "wcr": 20, "nowc": 1,
                "cctRange": [2700, 2700, 5000, 5000], "renderFactor": [255, 0, 255, 255, 0, 0, 0, 0, 0, 0],
                "drvIface": 0,
            ]
        case "ESP10_SOCKET_06":
            return [
                "ps": 1, "pwmFreq": 200, "pwmRange": [1, 100], "wcr": 20, "nowc": 2,
                "cctRange": [2700, 2700, 2700, 2700], "renderFactor": [255, 0, 255, 255, 0, 0, 0, 0, 0, 0],
            ]
        case "ESP20_SHRGB_01BT", "ESP25_SHRGB_01", "ESP25_SHORGB_01":
            return [
                "ps": 1, "pwmFreq": 2000, "pwmRange": [0, 100], "wcr": 20, "nowc": 2,
                "cctRange": [2200, 2700, 6500, 6500], "renderFactor": [200, 255, 255, 150, 0, 0, 40, 0, 0, 0],
                "hasAdjMinDim": 0, "hasTapSensor": 1, "pm": 0, "fanSpeed": 0,
            ]
        default:
            return nil
        }
    }
}
