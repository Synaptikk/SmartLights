// Loopback test networking (Linux and macOS, no third-party dependencies): a tiny HTTP/1.1
// server with optional WebSocket upgrade, a matching blocking HTTP/WebSocket client and UDP
// sockets, all on 127.0.0.1 with ephemeral ports. Blocking socket calls run on dedicated
// `Thread`s so they never tie up the Swift concurrency pool.
//
// The same file is used by TwinklyKit and DirigeraKit tests; keep the copies identical.
import Foundation
#if canImport(Glibc)
import Glibc
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let sockStream = SOCK_STREAM
private let sockDgram = SOCK_DGRAM
#endif

struct LoopbackError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
    static func errno(_ op: String) -> LoopbackError { LoopbackError(message: "\(op) failed: errno \(Foundation.errno)") }
}

// MARK: - POSIX helpers

enum POSIX {
    static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, host, &addr.sin_addr)
        return addr
    }

    static func hostString(_ addr: in_addr) -> String {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func boundPort(_ fd: Int32) -> UInt16 {
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    static func bind(_ fd: Int32, port: UInt16) throws {
        var addr = address("127.0.0.1", port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                socketBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw LoopbackError.errno("bind") }
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: time_t(seconds), tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { socketWrite(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Reads up to `max` bytes; nil on EOF/error/timeout.
    static func read(_ fd: Int32, max: Int = 65_536) -> Data? {
        var buffer = [UInt8](repeating: 0, count: max)
        let n = buffer.withUnsafeMutableBytes { socketRead(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }
}

#if canImport(Glibc)
private func socketBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Glibc.bind(fd, a, l) }
private func socketWrite(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Glibc.send(fd, p, n, Int32(MSG_NOSIGNAL)) }
private func socketRead(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Glibc.recv(fd, p, n, 0) }
private func socketConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Glibc.connect(fd, a, l) }
private func socketShutdown(_ fd: Int32) { _ = Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
#else
private func socketBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Darwin.bind(fd, a, l) }
private func socketWrite(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Darwin.send(fd, p, n, 0) }
private func socketRead(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Darwin.recv(fd, p, n, 0) }
private func socketConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Darwin.connect(fd, a, l) }
private func socketShutdown(_ fd: Int32) { _ = Darwin.shutdown(fd, SHUT_RDWR) }
#endif

/// Owns one descriptor. Only the thread that reads it closes it (after its loop ends); other
/// threads use `shutdown` to wake it. Closing from elsewhere would let the number be reused by
/// another socket while the reader still polls it.
final class FDBox: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(_ fd: Int32) { self.fd = fd }

    var isClosed: Bool { lock.withLock { closed } }

    func shutdown() { lock.withLock { if !closed { socketShutdown(fd) } } }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            POSIX.closeFD(fd)
        }
    }

    /// Runs `body` with the descriptor while it is still open.
    @discardableResult
    func withOpen<T>(_ body: (Int32) -> T) -> T? { lock.withLock { closed ? nil : body(fd) } }
}

private func noSigPipe(_ fd: Int32) {
    #if canImport(Darwin)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

/// Runs `body` on a fresh thread and returns its result asynchronously.
func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let thread = Thread {
            do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
        }
        thread.start()
    }
}

// MARK: - HTTP message parsing

struct LoopbackRequest: Sendable {
    var method: String
    /// Path without query.
    var path: String
    var query: [String: String]
    /// Lower-cased header names.
    var headers: [String: String]
    var body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }
    var json: Any? { try? JSONSerialization.jsonObject(with: body) }
}

struct LoopbackResponse: Sendable {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data

    static func json(_ text: String, status: Int = 200) -> LoopbackResponse {
        LoopbackResponse(status: status, body: Data(text.utf8))
    }

    static func json(object: Any, status: Int = 200) -> LoopbackResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return LoopbackResponse(status: status, body: data)
    }

    static func text(_ text: String, status: Int) -> LoopbackResponse {
        LoopbackResponse(status: status, headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
    }
}

enum LoopbackReply: Sendable {
    case response(LoopbackResponse)
    /// Accepts a WebSocket upgrade; `onOpen` gets the server side of the connection.
    case webSocket(onOpen: @Sendable (WebSocketServerConnection) -> Void)
}

