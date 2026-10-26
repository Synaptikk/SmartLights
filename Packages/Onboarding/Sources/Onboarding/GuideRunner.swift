import Foundation
import LightCore
import Observation

/// What a step produced. Secrets (`.secret`, `.file`) never appear in `description`.
public enum StepAnswer: Sendable, Equatable, CustomStringConvertible {
    case done
    case confirmed(Bool)
    case text(String)
    case secret(String)
    case file(Data)
    case choice(Int)
    case discovered([DiscoveredDevice])
    case paired(PairedDevice)

    public var description: String {
        switch self {
        case .done: "done"
        case .confirmed(let v): "confirmed(\(v))"
        case .text(let v): "text(\(v))"
        case .secret: "secret(<redacted>)"
        case .file(let d): "file(\(d.count) bytes)"
        case .choice(let i): "choice(\(i))"
        case .discovered(let d): "discovered(\(d.count))"
        case .paired(let p): "paired(\(p.storeKey))"
        }
    }

    var isSensitive: Bool {
        switch self {
        case .secret, .file: true
        default: false
        }
    }
}

/// A prompt raised by a provider through `PairingInteraction`, shown by the wizard UI.
public struct PromptRequest: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case confirm(String)
        case text(String)
        case secureText(String)
        case importFile(String, allowedTypes: [String])
        case choose(String, options: [String])
    }

    public let id: Int
    public let kind: Kind

    public var message: String {
        switch kind {
        case .confirm(let m), .text(let m), .secureText(let m), .importFile(let m, _), .choose(let m, _): m
        }
    }
}

/// The user's answer to a `PromptRequest`. `.text` answers both text and secure-text prompts.
public enum PromptResponse: Sendable, Equatable {
    case confirm(Bool)
    case text(String)
    case file(Data)
    case choice(Int)
}

/// Passed to the app's action handler for provider-driven steps.
public struct GuideActionContext: Sendable {
    public let guide: BrandGuide
    public let step: GuideStep
    public let action: ActionKind
    /// Answers collected so far (e.g. a manual IP from an earlier step).
    public let answers: [String: StepAnswer]
    /// Pass this to `LightProvider.pair(_:using:)`; its prompts appear in the wizard.
    public let ui: any PairingInteraction

    public var brand: Brand? { guide.brand }
    public var callback: String? { step.callback }
}

/// Walks a `BrandGuide` step by step and bridges provider `PairingInteraction` prompts into UI prompts.
///
/// Usage (app side):
/// ```swift
/// let runner = GuideRunner(guide: GuideCatalog.hue)
/// runner.actionHandler = { ctx in
///     switch ctx.callback {
///     case GuideCallback.pair: .paired(try await hue.pair(device, using: ctx.ui))
///     default: .done
///     }
/// }
/// ```
/// While the handler runs, `ui.confirm("Press the button...")` sets `pendingPrompt`; the UI shows it and
/// calls `respond(_:)` or `cancelPrompt()`.
@MainActor
@Observable
public final class GuideRunner: PairingInteraction {
    public typealias ActionHandler = @MainActor @Sendable (GuideActionContext) async throws -> StepAnswer

    public enum Activity: Sendable, Equatable {
        case idle
        case running(stepID: String)
        case failed(stepID: String, message: String)
    }

    public let guide: BrandGuide
    public private(set) var currentIndex: Int = 0
    public private(set) var isFinished = false
    public private(set) var answers: [String: StepAnswer] = [:]
    /// Ticked checklist item indices per step id.
    public private(set) var checked: [String: Set<Int>] = [:]
    public private(set) var activity: Activity = .idle
    /// Prompt waiting for the user (raised by a provider through `PairingInteraction`).
    public private(set) var pendingPrompt: PromptRequest?
    /// Latest `PairingInteraction.status` line.
    public private(set) var statusMessage: String?

    /// Runs provider-driven steps (`scan`, `verifyBlink`, or any step with a `callback`).
    /// Without a handler those steps complete immediately with a default answer (previews, tests).
    @ObservationIgnored public var actionHandler: ActionHandler?
    /// Called whenever a prompt is raised (used by `ScriptedUI`; the SwiftUI views observe `pendingPrompt`).
    @ObservationIgnored public var onPrompt: (@MainActor (PromptRequest) -> Void)?
    /// Called for every status line.
    @ObservationIgnored public var onStatus: (@MainActor (String) -> Void)?

