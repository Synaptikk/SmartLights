import Foundation

/// Daily request budget for one Govee API key (~10,000 requests/day).
///
/// Polling must leave room for user commands and device-list refreshes, so only
/// `1 - reserveFraction` of the daily limit is spent on state polling.
public struct GoveeCloudBudget: Sendable, Hashable {
    public var dailyLimit: Int
    /// Share of the daily limit kept for control commands and device lists.
    public var reserveFraction: Double
    /// Never poll faster than this (the task requires 60 s).
    public var minimumPollInterval: Duration

    public init(dailyLimit: Int = 10_000, reserveFraction: Double = 0.3, minimumPollInterval: Duration = .seconds(60)) {
        self.dailyLimit = max(1, dailyLimit)
        self.reserveFraction = min(max(reserveFraction, 0), 0.95)
        self.minimumPollInterval = minimumPollInterval
    }

    public static let `default` = GoveeCloudBudget()

    /// Requests per day available for polling.
    public var pollingAllowance: Int { Int(Double(dailyLimit) * (1 - reserveFraction)) }

    /// Requests per day reserved for commands.
    public var commandReserve: Int { dailyLimit - pollingAllowance }

    /// Poll interval (one `device/state` request per device per tick) that keeps
    /// `devices` polls/day within `pollingAllowance`; at least `minimumPollInterval`.
    /// Nil when nothing needs polling.
    public func pollInterval(devices: Int) -> Duration? {
        guard devices > 0 else { return nil }
        let allowance = max(1, pollingAllowance)
        let seconds = (86_400.0 * Double(devices) / Double(allowance)).rounded(.up)
        let minimum = Double(minimumPollInterval.components.seconds)
        return .seconds(Int64(max(seconds, minimum)))
    }

    /// Requests per day spent by polling `devices` every `interval`.
    public func pollsPerDay(devices: Int, interval: Duration) -> Int {
        let s = max(1, Double(interval.components.seconds))
        return Int((86_400.0 / s).rounded(.down)) * max(0, devices)
    }
}

/// Counts requests per UTC day for one API key and combines that with server rate-limit headers.
/// Govee does not document when the daily window resets; UTC midnight is assumed `[verify]`.
public struct GoveeDailyQuota: Sendable, Hashable {
    public var budget: GoveeCloudBudget
    public private(set) var day: Int
    public private(set) var used: Int = 0
    /// Last `Remaining` value reported by the server (if any) for the current window.
    public private(set) var serverRemaining: Int?
    public private(set) var serverReset: Date?

    public init(budget: GoveeCloudBudget = .default, now: Date = Date()) {
        self.budget = budget
        self.day = Self.dayNumber(now)
    }

    static func dayNumber(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    mutating func roll(_ now: Date) {
        let d = Self.dayNumber(now)
        if d != day {
            day = d
            used = 0
            serverRemaining = nil
            serverReset = nil
        }
        if let reset = serverReset, now >= reset {
            serverRemaining = nil
            serverReset = nil
        }
    }

    /// Requests left today by our own count and by the server's.
    public mutating func remaining(now: Date = Date()) -> Int {
        roll(now)
        let own = budget.dailyLimit - used
        return min(own, serverRemaining ?? own)
    }

    /// Whether a request of `kind` may be sent now. Polls must leave the command reserve.
    public mutating func canSpend(polling: Bool, now: Date = Date()) -> Bool {
        let left = remaining(now: now)
        return polling ? left > budget.commandReserve : left > 0
    }

    /// Records one sent request.
    public mutating func record(now: Date = Date()) {
        roll(now)
        used += 1
        if let r = serverRemaining { serverRemaining = max(0, r - 1) }
    }

    /// Applies rate-limit headers from a response. Only a limit that looks daily (>= 1000) is
    /// taken as the daily window; per-minute windows are handled by the per-endpoint limiters.
    public mutating func update(_ info: GoveeRateLimitInfo, now: Date = Date()) {
        roll(now)
        guard let remaining = info.remaining else { return }
        if let limit = info.limit, limit < 1000 { return }
        serverRemaining = remaining
        serverReset = info.reset
    }

    /// Marks the budget as exhausted until `until` (after a daily 429).
    public mutating func exhaust(until: Date? = nil, now: Date = Date()) {
        roll(now)
        serverRemaining = 0
        serverReset = until
    }
}
