#if canImport(Darwin)
import Foundation
import OSLog

/// Events emitted by ``SSEClient``.
public enum SSEClientEvent: Sendable, Equatable {
    /// A connection was (re)established; `resumedFrom` is the `Last-Event-ID` sent, if any.
    case connected(resumedFrom: String?)
    case event(SSEEvent)
    /// The connection dropped; a reconnect follows after `retryIn`.
    case disconnected(reason: String, retryIn: Duration)
}

/// `text/event-stream` client on `URLSession.bytes(for:)` with header injection, `Last-Event-ID`,
/// a read (idle) timeout and reconnect with backoff (Hue CLIP v2 `/eventstream/clip/v2`,
/// Nanoleaf `/events`). Pass a session whose delegate is a ``TrustingSessionDelegate`` for Hue.
public final class SSEClient: Sendable {
    public struct Configuration: Sendable {
        public var url: URL
        /// Extra headers, e.g. `["hue-application-key": key]`. Never logged.
        public var headers: [String: String]
        /// Idle timeout: if no bytes arrive for this long the connection is dropped and retried.
        /// Hue: 90 s (with a keep-alive every 60 s from the caller).
        public var readTimeout: Duration
        public var backoff: ExponentialBackoff
        /// Resume point sent as `Last-Event-ID` on the first connection.
        public var lastEventID: String?
        /// Stop (finish the stream with the error) on these statuses instead of retrying.
        public var fatalStatuses: Set<Int>

        public init(url: URL, headers: [String: String] = [:], readTimeout: Duration = .seconds(90),
                    backoff: ExponentialBackoff = .hueEventStream, lastEventID: String? = nil,
                    fatalStatuses: Set<Int> = [401, 403, 404]) {
            self.url = url
            self.headers = headers
            self.readTimeout = readTimeout
            self.backoff = backoff
            self.lastEventID = lastEventID
            self.fatalStatuses = fatalStatuses
        }
    }

    public let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Starts streaming. The stream reconnects until cancelled (terminate it to stop) or a fatal
    /// HTTP status ends it with ``HTTPError``.
    public func events() -> AsyncThrowingStream<SSEClientEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SSEClientEvent, any Error>.makeStream()
        let configuration = self.configuration
        let session = self.session
        let task = Task {
            var backoff = configuration.backoff
            var lastEventID = configuration.lastEventID
            while !Task.isCancelled {
                var parser = SSEParser(lastEventID: lastEventID ?? "")
                let reason: String
                do {
                    var request = URLRequest(url: configuration.url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = configuration.readTimeout.timeInterval // idle timeout between packets
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    for (name, value) in configuration.headers { request.setValue(value, forHTTPHeaderField: name) }
                    if let lastEventID, !lastEventID.isEmpty {
                        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                    }

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
                    if let error = HTTPError.check(status: http.statusCode,
                                                   retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
                        if configuration.fatalStatuses.contains(http.statusCode) {
                            NetKitLog.sse.error("SSE fatal status \(http.statusCode, privacy: .public)")
                            continuation.finish(throwing: error)
                            return
                        }
                        throw error
                    }
                    continuation.yield(.connected(resumedFrom: lastEventID))
                    backoff.reset()

                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(4096)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || byte == 0x0D || chunk.count >= 4096 {
                            for event in parser.feed(chunk) { continuation.yield(.event(event)) }
                            chunk.removeAll(keepingCapacity: true)
                            if !parser.lastEventID.isEmpty { lastEventID = parser.lastEventID }
                        }
                    }
                    for event in parser.feed(chunk) { continuation.yield(.event(event)) }
                    reason = "stream ended"
                } catch is CancellationError {
                    break
                } catch let error as URLError where error.code == .cancelled {
                    if Task.isCancelled { break }
                    reason = "cancelled by system"
                } catch let error as URLError where error.code == .timedOut {
                    reason = "read timeout"
                } catch {
                    reason = String(describing: error)
                }
                parser.finish()
                if !parser.lastEventID.isEmpty { lastEventID = parser.lastEventID }
                var delay = backoff.nextDelay()
                if let serverRetry = parser.reconnectionTime, serverRetry > delay { delay = serverRetry }
                NetKitLog.sse.info("SSE disconnected (\(reason, privacy: .public)); retry in \(delay.timeInterval, privacy: .public) s")
                continuation.yield(.disconnected(reason: reason, retryIn: delay))
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

enum NetKitLog {
    static let sse = Logger(subsystem: "com.sinap.smartlights.netkit", category: "sse")
    static let http = Logger(subsystem: "com.sinap.smartlights.netkit", category: "http")
    static let trust = Logger(subsystem: "com.sinap.smartlights.netkit", category: "trust")
}
#endif
