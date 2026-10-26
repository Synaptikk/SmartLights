import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Something a test (or `simctl`) can start, stop and query for ports.
public protocol Simulator: AnyObject, Sendable {
    /// Human-readable name, e.g. "wiz", "hue", "aidot-cloud".
    var name: String { get }
    /// Binds every socket. Port 0 in a configuration means "pick an ephemeral port".
    func start() async throws
    /// Closes every socket. Safe to call twice.
    func stop() async throws
    /// Bound ports keyed by role, e.g. ["udp": 38899] or ["https": 4433, "http": 8080].
    var boundPorts: [String: Int] { get }
}

public enum SimulatorError: Error, CustomStringConvertible {
    case notStarted
    case alreadyStarted
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .notStarted: return "simulator not started"
        case .alreadyStarted: return "simulator already started"
        case .invalidConfiguration(let s): return "invalid configuration: \(s)"
        }
    }
}

/// Starts and stops a set of simulators together.
///
/// ```swift
/// let runner = SimulatorRunner()
/// let bulb = FakeWiZBulb(.init(port: 0))
/// try await runner.start(bulb)
/// let port = bulb.port!            // or runner.port(of: "wiz", role: "udp")
/// defer { Task { try await runner.stopAll() } }
/// ```
public final class SimulatorRunner: Sendable {
    public let group: any EventLoopGroup
    private let running = NIOLockedValueBox<[any Simulator]>([])

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    @discardableResult
    public func start<S: Simulator>(_ simulator: S) async throws -> S {
        try await simulator.start()
        running.withLockedValue { $0.append(simulator) }
        return simulator
    }

    public func stop(_ simulator: any Simulator) async throws {
        try await simulator.stop()
        running.withLockedValue { $0.removeAll { $0 === simulator } }
    }

    public func stopAll() async throws {
        let all = running.withLockedValue { list -> [any Simulator] in
            defer { list.removeAll() }
            return list
        }
        for s in all.reversed() { try await s.stop() }
    }

    public var simulators: [any Simulator] { running.withLockedValue { $0 } }

    public func simulator(named name: String) -> (any Simulator)? {
        simulators.first { $0.name == name }
    }

    public func port(of name: String, role: String) -> Int? {
        simulator(named: name)?.boundPorts[role]
    }
}

/// Helper used by the fakes to close a list of channels.
func closeAll(_ channels: [any Channel]) async {
    for ch in channels {
        try? await ch.close()
    }
}
