import Foundation
import LightCore
import Testing
@testable import HomeKitProvider

private let hueID = HomeKitMapper.lightID(accessoryID: Fixtures.hueAccessory, serviceID: Fixtures.hueService)!
private let stripID = HomeKitMapper.lightID(accessoryID: Fixtures.hueAccessory, serviceID: Fixtures.stripService)!
private let plugID = HomeKitMapper.lightID(accessoryID: Fixtures.plugAccessory, serviceID: Fixtures.plugService)!

@Suite("HomeKitProvider")
@MainActor
struct HomeKitProviderTests {

    private func make(
        _ bulbs: [HomeKitLightbulb],
        authorization: HomeKitAuthorizationState = .authorized
    ) async -> (HomeKitProvider, FakeHomeKitSession, EventRecorder) {
        let session = FakeHomeKitSession(bulbs: bulbs, authorization: authorization)
        let provider = HomeKitProvider(session: session, readyTimeout: .milliseconds(300))
        let recorder = EventRecorder()
        await recorder.start(provider.events)
        return (provider, session, recorder)
    }

    @Test func brandAndAccount() async {
        let (provider, _, _) = await make([])
        #expect(HomeKitProvider.brand == .appleHome)
        #expect(await provider.account == nil)
    }

    @Test func loadLightsMapsEveryLightbulbService() async throws {
        let (provider, session, _) = await make([Fixtures.colorBulb(), Fixtures.plug()])
        let lights = try await provider.loadLights()
        #expect(lights.map(\.id).sorted() == [hueID, plugID].sorted())
        #expect(lights.allSatisfy { $0.brand == .appleHome })
        let plug = try #require(lights.first { $0.id == plugID })
        #expect(plug.capabilities.supportedColorModes == [.onOff])
        #expect(plug.manufacturer == "Eve Systems")
        #expect(session.startCount == 1)
        #expect(await provider.authorizationState == .authorized)
    }

