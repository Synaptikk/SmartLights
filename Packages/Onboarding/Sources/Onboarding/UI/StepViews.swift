#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Renders one step of any kind. Only the runner's current step is shown.
public struct StepView: View {
    let step: GuideStep
    let runner: GuideRunner

    public init(step: GuideStep, runner: GuideRunner) {
        self.step = step
        self.runner = runner
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title).font(.title2.weight(.bold))
                if step.isOptional {
                    Text("Optional").font(.caption).foregroundStyle(.secondary)
                }
                if step.needsVerification { VerificationBadge(note: step.verifyNote) }
            }
            if let detail = step.detail {
                RichTextView(detail).font(.callout).foregroundStyle(.secondary)
            }
            switch step.kind {
            case .info(let text):
                RichTextView(text)
            case .checklist(let items):
                ChecklistStepView(step: step, items: items, runner: runner)
            case .action(let kind, let prompt):
                ActionStepView(step: step, kind: kind, prompt: prompt, runner: runner)
            case .troubleshoot(let problems):
                ProblemList(problems: problems)
            }
            if !step.problems.isEmpty {
                DisclosureGroup("It didn't work?") {
                    ProblemList(problems: step.problems).padding(.top, 6)
                }
            }
        }
    }
}

struct ChecklistStepView: View {
    let step: GuideStep
    let items: [ChecklistItem]
    let runner: GuideRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items.indices, id: \.self) { index in
                let isOn = runner.isChecked(index, in: step.id)
                Button {
                    runner.toggle(item: index)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                        RichTextView(items[index].text)
                        if items[index].needsVerification { VerificationBadge() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

struct ActionStepView: View {
    let step: GuideStep
    let kind: ActionKind
    let prompt: RichText
    let runner: GuideRunner

    @State private var input = ""
    @State private var isImporting = false
    @State private var importError: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RichTextView(prompt)
            control
            StepStatusView(step: step, runner: runner)
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        }
    }

    @ViewBuilder private var control: some View {
        if step.isProviderDriven {
            // The provider does the work; its PairingInteraction prompts appear in a sheet.
            Button {
                runner.perform()
            } label: {
                Label(Self.buttonTitle(for: kind), systemImage: Self.icon(for: kind))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(runner.isBusy)
        } else {
            localControl
        }
    }

    @ViewBuilder private var localControl: some View {
        switch kind {
        case .scan, .verifyBlink, .confirm:
            Button {
                runner.perform()
            } label: {
                Label(Self.buttonTitle(for: kind), systemImage: Self.icon(for: kind)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .text(let field):
            VStack(alignment: .leading, spacing: 8) {
                TextField(field.label, text: $input, prompt: field.placeholder.map { Text($0) })
                    .textFieldStyle(.roundedBorder)
                    .modifier(InputTraits(type: field.contentType))
                    .onSubmit(submitText)
                Button("Save", action: submitText)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedInput.isEmpty)
            }

        case .secureText(let field):
            VStack(alignment: .leading, spacing: 8) {
                SecureField(field.label, text: $input, prompt: field.placeholder.map { Text($0) })
                    .textFieldStyle(.roundedBorder)
                    .modifier(InputTraits(type: field.contentType))
                    .onSubmit(submitSecret)
                Button("Save", action: submitSecret)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedInput.isEmpty)
            }

        case .importFile(let types):
            Button {
                isImporting = true
            } label: {
                Label("Choose file…", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: contentTypes(types)) { result in
                switch readFile(result) {
                case .success(let data): importError = nil; runner.submit(.file(data))
                case .failure(let error): importError = error.localizedDescription
                }
            }

        case .choose(let options):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let selected = runner.answer(for: step.id) == .choice(index)
                    Button {
                        runner.submit(.choice(index))
                    } label: {
                        HStack {
                            Text(options[index])
                            Spacer()
                            if selected { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

        case .openApp(let name, let deepLink):
            if let deepLink, let url = URL(string: deepLink) {
                Button {
                    openURL(url)
                    runner.perform()
                } label: {
                    Label("Open \(name)", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Done in \(name)") { runner.perform() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submitText() {
        guard !trimmedInput.isEmpty else { return }
        runner.submit(.text(trimmedInput))
    }

    private func submitSecret() {
        guard !trimmedInput.isEmpty else { return }
        runner.submit(.secret(trimmedInput))
        input = ""
    }

    static func buttonTitle(for kind: ActionKind) -> String {
        switch kind {
        case .scan: "Scan"
        case .confirm(let button): button
        case .verifyBlink: "Blink a light"
        case .importFile: "Import"
        case .text, .secureText: "Enter"
        case .choose: "Choose"
        case .openApp(let name, _): "Open \(name)"
        }
    }

    static func icon(for kind: ActionKind) -> String {
        switch kind {
        case .scan: "magnifyingglass"
        case .confirm: "hand.tap"
        case .verifyBlink: "lightbulb.max"
        case .importFile: "doc.badge.plus"
        case .text, .secureText: "keyboard"
        case .choose: "list.bullet"
        case .openApp: "arrow.up.forward.app"
        }
    }
}

/// Running / failed / done line under an action step.
struct StepStatusView: View {
    let step: GuideStep
    let runner: GuideRunner

    var body: some View {
        switch runner.activity {
        case .running(let id) where id == step.id:
            HStack(spacing: 10) {
                ProgressView()
                Text(runner.statusMessage ?? "Working…").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { runner.cancelAction() }
            }
        case .failed(let id, let message) where id == step.id:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        default:
            if let answer = runner.answer(for: step.id) {
                Label(Self.summary(answer), systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    static func summary(_ answer: StepAnswer) -> String {
        switch answer {
        case .done, .confirmed(true): "Done"
        case .confirmed(false): "Skipped"
        case .text(let s): s
        case .secret: "Saved"
        case .file(let d): "Imported (\(d.count) bytes)"
        case .choice: "Selected"
        case .discovered(let devices): devices.count == 1 ? "Found 1 device" : "Found \(devices.count) devices"
        case .paired(let device): "Added \(device.name)"
        }
    }
}

// MARK: - Helpers shared with the prompt sheet

func contentTypes(_ identifiers: [String]) -> [UTType] {
    let types = identifiers.compactMap { UTType($0) ?? UTType(filenameExtension: $0) }
    return types.isEmpty ? [.data] : types
}

func readFile(_ result: Result<URL, any Error>) -> Result<Data, any Error> {
    result.flatMap { url in
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Result { try Data(contentsOf: url) }
    }
}

struct InputTraits: ViewModifier {
    let type: InputField.ContentType

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .textContentType(textContentType)
        #else
        content.autocorrectionDisabled()
        #endif
    }

    #if os(iOS)
    private var keyboard: UIKeyboardType {
        switch type {
        case .email: .emailAddress
        case .ipAddress: .numbersAndPunctuation
        case .url: .URL
        case .plain, .username, .password, .countryCode, .hexKey, .token: .asciiCapable
        }
    }

    private var textContentType: UITextContentType? {
        switch type {
        case .email: .emailAddress
        case .username: .username
        case .password: .password
        case .url: .URL
        case .plain, .ipAddress, .countryCode, .hexKey, .token: nil
        }
    }
    #endif
}
#endif
