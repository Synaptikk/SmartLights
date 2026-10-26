import Foundation
import OSLog

/// Result of reading the unified log for this process.
struct OSLogReadResult: Sendable {
    var lines: [DiagnosticsLogLine]
    /// Why reading failed or was cut short, if it did.
    var error: String?
}

/// Reads recent entries of this process from `OSLogStore(scope: .currentProcessIdentifier)`,
/// filtered to the `com.sinap.smartlights` subsystem prefix.
///
/// `read` is synchronous and can take a while on a busy log. Call it off the main actor via
/// `DiagnosticsProbe.withTimeout`, which runs it detached and cancels it on timeout (the loop
/// checks `Task.isCancelled`).
enum OSLogCollector {
    static let subsystemPrefix = "com.sinap.smartlights"

    static func read(lookback: TimeInterval = 3_600, limit: Int = 1_500) -> OSLogReadResult {
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            return OSLogReadResult(lines: [], error: "OSLogStore unavailable: \(error.localizedDescription)")
        }
        let position = store.position(date: Date().addingTimeInterval(-lookback))
        let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", subsystemPrefix)

        let entries: AnySequence<OSLogEntry>
        do {
            entries = try store.getEntries(at: position, matching: predicate)
        } catch {
            // Some OS versions reject predicates on this scope; fall back to manual filtering.
            do {
                entries = try store.getEntries(at: position)
            } catch {
                return OSLogReadResult(lines: [], error: "Reading OSLog failed: \(error.localizedDescription)")
            }
        }

        var lines: [DiagnosticsLogLine] = []
        var visited = 0
        var cancelled = false
        for entry in entries {
            visited += 1
            if visited % 200 == 0, Task.isCancelled {
                cancelled = true
                break
            }
            guard let log = entry as? OSLogEntryLog, log.subsystem.hasPrefix(subsystemPrefix) else { continue }
            lines.append(DiagnosticsLogLine(
                date: log.date,
                level: levelName(log.level),
                source: .osLog,
                subsystem: log.subsystem,
                category: log.category,
                message: log.composedMessage
            ))
            if lines.count > limit * 2 { lines.removeFirst(lines.count - limit) }
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        return OSLogReadResult(lines: lines, error: cancelled ? "Stopped early (time limit); log is partial" : nil)
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        case .undefined: "LOG"
        @unknown default: "LOG"
        }
    }
}
