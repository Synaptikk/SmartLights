import Foundation

/// Token bucket per key (e.g. Hue: 10/s per light, 1/s per grouped_light; Yeelight 60/min).
///
/// `acquire` reserves a token immediately (tokens may go negative) and sleeps until it is
/// covered, so concurrent callers are served in call order without busy-waiting.
public actor RateLimiter<Key: Hashable & Sendable> {
    public struct Limit: Sendable, Hashable {
        /// Burst size.
        public var capacity: Double
        /// Tokens added per second.
        public var refillPerSecond: Double

        public init(capacity: Int, refillPerSecond: Double) {
            self.capacity = Double(max(1, capacity))
            self.refillPerSecond = max(refillPerSecond, .leastNonzeroMagnitude)
        }

        /// `count` operations per `interval`, burst `count`.
        public init(_ count: Int, per interval: Duration) {
            let seconds = interval.secondsDouble
            self.init(capacity: count, refillPerSecond: seconds > 0 ? Double(max(1, count)) / seconds : Double(max(1, count)))
        }
    }

    private struct Bucket {
        var tokens: Double
        var last: ContinuousClock.Instant
        var limit: Limit
    }

    private let clock = ContinuousClock()
    private let defaultLimit: Limit
    private var overrides: [Key: Limit] = [:]
    private var buckets: [Key: Bucket] = [:]

    public init(_ limit: Limit) {
        defaultLimit = limit
    }

    public init(capacity: Int, refillPerSecond: Double) {
        self.init(Limit(capacity: capacity, refillPerSecond: refillPerSecond))
    }

    /// Use a different limit for one key (e.g. group ids vs light ids).
    public func setLimit(_ limit: Limit, for key: Key) {
        overrides[key] = limit
        if var bucket = buckets[key] {
            bucket.limit = limit
            bucket.tokens = min(bucket.tokens, limit.capacity)
            buckets[key] = bucket
        }
    }

    private func refilled(_ key: Key) -> Bucket {
        let now = clock.now
        let limit = overrides[key] ?? defaultLimit
        guard var bucket = buckets[key] else {
            return Bucket(tokens: limit.capacity, last: now, limit: limit)
        }
        let elapsed = (now - bucket.last).secondsDouble
        bucket.tokens = min(bucket.limit.capacity, bucket.tokens + elapsed * bucket.limit.refillPerSecond)
        bucket.last = now
        return bucket
    }

    /// Takes a token if one is available right now.
    public func tryAcquire(_ key: Key) -> Bool {
        var bucket = refilled(key)
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[key] = bucket
        return true
    }

    /// Waits until a token is available for `key`, then takes it. Throws `CancellationError`
    /// if the task is cancelled while waiting (the reservation is returned).
    public func acquire(_ key: Key) async throws {
        try Task.checkCancellation()
        var bucket = refilled(key)
        bucket.tokens -= 1
        buckets[key] = bucket
        guard bucket.tokens < 0 else { return }
        let wait = -bucket.tokens / bucket.limit.refillPerSecond
        do {
            try await Task.sleep(for: .seconds(wait))
        } catch {
            var current = refilled(key)
            current.tokens = min(current.limit.capacity, current.tokens + 1)
            buckets[key] = current
            throw error
        }
    }

    /// Tokens currently available for `key` (diagnostics/tests).
    public func available(_ key: Key) -> Double {
        let bucket = refilled(key)
        buckets[key] = bucket
        return bucket.tokens
    }
}

extension Duration {
    /// Duration as fractional seconds.
    var secondsDouble: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
