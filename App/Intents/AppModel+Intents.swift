import Foundation
import LightCore

/// Errors an intent reports back to Siri / Shortcuts (spoken or shown as the failure text).
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
    case notFound(String)
    case noLights(String)
    case unsupported(String)
    case commandFailed(String)

    var message: String {
        switch self {
        case .notFound(let name): "SmartLights can't find \(name)."
        case .noLights(let name): "\(name) has no lights."
        case .unsupported(let message): message
        case .commandFailed(let message): message
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
    var errorDescription: String? { message }
}

/// What a command did, for the intent's spoken result.
struct IntentOutcome: Sendable, Equatable {
    var succeeded: [LightID] = []
    /// Names of lights that did not respond.
    var failedNames: [String] = []

    /// " Kitchen Lamp didn't respond." or "".
    var failureSuffix: String {
        guard !failedNames.isEmpty else { return "" }
        return " \(ListFormatter.localizedString(byJoining: failedNames)) didn't respond."
    }
}

/// The fast path Siri and Shortcuts use (T1.10).
///
/// Intents run in the app process, often launched in the background just for the intent. They
/// must answer within a few seconds, so this path never starts discovery: it waits only for the
/// cached lights (`start()` loads `DeviceStore.cachedLights()` first) and for the providers to be
/// registered (providers restore paired devices with their cached IPs), then sends directly
/// through the registry and awaits the result so Siri can report failures. The optimistic UI
/// state is updated afterwards so an open app reflects the change.
extension AppModel {
    /// Makes sure cached lights and the library are loaded. Kicks off `start()` if the app was
    /// launched in the background for an intent; returns as soon as the cache is in memory.
    func prepareForIntents(timeout: Duration = .seconds(3)) async {
        if isLoading {
            Task { await self.start() }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits (bounded) until every brand has a registered provider. Returns the brands still missing.
    @discardableResult
    func waitForProviders(_ brands: Set<Brand>, timeout: Duration = .seconds(3)) async -> Set<Brand> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var missing = brands
        while true {
            for brand in missing {
                if await registry.provider(for: brand) != nil { missing.remove(brand) }
            }
            if missing.isEmpty || clock.now >= deadline { return missing }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Lookup

    /// Every name Siri may hear; when it changes the app refreshes the App Shortcut parameters.
    var intentVocabulary: [String] {
        lights.map(\.name) + rooms.map(\.name) + intentScenes.map(\.name)
    }

    /// Lights whose name matches `query` (see `IntentNameMatcher`), best match first.
    func intentLights(matching query: String) -> [Light] {
        IntentNameMatcher.filter(lights, matching: query) { $0.name }
    }

    func intentRooms(matching query: String) -> [Room] {
        IntentNameMatcher.filter(rooms, matching: query) { $0.name }
    }

    /// App scenes first, then vendor scenes (Hue scenes etc.).
    var intentScenes: [LightScene] { appScenes + vendorScenes }

    func intentScenes(matching query: String) -> [LightScene] {
        IntentNameMatcher.filter(intentScenes, matching: query) { $0.name }
    }

    func intentScene(id: LightScene.ID) -> LightScene? {
        intentScenes.first { $0.id == id }
    }

    // MARK: Commands

    /// Sends one command to the lights and waits for the providers' answer. Throws only when
    /// every light failed; partial failures are listed in the outcome.
    func performIntent(_ command: LightCommand, on ids: [LightID]) async throws -> IntentOutcome {
        let targets = ids.filter { lightsByID[$0] != nil }
        guard !targets.isEmpty else { throw IntentFailure.noLights("That") }
        guard !command.isEmpty else { throw IntentFailure.unsupported("Nothing to change.") }
        await waitForProviders(Set(targets.map(\.brand)))

        let clock = ContinuousClock()
        let started = clock.now
        var failures: [LightID: String] = [:]
        do {
            if targets.count == 1 {
                try await registry.send(command, to: targets[0])
            } else {
                try await registry.sendGroup(command, to: targets)
            }
        } catch let LightCoreError.partialFailure(perLight) {
            failures = perLight
        } catch {
            let message = Self.message(for: error)
            for id in targets { failures[id] = message }
        }
        return try finishIntent(command: { _ in command }, targets: targets, failures: failures, duration: clock.now - started)
    }

    /// Recalls an app scene (per-light commands) or a vendor scene (through its provider).
    func recallForIntent(_ scene: LightScene) async throws -> IntentOutcome {
        let clock = ContinuousClock()
        let started = clock.now
        switch scene.kind {
        case .vendor:
            if let brand = scene.brand { await waitForProviders([brand]) }
            do {
                try await registry.recall(scene)
            } catch {
                throw IntentFailure.commandFailed(Self.message(for: error))
            }
            return IntentOutcome(succeeded: scene.lightIDs)
        case .app:
            let targets = scene.commands.keys.filter { lightsByID[$0] != nil }.sorted()
            guard !targets.isEmpty else { throw IntentFailure.noLights(scene.name) }
            await waitForProviders(Set(targets.map(\.brand)))
            var failures: [LightID: String] = [:]
            await withTaskGroup(of: (LightID, String?).self) { group in
                for id in targets {
                    guard let command = scene.commands[id] else { continue }
                    let registry = self.registry
                    group.addTask {
                        do {
                            try await registry.send(command, to: id)
                            return (id, nil)
                        } catch {
                            return (id, String(describing: error))
                        }
                    }
                }
                for await (id, message) in group {
                    if let message { failures[id] = message }
                }
            }
            let commands = scene.commands
            return try finishIntent(
                command: { commands[$0] ?? LightCommand() },
                targets: targets,
                failures: failures,
                duration: clock.now - started
            )
        }
    }

    /// Records diagnostics, applies the new state to successful lights and builds the outcome.
    private func finishIntent(
        command: (LightID) -> LightCommand,
        targets: [LightID],
        failures: [LightID: String],
        duration: Duration
    ) throws -> IntentOutcome {
        var outcome = IntentOutcome()
        for id in targets {
            if let message = failures[id] {
                DiagnosticsCollector.shared.record(error: message, for: id)
                record(error: "Siri: \(lightsByID[id]?.name ?? id.rawValue): \(message)")
                outcome.failedNames.append(lightsByID[id]?.name ?? id.rawValue)
            } else {
                DiagnosticsCollector.shared.record(latency: duration, for: id)
                outcome.succeeded.append(id)
                // A UI burst in flight owns the light's state; the provider event reconciles it.
                if !coalescer.isBusy(id), var light = lightsByID[id] {
                    light.state = light.state.applying(command(id).normalized(for: light.capabilities))
                    lightsByID[id] = light
                    lastSeen[id] = Date()
                }
            }
        }
        scheduleLightCacheSave()
        if outcome.succeeded.isEmpty {
            let first = targets.compactMap { failures[$0] }.first ?? "No light responded."
            if targets.count == 1, let name = lightsByID[targets[0]]?.name {
                throw IntentFailure.commandFailed("\(name) didn't respond: \(first)")
            }
            throw IntentFailure.commandFailed("No light responded: \(first)")
        }
        return outcome
    }
}
