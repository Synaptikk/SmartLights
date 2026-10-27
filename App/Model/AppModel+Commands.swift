import Foundation
import LightCore

/// Sending commands: optimistic state first, then a coalesced, rate-limited dispatch through
/// the registry. Errors show a toast and roll back to the provider's state.
extension AppModel {
    /// Sends a command to one light. Safe to call on every slider tick.
    func send(_ command: LightCommand, to id: LightID) {
        send(command, toLights: [id], groupKey: .light(id))
    }

    /// Sends one group command to every light in a room (providers may use native groups).
    func send(_ command: LightCommand, toRoom roomID: Room.ID) {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return }
        send(command, toLights: room.lightIDs, groupKey: .room(roomID))
    }

    /// Sends one command to several lights as a group. `groupKey` identifies the coalescing
    /// slot, so repeated calls with the same key replace each other (latest wins).
    func send(_ command: LightCommand, toLights ids: [LightID], groupKey: CommandCoalescer.Key) {
        let targets = ids.filter { lightsByID[$0] != nil }
        guard !targets.isEmpty, !command.isEmpty else { return }
        for id in targets {
            applyOptimistically(command, to: id)
        }
        coalescer.enqueue(command, key: groupKey, targets: targets)
        for id in targets {
            mirrorLightSync(from: id)
        }
    }

    func setPower(_ isOn: Bool, for id: LightID) {
        send(LightCommand(on: isOn), to: id)
    }

    func toggle(_ id: LightID) {
        guard let light = lightsByID[id] else { return }
        setPower(!light.state.isOn, for: id)
    }

    func setBrightness(_ brightness: Double, for id: LightID) {
        send(LightCommand(on: true, brightness: brightness), to: id)
    }

    /// Bypasses coalescing and optimistic UI; returns the round-trip time (Diagnostics "test command").
    func sendNow(_ command: LightCommand, to id: LightID) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await registry.send(command, to: id)
        } catch {
            DiagnosticsCollector.shared.record(error: error, for: id)
            throw error
        }
        let duration = clock.now - start
        DiagnosticsCollector.shared.record(latency: duration, for: id)
        return duration
    }

    // MARK: Optimistic state + reconciliation

    private func applyOptimistically(_ command: LightCommand, to id: LightID) {
        guard var light = lightsByID[id] else { return }
        if !coalescer.isBusy(id) {
            baselines[id] = light.state
            deferredStates[id] = nil
        }
        let normalized = command.normalized(for: light.capabilities)
        light.state = light.state.applying(normalized)
        lightsByID[id] = light
    }

    func handleCoalescer(_ event: CommandCoalescer.Event) {
        switch event {
        case .willSend(let targets):
            let now = Date()
            for id in targets { dispatchStartedAt[id] = now }
        case .finished(let targets, let error, let duration, let idle):
            if let error { showError(error) }
            let failed = Self.failedLights(error, targets: targets)
            reportToDiagnostics(targets: targets, failed: failed, error: error, duration: duration)
            guard idle else { return }
            for id in targets where !coalescer.isBusy(id) {
                settle(id, failed: failed.contains(id))
            }
        }
    }

    /// End of a command burst: adopt the provider's latest report, or roll back on failure.
    private func settle(_ id: LightID, failed: Bool) {
        let baseline = baselines.removeValue(forKey: id)
        let deferred = deferredStates.removeValue(forKey: id)
        dispatchStartedAt[id] = nil
        if let deferred {
            lightsByID[id]?.state = deferred
        } else if failed, let baseline {
            lightsByID[id]?.state = baseline
        }
        scheduleLightCacheSave()
    }

    private func reportToDiagnostics(targets: [LightID], failed: Set<LightID>, error: (any Error)?, duration: Duration) {
        let collector = DiagnosticsCollector.shared
        var perLight: [LightID: String] = [:]
        if let coreError = error as? LightCoreError, case .partialFailure(let failures) = coreError {
            perLight = failures
        }
        for id in targets {
            if failed.contains(id) {
                if let message = perLight[id] {
                    collector.record(error: message, for: id)
                } else if let error {
                    collector.record(error: error, for: id)
                }
            } else {
                collector.record(latency: duration, for: id)
            }
        }
    }

    private static func failedLights(_ error: (any Error)?, targets: [LightID]) -> Set<LightID> {
        guard let error else { return [] }
        if let coreError = error as? LightCoreError, case .partialFailure(let failures) = coreError {
            return Set(failures.keys)
        }
        return Set(targets)
    }
}
