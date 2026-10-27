import Foundation
#if canImport(Glibc)
import Glibc
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let sockDgram = SOCK_DGRAM
private let sockStream = SOCK_STREAM
#endif

/// Minimal POSIX sockets for the in-package fakes (Linux and Apple). Loopback only.
struct TestSocketError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32
    var description: String { "\(operation) failed (errno \(code))" }
}

private func sysClose(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

private func makeAddress(_ host: String, _ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    _ = inet_pton(AF_INET, host, &address.sin_addr)
    return address
}

private func hostString(_ address: sockaddr_in) -> String {
    var addr = address.sin_addr
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func boundPort(_ fd: Int32) -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

private func bindSocket(_ fd: Int32, host: String, port: UInt16) throws {
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = makeAddress(host, port)
    let rc = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else {
        let code = errno
        sysClose(fd)
        throw TestSocketError(operation: "bind", code: code)
    }
}

/// Waits up to `timeoutMs` for `fd` to become readable.
private func waitReadable(_ fd: Int32, timeoutMs: Int32) -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&pfd, 1, timeoutMs) > 0 && (pfd.revents & Int16(POLLIN)) != 0
}

/// Simple lock-protected value.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    var current: Value { withLock { $0 } }
}

/// UDP socket with a background reader thread.
final class TestUDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let running = Locked(true)
    private let finished = Locked(false)

    init(host: String = "127.0.0.1", port: UInt16 = 0) throws {
        let fd = socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { throw TestSocketError(operation: "socket", code: errno) }
        try bindSocket(fd, host: host, port: port)
        self.fd = fd
        self.port = boundPort(fd)
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var address = makeAddress(host, port)
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw TestSocketError(operation: "sendto", code: errno) }
    }

    /// Starts a reader thread delivering each datagram with its sender host/port.
    func startReceiving(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        let fd = self.fd
        let running = self.running
        let finished = self.finished
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while running.current {
                guard waitReadable(fd, timeoutMs: 50) else { continue }
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                        }
                    }
                }
                if count > 0 {
                    handler(Data(buffer[0..<count]), hostString(from), UInt16(bigEndian: from.sin_port))
                }
            }
            sysClose(fd)
            finished.withLock { $0 = true }
        }
        thread.start()
    }

    func close() {
        running.withLock { $0 = false }
    }
}

/// Tiny HTTP/1.1 server (one request per connection, `Connection: close`).
final class TestHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    let port: UInt16
    private let fd: Int32
    private let running = Locked(true)

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw TestSocketError(operation: "socket", code: errno) }
        try bindSocket(fd, host: "127.0.0.1", port: 0)
        guard listen(fd, 16) == 0 else { throw TestSocketError(operation: "listen", code: errno) }
        self.fd = fd
        self.port = boundPort(fd)
        let running = self.running
        let thread = Thread {
            while running.current {
                guard waitReadable(fd, timeoutMs: 50) else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                TestHTTPServer.serve(client, handler: handler)
            }
            sysClose(fd)
        }
        thread.start()
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        running.withLock { $0 = false }
    }

    private static func serve(_ client: Int32, handler: (Request) -> Response) {
        defer { sysClose(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var request: Request?
        let separator = Data("\r\n\r\n".utf8)
        while request == nil {
            guard waitReadable(client, timeoutMs: 2_000) else { return }
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { return }
            data.append(contentsOf: buffer[0..<n])
            guard let range = data.range(of: separator) else { continue }
            let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
            let bodyStart = range.upperBound
            if data.count - bodyStart < length { continue }
            request = Request(
                method: requestLine.count > 0 ? String(requestLine[0]) : "",
                path: requestLine.count > 1 ? String(requestLine[1]) : "",
                headers: headers,
                body: Data(data[bodyStart..<(bodyStart + length)])
            )
        }
        guard let request else { return }
        let response = handler(request)
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let out = Data(head.utf8) + response.body
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags: Int32 = 0
        #endif
        _ = out.withUnsafeBytes { raw in send(client, raw.baseAddress, raw.count, flags) }
    }
}
