import Foundation
import LightCore
@testable import TPLinkProvider

/// Minimal TCP server on 127.0.0.1 for the fakes (Linux and macOS). Each accepted connection is
/// handed to `handler` on its own thread; the handler owns and closes the fd.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var clients: Set<Int32> = []

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let (fd, port) = try PosixSocket.listenLoopback()
        listener = fd
        self.port = port
        let thread = Thread { [self] in
            while !isStopped {
                guard let client = PosixSocket.accept(fd, timeoutMs: 50) else { continue }
                if isStopped {
                    PosixSocket.close(client)
                    break
                }
                track(client, add: true)
                Thread { [self] in
                    handler(client)
                    track(client, add: false)
                }.start()
            }
            PosixSocket.close(fd)
        }
        thread.start()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func track(_ fd: Int32, add: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if add { clients.insert(fd) } else { clients.remove(fd) }
    }

    /// Stops accepting and shuts down open connections (the port then refuses connections).
    func stop() {
        lock.lock()
        stopped = true
        let open = clients
        lock.unlock()
        for fd in open { PosixSocket.shutdownBoth(fd) }
    }

    /// A port with nothing listening (connections are refused).
    static func closedPort() throws -> UInt16 {
        let (fd, port) = try PosixSocket.listenLoopback()
        PosixSocket.close(fd)
        return port
    }
}

/// One HTTP/1.1 request as seen by the fake (no chunked bodies; URLSession sends Content-Length).
struct FakeHTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var cookies: [String: String] {
        var out: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// Reads one request from `fd`; nil when the peer closed or sent garbage.
    static func read(from fd: Int32) -> FakeHTTPRequest? {
        var buffer = [UInt8]()
        let separator: [UInt8] = [13, 10, 13, 10]
        var headerEnd: Int?
        while headerEnd == nil {
            let (n, chunk) = PosixSocket.receiveSome(fd, max: 4096)
            guard n > 0 else { return nil }
            buffer += chunk
            if buffer.count >= 4 {
                for i in 0...(buffer.count - 4) where Array(buffer[i..<i + 4]) == separator {
                    headerEnd = i
                    break
                }
            }
        }
        let end = headerEnd!
        let head = String(decoding: buffer[0..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Array(buffer[(end + 4)...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < length {
            let (n, chunk) = PosixSocket.receiveSome(fd, max: length - body.count)
            guard n > 0 else { return nil }
            body += chunk
        }
        let target = String(requestLine[1])
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for item in pathAndQuery[1].split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
            }
        }
        return FakeHTTPRequest(method: String(requestLine[0]), path: String(pathAndQuery[0]), query: query, headers: headers, body: Data(body))
    }

    /// Writes a complete response and leaves the connection to the caller.
    static func respond(_ fd: Int32, status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        let reason = status == 200 ? "OK" : (status == 403 ? "Forbidden" : "Error")
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        try? PosixSocket.sendAll(fd, Data(head.utf8) + body)
    }
}

extension NSLock {
    /// Runs `body` while holding the lock.
    func sync<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
