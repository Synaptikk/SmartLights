import Foundation
import LightCore
@testable import Onboarding
import Testing

/// Small guide covering every step kind.
func dummyGuide() -> BrandGuide {
    BrandGuide(
        id: "dummy",
        brand: .wiz,
        title: "Dummy Brand",
        summary: "A **test** guide.",
        phase: 1,
        section: "§99",
        steps: [
            GuideStep(id: "before", title: "Before you start", kind: .checklist([
                ChecklistItem("Bulb is on."),
                ChecklistItem("Phone on **same Wi-Fi**.", needsVerification: true),
            ])),
            GuideStep(id: "intro", title: "Intro", kind: .info("Read this.\n- one\n- two")),
            GuideStep(id: "scan", title: "Scan", kind: .action(.scan, prompt: "Tap **Scan**."), callback: GuideCallback.discover),
            GuideStep(
                id: "pair", title: "Pair",
                kind: .action(.confirm(button: "Continue"), prompt: "Press the button."),
                needsVerification: true, verifyNote: "button window",
                callback: GuideCallback.pair,
                problems: [Problem("Timed out", fix: "Press again.")]
            ),
            GuideStep(id: "ip", title: "Add by IP", kind: .action(.text(InputField(key: "host", label: "IP address", contentType: .ipAddress)), prompt: "Enter the IP."), isOptional: true),
            GuideStep(id: "key", title: "Key", kind: .action(.secureText(InputField(key: "key", label: "Key", contentType: .hexKey)), prompt: "Paste the key.")),
            GuideStep(id: "file", title: "File", kind: .action(.importFile(allowedTypes: ["public.json"]), prompt: "Import the file."), isOptional: true),
            GuideStep(id: "mode", title: "Mode", kind: .action(.choose(options: ["A", "B"]), prompt: "Pick one."), isOptional: true),
            GuideStep(id: "app", title: "App", kind: .action(.openApp(name: "Vendor", deepLink: "vendor://"), prompt: "Open the [vendor app](vendor://)."), isOptional: true),
            GuideStep(id: "blink", title: "Blink", kind: .action(.verifyBlink, prompt: "Watch the light."), callback: GuideCallback.verify, isOptional: true),
            GuideStep(id: "help", title: "Troubleshooting", kind: .troubleshoot([Problem("Not found", fix: "Enter the IP.")])),
        ],
        alternatives: [GuideAlternative(title: "Matter", detail: "Use Apple Home.", targetGuideID: "matter-apple-home")],
        verifyFlags: [VerifyFlag(id: "dummy-1", note: "Check everything.")]
    )
}

@MainActor final class Counter { var value = 0 }

/// Minimal provider whose `pair` drives the UI exactly like a real one (link-button confirm etc.).
actor FakeButtonProvider: LightProvider {
    static let brand: Brand = .hue
    var account: ProviderAccount? { nil }
    private(set) var receivedKey: String?

    func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice> {
        AsyncStream { c in
            c.yield(DiscoveredDevice(id: "bridge1", brand: .hue, name: "Hue Bridge", host: "10.0.0.2", method: .manual))
            c.finish()
        }
    }

    func pair(_ device: DiscoveredDevice, using ui: any PairingInteraction) async throws -> PairedDevice {
        await ui.status("Waiting for link button...")
        guard try await ui.confirm("Press the link button on the bridge") else { throw LightCoreError.userCancelled }
        let name = try await ui.text("Name this bridge")
        receivedKey = try await ui.secureText("Paste the key")
        let region = try await ui.choose("Region", options: ["EU", "US"])
        let file = try await ui.importFile("Import key file", allowedTypes: ["public.json"])
        return PairedDevice(id: device.id, brand: .hue, name: name, metadata: ["region": ["EU", "US"][region], "fileBytes": "\(file.count)"])
    }

    func loadLights() async throws -> [Light] { [] }
    func send(_ command: LightCommand, to light: LightID) async throws {}
    nonisolated var events: AsyncStream<ProviderEvent> { AsyncStream { $0.finish() } }
}

