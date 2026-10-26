import Foundation
#if canImport(os)
import os
#endif

/// Logging facade: `os.Logger` on Apple platforms, `print` on Linux.
/// Subsystem is `com.sinap.smartlights.<package>` (CLAUDE.md). Messages are logged as public,
/// so never pass credentials, keys or tokens; use `Log.redact` for anything sensitive.
public struct Log: Sendable {
    public enum Level: Int, Sendable, Comparable, CustomStringConvertible {
        case debug, info, notice, error, fault

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .notice: "NOTICE"
            case .error: "ERROR"
            case .fault: "FAULT"
            }
        }
    }

    public let subsystem: String
    public let category: String

    /// - Parameters:
    ///   - package: lowercase package name, e.g. "huekit", "lightcore".
    ///   - category: area within the package, e.g. "sse", "pairing".
    public init(package: String, category: String) {
        subsystem = "com.sinap.smartlights.\(package)"
        self.category = category
    }

    public static let lightCore = Log(package: "lightcore", category: "core")

    public func log(_ level: Level, _ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .fault: logger.fault("\(text, privacy: .public)")
        }
        #else
        if level == .debug && ProcessInfo.processInfo.environment["SMARTLIGHTS_DEBUG"] == nil { return }
        print("[\(level)] \(subsystem)/\(category): \(message())")
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    public func fault(_ message: @autoclosure () -> String) { log(.fault, message()) }

    /// Placeholder for a sensitive value: reveals only presence and length.
    public static func redact(_ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "<empty>" }
        return "<redacted \(secret.count) chars>"
    }
}
