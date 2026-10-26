#if canImport(SwiftUI)
import SwiftUI

/// Build configuration helpers for the onboarding UI.
public enum OnboardingBuild {
    /// True in debug builds (SwiftPM and Xcode define `DEBUG` for the Debug configuration).
    public static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
}

private struct ShowsVerificationBadgesKey: EnvironmentKey {
    static let defaultValue: Bool = OnboardingBuild.isDebug
}

extension EnvironmentValues {
    /// Show "Verify wording" badges on copy marked [verify]. Defaults to on in debug builds only.
    public var showsVerificationBadges: Bool {
        get { self[ShowsVerificationBadgesKey.self] }
        set { self[ShowsVerificationBadgesKey.self] = newValue }
    }
}

// MARK: - Rich text

/// Renders `RichText` (bold, code, links, bullets).
public struct RichTextView: View {
    let text: RichText

    public init(_ text: RichText) {
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let inlines):
                    Text(Self.attributed(inlines))
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let inlines):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(Self.attributed(inlines))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ inlines: [RichText.Inline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let s):
                result += AttributedString(s)
            case .bold(let s):
                var run = AttributedString(s)
                run.inlinePresentationIntent = .stronglyEmphasized
                result += run
            case .code(let s):
                var run = AttributedString(s)
                run.inlinePresentationIntent = .code
                result += run
            case .link(let label, let url):
                var run = AttributedString(label)
                run.link = URL(string: url)
                result += run
            }
        }
        return result
    }
}

// MARK: - Badges

/// Debug-only badge for copy that still needs confirming on a real device/app.
public struct VerificationBadge: View {
    @Environment(\.showsVerificationBadges) private var showsBadges
    let note: String?

    public init(note: String? = nil) {
        self.note = note
    }

    public var body: some View {
        if showsBadges {
            Label("Verify wording", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
                .help(note ?? "Copy marked [verify] in docs/ONBOARDING-WALKTHROUGHS.md")
                .accessibilityLabel("Wording not yet verified" + (note.map { ": \($0)" } ?? ""))
        }
    }
}

/// "Phase 1/2/3" badge; stubs read "Guide only".
public struct PhaseBadge: View {
    let guide: BrandGuide

    public init(guide: BrandGuide) {
        self.guide = guide
    }

    var text: String {
        switch guide.listing {
        case .pointer: "Info"
        case .setup: "Setup"
        case .brand: guide.isStub ? "Phase \(guide.phase) · guide only" : "Phase \(guide.phase)"
        }
    }

    var color: Color {
        switch guide.listing {
        case .pointer, .setup: .secondary
        case .brand: guide.phase == 1 ? .green : (guide.phase == 2 ? .blue : .purple)
        }
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityLabel(text)
    }
}

// MARK: - Problems and alternatives

/// Expanders for problems ("It didn't work?").
struct ProblemList: View {
    let problems: [Problem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(problems, id: \.self) { problem in
                DisclosureGroup {
                    RichTextView(problem.fix)
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text(problem.title).font(.subheadline.weight(.medium))
                        if problem.needsVerification { VerificationBadge() }
                    }
                }
            }
        }
    }
}

struct AlternativesView: View {
    let alternatives: [GuideAlternative]
    let catalog: GuideCatalog
    let onOpenGuide: (@MainActor (BrandGuide) -> Void)?

    var body: some View {
        DisclosureGroup("Other ways to add these lights") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(alternatives, id: \.self) { alt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(alt.title).font(.subheadline.weight(.semibold))
                            if alt.isRecommended {
                                Text("Recommended").font(.caption2).foregroundStyle(.green)
                            }
                            if alt.needsVerification { VerificationBadge() }
                        }
                        RichTextView(alt.detail).font(.subheadline)
                        if let id = alt.targetGuideID, let target = catalog.guide(id: id), let onOpenGuide {
                            Button("Open \u{201C}\(target.title)\u{201D}") { onOpenGuide(target) }
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

struct FactsView: View {
    let facts: WizardFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Vendor app first", facts.vendorAppFirst)
            row("We ask for", facts.asksFor)
            row("Setting to flip", facts.settingToFlip)
            row("Pairing", facts.pairingAction)
            row("Apple Home", facts.homeKit)
            row("Matter", facts.matter)
        }
        .font(.footnote)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(RichTextView.attributed(RichText(value).blocks.first.map(Self.inlines) ?? [])) }
    }

    private static func inlines(_ block: RichText.Block) -> [RichText.Inline] {
        switch block {
        case .paragraph(let i), .bullet(let i): i
        }
    }
}
#endif
