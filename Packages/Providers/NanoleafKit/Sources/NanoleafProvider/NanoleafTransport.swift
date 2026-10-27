import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NanoleafCodec

/// Where a controller lives (IP is a hint; devices are keyed by stable id).
public struct NanoleafEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = NanoleafAPI.port) {
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }

    /// `http://host:port` + request path.
    func url(for request: NanoleafRequest) -> URL? {
        URL(string: "http://\(host):\(port)\(request.path)")
    }
}

/// HTTP status + body.
public struct NanoleafHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Pieces of a streaming (SSE) response.
public enum NanoleafStreamPart: Sendable, Hashable {
    /// Response head received.
    case opened(status: Int)
    case bytes([UInt8])
}

/// Transport-level failure (no HTTP response). Messages never contain URLs (they hold the token).
public enum NanoleafTransportError: Error, Sendable, Equatable {
    case invalidURL
    case timedOut
    case unreachable(String)
}

/// HTTP + SSE transport. The default is `URLSessionNanoleafTransport`; tests may inject fakes.
public protocol NanoleafTransport: Sendable {
    /// Performs one request. Throws `NanoleafTransportError` (or `CancellationError`) when no HTTP
    /// response arrives; any HTTP status is returned, not thrown.
    func send(_ request: NanoleafRequest, to endpoint: NanoleafEndpoint, timeout: Duration) async throws
        -> NanoleafHTTPResponse
    /// Opens a long-lived streaming GET. The stream yields `.opened` once, then body bytes, and
    /// finishes when the connection closes (throwing on transport errors). Terminating the stream
    /// cancels the request. `idleTimeout`: drop the connection when no bytes arrive for this long.
    func stream(_ request: NanoleafRequest, to endpoint: NanoleafEndpoint, idleTimeout: Duration)
        -> AsyncThrowingStream<NanoleafStreamPart, any Error>
}

/// URLSession-based transport. Works on Apple platforms and on Linux (FoundationNetworking), which is
/// why the provider does not use NetKit's Darwin-only `HTTPClient`/`SSEClient`: the same code path is
/// exercised by the Linux tests and shipped in the app. SSE bytes are parsed by NetKit's `SSEParser`
/// in the provider.
public final class URLSessionNanoleafTransport: NanoleafTransport, Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: NanoleafRequest, to endpoint: NanoleafEndpoint, timeout: Duration) async throws
        -> NanoleafHTTPResponse
    {
        let urlRequest = try Self.makeRequest(request, endpoint: endpoint, timeout: timeout)
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NanoleafHTTPResponse, any Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: NanoleafHTTPResponse(status: http.statusCode, body: data ?? Data()))
                    } else {
                        continuation.resume(throwing: NanoleafTransportError.unreachable("no HTTP response"))
                    }
                }
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    public func stream(_ request: NanoleafRequest, to endpoint: NanoleafEndpoint, idleTimeout: Duration)
        -> AsyncThrowingStream<NanoleafStreamPart, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream<NanoleafStreamPart, any Error>.makeStream()
        let urlRequest: URLRequest
        do {
            var r = try Self.makeRequest(request, endpoint: endpoint, timeout: idleTimeout)
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            urlRequest = r
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.seconds(idleTimeout)
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let delegate = StreamDelegate(continuation: continuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        let holder = TaskHolder()
        holder.set(task)
        continuation.onTermination = { _ in
            holder.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        return stream
    }

    // MARK: - Helpers

    static func makeRequest(_ request: NanoleafRequest, endpoint: NanoleafEndpoint, timeout: Duration) throws
        -> URLRequest
    {
        guard let url = endpoint.url(for: request) else { throw NanoleafTransportError.invalidURL }
        var r = URLRequest(url: url)
        r.httpMethod = request.method.rawValue
        r.timeoutInterval = seconds(timeout)
        r.httpBody = request.body
        if request.body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return max(0.001, Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    /// Maps URLSession errors without leaking the URL (which contains the token).
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return NanoleafTransportError.timedOut
            default: return NanoleafTransportError.unreachable("URLError \(urlError.code.rawValue)")
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return CancellationError() }
            if ns.code == NSURLErrorTimedOut { return NanoleafTransportError.timedOut }
        }
        return NanoleafTransportError.unreachable("\(ns.domain) \(ns.code)")
    }
}

/// Holds a URLSessionTask so cancellation handlers (which may run first) can cancel it.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.task = task
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Streams a data task's response into an AsyncThrowingStream.
private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<NanoleafStreamPart, any Error>.Continuation
    private let lock = NSLock()
    private var opened = false

    init(continuation: AsyncThrowingStream<NanoleafStreamPart, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// Yields `.opened` once (from the response callback, or lazily from the first data/completion).
    private func open(_ response: URLResponse?) {
        lock.lock()
        let first = !opened
        opened = true
        lock.unlock()
        if first { continuation.yield(.opened(status: (response as? HTTPURLResponse)?.statusCode ?? 0)) }
    }

    #if canImport(Darwin)
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        open(response)
        completionHandler(.allow)
    }
    #else
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        open(response)
        completionHandler(.allow)
    }
    #endif

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        open(dataTask.response)
        continuation.yield(.bytes([UInt8](data)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let mapped = URLSessionNanoleafTransport.map(error)
            if mapped is CancellationError {
                continuation.finish()
            } else {
                continuation.finish(throwing: mapped)
            }
        } else {
            open(task.response)
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
