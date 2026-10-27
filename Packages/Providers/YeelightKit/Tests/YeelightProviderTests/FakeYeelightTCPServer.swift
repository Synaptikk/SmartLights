import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import YeelightCodec
@testable import YeelightProvider

// BSD-socket helpers at file scope (so `connect`/`close`/`send` resolve to the C functions).

private func sysTCPSocket() -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd >= 0 {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    return fd
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func sysLoopback(port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    #if canImport(Darwin)
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    return a
}

private func sysBind(_ fd: Int32, port: UInt16) -> Int32 {
    var a = sysLoopback(port: port)
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
}

private func sysConnect(_ fd: Int32, host: String, port: UInt16) -> Int32 {
    var a = sysLoopback(port: port)
    a.sin_addr.s_addr = inet_addr(host)
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
}

private func sysLocalPort(_ fd: Int32) -> UInt16 {
    var a = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return UInt16(bigEndian: a.sin_port)
}

/// Waits up to `ms` for readability.
private func sysReadable(_ fd: Int32, ms: Int32) -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&p, 1, ms) > 0
}

private func sysRecv(_ fd: Int32, _ buffer: inout [UInt8]) -> Int {
    buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
}

private func sysSendAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

private func sysShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
private func sysClose(_ fd: Int32) { _ = close(fd) }

/// A port on 127.0.0.1 with nothing listening (connect -> ECONNREFUSED).
func unusedLoopbackPort() -> UInt16 {
    let fd = sysTCPSocket()
    _ = sysBind(fd, port: 0)
    let port = sysLocalPort(fd)
    sysClose(fd)
    return port
}

/// A Yeelight device on a real TCP socket (127.0.0.1, ephemeral port) backed by `FakeYeelightBulb`.
/// One thread accepts, one thread per client reads; replies and `props` notifications are written
/// back like a real bulb. Used only by tests (does not touch `Packages/Simulators`).
final class FakeYeelightTCPServer: @unchecked Sendable {
    let bulb: FakeYeelightBulb
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var clients: [Int32] = []

    init(bulb: FakeYeelightBulb) throws {
        self.bulb = bulb
        let fd = sysTCPSocket()
        guard fd >= 0 else { throw YeelightTransportError.other("socket \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard sysBind(fd, port: 0) == 0, listen(fd, 8) == 0 else {
            sysClose(fd)
            throw YeelightTransportError.other("bind/listen \(errno)")
        }
        listenFD = fd
        port = sysLocalPort(fd)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var isStopped: Bool { lock.locked { stopped } }

    func stop() {
        let fds: [Int32] = lock.locked {
            stopped = true
            return clients
        }
        for c in fds { sysShutdown(c) }
    }

    /// Closes every client connection (the server keeps listening).
    func dropClients() {
        let fds: [Int32] = lock.locked { clients }
        for c in fds { sysShutdown(c) }
    }

    private func acceptLoop() {
        while !isStopped {
            guard sysReadable(listenFD, ms: 50) else { continue }
            let c = accept(listenFD, nil, nil)
            guard c >= 0 else { continue }
            lock.locked { clients.append(c) }
            let thread = Thread { [self] in clientLoop(c) }
            thread.start()
        }
        sysClose(listenFD)
    }

    private func clientLoop(_ fd: Int32) {
        let writeLock = NSLock()
        let write: @Sendable (Data) -> Void = { data in writeLock.locked { _ = sysSendAll(fd, data) } }
        let token = bulb.attach(write)
        var framer = YeelightLineFramer()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            guard sysReadable(fd, ms: 50) else { continue }
            let n = sysRecv(fd, &buffer)
            if n <= 0 { break }
            for line in framer.append(Data(buffer[0..<n])) {
                bulb.handle(line: line, replyTo: write)
            }
        }
        bulb.detach(token)
        lock.locked { clients.removeAll { $0 == fd } }
        writeLock.locked { sysClose(fd) }
    }
}

/// `YeelightConnector` over blocking BSD sockets + a reader thread. Test-only stand-in for
/// `NWYeelightConnector` so the provider can be exercised over real TCP on Linux.
struct POSIXYeelightConnector: YeelightConnector {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any YeelightConnection {
        let fd = sysTCPSocket()
        guard fd >= 0 else { throw YeelightTransportError.other("socket") }
        if sysConnect(fd, host: host, port: port) != 0 {
            let code = errno
            sysClose(fd)
            if code == ECONNREFUSED { throw YeelightTransportError.connectionRefused }
            throw YeelightTransportError.other("connect errno \(code)")
        }
        return POSIXYeelightConnection(fd: fd)
    }
}

final class POSIXYeelightConnection: YeelightConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let thread = Thread { [self] in readLoop() }
        thread.start()
    }

    private var isClosed: Bool { lock.locked { closed } }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isClosed {
            guard sysReadable(fd, ms: 50) else { continue }
            let n = sysRecv(fd, &buffer)
            if n <= 0 { break }
            continuation.yield(Data(buffer[0..<n]))
        }
        continuation.finish()
        lock.locked {
            closed = true
            sysClose(fd)
        }
    }

    func send(_ data: Data) async throws {
        let ok: Bool = lock.locked { closed ? false : sysSendAll(fd, data) }
        if !ok { throw YeelightTransportError.connectionLost }
    }

    func close() async {
        lock.locked {
            guard !closed else { return }
            closed = true
            sysShutdown(fd)
        }
    }
}
