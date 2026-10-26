import Foundation
import LightCore
@testable import Onboarding
import Testing

@Suite("Codable")
struct SerializationTests {
    @Test func everyCatalogGuideRoundTrips() throws {
        for guide in GuideCatalog.standard.guides {
            let data = try guide.jsonData()
            let decoded = try BrandGuide.decode(fromJSON: data)
            #expect(decoded == guide, "\(guide.id)")
            #expect(try decoded.jsonData() == data, "\(guide.id) stable encoding")
        }
    }

    @Test func dummyGuideRoundTripsAndUsesReadableJSON() throws {
        let guide = dummyGuide()
        let data = try guide.jsonData()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""type" : "checklist""#))
        #expect(json.contains(#""type" : "secureText""#))
        #expect(json.contains(#""deepLink" : "vendor://""#))
        #expect(json.contains(#""brand" : "wiz""#))
        #expect(json.contains(#""text" : "Read this.\n- one\n- two""#))
        #expect(try BrandGuide.decode(fromJSON: data) == guide)
    }

    @Test func decodesHandWrittenJSON() throws {
        let json = """
        {"id":"x","title":"X","summary":"S","phase":2,"listing":"brand","steps":[
          {"id":"a","title":"A","needsVerification":false,"isOptional":false,"problems":[],
           "kind":{"type":"action","prompt":"Press","action":{"type":"confirm"}}}
        ],"alternatives":[],"verifyFlags":[],"prerequisites":[]}
        """
        let guide = try BrandGuide.decode(fromJSON: Data(json.utf8))
        #expect(guide.brand == nil)
        #expect(guide.steps.first?.actionKind == .confirm(button: "Continue"))
    }

    @Test func unknownStepTypeFails() {
        let json = #"{"type":"hologram","text":"x"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GuideStep.Kind.self, from: Data(json.utf8))
        }
    }
}

@Suite("Snapshots")
struct SnapshotTests {
    static let snapshotDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")

    @Test func dummyGuideRendersExactly() {
        let expected = """
        # Dummy Brand (§99) [phase 1] [verify]
        A *test* guide.

        1. Before you start
           [ ] Bulb is on.
           [ ] Phone on *same Wi-Fi*. [verify]

        2. Intro
           Read this.
           • one
           • two

        3. Scan
           Tap *Scan*.
           > [Scan]

        4. Pair [verify]
           Press the button.
           > [Continue]
           It didn't work?
             ? Timed out
               Press again.
           (verify: button window)

        5. Add by IP (optional)
           Enter the IP.
           > [text: IP address]

        6. Key
           Paste the key.
           > [secure: Key]

        7. File (optional)
           Import the file.
           > [Import file: public.json]

        8. Mode (optional)
           Pick one.
           > [Choose: A | B]

        9. App (optional)
           Open the vendor app <vendor://>.
           > [Open Vendor <vendor://>]

        10. Blink (optional)
           Watch the light.
           > [Blink]

        11. Troubleshooting
           ? Not found
             Enter the IP.

        Alternatives:
        - Matter -> matter-apple-home
          Use Apple Home.

        To verify:
        - dummy-1: Check everything.

        """
        #expect(GuideTextRenderer.render(dummyGuide()) == expected)
    }

    @Test func releaseRenderingHidesVerifyMarkers() {
        let text = GuideTextRenderer.render(dummyGuide(), showVerification: false)
        #expect(!text.contains("[verify]"))
        #expect(!text.contains("To verify"))
    }

    /// Snapshot of the generic Apple-side guide (§0). Re-record with `RECORD_SNAPSHOTS=1 swift test`.
    @Test(arguments: [GuideCatalog.iPhoneSetupID, GuideCatalog.matterIntoAppleHomeID])
    func appleSideGuideMatchesSnapshot(id: String) throws {
        let guide = try #require(GuideCatalog.standard.guide(id: id))
        let rendered = GuideTextRenderer.render(guide)
        let file = Self.snapshotDir.appendingPathComponent("\(id).txt")
        let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
        // Tolerate CRLF checkouts on Windows.
        let existing = (try? String(contentsOf: file, encoding: .utf8))?.replacingOccurrences(of: "\r\n", with: "\n")
        if record || existing == nil || existing?.isEmpty == true {
            try FileManager.default.createDirectory(at: Self.snapshotDir, withIntermediateDirectories: true)
            try rendered.write(to: file, atomically: true, encoding: .utf8)
            Issue.record("Recorded snapshot \(file.lastPathComponent); re-run without RECORD_SNAPSHOTS")
            return
        }
        #expect(rendered == existing)
    }
}
