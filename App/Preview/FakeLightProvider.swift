#if DEBUG
import Foundation
import LightCore

/// Selects the brand a `FakeLightProvider` impersonates (`LightProvider.brand` is static).
protocol FakeBrandTag: Sendable {
    static var brand: Brand { get }
}

enum FakeHue: FakeBrandTag { static var brand: Brand { .hue } }
enum FakeWiZ: FakeBrandTag { static var brand: Brand { .wiz } }
enum FakeAiDot: FakeBrandTag { static var brand: Brand { .aidot } }
enum FakeAppleHome: FakeBrandTag { static var brand: Brand { .appleHome } }

/// In-memory provider for SwiftUI previews and app unit tests. No networking: commands are
/// applied after `latency` and echoed back as `stateChanged` events, like a real device push.
actor FakeLightProvider<Tag: FakeBrandTag>: LightProvider {
    static var brand: Brand { Tag.brand }

    let account: ProviderAccount? = nil
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var lights: [LightID: Light]
    private let vendorScenes: [LightScene]
    private let latency: Duration
    /// Lights whose commands fail (to preview/test error toasts and rollback).
    private var failing: Set<LightID>
    /// Number of `send`/`sendGroup` calls received (tests).
    private(set) var commandCount = 0

    init(lights: [Light], scenes: [LightScene] = [], latency: Duration = .milliseconds(60), failing: Set<LightID> = []) {
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.lights = Dictionary(lights.filter { $0.brand == Tag.brand }.map { ($0.id, $0) }) { first, _ in first }
        self.vendorScenes = scenes.filter { $0.brand == Tag.brand }
        self.latency = latency
        self.failing = failing
    }

    func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        let device = DiscoveredDevice(id: "fake-\(Tag.brand.rawValue)", brand: Tag.brand, name: "Fake \(Tag.brand.displayName)", method: .manual)
        return AsyncStream { continuation in
            continuation.yield(device)
            continuation.finish()
        }
    }

    func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        guard try await ui.confirm("Pair \(device.name)?") else { throw LightCoreError.userCancelled }
        return PairedDevice(id: device.id, brand: Tag.brand, name: device.name, lightIDs: Array(lights.keys))
    }

    func loadLights() async throws -> [Light] {
        lights.values.sorted { $0.id < $1.id }
    }

    func send(_ command: LightCommand, to id: LightID) async throws {
        commandCount += 1
        try await apply(command, to: id)
    }

    func sendGroup(_ command: LightCommand, to ids: [LightID]) async throws {
        commandCount += 1
        var failures: [LightID: String] = [:]
        for id in ids {
            do { try await apply(command, to: id) } catch { failures[id] = String(describing: error) }
        }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    func scenes() async throws -> [LightScene] { vendorScenes }

    func recall(_ sceneID: LightScene.ID) async throws {
        guard let scene = vendorScenes.first(where: { $0.id == sceneID }) else {
            throw LightCoreError.unsupported("unknown scene \(sceneID)")
        }
        let targets = scene.lightIDs.isEmpty ? Array(lights.keys) : scene.lightIDs
        for id in targets {
            try await apply(LightCommand(on: true, brightness: 0.7, color: .hs(HS(h: Double(id.stableId.count * 40 % 360), s: 0.8))), to: id)
        }
    }

    /// Simulates an external change (e.g. the vendor app) for previews/tests.
    func simulateExternalChange(_ command: LightCommand, to id: LightID) {
        guard var light = lights[id] else { return }
        light.state = light.state.applying(command.normalized(for: light.capabilities))
        lights[id] = light
        continuation.yield(.stateChanged(id, light.state))
    }

    func setFailing(_ id: LightID, _ isFailing: Bool) {
        if isFailing { failing.insert(id) } else { failing.remove(id) }
    }

    private func apply(_ command: LightCommand, to id: LightID) async throws {
        guard lights[id] != nil else { throw LightCoreError.lightNotFound(id) }
        try await Task.sleep(for: latency)
        guard var light = lights[id] else { throw LightCoreError.lightNotFound(id) }
        if failing.contains(id) { throw LightCoreError.unreachable(light.name) }
        light.state = light.state.applying(command.normalized(for: light.capabilities))
        lights[id] = light
        continuation.yield(.stateChanged(id, light.state))
    }
}
#endif
