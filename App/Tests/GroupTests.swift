import Foundation
import Testing
import LightCore
@testable import SmartLights

@Suite("App library persistence")
struct AppLibraryCodingTests {
    @Test("Version-1 files without groups still decode")
    func decodesVersionOne() throws {
        let json = #"{"version":1,"rooms":[],"scenes":[],"seenLightIDs":[]}"#
        let library = try JSONDecoder().decode(AppLibrary.self, from: Data(json.utf8))
        #expect(library.version == 1)
        #expect(library.groups.isEmpty)
    }

    @Test("Groups round-trip with transition and Light Sync source")
    func roundTripsGroups() throws {
        let hue = LightID(brand: .hue, stableId: "a1")!
        let wiz = LightID(brand: .wiz, stableId: "a8bb5006033d")!
        let group = LightGroup(name: "Mixed", lightIDs: [hue, wiz], transitionMilliseconds: 1000, syncSourceID: hue)
        let library = AppLibrary(groups: [group])
        let decoded = try JSONDecoder().decode(AppLibrary.self, from: JSONEncoder().encode(library))
        #expect(decoded == library)
        #expect(decoded.version == AppLibrary.currentVersion)
        #expect(decoded.groups.first?.transition == .seconds(1))
        #expect(decoded.groups.first?.syncTargets == [wiz])
    }

    @Test("Transition options map to stored milliseconds and back")
    func transitionOptions() {
        for option in TransitionOption.allCases {
            #expect(TransitionOption(milliseconds: option.milliseconds) == option)
        }
        #expect(TransitionOption.short.milliseconds == 400)
        #expect(TransitionOption(milliseconds: 1234) == .providerDefault)
    }
}

@Suite("Scene recall buckets")
struct SceneBucketTests {
    @Test("Lights with the same command share one group send")
    func buckets() {
        let a = LightID(brand: .hue, stableId: "a")!
        let b = LightID(brand: .wiz, stableId: "b")!
        let c = LightID(brand: .aidot, stableId: "c")!
        let buckets = AppModel.commandBuckets([a: .turnOn, b: .turnOn, c: .turnOff])
        #expect(buckets.count == 2)
        #expect(buckets.first { $0.command == .turnOn }?.lightIDs == [a, b].sorted())
        #expect(buckets.first { $0.command == .turnOff }?.lightIDs == [c])
        // Stable order (by first light id) so repeated recalls reuse the same coalescing slots.
        #expect(buckets.map { $0.lightIDs[0] } == buckets.map { $0.lightIDs[0] }.sorted())
    }
}

#if DEBUG
@Suite("Cross-brand groups")
@MainActor
struct GroupTests {
    private let hue = PreviewData.hueColor.id
    private let wiz = PreviewData.wizColor.id
    private let aidot = PreviewData.aidotRGBW.id
    private let home = PreviewData.homeDimmable.id

    private struct Fixture {
        let model: AppModel
        let hue: FakeLightProvider<FakeHue>
        let wiz: FakeLightProvider<FakeWiZ>
        let aidot: FakeLightProvider<FakeAiDot>
        let home: FakeLightProvider<FakeAppleHome>
    }

    private func makeFixture() async -> Fixture {
        let model = PreviewRegistry.makeModel(library: AppLibrary())
        let lights = PreviewData.lights
        let fixture = Fixture(
            model: model,
            hue: FakeLightProvider<FakeHue>(lights: lights, latency: .milliseconds(5)),
            wiz: FakeLightProvider<FakeWiZ>(lights: lights, latency: .milliseconds(5)),
            aidot: FakeLightProvider<FakeAiDot>(lights: lights, latency: .milliseconds(5)),
            home: FakeLightProvider<FakeAppleHome>(lights: lights, latency: .milliseconds(5))
        )
        await model.registry.register(fixture.hue)
        await model.registry.register(fixture.wiz)
        await model.registry.register(fixture.aidot)
        await model.registry.register(fixture.home)
        await model.start()
        return fixture
    }

