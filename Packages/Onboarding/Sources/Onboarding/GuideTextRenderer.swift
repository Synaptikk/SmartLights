import Foundation

/// Deterministic plain-text rendering of a guide. Used for Linux snapshot tests (the SwiftUI views
/// render the same structure) and for copy review / diagnostics export.
public enum GuideTextRenderer {
    /// - Parameter showVerification: include `[verify]` markers (debug builds show the same as a badge).
    public static func render(_ guide: BrandGuide, showVerification: Bool = true) -> String {
        var out: [String] = []
        var header = "# \(guide.title)"
        if let section = guide.section { header += " (\(section))" }
        header += " [phase \(guide.phase)]"
        if guide.isStub { header += " [guide only]" }
        if showVerification, guide.needsVerification { header += " [verify]" }
        out.append(header)
        out.append(contentsOf: indent(render(guide.summary), by: 0))

        if let facts = guide.facts {
            out.append("")
            out.append("Asks for: \(facts.asksFor) | Setting: \(facts.settingToFlip) | Pairing: \(facts.pairingAction)")
        }

        for (index, step) in guide.steps.enumerated() {
            out.append("")
            var title = "\(index + 1). \(step.title)"
            if step.isOptional { title += " (optional)" }
            if showVerification, step.needsVerification { title += " [verify]" }
            out.append(title)
            if let detail = step.detail { out.append(contentsOf: indent(render(detail), by: 3)) }
            out.append(contentsOf: indent(render(step.kind, showVerification: showVerification), by: 3))
            if !step.problems.isEmpty {
                out.append("   It didn't work?")
                for problem in step.problems {
                    out.append(contentsOf: indent(render(problem, showVerification: showVerification), by: 5))
                }
            }
            if showVerification, let note = step.verifyNote { out.append("   (verify: \(note))") }
        }

        if !guide.alternatives.isEmpty {
            out.append("")
            out.append("Alternatives:")
            for alt in guide.alternatives {
                var line = "- \(alt.title)"
                if alt.isRecommended { line += " (recommended)" }
                if let target = alt.targetGuideID { line += " -> \(target)" }
                if showVerification, alt.needsVerification { line += " [verify]" }
                out.append(line)
                out.append(contentsOf: indent(render(alt.detail), by: 2))
            }
        }

        if showVerification, !guide.verifyFlags.isEmpty {
            out.append("")
            out.append("To verify:")
            for flag in guide.verifyFlags { out.append("- \(flag.id): \(flag.note)") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func render(_ text: RichText) -> [String] {
        text.blocks.map { block in
            switch block {
            case .paragraph(let inlines): inline(inlines)
            case .bullet(let inlines): "• " + inline(inlines)
            }
        }
    }

    static func inline(_ inlines: [RichText.Inline]) -> String {
        inlines.map { run in
            switch run {
            case .text(let s): s
            case .bold(let s): "*\(s)*"
            case .code(let s): "`\(s)`"
            case .link(let label, let url): "\(label) <\(url)>"
            }
        }.joined()
    }

    static func render(_ kind: GuideStep.Kind, showVerification: Bool) -> [String] {
        switch kind {
        case .info(let text):
            return render(text)
        case .checklist(let items):
            return items.flatMap { item -> [String] in
                var lines = render(item.text)
                if !lines.isEmpty {
                    lines[0] = "[ ] " + lines[0] + (showVerification && item.needsVerification ? " [verify]" : "")
                }
                return lines
            }
        case .action(let action, let prompt):
            return render(prompt) + ["> " + describe(action)]
        case .troubleshoot(let problems):
            return problems.flatMap { render($0, showVerification: showVerification) }
        }
    }

    static func render(_ problem: Problem, showVerification: Bool) -> [String] {
        let title = "? " + problem.title + (showVerification && problem.needsVerification ? " [verify]" : "")
        return [title] + indent(render(problem.fix), by: 2)
    }

    static func describe(_ action: ActionKind) -> String {
        switch action {
        case .scan: "[Scan]"
        case .confirm(let button): "[\(button)]"
        case .text(let field): "[text: \(field.label)]"
        case .secureText(let field): "[secure: \(field.label)]"
        case .importFile(let types): "[Import file: \(types.joined(separator: ", "))]"
        case .choose(let options): "[Choose: \(options.joined(separator: " | "))]"
        case .openApp(let name, let link): "[Open \(name)\(link.map { " <\($0)>" } ?? "")]"
        case .verifyBlink: "[Blink]"
        }
    }

    static func indent(_ lines: [String], by n: Int) -> [String] {
        let pad = String(repeating: " ", count: n)
        return lines.map { pad + $0 }
    }
}