/// Splits `head\r\n\r\nbody`; nil until the head is complete.
private func splitHead(_ data: Data) -> (head: String, rest: Data)? {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = data.range(of: separator) else { return nil }
    let head = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
    return (head, Data(data[range.upperBound...]))
}

private func parseHeaders(_ lines: ArraySlice<Substring>) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return headers
}

private func decodeChunked(_ data: Data) -> Data? {
    var out = Data()
    var rest = data
    while true {
        guard let lineEnd = rest.range(of: Data("\r\n".utf8)) else { return nil }
        let sizeText = String(decoding: rest[rest.startIndex..<lineEnd.lowerBound], as: UTF8.self)
        guard let size = Int(sizeText.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { return nil }
        let start = lineEnd.upperBound
        if size == 0 { return out }
        guard rest.distance(from: start, to: rest.endIndex) >= size + 2 else { return nil }
        let end = rest.index(start, offsetBy: size)
        out.append(rest[start..<end])
        rest = Data(rest[rest.index(end, offsetBy: 2)...])
    }
}

// MARK: - Server

/// HTTP/1.1 server on 127.0.0.1 (one request per connection, `Connection: close`).
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (LoopbackRequest) -> LoopbackReply

    let port: UInt16
    private let listener: FDBox
    private let handler: Handler
    private let lock = NSLock()
    private var stopped = false
    private var clients: [Int32: FDBox] = [:]

    init(handler: @escaping Handler) throws {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw LoopbackError.errno("socket") }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        do {
            try POSIX.bind(fd, port: 0)
        } catch {
            POSIX.closeFD(fd)
            throw error
        }
        guard listen(fd, 64) == 0 else {
            POSIX.closeFD(fd)
            throw LoopbackError.errno("listen")
        }
        self.listener = FDBox(fd)
        self.port = POSIX.boundPort(fd)
        self.handler = handler
        let listener = self.listener
        let thread = Thread { [weak self] in
            while let server = self, server.acceptOnce() {}
            listener.close()
        }
        thread.start()
    }

    deinit { stop() }

    var baseHost: String { "127.0.0.1:\(port)" }

    func stop() {
        let open: [FDBox] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            return Array(clients.values)
        }
        listener.shutdown()
        for client in open { client.shutdown() }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Waits up to 100 ms for one connection; false once stopped.
    private func acceptOnce() -> Bool {
        guard !isStopped else { return false }
        var pfd = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 100) > 0 else { return true }
        let client = accept(listener.fd, nil, nil)
        guard client >= 0 else { return true }
        noSigPipe(client)
        let box = FDBox(client)
        lock.withLock { clients[client] = box }
        let thread = Thread { [self] in
            self.serve(client, box: box)
            _ = self.lock.withLock { self.clients.removeValue(forKey: client) }
            box.close()
        }
        thread.start()
        return true
    }

    /// Never closes `client` (the caller does once this returns).
    private func serve(_ client: Int32, box: FDBox) {
        POSIX.setTimeout(client, seconds: 5)
        var buffer = Data()
        var parsed: (head: String, rest: Data)?
        while parsed == nil {
            guard let chunk = POSIX.read(client) else { return }
            buffer.append(chunk)
            parsed = splitHead(buffer)
        }
        guard let (head, rest) = parsed else { return }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return }
        let headers = parseHeaders(lines.dropFirst())
        var body = rest
        if let length = headers["content-length"].flatMap(Int.init) {
            while body.count < length, let chunk = POSIX.read(client) { body.append(chunk) }
            body = body.prefix(length)
        } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
            while decodeChunked(body) == nil, let chunk = POSIX.read(client) { body.append(chunk) }
            body = decodeChunked(body) ?? Data()
        }
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }
        let request = LoopbackRequest(method: String(requestLine[0]), path: String(parts[0]), query: query, headers: headers, body: body)

        switch handler(request) {
        case .response(let response):
            write(response, to: client)
        case .webSocket(let onOpen):
            guard let key = headers["sec-websocket-key"] else {
                write(.text("expected websocket", status: 400), to: client)
                return
            }
            let accept = Data(SHA1.hash(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            guard POSIX.writeAll(client, Data(head.utf8)) else { return }
            POSIX.setTimeout(client, seconds: 0.2)
            let connection = WebSocketServerConnection(box: box)
            onOpen(connection)
            connection.runReadLoop { [weak self] in self?.isStopped ?? true }
        }
    }

    private func write(_ response: LoopbackResponse, to client: Int32) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        _ = POSIX.writeAll(client, Data(head.utf8) + response.body)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

/// Server side of an upgraded WebSocket (text frames only).
final class WebSocketServerConnection: @unchecked Sendable {
    private let box: FDBox
    private let lock = NSLock()
    private var closed = false

    init(box: FDBox) { self.box = box }

    var isOpen: Bool { lock.withLock { !closed } }

    /// Sends one unmasked text frame (server to client).
    @discardableResult
    func send(_ text: String) -> Bool {
        guard isOpen else { return false }
        let frame = WebSocketFrame.encode(opcode: 0x1, payload: Data(text.utf8), masked: false)
        return box.withOpen { POSIX.writeAll($0, frame) } ?? false
    }

    /// Sends a close frame and wakes the read loop; the server thread closes the descriptor.
    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        box.withOpen { _ = POSIX.writeAll($0, WebSocketFrame.encode(opcode: 0x8, payload: Data(), masked: false)) }
        box.shutdown()
    }

    /// Answers pings and notices close frames until the peer or the server goes away.
    func runReadLoop(stop: () -> Bool) {
        let fd = box.fd
        var buffer = Data()
        while isOpen, !stop() {
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&readable, 1, 100) <= 0 { continue }
            guard let chunk = POSIX.read(fd) else { break }
            buffer.append(chunk)
            while let (frame, used) = WebSocketFrame.decode(buffer) {
                buffer = Data(buffer.dropFirst(used))
                switch frame.opcode {
                case 0x8: close(); return
                case 0x9: box.withOpen { _ = POSIX.writeAll($0, WebSocketFrame.encode(opcode: 0xA, payload: frame.payload, masked: false)) }
                default: break
                }
            }
        }
        close()
    }
}

