import Foundation
import Synchronization

/// Time-boxing for diagnostics probes.
enum DiagnosticsProbe {
    /// Runs `operation` in a detached task (never on the main actor) and returns its result, or
    /// `fallback` once `timeout` elapses or the calling task is cancelled, whichever comes first.
    /// On timeout/cancellation the operation's task is cancelled and NOT awaited, so a probe that
    /// ignores cancellation cannot stall the caller.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let gate = FirstResultGate<T>()
        let work = Task.detached(priority: .utility) {
            let value = await operation()
            gate.finish(value)
        }
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            gate.finish(fallback)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                gate.install(continuation)
            }
        } onCancel: {
            gate.finish(fallback)
        }
        work.cancel()
        timer.cancel()
        return result
    }
}

/// Single-assignment rendezvous: the first `finish` wins; `install` may come before or after it.
private final class FirstResultGate<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Never>)
        case ready(T)
        case done
    }

    private let state = Mutex<State>(.idle)

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let ready: T? = state.withLock { s in
            switch s {
            case .idle:
                s = .waiting(continuation)
                return nil
            case .ready(let value):
                s = .done
                return value
            case .waiting, .done:
                return nil
            }
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ value: T) {
        let continuation: CheckedContinuation<T, Never>? = state.withLock { s in
            switch s {
            case .idle:
                s = .ready(value)
                return nil
            case .waiting(let c):
                s = .done
                return c
            case .ready, .done:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}
