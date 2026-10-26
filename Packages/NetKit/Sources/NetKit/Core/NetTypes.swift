import Foundation

/// A received UDP datagram.
public struct Datagram: Sendable, Hashable {
    public var data: Data
    public var host: IPv4Addr
    public var port: UInt16

    public init(data: Data, host: IPv4Addr, port: UInt16) {
        self.data = data
        self.host = host
        self.port = port
    }
}

/// Whether this process may send IPv4 broadcast (iOS needs `com.apple.developer.networking.multicast`).
public enum BroadcastCapabilityStatus: String, Sendable, Codable, CaseIterable {
    /// A broadcast send succeeded.
    case entitled
    /// Broadcast send failed with EACCES/EPERM while unicast local networking is allowed.
    case notEntitled
    /// The user denied Local Network access; nothing local works until they enable it.
    case localNetworkDenied
    /// Could not determine (no Wi-Fi, other errors).
    case unknown

    /// Pure classification used by `BroadcastCapability`.
    /// - Parameters:
    ///   - sendErrno: `nil` if the broadcast send succeeded, else the `errno` it failed with.
    ///   - localNetworkDenied: result of a Local Network permission check if one was made.
    public static func classify(sendErrno: Int32?, localNetworkDenied: Bool?) -> BroadcastCapabilityStatus {
        if localNetworkDenied == true { return .localNetworkDenied }
        guard let code = sendErrno else { return .entitled }
        switch code {
        case EACCES, EPERM: return .notEntitled
        default: return .unknown
        }
    }
}

/// Local Network privacy state as far as it can be observed (there is no query API; FB8711182).
public enum LocalNetworkPermission: String, Sendable, Codable {
    case granted
    case denied
    /// No answer yet (prompt showing or never triggered) or no usable interface.
    case undetermined
}

/// Thrown when an operation exceeds its deadline.
public struct NetTimeoutError: Error, Sendable, Equatable {
    public init() {}
}

/// A single-assignment bridge between callback APIs and `async` code. Whichever of
/// `resume(...)` / timeout / cancellation happens first wins; later calls are ignored.
/// Safe to resume before `wait()` is called.
final class ResumeGate<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, any Error>)
        case ready(Result<T, any Error>)
        case done
    }

    private let state = LockedBox<State>(.idle)

    init() {}

    /// Waits for the result; throws ``NetTimeoutError`` after `timeout` and `CancellationError`
    /// if the current task is cancelled.
    func wait(timeout: Duration? = nil) async throws -> T {
        var timer: Task<Void, Never>?
        if let timeout {
            timer = Task { [self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                self.resume(throwing: NetTimeoutError())
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let pending: Result<T, any Error>? = state.withLock { s in
                    switch s {
                    case .idle:
                        s = .waiting(continuation)
                        return nil
                    case .ready(let result):
                        s = .done
                        return result
                    case .waiting, .done:
                        return .failure(CancellationError())
                    }
                }
                if let pending { continuation.resume(with: pending) }
            }
        } onCancel: {
            self.resume(throwing: CancellationError())
        }
    }

    func resume(returning value: T) { resume(with: .success(value)) }
    func resume(throwing error: any Error) { resume(with: .failure(error)) }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { s in
            switch s {
            case .idle:
                s = .ready(result)
                return nil
            case .waiting(let c):
                s = .done
                return c
            case .ready, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    var isFinished: Bool {
        state.withLock { s in
            switch s {
            case .ready, .done: return true
            case .idle, .waiting: return false
            }
        }
    }
}

/// Minimal lock-protected box (NSLock based so it works on every platform/OS version).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
