import Foundation
import LightCore
@testable import Onboarding
import Testing

@Suite("PairingInteraction bridging")
@MainActor
struct BridgingTests {
    let device = DiscoveredDevice(id: "bridge1", brand: .hue, name: "Hue Bridge", host: "10.0.0.2", method: .manual)

    @Test func providerPromptsAppearInTheWizardAndAnswersFlowBack() async throws {
        let runner = GuideRunner(guide: GuideCatalog.hue)
        let provider = FakeButtonProvider()
        let ui = ScriptedUI([.confirm(true), .text("Living room bridge"), .text("secret-key"), .choice(1), .file(Data("{}".utf8))])
        ui.attach(to: runner)
        let device = self.device
        runner.actionHandler = { ctx in
            #expect(ctx.callback == GuideCallback.pair)
            return .paired(try await provider.pair(device, using: ctx.ui))
        }

        runner.go(to: "link-button")
        runner.perform()
        await runner.waitForAction()

        #expect(runner.activity == .idle)
        #expect(ui.messages == [
            "Press the link button on the bridge",
            "Name this bridge",
            "Paste the key",
            "Region",
            "Import key file",
        ])
        #expect(ui.prompts.map(\.kind) == [
            .confirm("Press the link button on the bridge"),
            .text("Name this bridge"),
            .secureText("Paste the key"),
            .choose("Region", options: ["EU", "US"]),
            .importFile("Import key file", allowedTypes: ["public.json"]),
        ])
        #expect(ui.statuses == ["Waiting for link button..."])
        #expect(runner.statusMessage == "Waiting for link button...")
        #expect(runner.pendingPrompt == nil)
        guard case .paired(let paired) = runner.answer(for: "link-button") else {
            Issue.record("expected paired"); return
        }
        #expect(paired.name == "Living room bridge")
        #expect(paired.metadata == ["region": "US", "fileBytes": "2"])
        #expect(await provider.receivedKey == "secret-key")
        #expect(runner.canAdvance)
    }

    @Test func dismissingAPromptCancelsThePairing() async {
        let runner = GuideRunner(guide: GuideCatalog.hue)
        let provider = FakeButtonProvider()
        let ui = ScriptedUI([.cancel])
        ui.attach(to: runner)
        let device = self.device
        runner.actionHandler = { ctx in .paired(try await provider.pair(device, using: ctx.ui)) }

        runner.go(to: "link-button")
        runner.perform()
        await runner.waitForAction()

        #expect(ui.messages == ["Press the link button on the bridge"])
        #expect(runner.activity == .idle) // user cancellation is not an error
        #expect(runner.answer(for: "link-button") == nil)
        #expect(!runner.canAdvance)
    }

    @Test func answeringNoIsSurfacedAsCancellation() async {
        let runner = GuideRunner(guide: GuideCatalog.hue)
        let provider = FakeButtonProvider()
        let ui = ScriptedUI([.confirm(false)])
        ui.attach(to: runner)
        let device = self.device
        runner.actionHandler = { ctx in .paired(try await provider.pair(device, using: ctx.ui)) }
        runner.go(to: "link-button")
        runner.perform()
        await runner.waitForAction()
        #expect(runner.answer(for: "link-button") == nil)
        #expect(ui.remainingReplies == 0)
    }

    @Test func cancelActionResolvesAnOpenPrompt() async {
        let runner = GuideRunner(guide: GuideCatalog.hue)
        let provider = FakeButtonProvider()
        let ui = ScriptedUI([.ignore])
        ui.attach(to: runner)
        let device = self.device
        runner.actionHandler = { ctx in .paired(try await provider.pair(device, using: ctx.ui)) }
        runner.go(to: "link-button")
        runner.perform()
        // Let the provider reach its first prompt.
        while runner.pendingPrompt == nil { await Task.yield() }
        #expect(runner.pendingPrompt?.message == "Press the link button on the bridge")
        runner.cancelAction()
        #expect(runner.pendingPrompt == nil)
        #expect(!runner.isBusy)
        await runner.waitForAction()
        #expect(runner.answer(for: "link-button") == nil)
    }

    @Test func wrongResponseTypeIsAProtocolError() async {
        let runner = GuideRunner(guide: GuideCatalog.hue)
        let ui = ScriptedUI([.text("oops")])
        ui.attach(to: runner)
        runner.actionHandler = { ctx in
            _ = try await ctx.ui.confirm("Press")
            return .done
        }
        runner.go(to: "link-button")
        runner.perform()
        await runner.waitForAction()
        #expect(runner.activity == .failed(stepID: "link-button", message: "Unexpected device response: expected confirm"))
    }

    @Test func runnerIsUsableDirectlyAsPairingInteraction() async throws {
        let runner = GuideRunner(guide: GuideCatalog.wiz)
        let ui = ScriptedUI([.choice(0), .text("abc")])
        ui.attach(to: runner)
        let interaction: any PairingInteraction = runner
        #expect(try await interaction.choose("Mode", options: ["x", "y"]) == 0)
        #expect(try await interaction.text("Host") == "abc")
        await #expect(throws: LightCoreError.userCancelled) {
            _ = try await interaction.confirm("No replies left")
        }
    }
}
