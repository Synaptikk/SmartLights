#if !canImport(Network) && canImport(Glibc)
import AiDotCodec
import Foundation
import Glibc
import LightCore
import Synchronization

// Minimal blocking-socket transport for Linux (tests in the swift:6.1 container, server builds).
// Blocking calls run on dedicated `Thread`s, never on the Swift concurrency pool.

enum Posix {
    static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        let h = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { throw LightCoreError.transport("not an IPv4 address: \(host)") }
        return addr
    }

    static func hostString(_ addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, _ duration: Duration) {
        let s = max(duration.seconds, 0.001)
        var tv = timeval(tv_sec: Int(s), tv_usec: Int((s - Double(Int(s))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func withSockaddr<R>(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    /// Runs `body` on a new thread and returns its result.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> Result<T, any Error>) async throws -> T {
        let gate = OnceGate<T>()
        let thread = Thread { gate.resume(body()) }
        thread.start()
        return try await gate.wait()
    }
}

struct PosixAiDotTCPConnector: AiDotTCPConnector {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any AiDotTCPConnection {
        let address = try Posix.address(host, port: port)
        let fd: Int32 = try await Posix.onThread {
            var addr = address
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard fd >= 0 else { return .failure(LightCoreError.transport("socket() errno \(errno)")) }
            Posix.setTimeout(fd, SO_SNDTIMEO, timeout)
            var one: Int32 = 1
            _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let rc = Posix.withSockaddr(&addr) { Glibc.connect(fd, $0, $1) }
            guard rc == 0 else {
                let e = errno
                Glibc.close(fd)
                return .failure(LightCoreError.unreachable("\(host):\(port) connect errno \(e)"))
            }
            return .success(fd)
        }
        let connection = PosixTCPConnection(fd: fd)
        connection.startReader()
        return connection
    }
}

final class PosixTCPConnection: AiDotTCPConnection, Sendable {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let fd: Int32
    private let closed = Mutex(false)

    init(fd: Int32) {
        self.fd = fd
        (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func startReader() {
        let fd = fd
        let continuation = continuation
        Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n > 0 {
                    continuation.yield(Data(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
            Glibc.close(fd)
        }.start()
    }

    func send(_ data: Data) async throws {
        guard !closed.withLock({ $0 }) else { throw LightCoreError.transport("connection closed") }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw LightCoreError.transport("send errno \(errno)")
            }
            offset += n
        }
    }

    func close() {
        let wasClosed = closed.withLock { c -> Bool in
            defer { c = true }
            return c
        }
        guard !wasClosed else { return }
        _ = shutdown(fd, Int32(SHUT_RDWR)) // wakes the reader, which closes the fd
        continuation.finish()
    }
}

struct PosixAiDotDatagramTransport: AiDotDatagramTransport {
    func broadcast(_ payload: Data, port: UInt16, listen: Duration) -> AsyncStream<AiDotDatagramReply> {
        AsyncStream { continuation in
            Thread {
                let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
                guard fd >= 0 else { continuation.finish(); return }
                defer { Glibc.close(fd) }
                var one: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
                Posix.setTimeout(fd, SO_RCVTIMEO, .milliseconds(200))
                guard var target = try? Posix.address("255.255.255.255", port: port) else { continuation.finish(); return }
                let bytes = [UInt8](payload)
                _ = Posix.withSockaddr(&target) { a, l in bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, a, l) } }
                let deadline = Date().addingTimeInterval(listen.seconds)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while Date() < deadline {
                    var from = sockaddr_in()
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = buffer.withUnsafeMutableBytes { raw in
                        withUnsafeMutablePointer(to: &from) { p in
                            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &len) }
                        }
                    }
                    if n > 0 { continuation.yield(AiDotDatagramReply(data: Data(buffer[0..<n]), host: Posix.hostString(from))) }
                }
                continuation.finish()
            }.start()
        }
    }

    func request(_ payload: Data, host: String, port: UInt16, timeout: Duration) async -> AiDotDatagramReply? {
        guard let address = try? Posix.address(host, port: port) else { return nil }
        return try? await Posix.onThread {
            var target = address
            let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            guard fd >= 0 else { return .failure(LightCoreError.transport("socket")) }
            defer { Glibc.close(fd) }
            Posix.setTimeout(fd, SO_RCVTIMEO, timeout)
            let bytes = [UInt8](payload)
            let sent = Posix.withSockaddr(&target) { a, l in bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, a, l) } }
            guard sent >= 0 else { return .failure(LightCoreError.transport("sendto")) }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return .failure(LightCoreError.timeout) }
            return .success(AiDotDatagramReply(data: Data(buffer[0..<n]), host: host))
        }
    }

    func sweepHosts() -> [String] { [] }
}
#endif