    @ObservationIgnored private var continuation: CheckedContinuation<PromptResponse, any Error>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var lastPromptID = 0

    public init(guide: BrandGuide, actionHandler: ActionHandler? = nil) {
        self.guide = guide
        self.actionHandler = actionHandler
        self.isFinished = guide.steps.isEmpty
    }

    // MARK: Navigation

    public var steps: [GuideStep] { guide.steps }
    public var currentStep: GuideStep? { guide.steps.indices.contains(currentIndex) && !isFinished ? guide.steps[currentIndex] : nil }
    public var isFirstStep: Bool { currentIndex == 0 }
    public var isLastStep: Bool { currentIndex == guide.steps.count - 1 }
    public var isBusy: Bool { if case .running = activity { true } else { false } }
    /// 0...1 for a progress bar.
    public var progress: Double {
        guard !guide.steps.isEmpty else { return 1 }
        return isFinished ? 1 : Double(currentIndex) / Double(guide.steps.count)
    }

    public func answer(for stepID: String) -> StepAnswer? { answers[stepID] }

    /// Whether `next()` may move on from the current step.
    public var canAdvance: Bool {
        guard let step = currentStep, !isBusy else { return false }
        if step.isOptional { return true }
        switch step.kind {
        case .info, .troubleshoot:
            return true
        case .checklist(let items):
            return checked[step.id, default: []].isSuperset(of: Set(items.indices))
        case .action:
            return answers[step.id] != nil
        }
    }

    /// Moves to the next step (or finishes). Returns false if the current step is not complete.
    @discardableResult
    public func next() -> Bool {
        guard canAdvance else { return false }
        if currentIndex + 1 < guide.steps.count {
            currentIndex += 1
            if case .failed = activity { activity = .idle }
        } else {
            isFinished = true
        }
        return true
    }

    @discardableResult
    public func back() -> Bool {
        guard !isBusy else { return false }
        if isFinished, !guide.steps.isEmpty {
            isFinished = false
            currentIndex = guide.steps.count - 1
            return true
        }
        guard currentIndex > 0 else { return false }
        currentIndex -= 1
        activity = .idle
        return true
    }

    /// Jump to a step by id (e.g. from a troubleshooting link). Cancels a running action.
    public func go(to stepID: String) {
        guard let index = guide.steps.firstIndex(where: { $0.id == stepID }) else { return }
        cancelAction()
        isFinished = false
        currentIndex = index
    }

    public func restart() {
        cancelAction()
        currentIndex = 0
        isFinished = guide.steps.isEmpty
        answers = [:]
        checked = [:]
        statusMessage = nil
        activity = .idle
    }

    // MARK: Step input

    public func toggle(item index: Int) {
        guard let step = currentStep, case .checklist(let items) = step.kind, items.indices.contains(index) else { return }
        var set = checked[step.id, default: []]
        if set.contains(index) { set.remove(index) } else { set.insert(index) }
        checked[step.id] = set
    }

    public func isChecked(_ index: Int, in stepID: String) -> Bool {
        checked[stepID, default: []].contains(index)
    }

    /// Record an answer the wizard collected itself (text field, secure field, file, choice, confirm).
    /// For a `.confirm` step that has a provider callback, use `perform()` instead.
    public func submit(_ answer: StepAnswer) {
        guard let step = currentStep, !isBusy else { return }
        answers[step.id] = answer
        if case .failed = activity { activity = .idle }
    }

    /// Runs the current action step: provider-driven steps go through `actionHandler`;
    /// local steps (`confirm`, `openApp`) are recorded as done.
    public func perform() {
        guard let step = currentStep, let kind = step.actionKind, !isBusy else { return }
        guard step.isProviderDriven, let handler = actionHandler else {
            answers[step.id] = Self.defaultAnswer(for: kind)
            activity = .idle
            return
        }
        activity = .running(stepID: step.id)
        statusMessage = nil
        let context = GuideActionContext(guide: guide, step: step, action: kind, answers: answers, ui: self)
        actionTask = Task { [weak self] in
            do {
                let answer = try await handler(context)
                self?.finishAction(stepID: step.id, result: .success(answer))
            } catch {
                self?.finishAction(stepID: step.id, result: .failure(error))
            }
        }
    }

