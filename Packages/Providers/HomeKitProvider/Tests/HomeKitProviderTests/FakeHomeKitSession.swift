import Foundation
import LightCore
@testable import HomeKitProvider

/// In-memory `HomeKitSession` (HomeKit does not work in the Simulator, and tests must not create
/// HMHomeManager).
@MainActor
final class FakeHomeKitSession: HomeKitSession {
    nonisolated let events: AsyncStream<HomeKitSessionEvent>
    nonisolated let continuation: AsyncStream<HomeKitSessionEvent>.Continuation

    var bulbs: [HomeKitLightbulb]
    var authorizationState: HomeKitAuthorizationState
    var isReady = false
    /// When false, `start()` does not mark the session ready (simulates a slow home list).
    var becomesReadyOnStart = true
    var writeDelay: Duration?
    var failWrites: (any Error)?

    private(set) var startCount = 0
    private(set) var writeLog: [(accessoryID: UUID, serviceID: UUID, writes: [HomeKitWrite])] = []
    private(set) var notificationsEnabled: [UUID] = []
    private var inFlight: [UUID: Int] = [:]
    private(set) var maxInFlightPerAccessory = 0
    private var inFlightTotal = 0
    private(set) var maxInFlightTotal = 0

    nonisolated init(bulbs: [HomeKitLightbulb], authorization: HomeKitAuthorizationState = .authorized) {
        (events, continuation) = AsyncStream.makeStream(of: HomeKitSessionEvent.self)
        self.bulbs = bulbs
        self.authorizationState = authorization
    }

    func start() {
        startCount += 1
        guard startCount == 1 else { return }
        continuation.yield(.authorizationChanged(authorizationState))
        if becomesReadyOnStart {
            isReady = true
            continuation.yield(.homesChanged)
        }
    }

    func lightbulbs() -> [HomeKitLightbulb] { bulbs }

    func write(_ writes: [HomeKitWrite], accessoryID: UUID, serviceID: UUID) async throws {
        writeLog.append((accessoryID, serviceID, writes))
        inFlight[accessoryID, default: 0] += 1
        inFlightTotal += 1
        maxInFlightPerAccessory = max(maxInFlightPerAccessory, inFlight[accessoryID] ?? 0)
        maxInFlightTotal = max(maxInFlightTotal, inFlightTotal)
        defer {
            inFlight[accessoryID, default: 1] -= 1
            inFlightTotal -= 1
        }
        if let writeDelay { try await Task.sleep(for: writeDelay) }
        if let failWrites { throw failWrites }
        if let i = bulbs.firstIndex(where: { $0.accessoryID == accessoryID && $0.serviceID == serviceID }) {
            bulbs[i] = HomeKitMapper.applying(writes, to: bulbs[i])
        }
    }

    func enableNotifications(accessoryID: UUID, serviceID: UUID) async throws {
        notificationsEnabled.append(serviceID)
    }

    // MARK: - Test drivers

    func emit(_ event: HomeKitSessionEvent) { continuation.yield(event) }

    func setReady() {
        isReady = true
        continuation.yield(.homesChanged)
    }
}

/// Collects provider events in the background so tests can wait for one.
actor EventRecorder {
    private(set) var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    init() {}

    func start(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: ProviderEvent) { events.append(event) }

    /// Waits up to `timeout` for an event matching `predicate`.
    func waitFor(timeout: Duration = .seconds(2), _ predicate: @Sendable (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let match = events.first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events.first(where: predicate)
    }

    func cancel() { task?.cancel() }
}

enum Fixtures {
    static let hueAccessory = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let hueService = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let stripService = UUID(uuidString: "22222222-2222-2222-2222-333333333333")!
    static let plugAccessory = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let plugService = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let whiteAccessory = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    static let whiteService = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    /// Full colour bulb (power, brightness, hue, saturation, colour temperature 153...500 mireds).
    static func colorBulb(
        on: Bool = true,
        brightness: Double = 50,
        hue: Double = 30,
        saturation: Double = 80,
        mireds: Double = 370,
        reachable: Bool = true,
        service: UUID = hueService,
        name: String = "Desk Lamp",
        room: String? = "Office"
    ) -> HomeKitLightbulb {
        HomeKitLightbulb(
            accessoryID: hueAccessory,
            serviceID: service,
            accessoryName: name,
            manufacturer: "Signify Netherlands B.V.",
            model: "LCA001",
            firmwareVersion: "1.122.2",
            roomName: room,
            homeName: "Home",
            isReachable: reachable,
            characteristics: [
                .powerState: HomeKitCharacteristicSnapshot(value: on ? 1 : 0),
                .brightness: HomeKitCharacteristicSnapshot(value: brightness, minimum: 0, maximum: 100, step: 1),
                .hue: HomeKitCharacteristicSnapshot(value: hue, minimum: 0, maximum: 360),
                .saturation: HomeKitCharacteristicSnapshot(value: saturation, minimum: 0, maximum: 100),
                .colorTemperature: HomeKitCharacteristicSnapshot(value: mireds, minimum: 153, maximum: 500, step: 1),
            ]
        )
    }

    /// Plain on/off accessory (Matter plug exposed as a lightbulb service).
    static func plug(on: Bool = false) -> HomeKitLightbulb {
        HomeKitLightbulb(
            accessoryID: plugAccessory,
            serviceID: plugService,
            accessoryName: "Hall Plug",
            manufacturer: "Eve Systems",
            model: "Eve Energy",
            characteristics: [.powerState: HomeKitCharacteristicSnapshot(value: on ? 1 : 0)]
        )
    }

    /// Dimmable white with tunable temperature, no metadata (HAP default range).
    static func tunableWhite(on: Bool = true, brightness: Double = 100, mireds: Double? = 250) -> HomeKitLightbulb {
        HomeKitLightbulb(
            accessoryID: whiteAccessory,
            serviceID: whiteService,
            accessoryName: "Ceiling",
            serviceName: "Ceiling Light",
            manufacturer: "IKEA of Sweden",
            model: "TRADFRI bulb",
            isReachable: true,
            characteristics: [
                .powerState: HomeKitCharacteristicSnapshot(value: on ? 1 : 0),
                .brightness: HomeKitCharacteristicSnapshot(value: brightness),
                .colorTemperature: HomeKitCharacteristicSnapshot(value: mireds),
            ]
        )
    }
}
