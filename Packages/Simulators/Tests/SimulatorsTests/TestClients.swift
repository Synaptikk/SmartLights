// Minimal NIO clients used to exercise the fakes over real sockets.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Simulators

struct TestTimeout: Error, CustomStringConvertible {
    var what: String
    var description: String { "timed out waiting for \(what)" }
}

/// A thread-safe queue with an async, timeout-bounded `next()`.
final class Inbox<T: Sendable>: Sendable {
    private struct Waiter {
        var id: Int
        var cont: CheckedContinuation<T?, Never>
    }
    private struct Box {
        var items: [T] = []
        var waiter: Waiter?
        var nextId = 0
    }
    private let box = NIOLockedValueBox(Box())

    func put(_ item: T) {
        let w = box.withLockedValue { b -> Waiter? in
            if let w = b.waiter {
                b.waiter = nil
                return w
            }
            b.items.append(item)
            return nil
        }
        w?.cont.resume(returning: item)
    }

    func next(timeout: Duration = .seconds(5)) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let id = box.withLockedValue { b -> Int? in
                if !b.items.isEmpty {
                    let item = b.items.removeFirst()
                    cont.resume(returning: item)
                    return nil
                }
                b.nextId += 1
                b.waiter = Waiter(id: b.nextId, cont: cont)
                return b.nextId
            }
            guard let id else { return }
            Task {
                try? await Task.sleep(for: timeout)
                let w = self.box.withLockedValue { b -> Waiter? in
                    guard let w = b.waiter, w.id == id else { return nil }
                    b.waiter = nil
                    return w
                }
                w?.cont.resume(returning: nil)
            }
        }
    }

    func require(timeout: Duration = .seconds(5), _ what: String = "message") async throws -> T {
        guard let v = await next(timeout: timeout) else { throw TestTimeout(what: what) }
        return v
    }
}

private final class CollectHandler<T: Sendable>: ChannelInboundHandler {
    typealias InboundIn = T
    let inbox: Inbox<T>
    init(_ inbox: Inbox<T>) { self.inbox = inbox }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { inbox.put(unwrapInboundIn(data)) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}

// MARK: UDP

final class UDPTestClient: Sendable {
    let channel: any Channel
    let inbox: Inbox<AddressedEnvelope<ByteBuffer>>

    private init(channel: any Channel, inbox: Inbox<AddressedEnvelope<ByteBuffer>>) {
        self.channel = channel
        self.inbox = inbox
    }

    static func make(host: String = "127.0.0.1", port: Int = 0) async throws -> UDPTestClient {
        let inbox = Inbox<AddressedEnvelope<ByteBuffer>>()
        let ch = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(CollectHandler(inbox))
                }
            }
            .bind(host: host, port: port).get()
        return UDPTestClient(channel: ch, inbox: inbox)
    }

    var port: Int { channel.localAddress?.port ?? -1 }

    func send(_ bytes: [UInt8], port: Int, host: String = "127.0.0.1") async throws {
        let addr = try SocketAddress(ipAddress: host, port: port)
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: addr, data: channel.allocator.buffer(bytes: bytes)))
    }

    func receive(timeout: Duration = .seconds(5)) async throws -> [UInt8] {
        let env = try await inbox.require(timeout: timeout, "UDP datagram")
        return Array(env.data.readableBytesView)
    }

    func receiveJSON(timeout: Duration = .seconds(5)) async throws -> JSON {
        try JSON.parse(try await receive(timeout: timeout))
    }

    /// Sends a JSON string and returns the first reply parsed as JSON.
    func request(_ text: String, port: Int) async throws -> JSON {
        try await send(Array(text.utf8), port: port)
        return try await receiveJSON()
    }

    func close() async { try? await channel.close() }
}

// MARK: TCP (AiDot frames)

private struct TestFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = AiDotFrame
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let f = AiDotFrame.decode(from: &buffer) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(f))
        return .continue
    }
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

final class TCPFrameClient: Sendable {
    let channel: any Channel
    let inbox: Inbox<AiDotFrame>
    let key: [UInt8]

    private init(channel: any Channel, inbox: Inbox<AiDotFrame>, key: [UInt8]) {
        self.channel = channel
        self.inbox = inbox
        self.key = key
    }

