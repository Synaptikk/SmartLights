import Foundation
import TuyaCodec
#if canImport(Glibc)
import Glibc
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
private let noSignal = Int32(MSG_NOSIGNAL)
#elseif canImport(Darwin)
import Darwin
private let sockStream = SOCK_STREAM
private let sockDgram = SOCK_DGRAM
private let noSignal: Int32 = 0
#endif

/// An in-process Tuya Wi-Fi bulb (type B dps 20-24) on 127.0.0.1 speaking the LAN protocol over real
/// TCP, built on `TuyaSessionCodec(role: .device)`. Like real devices it serves **one** client at a time
/// (further connections are closed at once), closes the connection on frames it cannot decode (wrong
/// key, wrong protocol version), negotiates the 3.4/3.5 session key, answers `DP_QUERY`/`DP_QUERY_NEW`,
/// acknowledges `CONTROL`/`CONTROL_NEW` and pushes `STATUS` with the changed dps, and answers heartbeats.
final class FakeTuyaDevice: @unchecked Sendable {
    struct State {
        var dps: [String: TuyaJSON]
        /// Decoded client requests, in order.
        var requests: [TuyaResponse] = []
        var acceptedConnections = 0
        /// Connections refused because a client was already connected.
        var rejectedConnections = 0
        /// Connections closed because a frame could not be decoded / handshake failed.
        var droppedForBadFrames = 0
        var heartbeats = 0
        var clientConnected = false
        /// Do not answer heartbeats (tests the missed-heartbeat reset).
        var ignoreHeartbeats = false
        /// Answer DP_QUERY with "json obj data unvalid" (device22 behaviour).
        var device22 = false
    }

    let id: String
    let localKey: String
    let version: TuyaVersion
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var state: State
    private var stopped = false
    private var client: Client?

    init(id: String = "bf8d3e7a1c2b4f5e6a7b", localKey: String = "a1B2c3D4e5F6g7H8", version: TuyaVersion,
         dps: [String: TuyaJSON] = ["20": true, "21": "white", "22": 1000, "23": 0, "24": "000003e803e8", "25": "000e0d0000000000000000c80000", "26": 0]) throws {
        self.id = id
        self.localKey = localKey
        self.version = version
        state = State(dps: dps)
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw FakeSocketError(op: "socket", code: errno) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = fakeAddress("127.0.0.1", 0)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 8) == 0 else {
            let code = errno
            closeFD(fd)
            throw FakeSocketError(op: "bind/listen", code: code)
        }
        listenFD = fd
        port = boundPort(fd)
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    deinit { stop() }

    func stop() {
        let c: Client? = lock.withLock {
            stopped = true
            return client
        }
        c?.close()
    }

    func with<R>(_ body: (inout State) -> R) -> R { lock.withLock { body(&state) } }
    var snapshot: State { with { $0 } }

    /// Requests of one command.
    func requests(_ command: TuyaCommand) -> [TuyaResponse] { snapshot.requests.filter { $0.command == command.rawValue } }

    /// An external change (wall switch, Smart Life): updates dps and pushes STATUS to the client.
    func externalChange(_ dps: [String: TuyaJSON]) {
        let c: Client? = lock.withLock {
            state.dps.merge(dps) { _, n in n }
            return client
        }
        c?.pushStatus(dps)
    }

    /// Drops the current client (Wi-Fi hiccup, device reboot).
    func disconnectClient() {
        lock.withLock { client }?.close()
    }

    // MARK: - Server

