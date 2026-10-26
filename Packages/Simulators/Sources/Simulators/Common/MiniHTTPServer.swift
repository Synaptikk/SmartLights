// Tiny HTTP/1.1 server on SwiftNIO used by FakeHueBridge and FakeAiDotCloud.
// Supports plain HTTP or TLS, full responses, Server-Sent-Event streams, an
// artificial response delay and a concurrent-request limit (429).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var uri: String
    public var path: String
    public var query: [String: String]
    public var headers: HTTPHeaders
    public var body: [UInt8]

    public var bodyString: String { String(decoding: body, as: UTF8.self) }
    public var json: JSON? { try? JSON.parse(body) }

    init(head: HTTPRequestHead, body: [UInt8]) {
        method = head.method
        uri = head.uri
        headers = head.headers
        self.body = body
        let parts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = parts.first.map(String.init) ?? "/"
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                q[k] = v
            }
        }
        query = q
    }
}

public struct HTTPResponse: Sendable {
    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: [UInt8]

    public init(status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders(), body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: HTTPResponseStatus = .ok, _ value: JSON) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: ["Content-Type": "application/json"], body: Array(value.compact.utf8))
    }

    public static func text(_ status: HTTPResponseStatus, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain"], body: Array(text.utf8))
    }
}

/// An open `text/event-stream` response.
public final class EventStreamConnection: Sendable {
    let channel: any Channel
    public let id: Int

    init(channel: any Channel, id: Int) {
        self.channel = channel
        self.id = id
    }

    /// Writes raw text (caller formats `id:`/`data:` lines and the blank line).
    public func send(_ text: String) {
        let buf = channel.allocator.buffer(string: text)
        channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }

    public var isActive: Bool { channel.isActive }
}

public enum HTTPReply: Sendable {
    case response(HTTPResponse)
    /// Opens an SSE stream; `onOpen` runs once the response head has been written,
    /// `onClose` when the client goes away.
    case eventStream(
        headers: HTTPHeaders, onOpen: @Sendable (EventStreamConnection) -> Void,
        onClose: @Sendable (EventStreamConnection) -> Void)
}

public struct HTTPLimits: Sendable {
    /// More than this many in-flight (non-streaming) requests -> 429. nil = unlimited.
    public var maxConcurrentRequests: Int?
    /// Artificial latency before each full response (lets tests build up concurrency).
    public var responseDelay: TimeAmount = .zero
    public init(maxConcurrentRequests: Int? = nil, responseDelay: TimeAmount = .zero) {
        self.maxConcurrentRequests = maxConcurrentRequests
        self.responseDelay = responseDelay
    }
}

final class MiniHTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPReply

    let group: any EventLoopGroup
    let handler: Handler
    let limits: NIOLockedValueBox<HTTPLimits>
    let inFlight = NIOLockedValueBox(0)
    let streamCounter = NIOLockedValueBox(0)
    let tooManyResponse: @Sendable () -> HTTPResponse

    init(
        group: any EventLoopGroup, limits: NIOLockedValueBox<HTTPLimits>,
        tooManyResponse: @escaping @Sendable () -> HTTPResponse = { .text(.tooManyRequests, "Too Many Requests") },
        handler: @escaping Handler
    ) {
        self.group = group
        self.limits = limits
        self.handler = handler
        self.tooManyResponse = tooManyResponse
    }

    func bind(host: String, port: Int, tls: NIOSSLContext?) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    if let tls {
                        try sync.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try sync.configureHTTPServerPipeline(withErrorHandling: true)
                    try sync.addHandler(MiniHTTPHandler(server: self))
                }
            }
            .bind(host: host, port: port).get()
    }

    /// Returns false if the concurrency limit is exceeded.
    func acquire() -> Bool {
        let max = limits.withLockedValue { $0.maxConcurrentRequests }
        return inFlight.withLockedValue { n in
            if let max, n >= max { return false }
            n += 1
            return true
        }
    }

    func release() { inFlight.withLockedValue { $0 -= 1 } }

    func nextStreamID() -> Int { streamCounter.withLockedValue { $0 += 1; return $0 } }
}

final class MiniHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let server: MiniHTTPServer
    var head: HTTPRequestHead?
    var body: [UInt8] = []
    var stream: (EventStreamConnection, @Sendable (EventStreamConnection) -> Void)?

    init(server: MiniHTTPServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = []
        case .body(var buf):
            body += buf.readBytes(length: buf.readableBytes) ?? []
        case .end:
            guard let head else { return }
            self.head = nil
            handle(context: context, request: HTTPRequest(head: head, body: body), keepAlive: head.isKeepAlive)
        }
    }

    func handle(context: ChannelHandlerContext, request: HTTPRequest, keepAlive: Bool) {
        let wantsStream = request.headers["accept"].contains { $0.contains("text/event-stream") }
        if wantsStream || request.path.hasPrefix("/eventstream") {
            switch server.handler(request) {
            case .response(let r):
                write(context: context, response: r, keepAlive: keepAlive)
            case .eventStream(var headers, let onOpen, let onClose):
                if !headers.contains(name: "content-type") { headers.add(name: "Content-Type", value: "text/event-stream") }
                headers.add(name: "Cache-Control", value: "no-cache")
                headers.add(name: "Transfer-Encoding", value: "chunked")
                let conn = EventStreamConnection(channel: context.channel, id: server.nextStreamID())
                stream = (conn, onClose)
                context.writeAndFlush(
                    wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))),
                    promise: nil)
                onOpen(conn)
            }
            return
        }

        guard server.acquire() else {
            write(context: context, response: server.tooManyResponse(), keepAlive: keepAlive)
            return
        }
        let reply = server.handler(request)
        let response: HTTPResponse
        switch reply {
        case .response(let r): response = r
        case .eventStream: response = .text(.badRequest, "event stream requires Accept: text/event-stream")
        }
        let delay = server.limits.withLockedValue { $0.responseDelay }
        if delay > .zero {
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: delay) {
                let (handler, ctx) = bound.value
                handler.server.release()
                handler.write(context: ctx, response: response, keepAlive: keepAlive)
            }
        } else {
            server.release()
            write(context: context, response: response, keepAlive: keepAlive)
        }
    }

    func write(context: ChannelHandlerContext, response: HTTPResponse, keepAlive: Bool) {
        guard context.channel.isActive else { return }
        var headers = response.headers
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers))),
            promise: nil)
        if !response.body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: response.body)))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let (conn, onClose) = stream {
            stream = nil
            onClose(conn)
        }
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // A client hanging up an event stream (EOF / TLS close_notify): close our side too.
        if stream != nil, let e = event as? ChannelEvent, e == .inputClosed {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
