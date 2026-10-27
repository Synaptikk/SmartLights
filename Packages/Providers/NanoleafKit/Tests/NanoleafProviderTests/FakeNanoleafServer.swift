import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny fake Nanoleaf controller (Open API v1 subset) on POSIX sockets, for provider tests on Linux
/// and macOS. Plain HTTP/1.1 with `Connection: close`; the SSE endpoint keeps the socket open and
/// pushes events like a real controller does after each state change.
final class FakeNanoleafServer: @unchecked Sendable {
    struct Recorded: Sendable, Equatable {
        var method: String
        var path: String
        var body: String
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private(set) var port: UInt16 = 0

    // Device model (guarded by `lock`).
    private var _token: String
    private var _tokenValid = true
    private var _rejectAddUserCount: Int?
    private var _addUserAttempts = 0
    private var _requests: [Recorded] = []
    private var _eventClients: [Int32] = []
    private var _eventConnections = 0
    private var _identifyCount = 0
    var serialNo: String? = "S19124C8036"
    var name = "Shapes 4A2B"
    var on = true
    var brightness = 65
    var hue = 210
    var sat = 80
    var ct = 4000
    var colorMode = "effect"
    var select = "Northern Lights"
    var effectsList = ["Fireworks", "Flames", "Forest", "Northern Lights"]

    /// - Parameters:
    ///   - rejectAddUser: how many `POST /new` calls get 403 before a token is issued; nil = never
    ///     in pairing mode.
    init(token: String = "fakeToken0123456789abcdefABCDEF01", rejectAddUser: Int? = 0) {
        _token = token
        _rejectAddUserCount = rejectAddUser
    }

    var token: String { lock.withLock { _token } }
    var addUserAttempts: Int { lock.withLock { _addUserAttempts } }
    var requests: [Recorded] { lock.withLock { _requests } }
    var eventConnections: Int { lock.withLock { _eventConnections } }
    var openEventClients: Int { lock.withLock { _eventClients.count } }
    var identifyCount: Int { lock.withLock { _identifyCount } }
    var tokenValid: Bool { lock.withLock { _tokenValid } }

    func setPairingMode(rejectAddUser: Int?) { lock.withLock { _rejectAddUserCount = rejectAddUser; _addUserAttempts = 0 } }
    func revokeToken() { lock.withLock { _tokenValid = false } }
    func mutate(_ body: (FakeNanoleafServer) -> Void) { lock.withLock { body(self) } }

    // MARK: - Lifecycle

