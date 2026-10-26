import Foundation
import LightCore

/// Test/preview double for the wizard UI: answers `GuideRunner` prompts from a queue, the way a user
/// tapping through the sheet would. Attach it to a runner, then let a provider call `ui.confirm(...)`.
///
/// ```swift
/// let ui = ScriptedUI([.confirm(true), .text("me@example.com")])
/// ui.attach(to: runner)
/// ```
@MainActor
public final class ScriptedUI {
    public enum Reply: Sendable, Equatable {
        case confirm(Bool)
        case text(String)
        case file(Data)
        case choice(Int)
        /// Dismiss the prompt (provider gets `LightCoreError.userCancelled`).
        case cancel
        /// Leave the prompt open (lets tests exercise task cancellation).
        case ignore
    }

    private var replies: [Reply]
    /// Prompts seen, in order.
    public private(set) var prompts: [PromptRequest] = []
    /// Status lines seen, in order.
    public private(set) var statuses: [String] = []
    private weak var runner: GuideRunner?

    public init(_ replies: [Reply]) {
        self.replies = replies
    }

    /// Prompt messages, in order (for assertions).
    public var messages: [String] { prompts.map(\.message) }
    public var remainingReplies: Int { replies.count }

    public func attach(to runner: GuideRunner) {
        self.runner = runner
        runner.onPrompt = { [weak self] request in self?.handle(request) }
        runner.onStatus = { [weak self] line in self?.statuses.append(line) }
    }

    private func handle(_ request: PromptRequest) {
        prompts.append(request)
        let reply: Reply = replies.isEmpty ? .cancel : replies.removeFirst()
        // Answer on the next main-actor turn, like a real tap.
        Task { @MainActor [weak runner] in
            guard let runner, runner.pendingPrompt?.id == request.id else { return }
            switch reply {
            case .confirm(let v): runner.respond(.confirm(v))
            case .text(let v): runner.respond(.text(v))
            case .file(let v): runner.respond(.file(v))
            case .choice(let v): runner.respond(.choice(v))
            case .cancel: runner.cancelPrompt()
            case .ignore: break
            }
        }
    }
}