    private func settle(_ model: AppModel) async {
        for _ in 0..<300 where !model.coalescer.isIdle {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("A group mixes brands and is persisted with the library")
    func createAndEdit() async {
        let f = await makeFixture()
        let group = f.model.addGroup(named: "  Downstairs ", lightIDs: [hue, wiz, hue, aidot])
        #expect(group.name == "Downstairs")
        #expect(group.lightIDs == [hue, wiz, aidot])
        #expect(Set(f.model.lights(inGroup: group.id).map(\.brand)) == [.hue, .wiz, .aidot])

        f.model.setMember(home, true, inGroup: group.id)
        f.model.setMember(wiz, false, inGroup: group.id)
        f.model.setTransition(milliseconds: 400, forGroup: group.id)
        #expect(f.model.group(group.id)?.lightIDs == [hue, aidot, home])
        #expect(f.model.groups(containing: hue).map(\.id) == [group.id])
        #expect(f.model.group(named: "downstairs")?.id == group.id)

        // Groups do not move lights out of their rooms.
        #expect(f.model.room(named: "Living Room")?.lightIDs.contains(hue) == true)

        try? await Task.sleep(for: .milliseconds(400))
        let saved = try? await f.model.libraryStore.load()
        #expect(saved?.groups.first?.lightIDs == [hue, aidot, home])
        #expect(saved?.groups.first?.transitionMilliseconds == 400)
    }

    @Test("Group commands reach every brand's provider with one group send each")
    func controlsAllBrandsEqually() async {
        let f = await makeFixture()
        let group = f.model.addGroup(named: "Mixed", lightIDs: [hue, wiz, aidot, home], transitionMilliseconds: 1000)
        let before = (await f.hue.commandCount, await f.wiz.commandCount, await f.aidot.commandCount, await f.home.commandCount)

        f.model.setPower(true, forGroup: group.id)
        f.model.setBrightness(0.4, forGroup: group.id)
        for id in [hue, wiz, aidot, home] {
            #expect(f.model.lightsByID[id]?.state.isOn == true, "\(id)")
            #expect(f.model.lightsByID[id]?.state.brightness == 0.4, "\(id)")
        }
        await settle(f.model)

        // The burst coalesced into one group command, fanned out to each provider once.
        #expect(await f.hue.commandCount == before.0 + 1)
        #expect(await f.wiz.commandCount == before.1 + 1)
        #expect(await f.aidot.commandCount == before.2 + 1)
        #expect(await f.home.commandCount == before.3 + 1)
        for id in [hue, wiz, aidot, home] {
            #expect(f.model.lightsByID[id]?.state.brightness == 0.4, "\(id)")
        }

        f.model.setKelvin(2700, forGroup: group.id)
        #expect(f.model.lightsByID[hue]?.state.colorMode == .colorTemp)
        f.model.setColor(HS(h: 120, s: 1), forGroup: group.id)
        #expect(f.model.lightsByID[wiz]?.state.colorMode?.isColor == true)
        // On/off + brightness only: colour is dropped for it, power stays on.
        #expect(f.model.lightsByID[home]?.state.isOn == true)
        await settle(f.model)
    }

    @Test("The group's transition is added unless the command sets one")
    func transition() {
        let group = LightGroup(name: "G", transitionMilliseconds: 3000)
        #expect(AppModel.command(.turnOn, for: group).transition == .seconds(3))
        #expect(AppModel.command(LightCommand(on: true, transition: .zero), for: group).transition == .zero)
        #expect(AppModel.command(.turnOn, for: LightGroup(name: "Default")).transition == nil)
    }

    @Test("Light Sync mirrors the source light to the rest of the group")
    func lightSync() async {
        let f = await makeFixture()
        let group = f.model.addGroup(named: "Follow", lightIDs: [hue, wiz, aidot])
        #expect(f.model.setSyncSource(hue, forGroup: group.id))
        #expect(f.model.group(group.id)?.syncTargets == [wiz, aidot])

        // A change from this app.
        f.model.send(LightCommand(on: true, brightness: 0.3, color: .hs(HS(h: 200, s: 0.9))), to: hue)
        #expect(f.model.lightsByID[wiz]?.state.brightness == 0.3)
        #expect(f.model.lightsByID[aidot]?.state.isOn == true)
        await settle(f.model)

        // A change made elsewhere (vendor app), reported by the provider.
        await f.hue.simulateExternalChange(.turnOff, to: hue)
        for _ in 0..<100 where f.model.lightsByID[wiz]?.state.isOn != false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.model.lightsByID[wiz]?.state.isOn == false)
        #expect(f.model.lightsByID[aidot]?.state.isOn == false)
        await settle(f.model)

        // Off again: the members no longer follow.
        #expect(f.model.setSyncSource(nil, forGroup: group.id))
        f.model.send(.turnOn, to: hue)
        #expect(f.model.lightsByID[wiz]?.state.isOn == false)
        await settle(f.model)
    }

    @Test("Mirror commands copy state but not vendor effects")
    func mirrorCommand() {
        let state = LightState(isOn: true, brightness: 0.5, colorMode: .colorTemp, kelvin: 3000, effect: "candle")
        let command = AppModel.mirrorCommand(for: state, transition: .milliseconds(400))
        #expect(command == LightCommand(on: true, brightness: 0.5, color: .kelvin(3000), transition: .milliseconds(400)))
        #expect(AppModel.mirrorCommand(for: LightState(isOn: false), transition: nil) == .turnOff)
    }

    @Test("Light Sync refuses groups that would mirror each other")
    func syncLoopsAreRefused() async {
        let f = await makeFixture()
        let first = f.model.addGroup(named: "A", lightIDs: [hue, wiz])
        let second = f.model.addGroup(named: "B", lightIDs: [wiz, hue])
        #expect(f.model.setSyncSource(hue, forGroup: first.id))
        #expect(!f.model.setSyncSource(wiz, forGroup: second.id))
        #expect(f.model.group(second.id)?.syncSourceID == nil)

        // A chain is fine (hue -> wiz -> aidot) ...
        let third = f.model.addGroup(named: "C", lightIDs: [aidot])
        #expect(f.model.setSyncSource(wiz, forGroup: third.id))
        // ... until editing members closes the loop, which turns that group's sync off.
        f.model.setLights([aidot, hue], forGroup: third.id)
        #expect(f.model.group(third.id)?.syncSourceID == nil)
        #expect(f.model.group(first.id)?.syncSourceID == hue)
        await settle(f.model)
    }

    @Test("App scenes recall across brands")
    func sceneRecall() async {
        let f = await makeFixture()
        f.model.send(LightCommand(on: true, brightness: 0.2), toLights: [hue, wiz, aidot], groupKey: .group("setup"))
        await settle(f.model)
        let scene = f.model.createSnapshotScene(name: "Dim", lightIDs: [hue, wiz, aidot])
        f.model.send(.turnOff, toLights: [hue, wiz, aidot], groupKey: .group("setup"))
        await settle(f.model)

        f.model.recall(scene)
        for id in [hue, wiz, aidot] {
            #expect(f.model.lightsByID[id]?.state.isOn == true, "\(id)")
        }
        await settle(f.model)
    }

    @Test("Deleting a group leaves its lights alone")
    func delete() async {
        let f = await makeFixture()
        let group = f.model.addGroup(named: "Temp", lightIDs: [hue, wiz])
        f.model.deleteGroup(group.id)
        #expect(f.model.groups.isEmpty)
        #expect(f.model.lightsByID[hue] != nil && f.model.lightsByID[wiz] != nil)
    }
}
#endif