    private func acceptLoop() {
        defer { closeFD(listenFD) }
        while !lock.withLock({ stopped }) {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }
            let accepted: Client? = lock.withLock {
                if client != nil || stopped {
                    state.rejectedConnections += 1
                    return nil
                }
                state.acceptedConnections += 1
                state.clientConnected = true
                let c = Client(fd: fd, device: self)
                client = c
                return c
            }
            guard let accepted else {
                closeFD(fd)
                continue
            }
            Thread { accepted.run() }.start()
        }
    }

    fileprivate func clientEnded(_ c: Client) {
        lock.withLock {
            if client === c {
                client = nil
                state.clientConnected = false
            }
        }
    }

    fileprivate var isStopped: Bool { lock.withLock { stopped } }

    // MARK: - Protocol

    final class Client: @unchecked Sendable {
        let fd: Int32
        let device: FakeTuyaDevice
        private let lock = NSLock()
        private var codec: TuyaSessionCodec
        private var decoder = TuyaFrameDecoder()
        private var closed = false
        private var deviceSeq: UInt32 = 100

        init(fd: Int32, device: FakeTuyaDevice) {
            self.fd = fd
            self.device = device
            codec = try! TuyaSessionCodec(version: device.version, deviceId: device.id, localKey: device.localKey, role: .device)
        }

        func close() {
            let wasClosed = lock.withLock { () -> Bool in
                defer { closed = true }
                return closed
            }
            if !wasClosed { _ = shutdown(fd, Int32(SHUT_RDWR)) }
        }

        func run() {
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var tv = timeval(tv_sec: 0, tv_usec: 50_000)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            loop: while !device.isStopped && !lock.withLock({ closed }) {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n == 0 { break }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    break
                }
                let frames: [[UInt8]]
                do { frames = try decoder.append(buffer[0..<n]) } catch { break }
                for frame in frames where !handle(frame) {
                    device.with { $0.droppedForBadFrames += 1 }
                    break loop
                }
            }
            close()
            closeFD(fd)
            device.clientEnded(self)
        }

        /// Returns false to drop the connection.
        private func handle(_ frame: [UInt8]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if codec.needsNegotiation {
                guard let header = try? TuyaFrame.parseHeader(frame, maxPayload: .max) else { return false }
                switch TuyaCommand(rawValue: header.command) {
                case .sessKeyNegStart?:
                    guard let reply = try? codec.deviceNegotiationResponse(to: frame, remoteNonce: TuyaCrypto.randomNonce(),
                                                                           seqno: nextSeq()) else { return false }
                    return write(reply)
                case .sessKeyNegFinish?:
                    return (try? codec.deviceNegotiationFinish(frame)) != nil
                default:
                    return false
                }
            }
            guard let request = try? codec.decode(frame) else { return false }
            device.with { $0.requests.append(request) }
            let now = Int(Date().timeIntervalSince1970)
            switch request.tuyaCommand {
            case .dpQuery?, .dpQueryNew?:
                if device.snapshot.device22 {
                    return send(command: request.command, json: nil, raw: Array("json obj data unvalid".utf8))
                }
                return send(command: request.command, json: ["devId": .string(device.id), "dps": dpsJSON(nil), "t": .int(now)])
            case .controlNew? where request.json?["dps"] != nil && request.json?["data"] == nil:
                // device22 status query: CONTROL_NEW listing the wanted dps with null values.
                let wanted = request.dps.map { Array($0.keys) }
                return send(command: request.command, json: ["devId": .string(device.id), "dps": dpsJSON(wanted), "t": .int(now)])
            case .control?, .controlNew?:
                let changes = request.dps ?? [:]
                device.with { $0.dps.merge(changes) { _, n in n } }
                guard send(command: request.command, json: nil) else { return false }
                return sendStatus(changes)
            case .heartBeat?:
                let ignore = device.with { s -> Bool in
                    s.heartbeats += 1
                    return s.ignoreHeartbeats
                }
                return ignore ? true : send(command: request.command, json: nil)
            default:
                return send(command: request.command, json: nil)
            }
        }

        func pushStatus(_ dps: [String: TuyaJSON]) {
            lock.lock()
            defer { lock.unlock() }
            _ = sendStatus(dps)
        }

        private func sendStatus(_ dps: [String: TuyaJSON]) -> Bool {
            let now = Int(Date().timeIntervalSince1970)
            let body: TuyaJSON = codec.version.negotiatesSessionKey
                ? ["protocol": 4, "t": .int(now), "data": ["dps": orderedDPS(dps)]]
                : ["devId": .string(device.id), "dps": orderedDPS(dps), "t": .int(now)]
            return send(command: TuyaCommand.status.rawValue, json: body)
        }

        private func dpsJSON(_ only: [String]?) -> TuyaJSON {
            let all = device.snapshot.dps
            let selected = only.map { keys in all.filter { keys.contains($0.key) } } ?? all
            return orderedDPS(selected)
        }

        private func send(command: UInt32, json: TuyaJSON?, raw: [UInt8]? = nil) -> Bool {
            let payload = raw ?? json.map { Array($0.compactString().utf8) } ?? []
            guard let frame = try? codec.encode(command: command, payload: payload, seqnoOverride: nextSeq()) else { return false }
            return write(frame)
        }

        private func nextSeq() -> UInt32 {
            deviceSeq += 1
            return deviceSeq
        }

        private func write(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { sendBytes(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// dps as a JSON object in numeric key order.
func orderedDPS(_ dps: [String: TuyaJSON]) -> TuyaJSON {
    .object(dps.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { ($0, dps[$0]!) })
}

/// Sends one UDP datagram to 127.0.0.1:`port` (device announcements).
func sendUDP(_ bytes: [UInt8], port: UInt16) {
    let fd = socket(AF_INET, sockDgram, 0)
    guard fd >= 0 else { return }
    defer { closeFD(fd) }
    var addr = fakeAddress("127.0.0.1", port)
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

/// A currently free UDP port on 127.0.0.1.
func freeUDPPort() -> UInt16 {
    let fd = socket(AF_INET, sockDgram, 0)
    defer { closeFD(fd) }
    var addr = fakeAddress("127.0.0.1", 0)
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return boundPort(fd)
}

struct FakeSocketError: Error, CustomStringConvertible {
    var op: String
    var code: Int32
    var description: String { "\(op) failed: errno \(code)" }
}

private func fakeAddress(_ host: String, _ port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    #if canImport(Darwin)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, host, &addr.sin_addr)
    return addr
}

private func boundPort(_ fd: Int32) -> UInt16 {
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return UInt16(bigEndian: bound.sin_port)
}

private func closeFD(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

private func sendBytes(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int {
    #if canImport(Glibc)
    Glibc.send(fd, p, n, noSignal)
    #else
    Darwin.send(fd, p, n, noSignal)
    #endif
}
