import Foundation
import LightCore
import NetKit
import TPLinkCodec
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Transport seams of the provider. Production: POSIX TCP (legacy Kasa), URLSession (KLAP) and,
// on Apple platforms, NetKit UDP for discovery (`TPLinkAppleEnvironment.swift`). Tests inject
// fakes or point the real transports at loopback servers.

// MARK: - TCP (legacy Kasa, XOR on 9999)

public protocol TPLinkStreamTransport: Sendable {
    /// Connects, writes `frame` (length-prefixed XOR), reads one length-prefixed answer and returns
    /// it *including* its 4-byte prefix. Throws `LightCoreError.unreachable` / `.timeout` /
    /// `.transport`.
    func exchange(_ frame: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data
}

// MARK: - HTTP (KLAP)

public struct TPLinkHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    /// Cookies from `Set-Cookie` (`TP_SESSIONID`, `TIMEOUT`).
    public var cookies: [String: String]

    public init(status: Int, body: Data, cookies: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.cookies = cookies
    }
}

public protocol TPLinkHTTPTransport: Sendable {
    /// `POST url` with a binary body and an optional `Cookie` header. Returns every HTTP answer
    /// (non-2xx included); throws only for transport failures.
    func post(_ url: URL, body: Data, cookie: String?, timeout: Duration) async throws -> TPLinkHTTPResponse
}

/// URLSession transport (Apple platforms and Linux FoundationNetworking). Cookies are handled by
/// hand: the shared cookie store is never used, so sessions of different devices cannot mix.
public final class URLSessionTPLinkHTTPTransport: TPLinkHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    public func post(_ url: URL, body: Data, cookie: String?, timeout: Duration) async throws -> TPLinkHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.timeoutInterval = max(timeout.timeInterval, 0.1)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let gate = OnceGate<TPLinkHTTPResponse>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    gate.resume(.failure(LightCoreError.timeout))
                } else {
                    gate.resume(.failure(LightCoreError.unreachable("\(url.host ?? "device"): \(error.localizedDescription)")))
                }
            } else if let http = response as? HTTPURLResponse {
                var setCookie: [String] = []
                for (name, value) in http.allHeaderFields {
                    if String(describing: name).lowercased() == "set-cookie" { setCookie.append(String(describing: value)) }
                }
                gate.resume(.success(TPLinkHTTPResponse(status: http.statusCode, body: data ?? Data(),
                                                        cookies: TPLinkKLAP.parseCookies(setCookie))))
            } else {
                gate.resume(.failure(LightCoreError.transport("no HTTP response")))
            }
        }
        task.resume()
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            task.cancel()
            gate.resume(.failure(CancellationError()))
        }
    }
}

// MARK: - UDP (discovery)

public struct TPLinkDatagram: Sendable, Hashable {
    public var data: Data
    public var host: String
    /// Source port of the answer (9999 legacy, 20002 new).
    public var port: UInt16

    public init(data: Data, host: String, port: UInt16) {
        self.data = data
        self.host = host
        self.port = port
    }
}

/// One discovery datagram and its destination port.
public struct TPLinkProbe: Sendable, Hashable {
    public var payload: Data
    public var port: UInt16

    public init(payload: Data, port: UInt16) {
        self.payload = payload
        self.port = port
    }
}

public protocol TPLinkDatagramTransport: Sendable {
    /// Sends every probe to every address (`rounds` times) and streams answers until `listen`
    /// elapses. Broadcast needs the multicast entitlement on iOS.
    func broadcast(_ probes: [TPLinkProbe], to addresses: [String], rounds: Int, listen: Duration) -> AsyncStream<TPLinkDatagram>
    /// Unicast probes to one host; returns the answers received within `timeout`
    /// (early when every probe was answered).
    func probe(_ probes: [TPLinkProbe], host: String, timeout: Duration) async -> [TPLinkDatagram]
}

/// Everything the provider needs from the platform; injectable for tests.
public struct TPLinkNetworkEnvironment: Sendable {
    public var stream: any TPLinkStreamTransport
    public var http: any TPLinkHTTPTransport
    /// nil where UDP is unavailable (Linux builds): discovery then only probes TCP/HTTP hosts.
    public var datagrams: (any TPLinkDatagramTransport)?
    /// Broadcast destinations (directed broadcast of the Wi-Fi subnet, 255.255.255.255).
    public var broadcastAddresses: @Sendable () -> [String]
    /// Hosts for the unicast sweep (current Wi-Fi /24).
    public var sweepHosts: @Sendable () -> [IPv4Addr]

    public init(
        stream: any TPLinkStreamTransport = PosixTPLinkStreamTransport(),
        http: any TPLinkHTTPTransport = URLSessionTPLinkHTTPTransport(),
        datagrams: (any TPLinkDatagramTransport)? = nil,
        broadcastAddresses: @escaping @Sendable () -> [String] = { [] },
        sweepHosts: @escaping @Sendable () -> [IPv4Addr] = { [] }
    ) {
        self.stream = stream
        self.http = http
        self.datagrams = datagrams
        self.broadcastAddresses = broadcastAddresses
        self.sweepHosts = sweepHosts
    }
}

// MARK: - Helpers

/// Single-assignment bridge from callbacks to async code; the first `resume` wins.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?
    private var finished = false

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            lock.lock()
            if let result {
                finished = true
                self.result = nil
                lock.unlock()
                c.resume(with: result)
            } else if finished {
                lock.unlock()
                c.resume(throwing: CancellationError())
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    func resume(_ value: Result<T, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let c = continuation {
            continuation = nil
            finished = true
            lock.unlock()
            c.resume(with: value)
        } else if result == nil {
            result = value
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
