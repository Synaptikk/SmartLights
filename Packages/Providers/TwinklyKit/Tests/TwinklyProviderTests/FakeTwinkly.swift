import Foundation
import NetKit
import TwinklyCodec
import TwinklyProvider

/// An in-process Twinkly speaking the xled REST API over loopback HTTP and answering
/// `\x01discover` on a loopback UDP port. Behaviour follows xled-docs: `/login` issues a token
/// that only works after `/verify`; a successful verify invalidates the previous token; calls
/// without a valid `X-Auth-Token` get `401 Invalid Token.`; `/gestalt` and `/fw/version` are open;
/// `/led/color` is missing (404) before firmware 2.7.1.
final class FakeTwinkly: @unchecked Sendable {
    struct State {
        var mode = "movie"
        var hue = 0
        var saturation = 0
        var value = 255
        var brightness = 100
        var brightnessMode = "enabled"
        var effectID = 0
        var effectsNumber = 15
        var validToken: String?
        var pending: [String: String] = [:]
        var logins = 0
        var log: [LoopbackRequest] = []
    }

    let mac: String
    let name: String
    let firmware: String
    private let lock = NSLock()
    private var state: State
    private var http: LoopbackHTTPServer!
    private let udp: LoopbackUDPSocket

    var httpPort: Int { Int(http.port) }
    var udpPort: UInt16 { udp.port }
    var host: String { "127.0.0.1:\(http.port)" }
    var stableID: String { TwinklyIdentifiers.normalizeMAC(mac)! }

    init(mac: String = "98:f4:ab:1c:c1:90", name: String = "Twinkly_1CC190", firmware: String = "2.8.3",
         state: State = State()) throws {
        self.mac = mac
        self.name = name
        self.firmware = firmware
        self.state = state
        self.udp = try LoopbackUDPSocket()
        self.http = try LoopbackHTTPServer { [weak self] request in
            guard let self else { return .response(.text("gone", status: 500)) }
            return .response(self.handle(request))
        }
        let udp = self.udp
        let reply = TwinklyDiscovery.makeReply(ip: "127.0.0.1", deviceID: name)!
        udp.startReceiving { packet in
            if packet.data == TwinklyDiscovery.request { udp.send(reply, to: packet.host, port: packet.port) }
        }
    }

    deinit { stop() }

