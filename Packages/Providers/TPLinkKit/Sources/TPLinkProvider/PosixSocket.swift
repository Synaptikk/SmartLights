import Foundation
import LightCore
import TPLinkCodec
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Legacy Kasa over a blocking BSD TCP socket (works on Apple platforms and Linux). One short
/// connection per request: connect, write the frame, read one length-prefixed answer, close.
/// The blocking calls run on a dedicated `Thread`, never on the Swift concurrency pool.
/// Apple's guidance prefers Network.framework for TCP, but a plain socket keeps one tested code
/// path for the 9999 protocol, which has no TLS, no proxies and no long-lived state.
public struct PosixTPLinkStreamTransport: TPLinkStreamTransport {
    public init() {}

    public func exchange(_ frame: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await PosixSocket.onThread {
            let fd = try PosixSocket.connect(host: host, port: port, timeout: timeout)
            defer { PosixSocket.close(fd) }
            try PosixSocket.sendAll(fd, frame)
            let header = try PosixSocket.receive(fd, exactly: 4)
            guard let length = TPLinkXOR.announcedLength(Data(header)), length <= TPLinkXOR.maxFrameLength else {
                throw LightCoreError.protocolError("bad Kasa frame header")
            }
            let body = length > 0 ? try PosixSocket.receive(fd, exactly: length) : []
            return Data(header + body)
        }
    }
}

/// Thin, platform-neutral wrappers over BSD sockets (also used by the test fakes).
enum PosixSocket {
    #if canImport(Glibc)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let datagramType = Int32(SOCK_DGRAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
    static let streamType = SOCK_STREAM
    static let datagramType = SOCK_DGRAM
    static let sendFlags: Int32 = 0
    #endif

    /// Runs blocking `body` on a new thread.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            let thread = Thread {
                c.resume(with: Result(catching: { try body() }))
            }
            thread.start()
        }
    }

    static func close(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        let h = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else {
            throw LightCoreError.unsupported("TP-Link needs an IPv4 address, got \(host)")
        }
        return addr
    }

    static func hostString(_ addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    static func withSockaddr<R>(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, _ duration: Duration) {
        let s = max(duration.timeIntervalSeconds, 0.001)
        var tv = timeval()
        tv.tv_sec = .init(Int(s))
        tv.tv_usec = .init(Int((s - Double(Int(s))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setFlag(_ fd: Int32, _ level: Int32, _ option: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, level, option, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// TCP connect with a deadline (non-blocking connect + `poll`), then blocking I/O with
    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` = `timeout`.
    static func connect(host: String, port: UInt16, timeout: Duration) throws -> Int32 {
        var addr = try address(host, port: port)
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw LightCoreError.transport("socket() errno \(errno)") }
        #if canImport(Darwin)
        setFlag(fd, SOL_SOCKET, SO_NOSIGPIPE)
        #endif
        setFlag(fd, Int32(IPPROTO_TCP), TCP_NODELAY)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withSockaddr(&addr) { sysConnect(fd, $0, $1) }
        if rc != 0 {
            let e = errno
            guard e == EINPROGRESS || e == EINTR else {
                close(fd)
                throw LightCoreError.unreachable("\(host):\(port) connect failed (errno \(e))")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(clamping: Int((timeout.timeIntervalSeconds * 1000).rounded(.up)))
            let ready = poll(&pfd, 1, max(ms, 1))
            if ready == 0 {
                close(fd)
                throw LightCoreError.timeout
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if ready < 0 || soError != 0 {
                close(fd)
                throw LightCoreError.unreachable("\(host):\(port) connect failed (errno \(soError != 0 ? soError : errno))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(fd, SO_RCVTIMEO, timeout)
        setTimeout(fd, SO_SNDTIMEO, timeout)
        return fd
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { sysSend(fd, $0.baseAddress, $0.count, sendFlags) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw LightCoreError.timeout }
                throw LightCoreError.transport("send errno \(errno)")
            }
            offset += n
        }
    }

    /// Reads exactly `count` bytes. Throws `.timeout` on `SO_RCVTIMEO`, `.transport` when the peer closes.
    static func receive(_ fd: Int32, exactly count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = out.withUnsafeMutableBytes { raw in
                sysRecv(fd, raw.baseAddress! + offset, count - offset, 0)
            }
            if n > 0 {
                offset += n
            } else if n == 0 {
                throw LightCoreError.transport("connection closed after \(offset) of \(count) bytes")
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw LightCoreError.timeout
            } else {
                throw LightCoreError.transport("recv errno \(errno)")
            }
        }
        return out
    }

    /// Reads whatever is available (up to `max` bytes); 0 = peer closed, -1 = error/timeout.
    static func receiveSome(_ fd: Int32, max: Int = 65_536) -> (Int, [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: max)
        let n = buffer.withUnsafeMutableBytes { sysRecv(fd, $0.baseAddress, $0.count, 0) }
        return (n, n > 0 ? Array(buffer[0..<n]) : [])
    }

    // MARK: Server side (test fakes)

    /// TCP listener on 127.0.0.1 (`port` 0 = ephemeral). Returns the fd and bound port.
    static func listenLoopback(port: UInt16 = 0) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw LightCoreError.transport("socket() errno \(errno)") }
        setFlag(fd, SOL_SOCKET, SO_REUSEADDR)
        var addr = try address("127.0.0.1", port: port)
        guard withSockaddr(&addr, { sysBind(fd, $0, $1) }) == 0 else {
            let e = errno
            close(fd)
            throw LightCoreError.transport("bind errno \(e)")
        }
        guard sysListen(fd, 64) == 0 else {
            let e = errno
            close(fd)
            throw LightCoreError.transport("listen errno \(e)")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    /// Waits up to `timeoutMs` for a connection; nil on timeout or error.
    static func accept(_ listener: Int32, timeoutMs: Int32) -> Int32? {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        let client = sysAccept(listener, nil, nil)
        guard client >= 0 else { return nil }
        #if canImport(Darwin)
        setFlag(client, SOL_SOCKET, SO_NOSIGPIPE)
        #endif
        return client
    }

    static func shutdownBoth(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        #else
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        #endif
    }
}

// Free-function wrappers so the calls do not collide with method names.
private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}

private func sysBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.bind(fd, addr, len)
    #else
    return Darwin.bind(fd, addr, len)
    #endif
}

private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.listen(fd, backlog)
    #else
    return Darwin.listen(fd, backlog)
    #endif
}

private func sysAccept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    #if canImport(Glibc)
    return Glibc.accept(fd, addr, len)
    #else
    return Darwin.accept(fd, addr, len)
    #endif
}

private func sysSend(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
    #if canImport(Glibc)
    return Glibc.send(fd, buffer, count, flags)
    #else
    return Darwin.send(fd, buffer, count, flags)
    #endif
}

private func sysRecv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: Int32) -> Int {
    #if canImport(Glibc)
    return Glibc.recv(fd, buffer, count, flags)
    #else
    return Darwin.recv(fd, buffer, count, flags)
    #endif
}

extension Duration {
    /// Fractional seconds (local helper; NetKit's `timeInterval` lives behind an import we keep
    /// out of this file).
    var timeIntervalSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
