import Foundation
import LightCore

/// All guides the "Add brand" wizard knows. Content: `docs/ONBOARDING-WALKTHROUGHS.md`.
///
/// Conventions:
/// - the primary guide of a brand has `id == brand.rawValue`; variants (Hue Bluetooth) use other ids;
/// - generic guides (`listing == .setup`) have `brand == nil`;
/// - copy tagged [verify] in the doc has `needsVerification == true` (debug badge in the UI).
public struct GuideCatalog: Sendable, Hashable {
    public var guides: [BrandGuide]

    public init(guides: [BrandGuide]) {
        self.guides = guides
    }

    /// The built-in catalog.
    public static let standard = GuideCatalog(guides: [
        iPhoneSetup,
        matterIntoAppleHome,
        hue,
        hueBluetooth,
        wiz,
        aidot,
        appleHome,
    ] + phase2 + stubs + pointers)

    public func guide(id: String) -> BrandGuide? {
        guides.first { $0.id == id }
    }

    /// Primary guide for a brand (`id == brand.rawValue`).
    public func guide(for brand: Brand) -> BrandGuide? {
        guide(id: brand.rawValue)
    }

    /// All guides for a brand (primary first, then variants).
    public func guides(for brand: Brand) -> [BrandGuide] {
        func rank(_ g: BrandGuide) -> Int { g.id == brand.rawValue ? 0 : 1 }
        return guides.filter { $0.brand == brand }.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }

    /// Generic setup guides (§0, §0.1).
    public var setupGuides: [BrandGuide] { guides.filter { $0.listing == .setup } }

    /// Rows for the "Add brand" list: brand and pointer guides, by phase, then title.
    public var addBrandList: [BrandGuide] {
        guides
            .filter { $0.listing != .setup }
            .sorted { ($0.phase, $0.title.lowercased()) < ($1.phase, $1.title.lowercased()) }
    }

    /// `addBrandList` grouped by phase, ascending.
    public var addBrandListByPhase: [PhaseGroup] {
        let grouped = Dictionary(grouping: addBrandList, by: \.phase)
        return grouped.keys.sorted().map { PhaseGroup(phase: $0, guides: grouped[$0] ?? []) }
    }

    /// Guides of one release phase (for sectioned lists).
    public struct PhaseGroup: Sendable, Hashable, Identifiable {
        public var phase: Int
        public var guides: [BrandGuide]
        public var id: Int { phase }
    }

    /// Brands with no primary guide (should be empty; checked by tests).
    public var brandsWithoutGuide: [Brand] {
        Brand.allCases.filter { guide(for: $0) == nil }
    }

    /// Every guide whose copy still needs confirming on a real device.
    public var guidesNeedingVerification: [BrandGuide] { guides.filter(\.needsVerification) }
}

// MARK: - §0 One-time iPhone setup

extension GuideCatalog {
    public static let iPhoneSetupID = "iphone-setup"
    public static let matterIntoAppleHomeID = "matter-apple-home"

    /// §0: shown before the first LAN brand.
    public static let iPhoneSetup = BrandGuide(
        id: iPhoneSetupID,
        brand: nil,
        title: "Set up your iPhone",
        summary: "One-time iPhone setup, shown before the first brand that talks to lights on your Wi-Fi.",
        phase: 1,
        listing: .setup,
        section: "§0",
        steps: [
            GuideStep(
                id: "local-network",
                title: "Local Network permission",
                kind: .action(
                    .confirm(button: "Continue"),
                    prompt: """
                    The first time the app scans, iOS asks "SmartLights would like to find and connect to devices on your local network." Tap **Allow**.
                    """
                ),
                detail: "A denial silently breaks all discovery, so we explain the prompt before triggering it.",
                callback: GuideCallback.localNetworkPermission,
                problems: [
                    Problem(
                        "I tapped Don't Allow",
                        fix: "Settings > Privacy & Security > Local Network > turn **SmartLights** on."
                    ),
                ]
            ),
            GuideStep(
                id: "same-wifi",
                title: "Same Wi-Fi",
                kind: .checklist([
                    ChecklistItem("iPhone is on the home Wi-Fi (not cellular)."),
                    ChecklistItem("Not a Guest network."),
                    ChecklistItem("No VPN running."),
                ]),
                detail: "Most bulbs are 2.4 GHz-only; the phone can be on 5 GHz as long as it is the same network/subnet."
            ),
            GuideStep(
                id: "bluetooth",
                title: "Bluetooth permission",
                kind: .info("Only needed for Hue Bluetooth bulbs, SwitchBot BLE and Matter commissioning. The app asks when one of those needs it."),
                isOptional: true
            ),
            GuideStep(
                id: "homekit",
                title: "HomeKit permission",
                kind: .info("Only needed when you add the **Apple Home** provider."),
                isOptional: true
            ),
            GuideStep(
                id: "home-hub",
                title: "Home hub",
                kind: .info("""
                A home hub (HomePod / Apple TV) is only needed for Matter-over-Thread devices and for remote access/automations via Apple Home. iOS 18+ can add Wi-Fi Matter accessories without a hub.
                """),
                isOptional: true
            ),
        ]
    )

    /// §0.1: adding any Matter light to Apple Home (reused by many brands as the alternative path).
    public static let matterIntoAppleHome = BrandGuide(
        id: matterIntoAppleHomeID,
        brand: nil,
        title: "Add a Matter light to Apple Home",
        summary: "Generic route for any light with a Matter logo: add it in Apple's Home app, then control it here through the Apple Home provider.",
        phase: 1,
        listing: .setup,
        section: "§0.1",
        steps: [
            GuideStep(
                id: "open-home",
                title: "Open the Home app",
                kind: .action(
                    .openApp(name: "Home", deepLink: "com.apple.home://"),
                    prompt: "Open the Apple **Home** app > **+** > **Add Accessory**."
                ),
                isOptional: true
            ),
            GuideStep(
                id: "scan-code",
                title: "Scan the Matter code",
                kind: .info("""
                Scan the Matter QR code on the bulb/box.
                If the bulb is already paired to the vendor app, tap **More options** and pick it, or generate a pairing code in the vendor app (multi-admin).
                """),
                needsVerification: true,
                verifyNote: "Apple Home \"Turn On Pairing Mode\" wording for Matter multi-admin sharing."
            ),
            GuideStep(
                id: "commissioning",
                title: "While it pairs",
                kind: .checklist([
                    ChecklistItem("Bluetooth is on."),
                    ChecklistItem("You are near the device."),
                    ChecklistItem("Use the 2.4 GHz network during commissioning."),
                    ChecklistItem("Photograph the QR code; it is needed after a factory reset."),
                ])
            ),
            GuideStep(
                id: "back-in-app",
                title: "Back in SmartLights",
                kind: .info("""
                **Add brand > Apple Home** and grant HomeKit access. All Apple Home lights appear.
                Note: a native HomeKit (non-Matter) accessory can be paired to only one controller; Matter devices can be in several apps at once.
                """)
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Continue with Apple Home",
                detail: "Grant HomeKit access so every Apple Home light shows up here.",
                targetGuideID: Brand.appleHome.rawValue,
                isRecommended: true
            ),
        ],
        verifyFlags: [
            VerifyFlag(id: "apple-home-pairing-mode", note: "Apple Home \"Turn On Pairing Mode\" wording for Matter multi-admin sharing."),
            VerifyFlag(id: "home-deeplink", note: "Deep link com.apple.home:// opens the Home app (undocumented scheme)."),
        ]
    )
}