    func stop() {
        http?.stop()
        udp.close()
    }

    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    func mutate(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    var requests: [LoopbackRequest] { read(\.log) }
    var logins: Int { read(\.logins) }

    /// Authenticated writes (method + path + body), for assertions.
    var writes: [String] {
        requests.filter { $0.method == "POST" && !$0.path.hasSuffix("/login") && !$0.path.hasSuffix("/verify") }
            .map { "\($0.path.replacingOccurrences(of: "/xled/v1/", with: "")) \($0.bodyText)" }
    }

    /// Another controller logged in: our token stops working.
    func invalidateToken() { mutate { $0.validToken = "other-controller" } }

    private func handle(_ request: LoopbackRequest) -> LoopbackResponse {
        lock.withLock {
            state.log.append(request)
            return route(request, &state)
        }
    }

    private func route(_ r: LoopbackRequest, _ s: inout State) -> LoopbackResponse {
        let path = r.path.replacingOccurrences(of: "/xled/v1/", with: "")
        let body = (r.json as? [String: Any]) ?? [:]
        switch (r.method, path) {
        case ("GET", "gestalt"):
            return .json(object: [
                "product_name": "Twinkly", "hardware_version": "100", "bytes_per_led": 4, "hw_id": "1cc190",
                "flash_size": 64, "led_type": 12, "product_code": "TWI190SPP", "fw_family": "G", "device_name": name,
                "uptime": "8107194", "mac": mac, "uuid": "E103C5A3-3398-4B77-AE1A-9D8998A5EB62", "max_supported_led": 1200,
                "number_of_led": 190, "led_profile": "RGBW", "frame_rate": 28.57, "movie_capacity": 992, "wire_type": 4,
                "copyright": "LEDWORKS 2018", "code": 1000,
            ])
        case ("GET", "fw/version"):
            return .json(object: ["version": firmware, "code": 1000])
        case ("POST", "login"):
            guard body["challenge"] is String else { return .json(#"{"code":1104}"#, status: 400) }
            s.logins += 1
            let token = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let response = (0..<20).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            s.pending[token] = response
            return .json(object: ["authentication_token": token, "authentication_token_expires_in": 14400,
                                  "challenge-response": response, "code": 1000])
        case ("POST", "verify"):
            guard let token = r.headers["x-auth-token"], let expected = s.pending[token],
                  body["challenge-response"] as? String == expected else { return .text("Invalid Token.", status: 401) }
            s.pending[token] = nil
            s.validToken = token
            return .json(#"{"code":1000}"#)
        default:
            break
        }

        guard let token = r.headers["x-auth-token"], token == s.validToken else { return .text("Invalid Token.", status: 401) }
        let colorSupported = (TwinklyFirmwareVersion(firmware) ?? .colorEndpoint) >= .colorEndpoint
        switch (r.method, path) {
        case ("GET", "led/mode"):
            return .json(object: ["mode": s.mode, "shop_mode": 0, "code": 1000])
        case ("POST", "led/mode"):
            guard let mode = body["mode"] as? String else { return .json(#"{"code":1105}"#) }
            s.mode = mode
            if let id = body["effect_id"] as? Int { s.effectID = id }
            return .json(#"{"code":1000}"#)
        case ("GET", "led/color") where colorSupported:
            return .json(object: ["hue": s.hue, "saturation": s.saturation, "value": s.value, "red": 0, "green": 0, "blue": 0, "code": 1000])
        case ("POST", "led/color") where colorSupported:
            guard let h = body["hue"] as? Int, let sat = body["saturation"] as? Int, let v = body["value"] as? Int,
                  (0...359).contains(h), (0...255).contains(sat), (0...255).contains(v) else { return .json(#"{"code":1101}"#) }
            (s.hue, s.saturation, s.value) = (h, sat, v)
            return .json(#"{"code":1000}"#)
        case ("GET", "led/out/brightness"):
            return .json(object: ["value": s.brightness, "mode": s.brightnessMode, "code": 1000])
        case ("POST", "led/out/brightness"):
            guard let v = body["value"] as? Int, (0...100).contains(v) else { return .json(#"{"code":1101}"#) }
            s.brightness = v
            if let mode = body["mode"] as? String { s.brightnessMode = mode }
            return .json(#"{"code":1000}"#)
        case ("GET", "led/effects"):
            return .json(object: ["effects_number": s.effectsNumber, "code": 1000])
        case ("GET", "led/effects/current"):
            return .json(object: ["effect_id": s.effectID, "code": 1000])
        case ("POST", "led/effects/current"):
            guard let id = body["effect_id"] as? Int, id >= 0, id < s.effectsNumber else { return .json(#"{"code":1101}"#) }
            s.effectID = id
            return .json(#"{"code":1000}"#)
        default:
            return .text("Resource not found.", status: 404)
        }
    }
}

/// `TwinklyTransport` over the loopback client/UDP socket (Linux and macOS).
struct LoopbackTwinklyTransport: TwinklyTransport {
    var broadcast: [String] = []
    var sweep: [String] = []

    func send(_ request: TwinklyHTTPRequest) async throws -> TwinklyHTTPResponse {
        let timeout = request.timeout.timeInterval
        do {
            let response = try await onThread {
                try LoopbackHTTPClient.send(method: request.method, url: request.url, headers: request.headers,
                                            body: request.body, timeout: timeout)
            }
            return TwinklyHTTPResponse(status: response.status, body: response.body)
        } catch let error as LoopbackError {
            throw error.message == "timed out" ? TwinklyTransportError.timedOut : TwinklyTransportError.connectionFailed(error.message)
        }
    }

    func probeUDP(_ payload: Data, destinations: [String], port: UInt16, window: Duration) -> AsyncStream<TwinklyDatagram> {
        let (stream, continuation) = AsyncStream.makeStream(of: TwinklyDatagram.self)
        guard let socket = try? LoopbackUDPSocket() else {
            continuation.finish()
            return stream
        }
        socket.startReceiving { packet in
            continuation.yield(TwinklyDatagram(data: packet.data, host: packet.host, port: packet.port))
        }
        for destination in destinations {
            let parsed = TwinklyEndpoint.parse(destination)
            socket.send(payload, to: parsed.host, port: parsed.port.map { UInt16($0) } ?? port)
        }
        let task = Task {
            try? await Task.sleep(for: window)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            socket.close()
        }
        return stream
    }

    func broadcastAddresses() -> [String] { broadcast }
    func sweepHosts() -> [String] { sweep }
}

