import Foundation
import LIFXProvider
#if canImport(Glibc)
import Glibc
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let sockDgram = SOCK_DGRAM
#endif

private func closeFD(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

struct TestSocketError: Error, CustomStringConvertible {
    var op: String
    var code: Int32
    var description: String { "\(op) failed: errno \(code)" }
}

/// Minimal non-blocking UDP/IPv4 socket on 127.0.0.1 for tests (Linux and macOS).
/// Received datagrams are polled from a Task and published on `datagrams`.
final class TestUDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let datagrams: AsyncStream<LIFXDatagram>
    private let lock = NSLock()
    private var closed = false
    private var pump: Task<Void, Never>?

    init(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { throw TestSocketError(op: "socket", code: errno) }
        var addr = TestUDPSocket.address("127.0.0.1", requested)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let code = errno
            closeFD(fd)
            throw TestSocketError(op: "bind", code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        let (stream, continuation) = AsyncStream.makeStream(of: LIFXDatagram.self, bufferingPolicy: .bufferingNewest(1024))
        self.datagrams = stream
        pump = Task.detached { [fd] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while !Task.isCancelled {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen) }
                    }
                }
                if n > 0 {
                    let host = TestUDPSocket.hostString(from.sin_addr)
                    continuation.yield(LIFXDatagram(data: Data(buffer[0..<n]), host: host, port: UInt16(bigEndian: from.sin_port)))
                } else {
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            continuation.finish()
        }
    }

    deinit { close() }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var addr = TestUDPSocket.address(host, port)
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw TestSocketError(op: "sendto", code: errno) }
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        pump?.cancel()
        closeFD(fd)
    }

    private static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        var parts = host.split(separator: ".").compactMap { UInt32($0) }
        if parts.count != 4 { parts = [127, 0, 0, 1] }
        let raw = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
        addr.sin_addr = in_addr(s_addr: raw.bigEndian)
        return addr
    }

    private static func hostString(_ a: in_addr) -> String {
        let v = UInt32(bigEndian: a.s_addr)
        return "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}

/// `LIFXTransport` over `TestUDPSocket`, recording every datagram sent.
final class TestTransport: LIFXTransport, @unchecked Sendable {
    let socket: TestUDPSocket
    private let lock = NSLock()
    private var _sent: [(Data, String, UInt16)] = []

    init() throws { socket = try TestUDPSocket() }

    var datagrams: AsyncStream<LIFXDatagram> { socket.datagrams }

    func send(_ data: Data, to host: String, port: UInt16) async throws {
        lock.withLock { _sent.append((data, host, port)) }
        try socket.send(data, to: host, port: port)
    }

    func close() { socket.close() }

    var sentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sent.count
    }
}
