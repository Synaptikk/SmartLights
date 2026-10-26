import Foundation
import LightCore

/// Rate-limits UI-driven commands: at most one command in flight per key, newer commands
/// merge into the queued one (latest wins), and sends start at most every `minimumInterval`
/// (100 ms = 10/s, the strictest per-light vendor limit, Hue).
///
/// Keys are a single light or a room; a room key dispatches one group command so providers
/// can use native groups (Hue grouped_light).
@MainActor
final class CommandCoalescer {
    enum Key: Hashable, Sendable {
        case light(LightID)
        case room(Room.ID)
        /// Any other caller-defined group (intents, scene recall).
        case group(String)
    }

    enum Event {
        /// A command for `targets` is about to go to the providers.
        case willSend(targets: [LightID])
        /// A send finished. `idle` is true when nothing more is queued for that key.
        case finished(targets: [LightID], error: (any Error)?, duration: Duration, idle: Bool)
    }

    typealias Sender = @Sendable (LightCommand, [LightID]) async throws -> Void

    private struct Entry {
        var pending: LightCommand?
        var targets: [LightID]
        var worker: Task<Void, Never>?
    }

    private var entries: [Key: Entry] = [:]
    private let minimumInterval: Duration
    private let sender: Sender

    /// Called on the main actor for every send/finish.
    var onEvent: (@MainActor (Event) -> Void)?

    init(minimumInterval: Duration = .milliseconds(100), sender: @escaping Sender) {
        self.minimumInterval = minimumInterval
        self.sender = sender
    }

    func enqueue(_ command: LightCommand, key: Key, targets: [LightID]) {
        guard !targets.isEmpty, !command.isEmpty else { return }
        var entry = entries[key] ?? Entry(pending: nil, targets: targets, worker: nil)
        entry.pending = entry.pending.map { $0.merging(command) } ?? command
        entry.targets = targets
        let startWorker = entry.worker == nil
        entries[key] = entry
        if startWorker {
            entries[key]?.worker = Task { [weak self] in
                await self?.drain(key)
            }
        }
    }

    /// True while a command for `id` is queued or in flight (under any key).
    func isBusy(_ id: LightID) -> Bool {
        entries.values.contains { $0.targets.contains(id) }
    }

    var isIdle: Bool { entries.isEmpty }

    private func drain(_ key: Key) async {
        while let entry = entries[key], let command = entry.pending {
            entries[key]?.pending = nil
            let targets = entry.targets
            onEvent?(.willSend(targets: targets))

            let started = ContinuousClock.now
            var failure: (any Error)?
            do {
                try await sender(command, targets)
            } catch {
                failure = error
            }
            let elapsed = ContinuousClock.now - started
            if elapsed < minimumInterval {
                try? await Task.sleep(for: minimumInterval - elapsed)
            }

            let idle = entries[key]?.pending == nil
            if idle { entries[key] = nil }
            onEvent?(.finished(targets: targets, error: failure, duration: elapsed, idle: idle))
            if idle { return }
        }
        entries[key] = nil
    }
}
