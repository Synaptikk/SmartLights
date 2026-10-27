import Foundation
import LightCore

// MARK: - BrandGuide

/// One wizard definition (PLAN.md D8). Content comes from `docs/ONBOARDING-WALKTHROUGHS.md`.
/// Codable so guides can later be shipped/updated as JSON.
public struct BrandGuide: Codable, Sendable, Hashable, Identifiable {
    /// How the guide appears in the "Add brand" list.
    public enum Listing: String, Codable, Sendable, Hashable, CaseIterable {
        /// Adds a brand (variants such as Hue Bluetooth share the brand).
        case brand
        /// Generic setup shown before/alongside brand guides (iPhone setup §0, Matter into Apple Home §0.1).
        case setup
        /// No provider of its own: explains which route to use instead (Lutron via Apple Home, Wyze, ...).
        case pointer
    }

    /// Stable id. The primary guide of a brand uses `brand.rawValue` (`"hue"`, `"applehome"`).
    public var id: String
    /// nil for generic and pointer guides.
    public var brand: Brand?
    public var title: String
    public var summary: RichText
    /// Release phase (PLAN.md §6): 1 = MVP brands, 2 = common brands, 3 = hard/niche.
    public var phase: Int
    public var listing: Listing
    /// Section in `docs/ONBOARDING-WALKTHROUGHS.md` ("§1", "§0.1").
    public var section: String?
    /// Empty for stub guides (summary-only, provider not built yet).
    public var steps: [GuideStep]
    public var alternatives: [GuideAlternative]
    /// Open questions about this guide's copy (doc "Items to verify"), surfaced in debug builds.
    public var verifyFlags: [VerifyFlag]
    /// Row of the doc's wizard matrix.
    public var facts: WizardFacts?
    /// Guides that should be completed first (e.g. `"iphone-setup"` before the first LAN brand).
    public var prerequisites: [String]

    public init(
        id: String,
        brand: Brand?,
        title: String,
        summary: RichText,
        phase: Int,
        listing: Listing = .brand,
        section: String? = nil,
        steps: [GuideStep] = [],
        alternatives: [GuideAlternative] = [],
        verifyFlags: [VerifyFlag] = [],
        facts: WizardFacts? = nil,
        prerequisites: [String] = []
    ) {
        self.id = id
        self.brand = brand
        self.title = title
        self.summary = summary
        self.phase = phase
        self.listing = listing
        self.section = section
        self.steps = steps
        self.alternatives = alternatives
        self.verifyFlags = verifyFlags
        self.facts = facts
        self.prerequisites = prerequisites
    }

    /// Summary-only guide: the brand is listed but its walkthrough/provider is not built yet.
    public var isStub: Bool { steps.isEmpty }

    /// True if any copy in this guide still has to be confirmed on a real device/app.
    public var needsVerification: Bool {
        !verifyFlags.isEmpty
            || steps.contains(where: \.containsUnverifiedCopy)
            || alternatives.contains(where: \.needsVerification)
    }

    public func step(id: String) -> GuideStep? { steps.first { $0.id == id } }
}

// MARK: - GuideStep

public struct GuideStep: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Explanation only.
        case info(RichText)
        /// Things the user ticks off ("Before you start").
        case checklist([ChecklistItem])
        /// Something to do; provider-driven steps call back into the app via `GuideStep.callback`.
        case action(ActionKind, prompt: RichText)
        /// List of problems with fixes, rendered as expanders.
        case troubleshoot([Problem])
    }

    /// Unique within its guide.
    public var id: String
    public var title: String
    public var kind: Kind
    /// Optional extra explanation shown under the title.
    public var detail: RichText?
    /// The step's own copy is tagged [verify] in the walkthrough doc.
    public var needsVerification: Bool
    /// What exactly needs confirming ("exact wording and availability in your app version").
    public var verifyNote: String?
    /// Provider callback the app runs for this step (see `GuideCallback`), e.g. `"pair"`.
    public var callback: String?
    /// The user may continue without completing this step.
    public var isOptional: Bool
    /// Per-step "It didn't work?" expander.
    public var problems: [Problem]

    public init(
        id: String,
        title: String,
        kind: Kind,
        detail: RichText? = nil,
        needsVerification: Bool = false,
        verifyNote: String? = nil,
        callback: String? = nil,
        isOptional: Bool = false,
        problems: [Problem] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.detail = detail
        self.needsVerification = needsVerification
        self.verifyNote = verifyNote
        self.callback = callback
        self.isOptional = isOptional
        self.problems = problems
    }

    /// The step itself, one of its checklist items or one of its problems needs verification.
    public var containsUnverifiedCopy: Bool {
        if needsVerification { return true }
        if problems.contains(where: \.needsVerification) { return true }
        switch kind {
        case .checklist(let items): return items.contains(where: \.needsVerification)
        case .troubleshoot(let problems): return problems.contains(where: \.needsVerification)
        case .info, .action: return false
        }
    }

    public var actionKind: ActionKind? {
        if case .action(let kind, _) = kind { kind } else { nil }
    }

    /// Whether `GuideRunner.perform()` routes this step through the app's action handler.
    public var isProviderDriven: Bool {
        guard let actionKind else { return false }
        return callback != nil || actionKind.isProviderDriven
    }
}

