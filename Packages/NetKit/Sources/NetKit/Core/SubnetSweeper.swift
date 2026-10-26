import Foundation

/// Concurrency-limited unicast sweep over a list of hosts using a caller-supplied probe
/// (e.g. WiZ `getPilot`, LIFX `GetService`, AiDot discovery datagram). Pure Swift concurrency;
/// the Apple-only `SubnetSweeper.currentWiFiHosts()` supplies the host list from `getifaddrs`.
public struct SubnetSweeper: Sendable {
    /// Maximum probes in flight at once.
    public var maxConcurrent: Int
    /// Optional pause between launching probes (rate limiting); `nil` = launch immediately.
    public var launchInterval: Duration?

    public init(maxConcurrent: Int = 32, launchInterval: Duration? = nil) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.launchInterval = launchInterval
    }

    /// Probes every host and returns the non-`nil` results in completion order.
    /// Cancelling the calling task stops launching new probes and cancels running ones.
    public func sweep<R: Sendable>(
        _ hosts: [IPv4Addr],
        probe: @escaping @Sendable (IPv4Addr) async -> R?
    ) async -> [R] {
        var results: [R] = []
        for await result in stream(hosts, probe: probe) { results.append(result) }
        return results
    }

    /// Streams non-`nil` probe results as they arrive. Terminating the stream cancels the sweep.
    public func stream<R: Sendable>(
        _ hosts: [IPv4Addr],
        probe: @escaping @Sendable (IPv4Addr) async -> R?
    ) -> AsyncStream<R> {
        let (stream, continuation) = AsyncStream<R>.makeStream()
        let limit = maxConcurrent
        let interval = launchInterval
        let task = Task {
            await withTaskGroup(of: R?.self) { group in
                var iterator = hosts.makeIterator()
                var launched = 0
                while launched < limit, let host = iterator.next() {
                    group.addTask { await probe(host) }
                    launched += 1
                }
                while let result = await group.next() {
                    if let result { continuation.yield(result) }
                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }
                    if let interval { try? await Task.sleep(for: interval) }
                    if let host = iterator.next() {
                        group.addTask { await probe(host) }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
