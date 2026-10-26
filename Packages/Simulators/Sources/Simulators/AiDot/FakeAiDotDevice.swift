// Fake AiDot (Linkind) Wi-Fi light: UDP 6666 discovery responder + TCP 10000 control server.
// Follows python-aidot device_client.py / discover.py and research/research_aidot.md §2.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Identity of a fake AiDot device; also what the fake cloud returns in `/devices`.
public struct AiDotDeviceInfo: Sendable {
    public var id: String
    public var name: String
    public var mac: String
    public var modelId: String
    public var productId: String
    /// `aesKey[0]` from the cloud; zero-padded/truncated to 16 bytes for AES-128.
    public var aesKey: String
    /// Device password from the cloud record, sent in `loginReq`.
    public var password: String
    /// userId of the owning account; only this userId may log in over TCP.
    public var ownerUserId: String
    public var houseId: String
    public var roomId: String
    public var firmwareVersion: String
    public var hardwareVersion: String
    public var supportsRGBW: Bool
    public var cctRange: ClosedRange<Int>?

    public init(
        id: String = "8a040e2233a243e7a07eb6a1b7a210a7", name: String = "Bedroom bulb", mac: String = "a4c138000001",
        modelId: String = "LK.light.A001493", productId: String = "1508573286093647874",
        aesKey: String = "0123456789abcdef", password: String = "devpass-0001", ownerUserId: String = "1840000000000000001",
        houseId: String = "h-0001", roomId: String = "r-0001", firmwareVersion: String = "1.2.18",
        hardwareVersion: String = "1.0", supportsRGBW: Bool = true, cctRange: ClosedRange<Int>? = 2700...6500
    ) {
        self.id = id
        self.name = name
        self.mac = mac
        self.modelId = modelId
        self.productId = productId
        self.aesKey = aesKey
        self.password = password
        self.ownerUserId = ownerUserId
        self.houseId = houseId
        self.roomId = roomId
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.supportsRGBW = supportsRGBW
        self.cctRange = cctRange
    }
}

public struct AiDotLightState: Sendable, Equatable {
    public var onOff: Int = 1
    public var dimming: Int = 100
    public var cct: Int = 2700
    public var rgbw: Int = AiDotConstants.packRGBW(r: 255, g: 0, b: 0, w: 0)

    public init(onOff: Int = 1, dimming: Int = 100, cct: Int = 2700, rgbw: Int = AiDotConstants.packRGBW(r: 255, g: 0, b: 0, w: 0)) {
        self.onOff = onOff
        self.dimming = dimming
        self.cct = cct
        self.rgbw = rgbw
    }

    public var attr: JSONObject {
        ["OnOff": .int(onOff), "Dimming": .int(dimming), "CCT": .int(cct), "RGBW": .int(rgbw)]
    }
}

public final class FakeAiDotDevice: Simulator {
    public struct Configuration: Sendable {
        public var info: AiDotDeviceInfo = AiDotDeviceInfo()
        public var host: String = "127.0.0.1"
        /// UDP discovery port (real: 6666). 0 = ephemeral. nil = no discovery responder.
        public var discoveryPort: Int? = 0
        /// TCP control port (real: 10000). 0 = ephemeral.
        public var tcpPort: Int = 0
        /// IP reported in the discovery response and cloud `properties.ipAddress`.
        public var advertisedIP: String = "127.0.0.1"
        public var initialState: AiDotLightState = AiDotLightState()

        public init(info: AiDotDeviceInfo = AiDotDeviceInfo(), host: String = "127.0.0.1", discoveryPort: Int? = 0, tcpPort: Int = 0) {
            self.info = info
            self.host = host
            self.discoveryPort = discoveryPort
            self.tcpPort = tcpPort
        }
    }

    public struct ReceivedMessage: Sendable {
        public var msgType: UInt16
        public var json: JSON
    }

    struct State {
        var config: Configuration
        var light: AiDotLightState
        var ascNumber = 1
        var channels: [any Channel] = []
        var udpPort: Int?
        var tcpPort: Int?
        var sessions: [ObjectIdentifier: any Channel] = [:]
        var log: [ReceivedMessage] = []
        var discoveryRequests = 0
    }

