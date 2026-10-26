import Foundation
import Testing
import LightCore
@testable import SmartLights

@Suite("LightCommand merging")
struct LightCommandMergeTests {
    @Test("Newer fields win, unset fields keep the queued value")
    func latestWins() {
        let queued = LightCommand(on: true, brightness: 0.2)
        let merged = queued.merging(LightCommand(brightness: 0.8))
        #expect(merged.on == true)
        #expect(merged.brightness == 0.8)
    }

    @Test("Colour cancels a queued effect and effect cancels a queued colour")
    func colorAndEffectExclusive() {
        let withEffect = LightCommand(effect: "4").merging(LightCommand(color: .kelvin(3000)))
        #expect(withEffect.effect == nil)
        #expect(withEffect.color == .kelvin(3000))

        let withColor = LightCommand(color: .kelvin(3000)).merging(LightCommand(effect: "4"))
        #expect(withColor.color == nil)
        #expect(withColor.effect == "4")
    }
}

/// Counts sends for coalescer tests.
private actor SendLog {
    var commands: [LightCommand] = []
    func append(_ command: LightCommand) { commands.append(command) }
}

@Suite("Command coalescing")
@MainActor
struct CommandCoalescerTests {
    private let id = LightID(brand: .wiz, stableId: "a8bb5006033d")!

    private func waitUntilIdle(_ coalescer: CommandCoalescer) async {
        for _ in 0..<200 where !coalescer.isIdle {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A burst of slider ticks sends one merged command")
    func burstCoalesces() async {
        let log = SendLog()
        let coalescer = CommandCoalescer(minimumInterval: .milliseconds(20)) { command, _ in
            await log.append(command)
        }
        for step in 1...20 {
            coalescer.enqueue(LightCommand(brightness: Double(step) / 20), key: .light(id), targets: [id])
        }
        await waitUntilIdle(coalescer)
        let sent = await log.commands
        #expect(sent.count == 1)
        #expect(sent.last?.brightness == 1.0)
    }

    @Test("Ticks during an in-flight send collapse into one follow-up (latest wins)")
    func oneInFlight() async {
        let log = SendLog()
        let coalescer = CommandCoalescer(minimumInterval: .milliseconds(20)) { command, _ in
            await log.append(command)
            try await Task.sleep(for: .milliseconds(50))
        }
        coalescer.enqueue(LightCommand(brightness: 0.1), key: .light(id), targets: [id])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(coalescer.isBusy(id))
        coalescer.enqueue(LightCommand(brightness: 0.5), key: .light(id), targets: [id])
        coalescer.enqueue(LightCommand(brightness: 0.9), key: .light(id), targets: [id])
        await waitUntilIdle(coalescer)
        let sent = await log.commands.compactMap(\.brightness)
        #expect(sent == [0.1, 0.9])
        #expect(!coalescer.isBusy(id))
    }
}

#if DEBUG
@Suite("AppModel with fake providers")
@MainActor
struct AppModelTests {
    private func makeModel() async -> AppModel {
        let model = PreviewRegistry.makeModel(library: AppLibrary())
        await PreviewRegistry.registerFakeProviders(in: model, latency: .milliseconds(5))
        await model.start()
        return model
    }

    @Test("start() loads lights of every phase-1 brand, keyed by stable id")
    func loadsLights() async {
        let model = await makeModel()
        #expect(model.lightsByID.count == PreviewData.lights.count)
        #expect(Set(model.lights.map(\.brand)) == [.hue, .wiz, .aidot, .appleHome])
    }

    @Test("Rooms are created from provider room hints on first sighting")
    func autoRooms() async {
        let model = await makeModel()
        #expect(model.room(named: "Living Room")?.lightIDs.contains(PreviewData.hueColor.id) == true)
        #expect(model.unassignedLights.contains { $0.id == PreviewData.wizTunable.id })
    }

    @Test("send applies state optimistically before the provider answers")
    func optimistic() async {
        let model = await makeModel()
        let id = PreviewData.wizTunable.id
        model.send(LightCommand(on: true, brightness: 0.75), to: id)
        #expect(model.lightsByID[id]?.state.isOn == true)
        #expect(model.lightsByID[id]?.state.brightness == 0.75)
    }

    @Test("Snapshot scenes capture current state")
    func snapshot() async {
        let model = await makeModel()
        let scene = model.createSnapshotScene(name: "Test", lightIDs: [PreviewData.hueColor.id])
        #expect(scene.kind == .app)
        #expect(model.appScenes.contains { $0.id == scene.id })
        #expect(scene.commands[PreviewData.hueColor.id]?.on == true)
    }
}
#endif
