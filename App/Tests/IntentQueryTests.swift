import Foundation
import Testing
import LightCore
@testable import SmartLights

@Suite("Intent name matching")
struct IntentNameMatcherTests {
    @Test("Exact, prefix, word prefix, contains and wrapped-phrase ranks")
    func ranks() {
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "sofa lamp") == 0)
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "SOFA") == 1)
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "lamp") == 2)
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "ofa") == 3)
        #expect(IntentNameMatcher.rank("Bedroom", query: "the bedroom lights") == 4)
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "kitchen") == nil)
        #expect(IntentNameMatcher.rank("Sofa Lamp", query: "   ") == nil)
    }

    @Test("Case, diacritics and extra whitespace are ignored")
    func normalization() {
        #expect(IntentNameMatcher.rank("Café  Light", query: "cafe light") == 0)
        #expect(IntentNameMatcher.normalize("  Living\tRoom ") == "living room")
    }

    @Test("Short names do not match every phrase that contains them")
    func shortNamesNeedWholeWords() {
        #expect(IntentNameMatcher.rank("On", query: "turn on the lamp") == nil)
        #expect(IntentNameMatcher.rank("Den", query: "garden lights") == nil)
        #expect(IntentNameMatcher.rank("Den", query: "the den lights") == 4)
    }

    @Test("Results are ordered best match first")
    func ordering() {
        let names = ["Desk Lamp", "Lamp", "Sofa Lamp", "Lampshade"]
        let result = IntentNameMatcher.filter(names, matching: "lamp") { $0 }
        #expect(result == ["Lamp", "Lampshade", "Desk Lamp", "Sofa Lamp"])
    }
}

@Suite("Hex colours")
struct HexColorTests {
    @Test("Long, short and prefixed forms parse; junk does not")
    func parse() {
        #expect(HexColor.parse("#FF8800") == RGB(r: 255, g: 136, b: 0))
        #expect(HexColor.parse("ff8800") == RGB(r: 255, g: 136, b: 0))
        #expect(HexColor.parse("0x0000ff") == RGB(r: 0, g: 0, b: 255))
        #expect(HexColor.parse("#f80") == RGB(r: 255, g: 136, b: 0))
        #expect(HexColor.parse("#GG0000") == nil)
        #expect(HexColor.parse("blue") == nil)
    }
}

#if DEBUG
@Suite("Intent entity queries against preview providers")
@MainActor
struct IntentEntityQueryTests {
    @Test("Lights resolve by partial, case-insensitive name")
    func lights() {
        let model = PreviewRegistry.model()
        #expect(model.intentLights(matching: "sofa").map(\.id) == [PreviewData.hueColor.id])
        #expect(model.intentLights(matching: "DESK").first?.id == PreviewData.wizColor.id)
        #expect(model.intentLights(matching: "bulb").first?.id == PreviewData.wizColor.id)
        #expect(model.intentLights(matching: "turn on the porch light").first?.id == PreviewData.homeDimmable.id)
        #expect(model.intentLights(matching: "garage").isEmpty)
    }

    @Test("Rooms and scenes resolve by name")
    func roomsAndScenes() {
        let model = PreviewRegistry.model()
        #expect(model.intentRooms(matching: "living").first?.id == PreviewData.livingRoom.id)
        #expect(model.intentRooms(matching: "bedroom lights").first?.id == PreviewData.bedroom.id)
        #expect(model.intentScenes(matching: "even").first?.id == "preview-evening")
        #expect(model.intentScenes(matching: "relax").first?.id == "hue:scene-relax")
    }

    @Test("Light entities carry the stable id, brand and room")
    func lightEntity() {
        let model = PreviewRegistry.model()
        let entity = model.lightEntity(PreviewData.hueColor)
        #expect(entity.id == PreviewData.hueColor.id.rawValue)
        #expect(entity.lightID == PreviewData.hueColor.id)
        #expect(entity.brandName == Brand.hue.displayName)
        #expect(entity.roomName == "Living Room")
        #expect(model.lightEntity(PreviewData.homePlug).isAppleHome)
        #expect((try? model.resolve(entity))?.id == PreviewData.hueColor.id)
    }

    @Test("performIntent sends through the registry and updates state")
    func perform() async throws {
        let model = PreviewRegistry.makeModel(library: PreviewData.library)
        await PreviewRegistry.registerFakeProviders(in: model, latency: .milliseconds(5))
        await model.start()
        let id = PreviewData.wizTunable.id
        let outcome = try await model.performIntent(LightCommand(on: true, brightness: 0.3), on: [id])
        #expect(outcome.succeeded == [id])
        #expect(outcome.failedNames.isEmpty)
        #expect(model.lightsByID[id]?.state.isOn == true)
        #expect(model.lightsByID[id]?.state.brightness == 0.3)
    }

    @Test("performIntent reports failures from the provider")
    func performFailure() async {
        let model = PreviewRegistry.makeModel(library: PreviewData.library)
        let id = PreviewData.wizTunable.id
        await PreviewRegistry.registerFakeProviders(in: model, latency: .milliseconds(5), failing: [id])
        await model.start()
        await #expect(throws: IntentFailure.self) {
            try await model.performIntent(.turnOn, on: [id])
        }
    }
}
#endif
