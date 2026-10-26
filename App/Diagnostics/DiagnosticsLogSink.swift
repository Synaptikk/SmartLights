import Foundation
import Synchronization

/// One log line shown in Settings > Diagnostics and written into the export bundle.
struct DiagnosticsLogLine: Sendable, Identifiable, Hashable {
    enum Source: String, Sendable {
        /// Read back from `OSLogStore` (anything logged through `LightCore.Log`).
        case osLog = "oslog"
        /// Written directly into `DiagnosticsLogSink` (collector notes, probe results).
        case app = "app"
    }

    let id: UUID
    let date: Date
    let level: String
    let source: Source
    let subsystem: String
    let category: String
    let message: String

    init(date: Date = Date(), level: String, source: Source, subsystem: String, category: String, message: String) {
        id = UUID()
        self.date = date
        self.level = level
        self.source = source
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }

    /// One-line text form used by the export bundle. Not redacted here; the bundle is redacted as a whole.
    var formatted: String {
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "\(stamp) [\(level)] \(subsystem)/\(category) (\(source.rawValue)): \(message)"
    }
}

/// In-app log sink: a bounded, thread-safe ring buffer. Complements `OSLogStore`, which on iOS
/// often returns only persisted (notice and above) entries and nothing from earlier launches.
/// Callable from any isolation domain.
final class DiagnosticsLogSink: Sendable {
    static let shared = DiagnosticsLogSink()

    static let subsystem = "com.sinap.smartlights.app"

    let capacity: Int
    private let lines: Mutex<[DiagnosticsLogLine]>

    init(capacity: Int = 1_000) {
        self.capacity = max(1, capacity)
        lines = Mutex([])
    }

    func append(_ message: String, level: String = "INFO", category: String = "diagnostics") {
        append(DiagnosticsLogLine(level: level, source: .app, subsystem: Self.subsystem, category: category, message: message))
    }

    func append(_ line: DiagnosticsLogLine) {
        let capacity = capacity
        lines.withLock { buffer in
            buffer.append(line)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
    }

    func snapshot() -> [DiagnosticsLogLine] {
        lines.withLock { $0 }
    }

    func clear() {
        lines.withLock { $0.removeAll() }
    }
}
