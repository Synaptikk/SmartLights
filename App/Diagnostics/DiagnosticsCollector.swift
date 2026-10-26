import Foundation
import LightCore
import Observation

/// App-wide store of per-provider and per-device health samples shown in Settings > Diagnostics
/// and included in the export bundle.
///
/// Feeding it:
/// - Provider events: `ProviderRegistry.events` is a single-consumer stream and belongs to the app
///   state store (`AppModel`). Its event loop should forward every event with
///   `DiagnosticsCollector.shared.ingest(event)`. Only if nothing else consumes the stream may
///   `observe(registry.events)` be used instead (two consumers would split the events).
/// - Command timing/errors: whoever sends commands calls `record(latency:for:)` /
///   `record(error:for:)`.
/// - Free-form breadcrumbs: `note(_:)` (also lands in the in-app log sink).
@MainActor
@Observable
final class DiagnosticsCollector {
    static let shared = DiagnosticsCollector()

    struct ProviderSample: Sendable, Equatable {
        /// nil until the provider reports `connectionChanged`.
        var connected: Bool?
        var connectionDetail: String?
        var lastError: String?
        var lastErrorAt: Date?
        var needsReauthentication = false
        var lastEventAt: Date?
        var eventCount = 0
    }

    struct DeviceSample: Sendable, Equatable {
        var lastSeen: Date?
        var reachable: Bool?
        var lastLatency: Duration?
        /// Most recent latencies, newest last (at most `DiagnosticsCollector.latencyHistoryLimit`).
        var latencies: [Duration] = []
        var lastError: String?
        var lastErrorAt: Date?
        var commandCount = 0
        var errorCount = 0

        var averageLatency: Duration? {
            guard !latencies.isEmpty else { return nil }
            return latencies.reduce(Duration.zero, +) / latencies.count
        }
    }

    static let latencyHistoryLimit = 20

    private(set) var providers: [Brand: ProviderSample] = [:]
    private(set) var devices: [LightID: DeviceSample] = [:]

    private let sink: DiagnosticsLogSink
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(sink: DiagnosticsLogSink = .shared) {
        self.sink = sink
    }

    // MARK: - API for other parts of the app

    /// Round-trip time of a successful command to `light`. Also marks the light as seen.
    func record(latency: Duration, for light: LightID) {
        var sample = devices[light] ?? DeviceSample()
        sample.lastLatency = latency
        sample.latencies.append(latency)
        if sample.latencies.count > Self.latencyHistoryLimit {
            sample.latencies.removeFirst(sample.latencies.count - Self.latencyHistoryLimit)
        }
        sample.commandCount += 1
        sample.lastSeen = Date()
        devices[light] = sample
    }

    /// A failed command or read for `light`. Never pass messages containing secrets.
    func record(error: any Error, for light: LightID) {
        record(error: Self.describe(error), for: light)
    }

    func record(error message: String, for light: LightID) {
        var sample = devices[light] ?? DeviceSample()
        sample.lastError = message
        sample.lastErrorAt = Date()
        sample.commandCount += 1
        sample.errorCount += 1
        devices[light] = sample
        sink.append("\(light): \(message)", level: "ERROR", category: "device")
    }

    /// A provider-level failure (discovery, login, connection).
    func record(error: any Error, for brand: Brand) {
        record(error: Self.describe(error), for: brand)
    }

    func record(error message: String, for brand: Brand) {
        var sample = providers[brand] ?? ProviderSample()
        sample.lastError = message
        sample.lastErrorAt = Date()
        providers[brand] = sample
        sink.append("\(brand.rawValue): \(message)", level: "ERROR", category: "provider")
    }

    /// The light answered or pushed state at `date`.
    func markSeen(_ light: LightID, at date: Date = Date()) {
        var sample = devices[light] ?? DeviceSample()
        sample.lastSeen = date
        devices[light] = sample
    }

    /// Free-form breadcrumb for the in-app log (e.g. "Hue SSE reconnected after 72 s").
    func note(_ message: String, level: Log.Level = .info, category: String = "note") {
        sink.append(message, level: level.description, category: category)
    }

    /// Updates samples from one registry event. Call from the single consumer of `registry.events`.
    func ingest(_ event: RegistryEvent) {
        let now = Date()
        var provider = providers[event.brand] ?? ProviderSample()
        provider.lastEventAt = now
        provider.eventCount += 1

        switch event.event {
        case .stateChanged(let id, let state):
            var sample = devices[id] ?? DeviceSample()
            sample.lastSeen = now
            sample.reachable = state.reachable
            devices[id] = sample
        case .lightAdded(let light), .lightUpdated(let light):
            var sample = devices[light.id] ?? DeviceSample()
            sample.lastSeen = now
            sample.reachable = light.state.reachable
            devices[light.id] = sample
        case .lightRemoved(let id):
            sink.append("\(id) removed", category: "device")
        case .reachabilityChanged(let id, let reachable):
            var sample = devices[id] ?? DeviceSample()
            sample.reachable = reachable
            if reachable { sample.lastSeen = now }
            devices[id] = sample
            sink.append("\(id) \(reachable ? "reachable" : "unreachable")", level: reachable ? "INFO" : "NOTICE", category: "device")
        case .scenesChanged:
            break
        case .needsReauthentication:
            provider.needsReauthentication = true
            provider.lastError = "Needs sign-in again"
            provider.lastErrorAt = now
            sink.append("\(event.brand.rawValue): needs re-authentication", level: "NOTICE", category: "provider")
        case .connectionChanged(let connected, let detail):
            provider.connected = connected
            provider.connectionDetail = detail
            if connected { provider.needsReauthentication = false }
            sink.append("\(event.brand.rawValue): \(connected ? "connected" : "disconnected")\(detail.map { " (\($0))" } ?? "")",
                        level: connected ? "INFO" : "NOTICE", category: "provider")
        case .error(let message):
            provider.lastError = message
            provider.lastErrorAt = now
            sink.append("\(event.brand.rawValue): \(message)", level: "ERROR", category: "provider")
        }
        providers[event.brand] = provider
    }

    /// Consumes `events` until `stopObserving()` or the stream ends. Only for a stream nobody else
    /// consumes (see the type comment); `AppModel` should prefer calling `ingest(_:)`.
    func observe(_ events: AsyncStream<RegistryEvent>) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.ingest(event)
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    /// Clears all samples (Diagnostics "Reset" button, tests).
    func reset() {
        providers = [:]
        devices = [:]
    }

    static func describe(_ error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }
}