@Suite("GuideRunner")
@MainActor
struct RunnerTests {
    @Test func checklistGatesProgress() {
        let runner = GuideRunner(guide: dummyGuide())
        #expect(runner.currentStep?.id == "before")
        #expect(!runner.canAdvance)
        #expect(!runner.next())
        runner.toggle(item: 0)
        #expect(!runner.canAdvance)
        runner.toggle(item: 1)
        #expect(runner.canAdvance)
        runner.toggle(item: 1)
        #expect(!runner.canAdvance)
        runner.toggle(item: 1)
        runner.toggle(item: 7) // out of range: ignored
        #expect(runner.next())
        #expect(runner.currentStep?.id == "intro")
        #expect(runner.isChecked(0, in: "before"))
    }

    @Test func walksAllStepsWithoutHandler() {
        let runner = GuideRunner(guide: dummyGuide())
        runner.toggle(item: 0); runner.toggle(item: 1)
        #expect(runner.next())                         // before -> intro
        #expect(runner.next())                         // intro -> scan
        #expect(!runner.canAdvance)                    // action needs an answer
        runner.perform()                               // no handler: default answer
        #expect(runner.answer(for: "scan") == .done)
        #expect(runner.next())                         // -> pair
        runner.perform()
        #expect(runner.answer(for: "pair") == .confirmed(true))
        #expect(runner.next())                         // -> ip (optional)
        #expect(runner.canAdvance)
        #expect(runner.next())                         // skip -> key
        #expect(!runner.canAdvance)
        runner.submit(.secret("00112233445566778899aabbccddeeff"))
        #expect(runner.answer(for: "key")?.description == "secret(<redacted>)")
        #expect(runner.next())                         // -> file
        #expect(runner.back())
        #expect(runner.currentStep?.id == "key")
        #expect(runner.next())
        for _ in 0..<4 { #expect(runner.next()) }      // file, mode, app, blink (optional)
        #expect(runner.currentStep?.id == "help")
        #expect(runner.isLastStep)
        #expect(runner.next())
        #expect(runner.isFinished)
        #expect(runner.currentStep == nil)
        #expect(runner.progress == 1)
        runner.clearSecrets()
        #expect(runner.answer(for: "key") == .done)
        #expect(runner.back())
        #expect(runner.currentStep?.id == "help")
        runner.restart()
        #expect(runner.currentIndex == 0 && runner.answers.isEmpty && !runner.isFinished)
    }

    @Test func stubGuideIsFinishedImmediately() throws {
        let runner = GuideRunner(guide: try #require(GuideCatalog.standard.guide(for: .tuya)))
        #expect(runner.isFinished)
        #expect(runner.currentStep == nil)
        #expect(!runner.canAdvance)
    }

    @Test func goToJumpsByID() {
        let runner = GuideRunner(guide: dummyGuide())
        runner.go(to: "pair")
        #expect(runner.currentStep?.id == "pair")
        runner.go(to: "missing")
        #expect(runner.currentStep?.id == "pair")
    }

    @Test func handlerScanResultIsRecorded() async {
        let runner = GuideRunner(guide: dummyGuide())
        let provider = FakeButtonProvider()
        runner.actionHandler = { ctx in
            #expect(ctx.callback == GuideCallback.discover)
            #expect(ctx.brand == .wiz)
            var found: [DiscoveredDevice] = []
            for await device in await provider.discover(options: .default) { found.append(device) }
            return .discovered(found)
        }
        runner.go(to: "scan")
        runner.perform()
        #expect(runner.isBusy)
        #expect(!runner.canAdvance)
        await runner.waitForAction()
        #expect(runner.activity == .idle)
        guard case .discovered(let devices) = runner.answer(for: "scan") else {
            Issue.record("expected discovered answer"); return
        }
        #expect(devices.map(\.id) == ["bridge1"])
        #expect(runner.canAdvance)
    }

    @Test func handlerErrorShowsFailureAndAllowsRetry() async {
        let runner = GuideRunner(guide: dummyGuide())
        let attempts = Counter()
        runner.actionHandler = { _ in
            attempts.value += 1
            if attempts.value == 1 { throw LightCoreError.unreachable("10.0.0.2") }
            return .done
        }
        runner.go(to: "scan")
        runner.perform()
        await runner.waitForAction()
        #expect(runner.activity == .failed(stepID: "scan", message: "Unreachable: 10.0.0.2"))
        #expect(!runner.canAdvance)
        runner.perform()
        await runner.waitForAction()
        #expect(runner.activity == .idle)
        #expect(runner.canAdvance)
    }
}
