#if canImport(SwiftUI)
import SwiftUI

/// Renders any `BrandGuide` step by step, driven by a `GuideRunner`.
/// Provider prompts (`PairingInteraction`) raised while a step runs appear in a sheet.
///
/// ```swift
/// @State private var runner = GuideRunner(guide: GuideCatalog.hue)
/// ...
/// GuideFlowView(guide: runner.guide, runner: runner, onFinish: { dismiss() })
/// ```
public struct GuideFlowView: View {
    public let guide: BrandGuide
    @Bindable private var runner: GuideRunner
    private let catalog: GuideCatalog
    private let onOpenGuide: (@MainActor (BrandGuide) -> Void)?
    private let onFinish: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - guide: must be `runner.guide` (kept as a parameter so call sites read naturally).
    ///   - onOpenGuide: called when the user follows an alternative/prerequisite link (push that guide).
    ///   - onFinish: called from the final "Done" button.
    public init(
        guide: BrandGuide,
        runner: GuideRunner,
        catalog: GuideCatalog = .standard,
        onOpenGuide: (@MainActor (BrandGuide) -> Void)? = nil,
        onFinish: (@MainActor () -> Void)? = nil
    ) {
        assert(guide.id == runner.guide.id, "GuideFlowView: guide and runner.guide differ")
        self.guide = guide
        self._runner = Bindable(runner)
        self.catalog = catalog
        self.onOpenGuide = onOpenGuide
        self.onFinish = onFinish
    }

    public init(
        runner: GuideRunner,
        catalog: GuideCatalog = .standard,
        onOpenGuide: (@MainActor (BrandGuide) -> Void)? = nil,
        onFinish: (@MainActor () -> Void)? = nil
    ) {
        self.init(guide: runner.guide, runner: runner, catalog: catalog, onOpenGuide: onOpenGuide, onFinish: onFinish)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !guide.isStub {
                ProgressView(value: runner.progress)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityLabel("Progress")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if runner.isFirstStep || runner.currentStep == nil {
                        GuideHeaderView(guide: guide, catalog: catalog, onOpenGuide: onOpenGuide)
                    }
                    if let step = runner.currentStep {
                        Text("Step \(runner.currentIndex + 1) of \(guide.steps.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        StepView(step: step, runner: runner)
                            .id(step.id) // reset per-step @State (text fields, importer)
                    } else {
                        CompletionView(guide: guide)
                    }
                    if !guide.alternatives.isEmpty {
                        AlternativesView(alternatives: guide.alternatives, catalog: catalog, onOpenGuide: onOpenGuide)
                    }
                    VerifyFlagsView(flags: guide.verifyFlags)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            navigationBar
        }
        .navigationTitle(guide.title)
        .sheet(item: $runner.presentedPrompt) { request in
            PromptSheet(request: request, runner: runner)
                .interactiveDismissDisabled()
        }
    }

    private var navigationBar: some View {
        HStack {
            if !guide.isStub {
                Button("Back") { runner.back() }
                    .disabled((runner.isFirstStep && !runner.isFinished) || runner.isBusy)
            }
            Spacer()
            if runner.isFinished {
                Button("Done") { onFinish?() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(nextTitle) { runner.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!runner.canAdvance)
            }
        }
        .padding()
        .background(.bar)
    }

    private var nextTitle: String {
        guard let step = runner.currentStep else { return "Next" }
        if step.isOptional, step.actionKind != nil, runner.answer(for: step.id) == nil { return "Skip" }
        return runner.isLastStep ? "Finish" : "Next"
    }
}

struct GuideHeaderView: View {
    let guide: BrandGuide
    let catalog: GuideCatalog
    let onOpenGuide: (@MainActor (BrandGuide) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PhaseBadge(guide: guide)
                if guide.needsVerification { VerificationBadge() }
            }
            RichTextView(guide.summary)
            if guide.isStub, let facts = guide.facts {
                FactsView(facts: facts)
            }
            ForEach(guide.prerequisites.compactMap { catalog.guide(id: $0) }) { prerequisite in
                if let onOpenGuide {
                    Button {
                        onOpenGuide(prerequisite)
                    } label: {
                        Label("First time? \(prerequisite.title)", systemImage: "iphone")
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

struct CompletionView: View {
    let guide: BrandGuide

    var body: some View {
        if guide.isStub {
            Label(
                guide.listing == .brand
                    ? "Direct support for \(guide.title) arrives in phase \(guide.phase). Until then, see the other ways below."
                    : "See the options below.",
                systemImage: "clock"
            )
            .foregroundStyle(.secondary)
        } else {
            Label("All set.", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

struct VerifyFlagsView: View {
    let flags: [VerifyFlag]
    @Environment(\.showsVerificationBadges) private var showsBadges

    var body: some View {
        if showsBadges, !flags.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                VerificationBadge()
                ForEach(flags, id: \.self) { flag in
                    Text("\(flag.id): \(flag.note)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Sheet for a provider's `PairingInteraction` prompt.
struct PromptSheet: View {
    let request: PromptRequest
    let runner: GuideRunner

    @State private var input = ""
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.message)
                    if let status = runner.statusMessage {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { controls }
                if let importError {
                    Section { Text(importError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { runner.cancelPrompt() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch request.kind {
        case .confirm: "Action needed"
        case .text, .secureText: "Enter details"
        case .importFile: "Import"
        case .choose: "Choose"
        }
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var controls: some View {
        switch request.kind {
        case .confirm:
            Button("Continue") { runner.respond(.confirm(true)) }
                .bold()
            Button("Not now") { runner.respond(.confirm(false)) }

        case .text:
            TextField("Answer", text: $input)
                .modifier(InputTraits(type: .plain))
                .onSubmit { if !trimmed.isEmpty { runner.respond(.text(trimmed)) } }
            Button("OK") { runner.respond(.text(trimmed)) }
                .disabled(trimmed.isEmpty)

        case .secureText:
            SecureField("Answer", text: $input)
                .modifier(InputTraits(type: .password))
                .onSubmit { if !trimmed.isEmpty { runner.respond(.text(trimmed)) } }
            Button("OK") { runner.respond(.text(trimmed)) }
                .disabled(trimmed.isEmpty)

        case .importFile(_, let allowedTypes):
            Button("Choose file…") { isImporting = true }
                .fileImporter(isPresented: $isImporting, allowedContentTypes: contentTypes(allowedTypes)) { result in
                    switch readFile(result) {
                    case .success(let data): runner.respond(.file(data))
                    case .failure(let error): importError = error.localizedDescription
                    }
                }

        case .choose(_, let options):
            ForEach(options.indices, id: \.self) { index in
                Button(options[index]) { runner.respond(.choice(index)) }
            }
        }
    }
}
#endif
