import Foundation
import LightCore
import NetKit
import YeelightCodec
@testable import YeelightProvider

/// In-memory `YeelightConnector`: hosts map to fake bulbs; hosts can refuse a number of connects
/// (LAN Control off) and live connections can be dropped.
final class InMemoryConnector: YeelightConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var bulbs: [String: FakeYeelightBulb] = [:]
    private var refusals: [String: Int] = [:]
    private var connections: [String: [InMemoryConnection]] = [:]
    private var _connectCount: [String: Int] = [:]

    func add(_ bulb: FakeYeelightBulb, at host: String) { lock.locked { bulbs[host] = bulb } }

    /// Refuse the next `count` connects to `host` (`Int.max` = always).
    func refuse(_ host: String, count: Int = .max) { lock.locked { refusals[host] = count } }

    func connectCount(_ host: String) -> Int { lock.locked { _connectCount[host, default: 0] } }

    /// Drops every open connection to `host` (bulb rebooted / Wi-Fi blip).
    func drop(_ host: String) async {
        let conns = lock.locked { connections.removeValue(forKey: host) ?? [] }
        for c in conns { c.peerClosed() }
    }

    func openConnections(_ host: String) -> Int { lock.locked { connections[host]?.count ?? 0 } }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any YeelightConnection {
        let outcome: Result<FakeYeelightBulb, YeelightTransportError> = lock.locked {
            _connectCount[host, default: 0] += 1
            if let n = refusals[host], n > 0 {
                refusals[host] = n == .max ? n : n - 1
                return .failure(.connectionRefused)
            }
            guard let bulb = bulbs[host] else { return .failure(.timedOut) }
            return .success(bulb)
        }
        switch outcome {
        case .failure(let e):
            if e == .timedOut { try await Task.sleep(for: min(timeout, .milliseconds(50))) }
            throw e
        case .success(let bulb):
            let conn = InMemoryConnection(bulb: bulb)
            lock.locked { connections[host, default: []].append(conn) }
            return conn
        }
    }
}

final class InMemoryConnection: YeelightConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let bulb: FakeYeelightBulb
    private let lock = NSLock()
    private var framer = YeelightLineFramer()
    private var token: UUID?
    private var closed = false

    init(bulb: FakeYeelightBulb) {
        self.bulb = bulb
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let continuation = self.continuation
        token = bulb.attach { continuation.yield($0) }
    }

    func send(_ data: Data) async throws {
        let lines: [Data] = try lock.locked {
            guard !closed else { throw YeelightTransportError.connectionLost }
            return framer.append(data)
        }
        let continuation = self.continuation
        for line in lines { bulb.handle(line: line) { continuation.yield($0) } }
    }

    func peerClosed() {
        detach()
        continuation.finish()
    }

    func close() async {
        detach()
        continuation.finish()
    }

    private func detach() {
        let t: UUID? = lock.locked {
            closed = true
            defer { token = nil }
            return token
        }
        if let t { bulb.detach(t) }
    }
}

/// Scripted discovery backend.
struct FakeDiscoveryBackend: YeelightDiscoveryBackend {
    var multicast: [YeelightAdvertisement] = []
    /// host -> advertisement answered to a unicast search.
    var unicast: [String: YeelightAdvertisement] = [:]
    var bonjourHits: [YeelightBonjourHit] = []
    var sweep: [IPv4Addr] = []

    func multicastSearch(timeout: Duration) -> AsyncStream<YeelightAdvertisement> {
        AsyncStream { c in
            for a in multicast { c.yield(a) }
            c.finish()
        }
    }

    func unicastSearch(host: String, timeout: Duration) async -> YeelightAdvertisement? { unicast[host] }

    func bonjour(timeout: Duration) -> AsyncStream<YeelightBonjourHit> {
        AsyncStream { c in
            for h in bonjourHits { c.yield(h) }
            c.finish()
        }
    }

    func sweepHosts() -> [IPv4Addr] { sweep }
}

/// Collects provider events for assertions.
actor EventRecorder {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { [weak self] in
            for await e in stream { await self?.append(e) }
        }
    }

    private func append(_ e: ProviderEvent) { events.append(e) }

    /// Waits until an event matches (polling), up to `timeout`.
    func waitFor(timeout: Duration = .seconds(3), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let e = events.first(where: predicate) { return e }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events.first(where: predicate)
    }

    func clear() { events.removeAll() }
}

/// Polls `condition` until true or `timeout`.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension YeelightProvider.Configuration {
    /// Fast timeouts/backoff for tests.
    static func test(
        requestTimeout: Duration = .milliseconds(500),
        rateLimit: RateLimiter<String>.Limit = RateLimiter<String>.Limit(60, per: .seconds(60))
    ) -> YeelightProvider.Configuration {
        YeelightProvider.Configuration(
            session: YeelightSession.Options(
                connectTimeout: .milliseconds(500), requestTimeout: requestTimeout, keepAlive: true,
                backoff: ExponentialBackoff(initial: .milliseconds(20), multiplier: 2, maximum: .milliseconds(200), jitter: 0)
            ),
            rateLimit: rateLimit,
            probeTimeout: .milliseconds(300),
            sweepConcurrency: 8,
            pairAttempts: 3
        )
    }
}