    @Test func loadLightsEnablesNotifications() async throws {
        let (provider, session, _) = await make([Fixtures.colorBulb(), Fixtures.plug()])
        _ = try await provider.loadLights()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.notificationsEnabled.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(session.notificationsEnabled) == [Fixtures.hueService, Fixtures.plugService])
    }

    @Test func loadLightsWaitsForHomes() async throws {
        let session = FakeHomeKitSession(bulbs: [Fixtures.plug()])
        session.becomesReadyOnStart = false
        let provider = HomeKitProvider(session: session, readyTimeout: .seconds(2))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            session.setReady()
        }
        let lights = try await provider.loadLights()
        #expect(lights.map(\.id) == [plugID])
    }

    @Test func deniedAuthorizationSurfacesError() async throws {
        let (provider, _, recorder) = await make([Fixtures.plug()], authorization: .denied)
        await #expect(throws: LightCoreError.unsupported(HomeKitProvider.accessDeniedMessage)) {
            _ = try await provider.loadLights()
        }
        #expect(await provider.authorizationState == .denied)
        let error = await recorder.waitFor { if case .error = $0 { true } else { false } }
        #expect(error == .error(HomeKitProvider.accessDeniedMessage))
        let connection = await recorder.waitFor { if case .connectionChanged = $0 { true } else { false } }
        #expect(connection == .connectionChanged(connected: false, detail: HomeKitProvider.accessDeniedMessage))
    }

    @Test func authorizationGrantedLater() async throws {
        let (provider, session, recorder) = await make([], authorization: .notDetermined)
        await provider.start()
        session.authorizationState = .authorized
        session.emit(.authorizationChanged(.authorized))
        let event = await recorder.waitFor { $0 == .connectionChanged(connected: true, detail: nil) }
        #expect(event != nil)
        #expect(await provider.authorizationState == .authorized)
    }

    @Test func discoverYieldsEachServiceOnce() async {
        let (provider, _, _) = await make([Fixtures.colorBulb(), Fixtures.colorBulb(), Fixtures.plug()])
        var devices: [DiscoveredDevice] = []
        for await device in await provider.discover(options: DiscoveryOptions(timeout: .seconds(1))) {
            devices.append(device)
        }
        #expect(devices.count == 2)
        #expect(devices.allSatisfy { $0.method == .homeKit && $0.brand == .appleHome })
        #expect(Set(devices.map(\.id)) == [hueID.stableId, plugID.stableId])
    }

    @Test func discoverSkippedWhenHomeKitMethodNotAllowed() async {
        let (provider, session, _) = await make([Fixtures.plug()])
        var count = 0
        for await _ in await provider.discover(options: DiscoveryOptions(methods: [.bonjour])) { count += 1 }
        #expect(count == 0)
        #expect(session.startCount == 0)
    }

    @Test func pairRecordsDevice() async throws {
        let (provider, _, _) = await make([Fixtures.plug()])
        let device = HomeKitMapper.discoveredDevice(for: Fixtures.plug())
        let paired = try await provider.pair(device, using: ScriptedPairingInteraction([]))
        #expect(paired.brand == .appleHome)
        #expect(paired.id == plugID.stableId)
        #expect(paired.lightIDs == [plugID])
        #expect(await provider.pairedDevices[paired.id] == paired)

        let bogus = DiscoveredDevice(id: "ip:1.2.3.4", brand: .wiz, name: "x", method: .manual)
        await #expect(throws: LightCoreError.self) {
            _ = try await provider.pair(bogus, using: ScriptedPairingInteraction([]))
        }
    }

    @Test func sendWritesCharacteristicsAndPublishesState() async throws {
        let (provider, session, recorder) = await make([Fixtures.colorBulb(on: false, brightness: 10)])
        _ = try await provider.loadLights()
        try await provider.send(LightCommand(on: true, brightness: 0.75, color: .kelvin(2700)), to: hueID)
        #expect(session.writeLog.count == 1)
        #expect(session.writeLog.first?.writes == [.power(true), .brightness(75), .colorTemperature(mireds: 370)])
        #expect(session.writeLog.first?.serviceID == Fixtures.hueService)

        let event = await recorder.waitFor {
            if case .stateChanged(let id, let state) = $0 { id == hueID && state.isOn } else { false }
        }
        guard case .stateChanged(_, let state)? = event else {
            Issue.record("no stateChanged event")
            return
        }
        #expect(state.brightness == 0.75)
        #expect(state.colorMode == .colorTemp)
        #expect(state.kelvin == 2703)

        // Same command again: nothing changes, nothing is written.
        try await provider.send(LightCommand(on: true, brightness: 0.75, color: .kelvin(2700)), to: hueID)
        #expect(session.writeLog.count == 1)
    }

    @Test func sendToUnknownOrUnreachableLight() async throws {
        let (provider, session, _) = await make([Fixtures.colorBulb(reachable: false)])
        _ = try await provider.loadLights()
        let unknown = HomeKitMapper.lightID(accessoryID: UUID(), serviceID: UUID())!
        await #expect(throws: LightCoreError.lightNotFound(unknown)) {
            try await provider.send(.turnOn, to: unknown)
        }
        await #expect(throws: LightCoreError.self) {
            try await provider.send(.turnOn, to: hueID)
        }
        #expect(session.writeLog.isEmpty)
    }

    @Test func writeErrorsPropagate() async throws {
        let (provider, session, _) = await make([Fixtures.plug(on: false)])
        _ = try await provider.loadLights()
        session.failWrites = LightCoreError.transport("HomeKit HMErrorDomain 4")
        await #expect(throws: LightCoreError.transport("HomeKit HMErrorDomain 4")) {
            try await provider.send(.turnOn, to: plugID)
        }
    }

    @Test func writesAreSerialisedPerAccessoryAndConcurrentAcross() async throws {
        let strip = Fixtures.colorBulb(on: false, service: Fixtures.stripService, name: "Strip")
        let (provider, session, _) = await make([Fixtures.colorBulb(on: false), strip, Fixtures.plug(on: false)])
        session.writeDelay = .milliseconds(80)
        _ = try await provider.loadLights()
        try await provider.sendGroup(.turnOn, to: [hueID, stripID, plugID])
        #expect(session.writeLog.count == 3)
        #expect(session.maxInFlightPerAccessory == 1)
        #expect(session.maxInFlightTotal == 2)
    }

    @Test func concurrentSendsToOneAccessoryDoNotOverlap() async throws {
        let (provider, session, _) = await make([Fixtures.colorBulb(on: false)])
        session.writeDelay = .milliseconds(30)
        _ = try await provider.loadLights()
        let id = hueID
        try await withThrowingTaskGroup(of: Void.self) { group in
            for step in 1...5 {
                group.addTask { try await provider.send(LightCommand(brightness: Double(step) / 10), to: id) }
            }
            try await group.waitForAll()
        }
        #expect(session.maxInFlightPerAccessory == 1)
        #expect(session.writeLog.count == 5)
    }

    @Test func sendGroupReportsPartialFailure() async throws {
        let (provider, _, _) = await make([Fixtures.plug(on: false)])
        _ = try await provider.loadLights()
        let missing = HomeKitMapper.lightID(accessoryID: UUID(), serviceID: UUID())!
        do {
            try await provider.sendGroup(.turnOn, to: [plugID, missing])
            Issue.record("expected partial failure")
        } catch let LightCoreError.partialFailure(failures) {
            #expect(Array(failures.keys) == [missing])
        }
    }

    // MARK: Events

    @Test func externalCharacteristicChangeBecomesStateChanged() async throws {
        let (provider, session, recorder) = await make([Fixtures.colorBulb(brightness: 50)])
        _ = try await provider.loadLights()
        session.emit(.lightbulbUpdated(Fixtures.colorBulb(brightness: 20), changed: .brightness))
        let event = await recorder.waitFor {
            if case .stateChanged(let id, let state) = $0 { id == hueID && state.brightness == 0.2 } else { false }
        }
        #expect(event != nil)
    }

    @Test func externalColorTemperatureChangeSetsMode() async throws {
        let (provider, session, recorder) = await make([Fixtures.colorBulb(saturation: 80, mireds: 300)])
        _ = try await provider.loadLights()
        session.emit(.lightbulbUpdated(Fixtures.colorBulb(saturation: 80, mireds: 400), changed: .colorTemperature))
        let event = await recorder.waitFor {
            if case .stateChanged(_, let state) = $0 { state.colorMode == .colorTemp } else { false }
        }
        guard case .stateChanged(_, let state)? = event else {
            Issue.record("no stateChanged event")
            return
        }
        #expect(state.kelvin == 2500)
    }

    @Test func reachabilityChangePropagatesToAllServicesOfAccessory() async throws {
        let strip = Fixtures.colorBulb(service: Fixtures.stripService, name: "Strip")
        let (provider, session, recorder) = await make([Fixtures.colorBulb(), strip, Fixtures.plug()])
        _ = try await provider.loadLights()
        session.emit(.reachabilityChanged(accessoryID: Fixtures.hueAccessory, reachable: false))
        #expect(await recorder.waitFor { $0 == .reachabilityChanged(hueID, reachable: false) } != nil)
        #expect(await recorder.waitFor { $0 == .reachabilityChanged(stripID, reachable: false) } != nil)
        let all = await recorder.events
        let plugEvents = all.filter { $0 == .reachabilityChanged(plugID, reachable: false) }
        #expect(plugEvents.isEmpty)
        // Unreachable lights reject commands.
        await #expect(throws: LightCoreError.self) { try await provider.send(.turnOff, to: hueID) }
    }

    @Test func homesChangedEmitsAddedRemovedAndUpdated() async throws {
        let (provider, session, recorder) = await make([Fixtures.colorBulb(), Fixtures.plug()])
        _ = try await provider.loadLights()

        session.bulbs = [Fixtures.colorBulb(room: "Bedroom"), Fixtures.tunableWhite()]
        session.emit(.homesChanged)

        let whiteID = HomeKitMapper.lightID(accessoryID: Fixtures.whiteAccessory, serviceID: Fixtures.whiteService)!
        let added = await recorder.waitFor { if case .lightAdded(let l) = $0 { l.id == whiteID } else { false } }
        #expect(added != nil)
        #expect(await recorder.waitFor { $0 == .lightRemoved(plugID) } != nil)
        let updated = await recorder.waitFor { if case .lightUpdated(let l) = $0 { l.id == hueID } else { false } }
        guard case .lightUpdated(let light)? = updated else {
            Issue.record("no lightUpdated event")
            return
        }
        #expect(light.roomHint == "Bedroom")

        let lights = try await provider.loadLights()
        #expect(Set(lights.map(\.id)) == [hueID, whiteID])
    }

    @Test func initialHomesChangedAnnouncesLights() async throws {
        let (provider, _, recorder) = await make([Fixtures.plug()])
        await provider.start()
        let added = await recorder.waitFor { if case .lightAdded(let l) = $0 { l.id == plugID } else { false } }
        #expect(added != nil)
    }

    @Test func sameStateIgnoresTimestampAndReachability() {
        let a = LightState(isOn: true, brightness: 0.5, reachable: true, updatedAt: Date(timeIntervalSince1970: 0))
        var b = a
        b.updatedAt = Date()
        b.reachable = false
        #expect(HomeKitProvider.sameState(a, b))
        b.brightness = 0.6
        #expect(!HomeKitProvider.sameState(a, b))
    }
}
