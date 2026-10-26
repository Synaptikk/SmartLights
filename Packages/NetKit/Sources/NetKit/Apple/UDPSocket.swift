#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation

/// Errors from BSD socket calls; `code` is the `errno` value (e.g. `EACCES` when broadcast is
/// not entitled or Local Network access is denied).
public struct UDPSocketError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
    }
}

/// A UDP/IPv4 socket built on BSD sockets, as Apple DTS recommends for broadcast
/// (https://developer.apple.com/forums/thread/772642): one socket per interface bound with
/// `IP_BOUND_IF`, `SO_BROADCAST`, `SO_REUSEADDR`/`SO_REUSEPORT`, non-blocking with a
/// `DispatchSource` reader feeding ``datagrams``.
///
/// Sending broadcast on iOS requires the multicast entitlement; without it `send` throws
/// ``UDPSocketError`` with `code == EACCES` (see ``BroadcastCapability``).
public final class UDPSocket: @unchecked Sendable {
    public struct Options: Sendable {
        /// Interface to bind to with `IP_BOUND_IF` (e.g. the Wi-Fi interface from ``InterfaceInfo``).
        public var interfaceName: String?
        /// Local address to bind; `.any` (0.0.0.0) to receive broadcasts.
        public var localAddress: IPv4Addr
        /// Local port; 0 = ephemeral. Use a fixed port (e.g. WiZ 38900) to receive pushes.
        public var localPort: UInt16
        public var broadcast: Bool
        public var reuseAddress: Bool
        public var reusePort: Bool
        /// Receive buffer per datagram.
        public var maxDatagramSize: Int

        public init(interfaceName: String? = nil, localAddress: IPv4Addr = .any, localPort: UInt16 = 0,
                    broadcast: Bool = false, reuseAddress: Bool = true, reusePort: Bool = true,
                    maxDatagramSize: Int = 65_535) {
            self.interfaceName = interfaceName
            self.localAddress = localAddress
            self.localPort = localPort
            self.broadcast = broadcast
            self.reuseAddress = reuseAddress
            self.reusePort = reusePort
            self.maxDatagramSize = maxDatagramSize
        }
    }

    /// Datagrams received on this socket. Finishes when the socket is closed.
    public let datagrams: AsyncStream<Datagram>
    public let options: Options

    private let fd: Int32
    private let readSource: DispatchSourceRead
    private let continuation: AsyncStream<Datagram>.Continuation
    private let closed = LockedBox(false)

    public init(options: Options = Options()) throws {
        self.options = options
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPSocketError(operation: "socket", code: errno) }
        do {
            if options.reuseAddress { try UDPSocket.setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1, "SO_REUSEADDR") }
            if options.reusePort { try UDPSocket.setOption(fd, SOL_SOCKET, SO_REUSEPORT, 1, "SO_REUSEPORT") }
            if options.broadcast { try UDPSocket.setOption(fd, SOL_SOCKET, SO_BROADCAST, 1, "SO_BROADCAST") }
            if let name = options.interfaceName {
                let index = if_nametoindex(name)
                guard index != 0 else { throw UDPSocketError(operation: "if_nametoindex(\(name))", code: ENXIO) }
                try UDPSocket.setOption(fd, IPPROTO_IP, IP_BOUND_IF, Int32(bitPattern: index), "IP_BOUND_IF")
            }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw UDPSocketError(operation: "fcntl(O_NONBLOCK)", code: errno)
            }
            var address = UDPSocket.socketAddress(options.localAddress, port: options.localPort)
            let rc = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else { throw UDPSocketError(operation: "bind", code: errno) }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        self.fd = fd

        let (stream, continuation) = AsyncStream<Datagram>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.datagrams = stream
        self.continuation = continuation

        let queue = DispatchQueue(label: "com.sinap.smartlights.netkit.udp.\(fd)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let bufferSize = max(512, options.maxDatagramSize)
        source.setEventHandler {
            UDPSocket.drain(fd: fd, bufferSize: bufferSize, into: continuation)
        }
        source.setCancelHandler {
            _ = Darwin.close(fd)
            continuation.finish()
        }
        self.readSource = source
        source.resume()
    }

    deinit {
        close()
    }

    /// The locally bound port (useful when `localPort` was 0).
    public var localPort: UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return rc == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }

    /// Sends one datagram. Throws ``UDPSocketError`` (`EACCES` for unentitled broadcast or denied
    /// Local Network access, `EHOSTUNREACH`/`ENETUNREACH` when off Wi-Fi).
    public func send(_ data: Data, to host: IPv4Addr, port: UInt16) async throws {
        try sendNow(data, to: host, port: port)
    }

    /// Synchronous variant of ``send(_:to:port:)``.
    public func sendNow(_ data: Data, to host: IPv4Addr, port: UInt16) throws {
        guard !isClosed else { throw UDPSocketError(operation: "sendto", code: EBADF) }
        var address = UDPSocket.socketAddress(host, port: port)
        let sent: Int = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw UDPSocketError(operation: "sendto", code: errno) }
    }

    public var isClosed: Bool { closed.withLock { $0 } }

    /// Closes the socket and finishes ``datagrams``. Idempotent.
    public func close() {
        let wasClosed = closed.withLock { (value: inout Bool) -> Bool in
            defer { value = true }
            return value
        }
        guard !wasClosed else { return }
        readSource.cancel() // cancel handler closes the fd and finishes the stream
    }

    // MARK: - Helpers

    public static func interfaceIndex(named name: String) -> UInt32? {
        let index = if_nametoindex(name)
        return index == 0 ? nil : index
    }

    static func socketAddress(_ host: IPv4Addr, port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(host.rawValue).bigEndian)
        return address
    }

    private static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32, _ label: String) throws {
        var v = value
        guard setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw UDPSocketError(operation: "setsockopt(\(label))", code: errno)
        }
    }

    private static func drain(fd: Int32, bufferSize: Int, into continuation: AsyncStream<Datagram>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 { return } // EAGAIN/EWOULDBLOCK: drained; other errors: wait for next event
            let host = IPv4Addr(rawValue: UInt32(bigEndian: from.sin_addr.s_addr))
            let port = UInt16(bigEndian: from.sin_port)
            continuation.yield(Datagram(data: Data(buffer[0..<count]), host: host, port: port))
        }
    }
}
#endif
