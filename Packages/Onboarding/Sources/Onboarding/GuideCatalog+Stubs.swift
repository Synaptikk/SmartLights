import Foundation
import LightCore

// Phase-2/3 brands: summary-only stubs (steps added by T2.10 / phase-3 tasks), from
// docs/ONBOARDING-WALKTHROUGHS.md §5-§18 and the wizard matrix. Pointer guides cover §19-§21.
extension GuideCatalog {
    private static func matterAlternative(_ detail: RichText) -> GuideAlternative {
        GuideAlternative(title: "Matter into Apple Home", detail: detail, targetGuideID: matterIntoAppleHomeID)
    }

    private static func appleHomeAlternative(_ detail: RichText, recommended: Bool = false) -> GuideAlternative {
        GuideAlternative(title: "Apple Home", detail: detail, targetGuideID: Brand.appleHome.rawValue, isRecommended: recommended)
    }

    public static let stubs: [BrandGuide] = [
        BrandGuide(
            id: Brand.lifx.rawValue, brand: .lifx, title: "LIFX",
            summary: """
            Bulbs set up in the LIFX app (2.4 GHz). No account or token needed for local control.
            Scan (mDNS `_lifx._udp` and/or UDP 56700 broadcast, else subnet probe; Add by IP available). Optional: paste a LIFX cloud token from cloud.lifx.com/settings for away-from-home control (120 requests/min).
            """,
            phase: 2, section: "§5",
            alternatives: [appleHomeAlternative("Most LIFX are native HomeKit; new ones are Matter (Thread beta 2026).")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "optional cloud token", settingToFlip: "—",
                               discovery: "`_lifx._udp` / UDP 56700 / sweep", pairingAction: "none", homeKit: "yes", matter: "new SKUs"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.govee.rawValue, brand: .govee, title: "Govee",
            summary: """
            Device set up in Govee Home (2.4 GHz). For local control the model must support the LAN API (strips, lamps, panels; most plain A19 bulbs do not) and **LAN Control** must be on: Govee Home > device > Settings (gear) > **LAN Control**.
            For non-LAN models: Govee Home > Settings > **Apply for API Key** (emailed) and paste it (Developer API, 10k requests/day).
            """,
            phase: 2, section: "§6",
            alternatives: [matterAlternative("2025-26 Govee bulbs/lamps are Matter.")],
            verifyFlags: [VerifyFlag(id: "govee-lan-control", note: "Govee \"LAN Control\" menu path and firmware prerequisite.")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "API key (cloud models)", settingToFlip: "LAN Control",
                               discovery: "multicast 4001", pairingAction: "paste key", homeKit: "no", matter: "new SKUs"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.nanoleaf.rawValue, brand: .nanoleaf, title: "Nanoleaf",
            summary: """
            Panels (Light Panels, Canvas, Shapes, Elements, Lines): Scan (mDNS `_nanoleafapi._tcp`), then **hold the power button on the controller for 5-7 seconds until the LEDs flash** and tap Continue within 30 seconds (Skylight: "Connect to API" in the Nanoleaf app instead).
            Essentials (bulbs, strips): no local API; use Apple Home.
            """,
            phase: 2, section: "§7",
            alternatives: [appleHomeAlternative("Essentials bulbs/strips: add to Apple Home (HomeKit over Thread/BLE, or Matter Essentials). Thread needs a HomePod/Apple TV.")],
            verifyFlags: [VerifyFlag(id: "nanoleaf-hold-time", note: "Nanoleaf hold time (5 s per HA vs 5-7 s per Nanoleaf).")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
                               discovery: "`_nanoleafapi._tcp`", pairingAction: "hold power 5-7 s", homeKit: "yes", matter: "some"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.tplink.rawValue, brand: .tplink, title: "TP-Link Tapo and Kasa",
            summary: """
            Set up in the Tapo or Kasa app. Newer devices require your **TP-Link account email + password** for local control (case-sensitive). Some firmware needs **Tapo app > Tapo Lab > Third-Party Compatibility** turned on (TP-Link warns it lowers security). Legacy Kasa bulbs (KL/LB) need no credentials.
            """,
            phase: 2, section: "§8",
            alternatives: [matterAlternative("Tapo L535E and other Matter SKUs.")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "TP-Link email+password", settingToFlip: "Third-Party Compatibility",
                               discovery: "UDP 9999/20002", pairingAction: "enter creds", homeKit: "rare", matter: "some"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.yeelight.rawValue, brand: .yeelight, title: "Yeelight",
            summary: """
            Yeelight app > Device > (more) > **LAN Control** on (older firmware: "Developer mode"); update firmware if the toggle is missing. Some newer models removed it.
            Scan (SSDP to 239.255.255.250:1982, mDNS `_miio._udp`) or Add by IP. No auth.
            """,
            phase: 2, section: "§9",
            alternatives: [appleHomeAlternative("Some models are HomeKit-native or Matter.")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "LAN Control",
                               discovery: "SSDP 1982 / `_miio._udp`", pairingAction: "none", homeKit: "some", matter: "some"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.elgato.rawValue, brand: .elgato, title: "Elgato Key Light / Air / Mini / Ring / Strip",
            summary: "Set up in Elgato Control Center. Scan (mDNS `_elg._tcp`, HTTP 9123). No auth.",
            phase: 2, section: "§11",
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
                               discovery: "`_elg._tcp`", pairingAction: "none", homeKit: "no", matter: "no"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.shelly.rawValue, brand: .shelly, title: "Shelly",
            summary: "Set up in Shelly Smart Control (cloud optional). Scan (mDNS `_shelly._tcp`). If a device password was set: username is `admin` (digest auth).",
            phase: 2, section: "§12",
            alternatives: [matterAlternative("Gen3/4 can also do Matter (enable in device web UI).")],
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "admin password if set", settingToFlip: "—",
                               discovery: "`_shelly._tcp`", pairingAction: "none", homeKit: "no", matter: "Gen3/4"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.wled.rawValue, brand: .wled, title: "WLED",
            summary: "Flash WLED ≥ 0.14; join Wi-Fi `WLED-AP` (password `wled1234`), open http://4.3.2.1 > WiFi Setup, enter home SSID/password, set mDNS name, Save & Connect. Then Scan (mDNS `_wled._tcp`). No auth.",
            phase: 2, section: "§13",
            facts: WizardFacts(vendorAppFirst: "captive portal", asksFor: "nothing", settingToFlip: "—",
                               discovery: "`_wled._tcp`", pairingAction: "none", homeKit: "no", matter: "no"),
            prerequisites: [iPhoneSetupID]
        ),
        BrandGuide(
            id: Brand.magicHome.rawValue, brand: .magicHome, title: "Magic Home / Zengge / LEDENET",
            summary: "Set up in Magic Home. Scan (UDP 48899, TCP 5577). No auth. Drops offline while changing colours usually mean a weak power supply.",
            phase: 2, section: "§14",
            facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
                               discovery: "UDP 48899", pairingAction: "none", homeKit: "no", matter: "no"),
            prerequisites: [iPhoneSetupID]
        ),
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
