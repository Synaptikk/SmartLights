import Foundation
import Testing
@testable import SmartLights

/// Smoke test so `xcodebuild test -scheme SmartLights` has a test bundle to run.
@Suite("App skeleton")
struct SmartLightsAppTests {
    @Test("Bundle identifier matches the planned id")
    func bundleIdentifier() {
        // The test bundle is hosted by the app, so Bundle.main is the app bundle.
        #expect(Bundle.main.bundleIdentifier == "com.sinap.smartlights")
    }
}
