import Foundation

/// Exponential backoff with an optional cap and jitter.
///
/// `delay(forAttempt: n) = min(initial * multiplier^n, maximum)`; `nextDelay()` returns that for the
/// current attempt (reduced by up to `jitter * 100`% at random) and advances the attempt counter.
public struct ExponentialBackoff: Sendable, Equatable {
    public var initial: Duration
    public var multiplier: Double
    public var maximum: Duration
    /// 0 = deterministic; 0.5 = each delay is randomly reduced by up to 50%.
    public var jitter: Double
    public private(set) var attempt: Int = 0

    public init(initial: Duration = .seconds(1), multiplier: Double = 2, maximum: Duration = .seconds(60), jitter: Double = 0) {
        self.initial = initial
        self.multiplier = max(1, multiplier)
        self.maximum = maximum
        self.jitter = min(max(jitter, 0), 1)
    }

    /// The un-jittered delay for zero-based attempt `n`.
    public func delay(forAttempt n: Int) -> Duration {
        let base = initial.timeInterval
        let cap = maximum.timeInterval
        let value = base * pow(multiplier, Double(max(0, n)))
        guard value.isFinite, value < cap else { return maximum }
        return .seconds(value)
    }

    public mutating func nextDelay() -> Duration {
        var rng = SystemRandomNumberGenerator()
        return nextDelay(using: &rng)
    }

    public mutating func nextDelay<G: RandomNumberGenerator>(using generator: inout G) -> Duration {
        let d = delay(forAttempt: attempt)
        attempt += 1
        guard jitter > 0 else { return d }
        let factor = 1 - jitter * Double.random(in: 0..<1, using: &generator)
        return .seconds(d.timeInterval * factor)
    }

    public mutating func reset() { attempt = 0 }

    /// Hue event stream reconnect policy (aiohue uses roughly `min(2 * attempts, 600)` s;
    /// we use exponential from 1 s capped at 600 s with 20% jitter).
    public static let hueEventStream = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(600), jitter: 0.2)
}

extension Duration {
    /// The duration in (fractional) seconds.
    public var timeInterval: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
