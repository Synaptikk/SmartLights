import Foundation
import LightCore
import NetKit
import Observation

/// What Diagnostics needs from the rest of the app. Built from `AppModel` in `DiagnosticsView.swift`
/// (the only file that references `AppModel`), or `.empty` in previews.
struct DiagnosticsContext {
    var registry: ProviderRegistry?
    var lights: [Light]

    static let empty = DiagnosticsContext(registry: nil, lights: [])
}

/// Wi-Fi interface facts from `InterfaceInfo`.
struct NetworkSnapshot: Sendable, Equatable {
    var interfaceName: String?
    var address: String?
    var subnet: String?
    var netmask: String?
    var directedBroadcast: String?
    /// Other local-network interfaces, `name address/prefix`.
    var otherInterfaces: [String]

    static func capture() -> NetworkSnapshot {
        let wifi = InterfaceInfo.currentWiFi()
        let others = InterfaceInfo.localNetworkInterfaces()
            .filter { $0.name != wifi?.name }
            .map(\.description)
        return NetworkSnapshot(
            interfaceName: wifi?.name,
            address: wifi.map { "\($0.address)" },
            subnet: wifi?.subnet.map { "\($0)" },
            netmask: wifi.map { "\($0.netmask)" },
            directedBroadcast: wifi?.directedBroadcast.map { "\($0)" },
            otherInterfaces: others
        )
    }
}

/// Bonjour browse results for one service type.
struct BonjourTypeResult: Sendable, Identifiable, Equatable {
    var type: String
    var services: [BonjourService] = []
    var status: String = "Not run"
    var finished = false
    var id: String { type }
}

/// Progress of a per-device "send test command".
enum TestCommandState: Sendable, Equatable {
    case running(step: Int, of: Int)
    case succeeded(average: Duration)
    case failed(String)
    case cancelled
}

/// Runs the Diagnostics probes. Every probe is a cancellable task, time-boxed with
/// `DiagnosticsProbe.withTimeout` (blocking work runs detached, never on the main actor).
@MainActor
@Observable
final class DiagnosticsModel {
    nonisolated static let bonjourTypes = ["_hue._tcp", "_nanoleafapi._tcp", "_elg._tcp", "_shelly._tcp", "_wled._tcp", "_lifx._udp"]
    nonisolated static let bonjourDuration: Duration = .seconds(5)

    private(set) var localNetwork: LocalNetworkPermission?
    private(set) var checkingLocalNetwork = false

    private(set) var network: NetworkSnapshot?
    private(set) var entitlements: EntitlementsInfo?
    private(set) var broadcast: BroadcastCapabilityStatus?
    private(set) var checkingBroadcast = false

    private(set) var bonjour: [BonjourTypeResult] = DiagnosticsModel.bonjourTypes.map { BonjourTypeResult(type: $0) }
    private(set) var browsing = false

    private(set) var registeredBrands: [Brand] = []

    private(set) var logLines: [DiagnosticsLogLine] = []
    private(set) var logError: String?
    private(set) var loadingLogs = false

    private(set) var testRuns: [LightID: TestCommandState] = [:]

    private(set) var exportURL: URL?
    private(set) var exportError: String?
    private(set) var exporting = false

    private(set) var hasRun = false

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    private let sink: DiagnosticsLogSink

    init(sink: DiagnosticsLogSink = .shared) {
        self.sink = sink
    }

    // MARK: - Orchestration

    func runAll(registry: ProviderRegistry?) {
        hasRun = true
        checkLocalNetwork()
        refreshNetwork()
        checkBroadcast()
        browseBonjour()
        refreshProviders(registry: registry)
        loadLogs()
    }

    /// Cancels every running probe (view disappeared).
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func start(_ key: String, _ operation: @escaping @MainActor @Sendable () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { await operation() }
    }

    // MARK: - Permissions

    func checkLocalNetwork() {
        start("localNetwork") { [weak self] in
            await self?.performLocalNetworkCheck()
        }
    }

    /// Fires the TN3179 prompt trick, then re-checks.
    func triggerLocalNetworkPrompt() {
        start("localNetwork") { [weak self] in
            await DiagnosticsProbe.withTimeout(.seconds(2), fallback: ()) {
                LocalNetworkPermissionProbe.triggerPrompt()
            }
            self?.sink.append("Local Network prompt triggered", category: "diagnostics")
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.performLocalNetworkCheck()
        }
    }