// MARK: - WebSocket framing (RFC 6455)

enum WebSocketFrame {
    struct Frame {
        var opcode: UInt8
        var payload: Data
    }

    static func encode(opcode: UInt8, payload: Data, masked: Bool) -> Data {
        var out = Data([0x80 | opcode])
        let maskBit: UInt8 = masked ? 0x80 : 0
        if payload.count < 126 {
            out.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        if masked {
            let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            out.append(contentsOf: mask)
            out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        } else {
            out.append(payload)
        }
        return out
    }

    /// Decodes one complete frame from the start of `data`; returns it and the bytes consumed.
    static func decode(_ data: Data) -> (Frame, Int)? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7F)
        var index = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            index = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
            index = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= index + 4 else { return nil }
            mask = Array(b[index..<index + 4])
            index += 4
        }
        guard b.count >= index + length else { return nil }
        var payload = Array(b[index..<index + length])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        return (Frame(opcode: opcode, payload: Data(payload)), index + length)
    }
}

// MARK: - Client

/// Blocking HTTP/1.1 client for the loopback server (stands in for URLSession on Linux).
enum LoopbackHTTPClient {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static func connect(host: String, port: UInt16, timeout: Double) throws -> Int32 {
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw LoopbackError.errno("socket") }
        noSigPipe(fd)
        POSIX.setTimeout(fd, seconds: timeout)
        var addr = POSIX.address(host, port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            POSIX.closeFD(fd)
            throw LoopbackError.errno("connect")
        }
        return fd
    }

    static func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: Double) throws -> Response {
        guard let host = url.host else { throw LoopbackError(message: "bad url \(url)") }
        let port = UInt16(url.port ?? 80)
        let fd = try connect(host: host, port: port, timeout: timeout)
        defer { POSIX.closeFD(fd) }
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?\(query)" }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        guard POSIX.writeAll(fd, Data(head.utf8) + (body ?? Data())) else { throw LoopbackError.errno("send") }
        var buffer = Data()
        while let chunk = POSIX.read(fd) { buffer.append(chunk) }
        guard let (responseHead, rest) = splitHead(buffer) else {
            throw buffer.isEmpty ? LoopbackError(message: "timed out") : LoopbackError(message: "malformed response")
        }
        let lines = responseHead.split(separator: "\r\n", omittingEmptySubsequences: false)
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw LoopbackError(message: "bad status line") }
        let responseHeaders = parseHeaders(lines.dropFirst())
        var responseBody = rest
        if let length = responseHeaders["content-length"].flatMap(Int.init) { responseBody = responseBody.prefix(length) }
        return Response(status: status, headers: responseHeaders, body: responseBody)
    }

    /// Opens a WebSocket (`ws://` URL) and streams text frames until the server closes or the
    /// stream is terminated. Throws the HTTP status if the upgrade is refused.
    static func webSocket(url: URL, headers: [String: String], timeout: Double) async throws -> (status: Int, messages: AsyncStream<String>) {
        guard let host = url.host else { throw LoopbackError(message: "bad url \(url)") }
        let port = UInt16(url.port ?? 80)
        let handshake: (Int32, Int, Data) = try await onThread {
            let fd = try connect(host: host, port: port, timeout: timeout)
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            var head = "GET \(url.path.isEmpty ? "/" : url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\n"
            head += "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            guard POSIX.writeAll(fd, Data(head.utf8)) else {
                POSIX.closeFD(fd)
                throw LoopbackError.errno("send")
            }
            var buffer = Data()
            while splitHead(buffer) == nil, let chunk = POSIX.read(fd) { buffer.append(chunk) }
            guard let (responseHead, rest) = splitHead(buffer),
                  let status = responseHead.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                POSIX.closeFD(fd)
                throw LoopbackError(message: "no handshake response")
            }
            return (fd, status, rest)
        }
        let (fd, status, leftover) = handshake
        guard status == 101 else {
            POSIX.closeFD(fd)
            return (status, AsyncStream { $0.finish() })
        }
        POSIX.setTimeout(fd, seconds: 0.1)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let cancelled = LockedFlag()
        let box = FDBox(fd)
        continuation.onTermination = { _ in
            cancelled.set()
            box.shutdown()
        }
        let thread = Thread {
            var buffer = leftover
            loop: while !cancelled.isSet {
                while let (frame, used) = WebSocketFrame.decode(buffer) {
                    buffer = Data(buffer.dropFirst(used))
                    switch frame.opcode {
                    case 0x1: continuation.yield(String(decoding: frame.payload, as: UTF8.self))
                    case 0x8: break loop
                    case 0x9: box.withOpen { _ = POSIX.writeAll($0, WebSocketFrame.encode(opcode: 0xA, payload: frame.payload, masked: true)) }
                    default: break
                    }
                }
                var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&readable, 1, 100) <= 0 { continue }
                guard let chunk = POSIX.read(fd) else { break }
                buffer.append(chunk)
            }
            box.close()
            continuation.finish()
        }
        thread.start()
        return (status, stream)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - UDP