/// Well-known callback ids used in `GuideCatalog`. The app's `GuideRunner.actionHandler`
/// maps them to provider calls for `guide.brand` (T1.7). Custom ids are allowed.
public enum GuideCallback {
    /// Run `LightProvider.discover`; answer `.discovered`.
    public static let discover = "discover"
    /// Run `LightProvider.pair` with the runner as `PairingInteraction`; answer `.paired`.
    public static let pair = "pair"
    /// Cloud login (AiDot, Meross, SwitchBot); the provider prompts for its credentials.
    public static let login = "login"
    /// Signing key / token import (WiZ key, Govee API key, LIFX cloud token); the provider prompts.
    public static let importKey = "importKey"
    /// Blink a paired light so the user can confirm it works.
    public static let verify = "verify"
    /// Probe discovery so iOS shows the Local Network prompt (after the wizard explained it).
    public static let localNetworkPermission = "permission.localNetwork"
    public static let homeKitPermission = "permission.homeKit"
    public static let bluetoothPermission = "permission.bluetooth"
}

// MARK: - Action kinds

public enum ActionKind: Sendable, Hashable {
    /// Discover devices (provider callback).
    case scan
    /// The user does something physical, then taps `button` ("Press the link button, then Continue").
    case confirm(button: String)
    /// Plain text entry collected by the wizard itself.
    case text(InputField)
    /// Secure entry collected by the wizard itself. Never log the answer.
    case secureText(InputField)
    /// File import (UTType identifiers or extensions, e.g. `["public.json", "json"]`).
    case importFile(allowedTypes: [String])
    /// Pick one option.
    case choose(options: [String])
    /// Open another app (vendor app, Apple Home, Settings). `deepLink` nil = show instructions only.
    case openApp(name: String, deepLink: String?)
    /// Blink a light so the user can confirm it works.
    case verifyBlink

    /// Kinds that always need the app/provider to do work.
    public var isProviderDriven: Bool {
        switch self {
        case .scan, .verifyBlink: true
        case .confirm, .text, .secureText, .importFile, .choose, .openApp: false
        }
    }
}

public struct InputField: Codable, Sendable, Hashable {
    public enum ContentType: String, Codable, Sendable, Hashable {
        case plain, email, username, password, ipAddress, url, countryCode, hexKey, token
    }

    /// Key under which the answer is collected.
    public var key: String
    public var label: String
    public var placeholder: String?
    public var contentType: ContentType

    public init(key: String, label: String, placeholder: String? = nil, contentType: ContentType = .plain) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.contentType = contentType
    }
}

// MARK: - Small value types

public struct ChecklistItem: Codable, Sendable, Hashable {
    public var text: RichText
    public var needsVerification: Bool

    public init(_ text: RichText, needsVerification: Bool = false) {
        self.text = text
        self.needsVerification = needsVerification
    }
}

public struct Problem: Codable, Sendable, Hashable {
    public var title: String
    public var fix: RichText
    public var needsVerification: Bool

    public init(_ title: String, fix: RichText, needsVerification: Bool = false) {
        self.title = title
        self.fix = fix
        self.needsVerification = needsVerification
    }
}

/// Another route to the same lights (usually Matter into Apple Home, then the Apple Home provider).
public struct GuideAlternative: Codable, Sendable, Hashable {
    public var title: String
    public var detail: RichText
    /// Guide to open for this route (`"matter-apple-home"`, `"applehome"`), if any.
    public var targetGuideID: String?
    public var isRecommended: Bool
    public var needsVerification: Bool

