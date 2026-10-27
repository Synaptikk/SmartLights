import Foundation
import LightCore

// Phase-3 brands: summary-only stubs (steps added by the phase-3 tasks), from
// docs/ONBOARDING-WALKTHROUGHS.md §10, §15-§18 and the wizard matrix. Phase-2 brands have full
// guides in GuideCatalog+Phase2.swift. Pointer guides cover §19-§21.
extension GuideCatalog {
    static func matterAlternative(_ detail: RichText) -> GuideAlternative {
        GuideAlternative(title: "Matter into Apple Home", detail: detail, targetGuideID: matterIntoAppleHomeID)
    }

    static func appleHomeAlternative(_ detail: RichText, recommended: Bool = false) -> GuideAlternative {
        GuideAlternative(title: "Apple Home", detail: detail, targetGuideID: Brand.appleHome.rawValue, isRecommended: recommended)
    }

    public static let stubs: [BrandGuide] = [
        BrandGuide(
            id: Brand.tuya.rawValue, brand: .tuya, title: "Tuya / Smart Life",
            summary: """
            White-label brands: Feit, Globe, Merkury/Geeni, Teckin, Gosund, Treatlife, Sylvania Wi-Fi, Cree. Recommended: if the bulb has a Matter logo, add it to Apple Home.
            Cloud path: enter the Smart Life **User Code** (Smart Life > Me > gear > Account and Security) and scan a QR we show. Local path (advanced): paste device id + local key + IP from an iot.tuya.com project. Only one local connection at a time (close Smart Life). Re-pairing rotates the key.
            """,
            phase: 3, section: "§10",
            alternatives: [GuideAlternative(title: "Matter into Apple Home", detail: "If the bulb has a Matter logo.", targetGuideID: matterIntoAppleHomeID, isRecommended: true)],
            facts: WizardFacts(vendorAppFirst: "yes (Smart Life)", asksFor: "user code + QR, or local key", settingToFlip: "—",
                               discovery: "UDP 6666/6667/7000", pairingAction: "QR or key", homeKit: "no", matter: "some"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.meross.rawValue, brand: .meross, title: "Meross",
            summary: "Set up in the Meross app. Enter Meross email + password once (to fetch the per-account device key), then local HTTP control. Meross rate-limits cloud logins.",
            phase: 3, section: "§15",
            alternatives: [appleHomeAlternative("\"HK\" SKUs are HomeKit-native and \"MA\" SKUs are Matter: prefer Apple Home.", recommended: true)],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "email+password once", settingToFlip: "—",
                               discovery: "IP / DHCP", pairingAction: "login", homeKit: "HK SKUs", matter: "MA SKUs"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.switchbot.rawValue, brand: .switchbot, title: "SwitchBot",
            summary: "SwitchBot app > Profile > Preferences > About > tap **App Version 10 times** > Developer Options > copy **Token** and **Secret**, then paste both (cloud API, 10k/day; BLE-only devices need a SwitchBot Hub).",
            phase: 3, section: "§16",
            alternatives: [matterAlternative("Hub 2/3 can also expose lights as Matter (beta).")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "token+secret", settingToFlip: "tap version 10×",
                               discovery: "cloud", pairingAction: "paste", homeKit: "no", matter: "hub")
        ),
        BrandGuide(
            id: Brand.twinkly.rawValue, brand: .twinkly, title: "Twinkly",
            summary: "Set up in the Twinkly app (upload effects there). Scan (UDP 5555). A new login invalidates older tokens, so close other Twinkly controllers.",
            phase: 3, section: "§17",
            alternatives: [appleHomeAlternative("Gen II is HomeKit-native (Twinkly app > device > HomeKit).")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "upload effects",
                               discovery: "UDP 5555", pairingAction: "none", homeKit: "Gen II", matter: "?"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.dirigera.rawValue, brand: .dirigera, title: "IKEA Dirigera",
            summary: """
            Recommended: IKEA Home smart app > hub settings > Integrations > Apple Home or Matter, then the Apple Home provider.
            Direct: Scan (`gw2-<id>.local`, HTTPS 8443) > **press the action button on the bottom of the hub** > Continue. Trådfri gateway (legacy): add to Apple Home via its HomeKit code.
            """,
            phase: 3, section: "§18",
            alternatives: [appleHomeAlternative("IKEA Home smart app > hub settings > Integrations > Apple Home or Matter.", recommended: true)],
            verifyFlags: [VerifyFlag(id: "dirigera-integrations", note: "Dirigera Integrations menu path.")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
                               discovery: "`gw2-*.local`", pairingAction: "press hub button", homeKit: "yes", matter: "yes"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.homeAssistant.rawValue, brand: .homeAssistant, title: "Home Assistant",
            summary: "Connect to your Home Assistant server with a long-lived access token; its `light.*` entities appear here. The route for Zigbee, Sengled, Cync, Wyze and automations.",
            phase: 3,
            prerequisites: [iPhoneSetupID]
        ),
    ]

    public static let pointers: [BrandGuide] = [
        BrandGuide(
            id: "lutron", brand: nil, title: "Lutron Caséta",
            summary: "Add the Smart Bridge to Apple Home (HomeKit code on the bridge; Lutron app > Settings > Apple HomeKit) and use the Apple Home provider. No Matter.",
            phase: 1, listing: .pointer, section: "§19",
            alternatives: [appleHomeAlternative("Use the Apple Home provider.", recommended: true)]
        ),
        BrandGuide(
            id: "homekit-matter-only", brand: nil, title: "Eve, Aqara, Sylvania Bluetooth, Nanoleaf Essentials",
            summary: "Other HomeKit/Matter-only lights: add to Apple Home per the vendor's instructions, then the Apple Home provider.",
            phase: 1, listing: .pointer, section: "§20",
            alternatives: [appleHomeAlternative("Use the Apple Home provider.", recommended: true)]
        ),
        BrandGuide(
            id: "cloud-only", brand: nil, title: "GE Cync, Sengled Wi-Fi, Wyze",
            summary: """
            Not controllable locally from a phone. Buy/use their **Matter** SKUs (Cync "Matter" line, Sengled Matter bulbs) and add them to Apple Home.
            Wyze has no Matter/HomeKit; only Home Assistant with an unofficial cloud integration.
            """,
            phase: 1, listing: .pointer, section: "§21",
            alternatives: [
                matterAlternative("Cync \"Matter\" line, Sengled Matter bulbs."),
                GuideAlternative(title: "Home Assistant", detail: "Wyze only, via an unofficial cloud integration.", targetGuideID: Brand.homeAssistant.rawValue),
            ]
        ),
    ]
}
