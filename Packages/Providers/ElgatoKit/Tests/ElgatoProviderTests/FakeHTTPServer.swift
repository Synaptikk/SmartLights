import Foundation
#if canImport(Glibc)
import Glibc
private let sockStream = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let sockStream = SOCK_STREAM
#endif

private func closeFD(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

private func sendAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            #if canImport(Glibc)
            let n = Glibc.send(fd, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
            #else
            let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
            #endif
            if n <= 0 { return }
            offset += n
        }
    }
}

struct FakeServerError: Error, CustomStringConvertible {
    var op: String
    var code: Int32
    var description: String { "\(op) failed: errno \(code)" }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 for provider tests (Linux and macOS, no dependencies).
/// One connection at a time, one request per connection, always answers `Connection: close`.
/// The handler returns nil to drop the connection without an answer (a firmware reset).
/// Call `stop()` when done (the accept thread keeps the server alive until then).
final class FakeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Lower-cased header names.
        var headers: [String: String]
        var body: Data

        var bodyJSON: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    struct Response: Sendable {
        var status: Int
        var body: Data

        static func json(_ text: String, status: Int = 200) -> Response { Response(status: status, body: Data(text.utf8)) }
        static func json(object: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        static let notFound = Response(status: 404, body: Data("Not Found".utf8))
    }

    typealias Handler = @Sendable (Request) -> Response?

    let port: UInt16
    private let fd: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var stopped = false
    private var _requests: [Request] = []
    private var thread: Thread?

    init(handler: @escaping Handler) throws {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw FakeServerError(op: "socket", code: errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else {
            let code = errno
            closeFD(fd)
            throw FakeServerError(op: "bind/listen", code: code)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        self.handler = handler
        let thread = Thread { self.acceptLoop() }
        self.thread = thread
        thread.start()
    }

    var hostSpec: String { "127.0.0.1:\(port)" }

    var requests: [Request] { lock.withLock { _requests } }

    func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    /// Stops accepting; the accept thread closes the listening socket within 50 ms.
    func stop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        defer { closeFD(fd) }
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { closeFD(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard let request = readRequest(client) else { return }
        lock.withLock { _requests.append(request) }
        guard !isStopped, let response = handler(request) else { return }
        let reason = response.status == 200 ? "OK" : response.status == 404 ? "Not Found" : "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        sendAll(client, Data(head.utf8) + response.body)
    }

    private func readRequest(_ client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: separator)
            if buffer.count > 1 << 20 { return nil }
        }
        guard let end = headerEnd else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buffer[end.upperBound...])
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        while body.count < length {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return Request(method: String(requestLine[0]), path: path, headers: headers, body: body.prefix(length))
    }
}