    private func performLocalNetworkCheck() async {
        checkingLocalNetwork = true
        defer { checkingLocalNetwork = false }
        let result = await DiagnosticsProbe.withTimeout(.seconds(4), fallback: LocalNetworkPermission.undetermined) {
            await LocalNetworkPermissionProbe.check(timeout: .seconds(3))
        }
        guard !Task.isCancelled else { return }
        localNetwork = result
    }

    // MARK: - Network

    func refreshNetwork() {
        start("network") { [weak self] in
            let snapshot = await DiagnosticsProbe.withTimeout(.seconds(2), fallback: NetworkSnapshot?.none) {
                NetworkSnapshot.capture()
            }
            let entitlements = await DiagnosticsProbe.withTimeout(
                .seconds(3), fallback: EntitlementsInfo.unavailable("Timed out reading the code signature")
            ) {
                EntitlementsReader.read()
            }
            guard let self, !Task.isCancelled else { return }
            self.network = snapshot
            self.entitlements = entitlements
        }
    }

    func checkBroadcast() {
        start("broadcast") { [weak self] in
            guard let self else { return }
            self.checkingBroadcast = true
            defer { self.checkingBroadcast = false }
            let status = await DiagnosticsProbe.withTimeout(.seconds(6), fallback: BroadcastCapabilityStatus.unknown) {
                await BroadcastCapability.detect()
            }
            guard !Task.isCancelled else { return }
            self.broadcast = status
            self.sink.append("Broadcast capability: \(status.rawValue)", category: "diagnostics")
        }
    }

    // MARK: - Bonjour

    func browseBonjour() {
        start("bonjour") { [weak self] in
            guard let self else { return }
            self.browsing = true
            self.bonjour = Self.bonjourTypes.map { BonjourTypeResult(type: $0, status: "Browsing...") }
            defer { self.browsing = false }

            let duration = Self.bonjourDuration
            await withTaskGroup(of: Void.self) { group in
                for type in Self.bonjourTypes {
                    group.addTask {
                        await Self.browse(type: type, for: duration) { event in
                            await self.apply(event, type: type)
                        }
                    }
                }
            }
            for index in self.bonjour.indices where !self.bonjour[index].finished {
                self.bonjour[index].finished = true
                if Task.isCancelled {
                    self.bonjour[index].status = "Cancelled"
                } else if self.bonjour[index].status == "Browsing..." {
                    let count = self.bonjour[index].services.count
                    self.bonjour[index].status = count == 0 ? "None found" : "\(count) found"
                }
            }
        }
    }