    /// Cancels a running provider action and any pending prompt.
    public func cancelAction() {
        actionTask?.cancel()
        actionTask = nil
        failPendingPrompt(LightCoreError.userCancelled)
        if isBusy { activity = .idle }
    }

    /// Waits for the running action (tests and previews).
    public func waitForAction() async {
        await actionTask?.value
    }

    /// Replaces collected secrets/files with `.done` once the app has moved them to the Keychain.
    public func clearSecrets() {
        for (key, value) in answers where value.isSensitive { answers[key] = .done }
    }

    private func finishAction(stepID: String, result: Result<StepAnswer, any Error>) {
        actionTask = nil
        failPendingPrompt(LightCoreError.userCancelled)
        switch result {
        case .success(let answer):
            answers[stepID] = answer
            activity = .idle
        case .failure(let error):
            if Self.isCancellation(error) {
                activity = .idle
            } else {
                activity = .failed(stepID: stepID, message: Self.message(for: error))
            }
        }
    }

    static func defaultAnswer(for kind: ActionKind) -> StepAnswer {
        switch kind {
        case .confirm: .confirmed(true)
        case .scan, .verifyBlink, .openApp, .text, .secureText, .importFile, .choose: .done
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? LightCoreError) == .userCancelled
    }

    static func message(for error: any Error) -> String {
        if let error = error as? any LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }

    // MARK: Prompt bridge (UI side)

    /// `pendingPrompt` as a settable property for `.sheet(item: $runner.presentedPrompt)`.
    /// Setting it does nothing: prompts are closed only through `respond(_:)` or `cancelPrompt()`,
    /// so a sheet dismissal can never drop a provider's continuation by accident.
    public var presentedPrompt: PromptRequest? {
        get { pendingPrompt }
        set { _ = newValue }
    }

    /// Answer the pending prompt.
    public func respond(_ response: PromptResponse) {
        guard let continuation else { return }
        self.continuation = nil
        pendingPrompt = nil
        continuation.resume(returning: response)
    }

    /// Dismiss the pending prompt; the provider receives `LightCoreError.userCancelled`.
    public func cancelPrompt() {
        failPendingPrompt(LightCoreError.userCancelled)
    }

    private func cancelPrompt(id: Int) {
        guard pendingPrompt?.id == id else { return }
        cancelPrompt()
    }

    private func failPendingPrompt(_ error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        pendingPrompt = nil
        continuation.resume(throwing: error)
    }

    private func ask(_ kind: PromptRequest.Kind) async throws -> PromptResponse {
        if Task.isCancelled { throw LightCoreError.userCancelled }
        // Only one prompt at a time: a new one supersedes (cancels) an unanswered one.
        failPendingPrompt(LightCoreError.userCancelled)
        lastPromptID += 1
        let request = PromptRequest(id: lastPromptID, kind: kind)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PromptResponse, any Error>) in
                self.continuation = continuation
                self.pendingPrompt = request
                self.onPrompt?(request)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPrompt(id: request.id) }
        }
    }

    // MARK: PairingInteraction (provider side)

    public func confirm(_ message: String) async throws -> Bool {
        guard case .confirm(let value) = try await ask(.confirm(message)) else {
            throw LightCoreError.protocolError("expected confirm")
        }
        return value
    }

    public func text(_ prompt: String) async throws -> String {
        guard case .text(let value) = try await ask(.text(prompt)) else {
            throw LightCoreError.protocolError("expected text")
        }
        return value
    }

    public func secureText(_ prompt: String) async throws -> String {
        guard case .text(let value) = try await ask(.secureText(prompt)) else {
            throw LightCoreError.protocolError("expected secure text")
        }
        return value
    }

    public func importFile(_ prompt: String, allowedTypes: [String]) async throws -> Data {
        guard case .file(let value) = try await ask(.importFile(prompt, allowedTypes: allowedTypes)) else {
            throw LightCoreError.protocolError("expected file")
        }
        return value
    }

    public func choose(_ prompt: String, options: [String]) async throws -> Int {
        guard case .choice(let value) = try await ask(.choose(prompt, options: options)), options.indices.contains(value) else {
            throw LightCoreError.protocolError("expected valid choice")
        }
        return value
    }

    public func status(_ message: String) async {
        statusMessage = message
        onStatus?(message)
    }
}
