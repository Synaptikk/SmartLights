import Foundation

/// UI callbacks a provider uses while pairing (link-button confirm, key import, login form).
/// The app implements this on top of the onboarding wizard; tests use `ScriptedPairingInteraction`.
/// Every method throws `LightCoreError.userCancelled` when the user dismisses the prompt.
public protocol PairingInteraction: Sendable {
    /// Ask the user to do something and confirm ("Press the link button on the bridge").
    /// Returns false if the user answered "No"/"Not now".
    func confirm(_ message: String) async throws -> Bool
    /// Plain text entry (username, IP address, country code).
    func text(_ prompt: String) async throws -> String
    /// Secure text entry (password, API key). Never log the result.
    func secureText(_ prompt: String) async throws -> String
    /// Pick a file (e.g. WiZ key JSON). `allowedTypes` are UTType identifiers or file extensions.
    func importFile(_ prompt: String, allowedTypes: [String]) async throws -> Data
    /// Choose one of `options`; returns the selected index.
    func choose(_ prompt: String, options: [String]) async throws -> Int
    /// Non-blocking progress/status line ("Waiting for link button... 25 s").
    func status(_ message: String) async
}

extension PairingInteraction {
    public func status(_ message: String) async {}
}

/// Deterministic `PairingInteraction` for tests: answers come from a queue in order.
public actor ScriptedPairingInteraction: PairingInteraction {
    public enum Answer: Sendable {
        case confirm(Bool)
        case text(String)
        case file(Data)
        case choice(Int)
        case cancel
    }

    private var answers: [Answer]
    /// Prompts received, in order (for assertions).
    public private(set) var prompts: [String] = []

    public init(_ answers: [Answer]) {
        self.answers = answers
    }

    private func next(_ prompt: String) throws -> Answer {
        prompts.append(prompt)
        guard !answers.isEmpty else { throw LightCoreError.userCancelled }
        let answer = answers.removeFirst()
        if case .cancel = answer { throw LightCoreError.userCancelled }
        return answer
    }

    public func confirm(_ message: String) async throws -> Bool {
        guard case .confirm(let v) = try next(message) else { throw LightCoreError.protocolError("expected confirm") }
        return v
    }

    public func text(_ prompt: String) async throws -> String {
        guard case .text(let v) = try next(prompt) else { throw LightCoreError.protocolError("expected text") }
        return v
    }

    public func secureText(_ prompt: String) async throws -> String {
        guard case .text(let v) = try next(prompt) else { throw LightCoreError.protocolError("expected secure text") }
        return v
    }

    public func importFile(_ prompt: String, allowedTypes: [String]) async throws -> Data {
        guard case .file(let v) = try next(prompt) else { throw LightCoreError.protocolError("expected file") }
        return v
    }

    public func choose(_ prompt: String, options: [String]) async throws -> Int {
        guard case .choice(let v) = try next(prompt), options.indices.contains(v) else {
            throw LightCoreError.protocolError("expected valid choice")
        }
        return v
    }

    public func status(_ message: String) async {
        prompts.append(message)
    }
}