    /// Browses one type for `duration`; the browser is cancelled when the stream is abandoned.
    private nonisolated static func browse(
        type: String,
        for duration: Duration,
        onEvent: @escaping @Sendable (BonjourEvent) async -> Void
    ) async {
        let stream = BonjourBrowser.browse(type: type, resolve: true, resolveTimeout: .seconds(3))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream { await onEvent(event) }
            }
            group.addTask {
                try? await Task.sleep(for: duration)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func apply(_ event: BonjourEvent, type: String) {
        guard let index = bonjour.firstIndex(where: { $0.type == type }), !bonjour[index].finished else { return }
        switch event {
        case .added(let service):
            bonjour[index].services.removeAll { $0.name == service.name }
            bonjour[index].services.append(service)
        case .removed(let service):
            bonjour[index].services.removeAll { $0.name == service.name }
        case .policyDenied:
            bonjour[index].status = "Denied: Local Network access off, or type missing from NSBonjourServices"
        case .failed(let message):
            bonjour[index].status = "Failed: \(message)"
        }
    }

    // MARK: - Providers

    func refreshProviders(registry: ProviderRegistry?) {
        guard let registry else {
            registeredBrands = []
            return
        }
        start("providers") { [weak self] in
            let brands = await DiagnosticsProbe.withTimeout(.seconds(2), fallback: [Brand]?.none) {
                await registry.registeredBrands
            }
            guard let self, !Task.isCancelled, let brands else { return }
            self.registeredBrands = brands
        }
    }

    // MARK: - Devices

    /// Toggles `light` away from its current power state and back, twice, timing each command.
    func sendTestCommand(to light: Light, registry: ProviderRegistry?, collector: DiagnosticsCollector) {
        let id = light.id
        guard let registry else {
            testRuns[id] = .failed("No provider registry")
            return
        }
        let original = light.state.isOn
        let sequence = [!original, original, !original, original]
        start("test-\(id.rawValue)") { [weak self] in
            collector.note("Test command started for \(id)", category: "device")
            var latencies: [Duration] = []
            for (step, on) in sequence.enumerated() {
                guard !Task.isCancelled else {
                    self?.testRuns[id] = .cancelled
                    return
                }
                self?.testRuns[id] = .running(step: step + 1, of: sequence.count)
                let command: LightCommand = on ? .turnOn : .turnOff
                let clock = ContinuousClock()
                let started = clock.now
                let result = await DiagnosticsProbe.withTimeout(
                    .seconds(5), fallback: Result<Void, any Error>.failure(LightCoreError.timeout)
                ) {
                    do {
                        try await registry.send(command, to: id)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                switch result {
                case .success:
                    let elapsed = clock.now - started
                    latencies.append(elapsed)
                    collector.record(latency: elapsed, for: id)
                case .failure(let error):
                    if Task.isCancelled {
                        self?.testRuns[id] = .cancelled
                        return
                    }
                    collector.record(error: error, for: id)
                    self?.testRuns[id] = .failed("Step \(step + 1): \(DiagnosticsCollector.describe(error))")
                    return
                }
                if step < sequence.count - 1 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            let average = latencies.reduce(Duration.zero, +) / max(latencies.count, 1)
            self?.testRuns[id] = .succeeded(average: average)
            collector.note("Test command for \(id) succeeded, avg \(DiagnosticsFormat.latency(average))", category: "device")
        }
    }

    // MARK: - Logs

    func loadLogs() {
        start("logs") { [weak self] in
            await self?.performLoadLogs()
        }
    }

    func clearInAppLog() {
        sink.clear()
        logLines.removeAll { $0.source == .app }
    }

    private func performLoadLogs() async {
        loadingLogs = true
        defer { loadingLogs = false }
        let result = await DiagnosticsProbe.withTimeout(
            .seconds(8), fallback: OSLogReadResult(lines: [], error: "Timed out reading OSLog")
        ) {
            OSLogCollector.read()
        }
        guard !Task.isCancelled else { return }
        var merged = result.lines + sink.snapshot()
        merged.sort { $0.date < $1.date }
        if merged.count > 2_000 { merged.removeFirst(merged.count - 2_000) }
        logLines = merged
        logError = result.error
    }

    // MARK: - Export

    /// Refreshes logs, builds the text bundle, redacts it and writes it to a temporary file whose
    /// URL is published as `exportURL` (shown as a `ShareLink`).
    func export(context: DiagnosticsContext, collector: DiagnosticsCollector) {
        exportURL = nil
        exportError = nil
        start("export") { [weak self] in
            guard let self else { return }
            self.exporting = true
            defer { self.exporting = false }
            await self.performLoadLogs()
            guard !Task.isCancelled else { return }
            let text = DiagnosticsReport.build(model: self, context: context, collector: collector)
            let allowList = Set(context.lights.map(\.id.stableId))
            let url = await DiagnosticsProbe.withTimeout(.seconds(10), fallback: URL?.none) {
                DiagnosticsReport.write(DiagnosticsRedactor.redact(text, allowList: allowList))
            }
            guard !Task.isCancelled else { return }
            if let url {
                self.exportURL = url
            } else {
                self.exportError = "Could not write the diagnostics bundle"
            }
        }
    }
}

/// Shared formatting helpers for the screen and the report.
enum DiagnosticsFormat {
    static func latency(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let ms = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    static func permission(_ value: LocalNetworkPermission?) -> String {
        switch value {
        case nil: "Not checked"
        case .granted: "Granted"
        case .denied: "Denied"
        case .undetermined: "Undetermined (no answer / no Wi-Fi)"
        }
    }

    static func broadcast(_ value: BroadcastCapabilityStatus?) -> String {
        switch value {
        case nil: "Not tested"
        case .entitled: "Working (broadcast send succeeded)"
        case .notEntitled: "Blocked (EACCES/EPERM: entitlement missing)"
        case .localNetworkDenied: "Blocked (Local Network denied)"
        case .unknown: "Unknown (no Wi-Fi or other error)"
        }
    }

    static func yesNo(_ value: Bool?) -> String {
        switch value {
        case nil: "Unknown"
        case true?: "Yes"
        case false?: "No"
        }
    }

    static func connection(_ sample: DiagnosticsCollector.ProviderSample?) -> String {
        guard let connected = sample?.connected else { return "No connection events yet" }
        let base = connected ? "Connected" : "Disconnected"
        if let detail = sample?.connectionDetail, !detail.isEmpty { return "\(base) (\(detail))" }
        return base
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }

    static func testState(_ state: TestCommandState?) -> String? {
        switch state {
        case nil: nil
        case .running(let step, let total): "Testing \(step)/\(total)..."
        case .succeeded(let average): "Test passed, avg \(latency(average))"
        case .failed(let message): "Test failed: \(message)"
        case .cancelled: "Test cancelled"
        }
    }
}