/// UDP socket on 127.0.0.1 with a receive thread.
final class LoopbackUDPSocket: @unchecked Sendable {
    struct Packet: Sendable {
        var data: Data
        var host: String
        var port: UInt16
    }

    let port: UInt16
    private let box: FDBox
    private let lock = NSLock()
    private var stopped = false
    private var receiving = false

    init(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { throw LoopbackError.errno("socket") }
        do {
            try POSIX.bind(fd, port: requested)
        } catch {
            POSIX.closeFD(fd)
            throw error
        }
        self.box = FDBox(fd)
        self.port = POSIX.boundPort(fd)
    }

    deinit { close() }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Stops receiving; the receive thread (if any) closes the descriptor when it exits.
    func close() {
        let closeNow = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return !receiving
        }
        if closeNow { box.close() } else { box.shutdown() }
    }

    func send(_ data: Data, to host: String, port: UInt16) {
        var addr = POSIX.address(host, port)
        box.withOpen { fd in
            _ = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Calls `onPacket` for every datagram on a background thread until closed.
    func startReceiving(_ onPacket: @escaping @Sendable (Packet) -> Void) {
        let started = lock.withLock { () -> Bool in
            guard !stopped, !receiving else { return false }
            receiving = true
            return true
        }
        guard started else { return }
        let fd = box.fd
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while !self.isStopped {
                var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&readable, 1, 50) <= 0 { continue }
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen) }
                    }
                }
                if n > 0 {
                    onPacket(Packet(data: Data(buffer[0..<n]), host: POSIX.hostString(from.sin_addr), port: UInt16(bigEndian: from.sin_port)))
                }
            }
            self.box.close()
        }
        thread.start()
    }
}

// MARK: - SHA-1 (WebSocket accept key only)

enum SHA1 {
    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = b << 30 | b >> 2
                b = a
                a = temp
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    }
}