    func start() throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: out.sin_port)
        lock.withLock {
            listenFD = fd
            running = true
        }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.start()
    }

    func stop() {
        let (fd, clients): (Int32, [Int32]) = lock.withLock {
            running = false
            let c = _eventClients
            _eventClients = []
            let f = listenFD
            listenFD = -1
            return (f, c)
        }
        for c in clients { closeSocket(c) }
        if fd >= 0 { close(fd) }
    }

    /// Closes all open SSE connections (simulates a network drop).
    func dropEventClients() {
        let clients: [Int32] = lock.withLock {
            let c = _eventClients
            _eventClients = []
            return c
        }
        for c in clients { closeSocket(c) }
    }

    /// Pushes one SSE event to every open event stream.
    func push(id: Int, json: String) {
        let message = "id: \(id)\ndata: \(json)\n\n"
        let clients = lock.withLock { _eventClients }
        var dead: [Int32] = []
        for c in clients where !writeAll(c, Array(message.utf8)) { dead.append(c) }
        if !dead.isEmpty {
            lock.withLock { _eventClients.removeAll { dead.contains($0) } }
            for c in dead { closeSocket(c) }
        }
    }

    // MARK: - Accept / connection handling

    private func acceptLoop(_ fd: Int32) {
        while lock.withLock({ running }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            guard ready > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let thread = Thread { [self] in handle(client) }
            thread.start()
        }
    }

    private func handle(_ fd: Int32) {
        guard let request = readRequest(fd) else {
            closeSocket(fd)
            return
        }
        lock.withLock { _requests.append(Recorded(method: request.method, path: request.path, body: request.body)) }
        let reply = route(request)
        switch reply {
        case .response(let status, let body):
            _ = writeAll(fd, Array(Self.head(status: status, length: body.utf8.count).utf8) + Array(body.utf8))
            closeSocket(fd)
        case .eventStream:
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            guard writeAll(fd, Array(head.utf8)) else {
                closeSocket(fd)
                return
            }
            lock.withLock {
                _eventClients.append(fd)
                _eventConnections += 1
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var body: String
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Int?
        while headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            buffer += chunk[0..<n]
            if let r = Self.find([13, 10, 13, 10], in: buffer) { headerEnd = r }
            if buffer.count > 65536 { return nil }
        }
        let head = String(decoding: buffer[0..<headerEnd!], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        var body = Array(buffer[(headerEnd! + 4)...])
        while body.count < contentLength {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            body += chunk[0..<n]
        }
        return Request(method: String(parts[0]), path: String(parts[1]), body: String(decoding: body, as: UTF8.self))
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    private static func head(status: Int, length: Int) -> String {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 422: "Unprocessable Entity"][status] ?? "Status"
        var h = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if length > 0 || status != 204 { h += "Content-Type: application/json\r\nContent-Length: \(length)\r\n" }
        return h + "\r\n"
    }

    // MARK: - Routing

    private enum Reply {
        case response(Int, String)
        case eventStream
    }

    private func route(_ r: Request) -> Reply {
        let pathOnly = String(r.path.split(separator: "?", maxSplits: 1).first ?? "")
        if r.method == "POST", pathOnly == "/api/v1/new" {
            return lock.withLock {
                _addUserAttempts += 1
                guard let reject = _rejectAddUserCount, _addUserAttempts > reject else { return .response(403, "") }
                _tokenValid = true
                return .response(200, #"{"auth_token":"\#(_token)"}"#)
            }
        }
        let segments = pathOnly.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "api", "v1", token, rest...]
        guard segments.count >= 4, segments[1] == "api", segments[2] == "v1" else { return .response(404, "") }
        let valid = lock.withLock { _tokenValid && segments[3] == _token }
        guard valid else { return .response(401, "") }
        let rest = segments.dropFirst(4).filter { !$0.isEmpty }.joined(separator: "/")

        switch (r.method, rest) {
        case ("GET", ""):
            return .response(200, lock.withLock { infoJSON() })
        case ("DELETE", ""):
            lock.withLock { _tokenValid = false }
            return .response(204, "")
        case ("PUT", "state"):
            guard let changes = applyState(r.body) else { return .response(400, "") }
            if !changes.isEmpty { push(id: 1, json: #"{"events":[\#(changes.joined(separator: ","))]}"#) }
            return .response(204, "")
        case ("PUT", "effects"):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any],
                  let name = obj["select"] as? String else { return .response(400, "") }
            let known = lock.withLock { effectsList.contains(name) }
            guard known else { return .response(404, "") }
            lock.withLock {
                select = name
                colorMode = "effect"
            }
            push(id: 3, json: #"{"events":[{"attr":1,"value":"\#(name)"}]}"#)
            push(id: 1, json: #"{"events":[{"attr":6,"value":"effect"}]}"#)
            return .response(204, "")
        case ("GET", "effects/effectsList"):
            let list = lock.withLock { effectsList }
            return .response(200, String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self))
        case ("PUT", "identify"):
            lock.withLock { _identifyCount += 1 }
            return .response(204, "")
        case ("GET", "events"):
            return .eventStream
        default:
            return .response(404, "")
        }
    }

    /// Applies a state body; returns SSE change items.
    private func applyState(_ body: String) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        func value(_ key: String) -> Any? { (obj[key] as? [String: Any])?["value"] }
        return lock.withLock {
            var events: [String] = []
            if let v = value("on") as? Bool {
                on = v
                events.append(#"{"attr":1,"value":\#(v)}"#)
            }
            if let v = (value("brightness") as? NSNumber)?.intValue {
                brightness = v
                if (obj["on"] == nil) { on = true }
                events.append(#"{"attr":2,"value":\#(v)}"#)
            }
            if let v = (value("hue") as? NSNumber)?.intValue {
                hue = v
                colorMode = "hs"
                events.append(#"{"attr":3,"value":\#(v)}"#)
            }
            if let v = (value("sat") as? NSNumber)?.intValue {
                sat = v
                colorMode = "hs"
                events.append(#"{"attr":4,"value":\#(v)}"#)
            }
            if let v = (value("ct") as? NSNumber)?.intValue {
                ct = v
                colorMode = "ct"
                events.append(#"{"attr":5,"value":\#(v)}"#)
            }
            if !events.isEmpty { events.append(#"{"attr":6,"value":"\#(colorMode)"}"#) }
            return events
        }
    }

    /// Must be called with `lock` held.
    private func infoJSON() -> String {
        var info: [String: Any] = [
            "name": name,
            "manufacturer": "Nanoleaf",
            "firmwareVersion": "9.2.4",
            "model": "NL42",
            "effects": ["select": select, "effectsList": effectsList],
            "panelLayout": ["layout": ["numPanels": 2, "sideLength": 0, "positionData": [
                ["panelId": 1, "x": 0, "y": 0, "o": 0, "shapeType": 7],
                ["panelId": 2, "x": 100, "y": 0, "o": 0, "shapeType": 7],
            ]]],
            "state": [
                "on": ["value": on],
                "brightness": ["value": brightness, "min": 0, "max": 100],
                "hue": ["value": hue, "min": 0, "max": 360],
                "sat": ["value": sat, "min": 0, "max": 100],
                "ct": ["value": ct, "min": 1200, "max": 6500],
                "colorMode": colorMode,
            ],
        ]
        if let serialNo { info["serialNo"] = serialNo }
        return String(decoding: try! JSONSerialization.data(withJSONObject: info), as: UTF8.self)
    }

    // MARK: - Socket helpers

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func closeSocket(_ fd: Int32) {
        #if canImport(Darwin)
        _ = shutdown(fd, SHUT_RDWR)
        #else
        _ = shutdown(fd, Int32(SHUT_RDWR))
        #endif
        close(fd)
    }
}