    public let name: String
    public let group: any EventLoopGroup
    private let state: NIOLockedValueBox<State>

    public init(
        _ config: Configuration = Configuration(), name: String = "aidot-device",
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.name = name
        self.group = group
        self.state = NIOLockedValueBox(State(config: config, light: config.initialState))
    }

    public var info: AiDotDeviceInfo { state.withLockedValue { $0.config.info } }
    public var advertisedIP: String { state.withLockedValue { $0.config.advertisedIP } }
    var aesKey: [UInt8] { SimCrypto.paddedKey(info.aesKey, length: 16) }

    // MARK: Simulator

    public func start() async throws {
        let cfg = state.withLockedValue { $0.config }
        guard state.withLockedValue({ $0.channels.isEmpty }) else { throw SimulatorError.alreadyStarted }
        var chans: [any Channel] = []
        var udpPort: Int?
        if let dp = cfg.discoveryPort {
            let udp = try await DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { [self] ch in
                    ch.eventLoop.makeCompletedFuture {
                        try ch.pipeline.syncOperations.addHandler(AiDotDiscoveryHandler(device: self))
                    }
                }
                .bind(host: cfg.host, port: dp).get()
            chans.append(udp)
            udpPort = udp.localAddress?.port
        }
        let tcp = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(AiDotFrameDecoder()))
                    try ch.pipeline.syncOperations.addHandler(AiDotSessionHandler(device: self))
                }
            }
            .bind(host: cfg.host, port: cfg.tcpPort).get()
        chans.append(tcp)
        let finalChans = chans
        let finalUDP = udpPort
        state.withLockedValue {
            $0.channels = finalChans
            $0.udpPort = finalUDP
            $0.tcpPort = tcp.localAddress?.port
        }
    }

    public func stop() async throws {
        let (chans, sessions) = state.withLockedValue { s -> ([any Channel], [any Channel]) in
            defer {
                s.channels = []
                s.sessions = [:]
                s.udpPort = nil
                s.tcpPort = nil
            }
            return (s.channels, Array(s.sessions.values))
        }
        await closeAll(sessions)
        await closeAll(chans)
    }

    public var boundPorts: [String: Int] {
        state.withLockedValue { s in
            var d: [String: Int] = [:]
            if let p = s.udpPort { d["udp"] = p }
            if let p = s.tcpPort { d["tcp"] = p }
            return d
        }
    }

    public var discoveryPort: Int? { state.withLockedValue { $0.udpPort } }
    public var tcpPort: Int? { state.withLockedValue { $0.tcpPort } }

    // MARK: Test controls

    public var lightState: AiDotLightState { state.withLockedValue { $0.light } }
    public var ascNumber: Int { state.withLockedValue { $0.ascNumber } }
    public var loggedInSessionCount: Int { state.withLockedValue { $0.sessions.count } }
    public var receivedMessages: [ReceivedMessage] { state.withLockedValue { $0.log } }
    public var discoveryRequestCount: Int { state.withLockedValue { $0.discoveryRequests } }

    /// Simulate a change from the AiDot app / wall switch; pushes a status frame to logged-in sessions.
    public func externalChange(_ attr: JSONObject) {
        let pushes = state.withLockedValue { s -> [(any Channel, AiDotFrame)] in
            guard Self.apply(attr, to: &s) else { return [] }
            return Self.pushFrames(&s, key: SimCrypto.paddedKey(s.config.info.aesKey, length: 16))
        }
        send(pushes)
    }

    /// Drop every TCP session (simulates Wi-Fi blip / device reboot).
    public func disconnectAll() {
        let sessions = state.withLockedValue { s -> [any Channel] in
            defer { s.sessions = [:] }
            return Array(s.sessions.values)
        }
        for c in sessions { c.close(promise: nil) }
    }

    // MARK: Protocol

    static func ms() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func discoveryReply(to datagram: [UInt8]) -> [UInt8]? {
        guard let plain = try? SimCrypto.aesECBDecrypt(datagram, key: SimCrypto.aidotDiscoveryKey),
            let req = try? JSON.parse(plain), req["method"]?.stringValue == "devDiscoveryReq"
        else { return nil }
        let (info, ip) = state.withLockedValue { s -> (AiDotDeviceInfo, String) in
            s.discoveryRequests += 1
            return (s.config.info, s.config.advertisedIP)
        }
        let now = Self.ms()
        let resp: JSON = [
            "protocolVer": "2.0.0",
            "service": "device",
            "method": "devDiscoveryRsp",
            "seq": req["seq"] ?? .string(String(now)),
            "srcAddr": .string(info.id),
            "tst": .int(now),
            "ack": ["code": 200, "tst": .string(String(now))],
            "payload": [
                "ip": .string(ip), "mac": .string(info.mac), "devId": .string(info.id),
                "productModel": .string(info.modelId), "bindFlag": 1, "conMode": 0, "lanMode": 1, "wifiMode": 1,
                "wifiBand": 0, "version": 2, "extends": ["srvHost": "prod-us-mqtt.arnoo.com"],
            ],
        ]
        return try? SimCrypto.aesECBEncrypt(Array(resp.compact.utf8), key: SimCrypto.aidotDiscoveryKey)
    }

    struct SessionOutcome {
        var replies: [AiDotFrame] = []
        var pushes: [(any Channel, AiDotFrame)] = []
        var close = false
    }

    func handle(frame: AiDotFrame, session: AiDotSessionHandler, channel: any Channel) -> SessionOutcome {
        let key = aesKey
        var out = SessionOutcome()
        guard frame.magic == AiDotFrame.magic, let req = try? frame.decryptedJSON(key: key) else {
            out.close = true
            return out
        }
        let method = req["method"]?.stringValue ?? ""
        let seq = req["seq"] ?? "0"
        let payload = req["payload"]?.objectValue ?? JSONObject()

        state.withLockedValue { s in
            s.log.append(ReceivedMessage(msgType: frame.msgType, json: req))
            if s.log.count > 500 { s.log.removeFirst(s.log.count - 500) }
            let info = s.config.info

            func reply(_ method: String, code: Int, payload: JSONObject, msgType: UInt16 = 1) {
                let now = Self.ms()
                let msg: JSON = [
                    "service": .string(req["service"]?.stringValue ?? "device"), "method": .string(method), "seq": seq,
                    "srcAddr": .string(info.id), "deviceId": .string(info.id), "tst": .int(now),
                    "ack": ["code": .int(code), "tst": .string(String(now))], "payload": .object(payload),
                ]
                if let f = try? AiDotFrame.encrypted(msg, msgType: msgType, key: key) { out.replies.append(f) }
            }

            if frame.msgType == 2 || req["service"]?.stringValue == "test" || method == "pingreq" {
                let msg: JSON = [
                    "service": "test", "method": "pingresp", "seq": seq, "srcAddr": .string(info.id), "payload": [:],
                ]
                if let f = try? AiDotFrame.encrypted(msg, msgType: 2, key: key) { out.replies.append(f) }
                return
            }

            switch method {
            case "loginReq":
                let userId = payload["userId"]?.stringValue ?? req["srcAddr"]?.stringValue
                let password = payload["password"]?.stringValue
                if userId != info.ownerUserId {
                    session.loggedIn = false
                    reply("loginResp", code: 403, payload: ["ascNumber": .int(s.ascNumber)])
                } else if password != info.password {
                    session.loggedIn = false
                    reply("loginResp", code: 401, payload: ["ascNumber": .int(s.ascNumber)])
                } else {
                    session.loggedIn = true
                    s.sessions[ObjectIdentifier(channel)] = channel
                    reply("loginResp", code: 200, payload: ["devId": .string(info.id), "ascNumber": .int(s.ascNumber)])
                }
            case "setDevAttrReq":
                guard session.loggedIn else {
                    reply("setDevAttrResp", code: 401, payload: [:])
                    return
                }
                guard let attr = payload["attr"]?.objectValue, Self.validate(attr) else {
                    reply("setDevAttrResp", code: 400, payload: ["devId": .string(info.id), "ascNumber": .int(s.ascNumber)])
                    return
                }
                let changed = Self.apply(attr, to: &s)
                s.ascNumber += 1
                reply(
                    "setDevAttrResp", code: 200,
                    payload: ["devId": .string(info.id), "ascNumber": .int(s.ascNumber), "attr": .object(attr)])
                if changed { out.pushes = Self.pushFrames(&s, key: key) }
            case "getDevAttrReq":
                guard session.loggedIn else {
                    reply("getDevAttrResp", code: 401, payload: [:])
                    return
                }
                let full = s.light.attr
                var attr = JSONObject()
                let wanted = payload["attr"]?.arrayValue?.compactMap(\.stringValue)
                    ?? payload["attr"]?.objectValue?.keys ?? []
                if wanted.isEmpty {
                    attr = full
                } else {
                    for k in wanted { attr[k] = full[k] }
                }
                reply(
                    "getDevAttrResp", code: 200,
                    payload: ["devId": .string(info.id), "ascNumber": .int(s.ascNumber), "attr": .object(attr)])
            default:
                reply(method.isEmpty ? "unknownResp" : method.replacingOccurrences(of: "Req", with: "Resp"), code: 404, payload: [:])
            }
        }
        return out
    }

    func sessionClosed(_ channel: any Channel) {
        _ = state.withLockedValue { $0.sessions.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    func send(_ pushes: [(any Channel, AiDotFrame)]) {
        for (ch, f) in pushes {
            ch.writeAndFlush(ch.allocator.buffer(bytes: f.encoded()), promise: nil)
        }
    }

    static func validate(_ attr: JSONObject) -> Bool {
        for m in attr.members {
            switch m.key {
            case "OnOff": guard let v = m.value.intValue, v == 0 || v == 1 else { return false }
            case "Dimming": guard let v = m.value.intValue, (0...100).contains(v) else { return false }
            case "CCT": guard let v = m.value.intValue, (1000...10000).contains(v) else { return false }
            case "RGBW": guard let v = m.value.intValue, (Int(Int32.min)...Int(UInt32.max)).contains(v) else { return false }
            default: continue
            }
        }
        return true
    }

    static func apply(_ attr: JSONObject, to s: inout State) -> Bool {
        let before = s.light
        if let v = attr["OnOff"]?.intValue { s.light.onOff = v == 0 ? 0 : 1 }
        if let v = attr["Dimming"]?.intValue { s.light.dimming = max(0, min(100, v)) }
        if let v = attr["CCT"]?.intValue { s.light.cct = v }
        if let v = attr["RGBW"]?.intValue { s.light.rgbw = Int(Int32(truncatingIfNeeded: v)) }
        return s.light != before
    }

    static func pushFrames(_ s: inout State, key: [UInt8]) -> [(any Channel, AiDotFrame)] {
        let info = s.config.info
        let now = ms()
        let msg: JSON = [
            "service": "device", "method": "devAttrNotify", "seq": .string(String(now % 1_000_000_000)),
            "srcAddr": .string(info.id), "deviceId": .string(info.id), "tst": .int(now),
            "payload": ["devId": .string(info.id), "ascNumber": .int(s.ascNumber), "attr": .object(s.light.attr)],
        ]
        guard let f = try? AiDotFrame.encrypted(msg, msgType: 1, key: key) else { return [] }
        return s.sessions.values.map { ($0, f) }
    }
}

final class AiDotDiscoveryHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let device: FakeAiDotDevice
    init(device: FakeAiDotDevice) { self.device = device }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let env = unwrapInboundIn(data)
        guard let reply = device.discoveryReply(to: Array(env.data.readableBytesView)) else { return }
        let buf = context.channel.allocator.buffer(bytes: reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: env.remoteAddress, data: buf)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}

final class AiDotSessionHandler: ChannelInboundHandler {
    typealias InboundIn = AiDotFrame
    typealias OutboundOut = ByteBuffer

    let device: FakeAiDotDevice
    var loggedIn = false
    init(device: FakeAiDotDevice) { self.device = device }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let out = device.handle(frame: frame, session: self, channel: context.channel)
        for r in out.replies {
            context.write(wrapOutboundOut(context.channel.allocator.buffer(bytes: r.encoded())), promise: nil)
        }
        context.flush()
        if out.close {
            context.close(promise: nil)
            return
        }
        device.send(out.pushes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        device.sessionClosed(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