    public init(
        title: String,
        detail: RichText,
        targetGuideID: String? = nil,
        isRecommended: Bool = false,
        needsVerification: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.targetGuideID = targetGuideID
        self.isRecommended = isRecommended
        self.needsVerification = needsVerification
    }
}

/// An open question about a guide (doc section "Items to verify on real hardware").
public struct VerifyFlag: Codable, Sendable, Hashable {
    public var id: String
    public var note: String

    public init(id: String, note: String) {
        self.id = id
        self.note = note
    }
}

/// One row of the doc's wizard matrix.
public struct WizardFacts: Codable, Sendable, Hashable {
    public var vendorAppFirst: String
    public var asksFor: String
    public var settingToFlip: String
    public var discovery: String
    public var pairingAction: String
    public var homeKit: String
    public var matter: String

    public init(
        vendorAppFirst: String,
        asksFor: String,
        settingToFlip: String,
        discovery: String,
        pairingAction: String,
        homeKit: String,
        matter: String
    ) {
        self.vendorAppFirst = vendorAppFirst
        self.asksFor = asksFor
        self.settingToFlip = settingToFlip
        self.discovery = discovery
        self.pairingAction = pairingAction
        self.homeKit = homeKit
        self.matter = matter
    }
}

// MARK: - Codable for enums (flat "type" discriminator, readable JSON)

extension GuideStep.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, items, action, prompt, problems }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "info":
            self = .info(try c.decode(RichText.self, forKey: .text))
        case "checklist":
            self = .checklist(try c.decode([ChecklistItem].self, forKey: .items))
        case "action":
            self = .action(
                try c.decode(ActionKind.self, forKey: .action),
                prompt: try c.decode(RichText.self, forKey: .prompt)
            )
        case "troubleshoot":
            self = .troubleshoot(try c.decode([Problem].self, forKey: .problems))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown step type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .info(let text):
            try c.encode("info", forKey: .type)
            try c.encode(text, forKey: .text)
        case .checklist(let items):
            try c.encode("checklist", forKey: .type)
            try c.encode(items, forKey: .items)
        case .action(let kind, let prompt):
            try c.encode("action", forKey: .type)
            try c.encode(kind, forKey: .action)
            try c.encode(prompt, forKey: .prompt)
        case .troubleshoot(let problems):
            try c.encode("troubleshoot", forKey: .type)
            try c.encode(problems, forKey: .problems)
        }
    }
}

extension ActionKind: Codable {
    private enum CodingKeys: String, CodingKey { case type, button, field, allowedTypes, options, name, deepLink }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "scan":
            self = .scan
        case "confirm":
            self = .confirm(button: try c.decodeIfPresent(String.self, forKey: .button) ?? "Continue")
        case "text":
            self = .text(try c.decode(InputField.self, forKey: .field))
        case "secureText":
            self = .secureText(try c.decode(InputField.self, forKey: .field))
        case "importFile":
            self = .importFile(allowedTypes: try c.decode([String].self, forKey: .allowedTypes))
        case "choose":
            self = .choose(options: try c.decode([String].self, forKey: .options))
        case "openApp":
            self = .openApp(
                name: try c.decode(String.self, forKey: .name),
                deepLink: try c.decodeIfPresent(String.self, forKey: .deepLink)
            )
        case "verifyBlink":
            self = .verifyBlink
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown action type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scan:
            try c.encode("scan", forKey: .type)
        case .confirm(let button):
            try c.encode("confirm", forKey: .type)
            try c.encode(button, forKey: .button)
        case .text(let field):
            try c.encode("text", forKey: .type)
            try c.encode(field, forKey: .field)
        case .secureText(let field):
            try c.encode("secureText", forKey: .type)
            try c.encode(field, forKey: .field)
        case .importFile(let types):
            try c.encode("importFile", forKey: .type)
            try c.encode(types, forKey: .allowedTypes)
        case .choose(let options):
            try c.encode("choose", forKey: .type)
            try c.encode(options, forKey: .options)
        case .openApp(let name, let deepLink):
            try c.encode("openApp", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(deepLink, forKey: .deepLink)
        case .verifyBlink:
            try c.encode("verifyBlink", forKey: .type)
        }
    }
}

// MARK: - JSON helpers

extension BrandGuide {
    /// Stable, pretty JSON (sorted keys) for shipping/diffing guides.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(fromJSON data: Data) throws -> BrandGuide {
        try JSONDecoder().decode(BrandGuide.self, from: data)
    }
}