    static func connect(port: Int, key: [UInt8]) async throws -> TCPFrameClient {
        let inbox = Inbox<AiDotFrame>()
        let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(TestFrameDecoder()))
                    try ch.pipeline.syncOperations.addHandler(CollectHandler(inbox))
                }
            }
            .connect(host: "127.0.0.1", port: port).get()
        return TCPFrameClient(channel: ch, inbox: inbox, key: key)
    }

    func send(_ json: JSON, msgType: UInt16 = 1) async throws {
        let frame = try AiDotFrame.encrypted(json, msgType: msgType, key: key)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: frame.encoded()))
    }

    func receive(label: String = "AiDot frame", timeout: Duration = .seconds(5)) async throws -> (AiDotFrame, JSON) {
        let f = try await inbox.require(timeout: timeout, label)
        return (f, try f.decryptedJSON(key: key))
    }

    func close() async { try? await channel.close() }
}

// MARK: HTTP(S)

struct HTTPTestResponse: Sendable {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: [UInt8]
    var json: JSON? { try? JSON.parse(body) }
    var text: String { String(decoding: body, as: UTF8.self) }
}

final class HTTPTestConnection: Sendable {
    let channel: any Channel
    let parts: Inbox<HTTPClientResponsePart>
    let peerCertificateDER: NIOLockedValueBox<[UInt8]?>

    private init(channel: any Channel, parts: Inbox<HTTPClientResponsePart>, peer: NIOLockedValueBox<[UInt8]?>) {
        self.channel = channel
        self.parts = parts
        self.peerCertificateDER = peer
    }

    static func connect(port: Int, tls: Bool) async throws -> HTTPTestConnection {
        let parts = Inbox<HTTPClientResponsePart>()
        let peer = NIOLockedValueBox<[UInt8]?>(nil)
        let sslContext: NIOSSLContext? =
            tls
            ? try {
                var cfg = TLSConfiguration.makeClientConfiguration()
                cfg.certificateVerification = .none
                return try NIOSSLContext(configuration: cfg)
            }() : nil
        let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        let h = try NIOSSLClientHandler(
                            context: sslContext, serverHostname: nil,
                            customVerificationCallback: { certs, promise in
                                peer.withLockedValue { $0 = try? certs.first?.toDERBytes() }
                                promise.succeed(.certificateVerified)
                            })
                        try ch.pipeline.syncOperations.addHandler(h)
                    }
                    try ch.pipeline.syncOperations.addHTTPClientHandlers()
                    try ch.pipeline.syncOperations.addHandler(CollectHandler(parts))
                }
            }
            .connect(host: "127.0.0.1", port: port).get()
        return HTTPTestConnection(channel: ch, parts: parts, peer: peer)
    }

    func send(method: HTTPMethod, path: String, headers: [(String, String)] = [], body: String? = nil) async throws {
        var h = HTTPHeaders(headers)
        h.add(name: "Host", value: "127.0.0.1")
        if let body { h.add(name: "Content-Length", value: String(body.utf8.count)) }
        let head = HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: h)
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(string: body))), promise: nil)
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil))
    }

    func readHead(timeout: Duration = .seconds(5)) async throws -> HTTPResponseHead {
        while true {
            if case .head(let h) = try await parts.require(timeout: timeout, "HTTP head") { return h }
        }
    }

    /// Reads body chunks as text until `.end` (nil) or a chunk arrives.
    func readChunk(timeout: Duration = .seconds(5)) async throws -> String? {
        switch try await parts.require(timeout: timeout, "HTTP body chunk") {
        case .body(let b): return String(buffer: b)
        case .end: return nil
        case .head: return try await readChunk(timeout: timeout)
        }
    }

    func readResponse(timeout: Duration = .seconds(5)) async throws -> HTTPTestResponse {
        let head = try await readHead(timeout: timeout)
        var body: [UInt8] = []
        while true {
            switch try await parts.require(timeout: timeout, "HTTP body") {
            case .body(let b): body += Array(b.readableBytesView)
            case .end: return HTTPTestResponse(status: head.status, headers: head.headers, body: body)
            case .head: continue
            }
        }
    }

    /// Fire-and-forget close: a client-initiated TLS shutdown otherwise waits for
    /// NIOSSL's 5 s close_notify timeout.
    func close() async { channel.close(promise: nil) }

    /// One-shot request on a fresh connection.
    static func request(
        _ method: HTTPMethod, port: Int, path: String, tls: Bool = true, headers: [(String, String)] = [],
        body: String? = nil
    ) async throws -> HTTPTestResponse {
        let c = try await connect(port: port, tls: tls)
        try await c.send(method: method, path: path, headers: headers + [("Connection", "close")], body: body)
        let r = try await c.readResponse()
        await c.close()
        return r
    }
}
