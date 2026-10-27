import Foundation
import LightCore

// Phase-3 guides: docs/ONBOARDING-WALKTHROUGHS.md §10 (Tuya), §15 (Meross), §16 (SwitchBot),
// §17 (Twinkly), §18 (IKEA Dirigera) and the Home Assistant guide from
// Packages/Providers/HomeAssistantKit/README.md. Pointer guides cover §19-§21.
//
// Callbacks: LAN brands scan (`discover`) and pair (`pair`); the cloud-account brands (Meross,
// SwitchBot) sign in through `login`. Tuya and Home Assistant can be added without a scan: their
// pair step asks for everything (device id + local key + IP, or URL + token).
extension GuideCatalog {
    static func matterAlternative(_ detail: RichText) -> GuideAlternative {
        GuideAlternative(title: "Matter into Apple Home", detail: detail, targetGuideID: matterIntoAppleHomeID)
    }

    static func appleHomeAlternative(_ detail: RichText, recommended: Bool = false) -> GuideAlternative {
        GuideAlternative(title: "Apple Home", detail: detail, targetGuideID: Brand.appleHome.rawValue, isRecommended: recommended)
    }

    /// Every phase-3 brand guide, in doc order.
    public static let phase3: [BrandGuide] = [tuya, meross, switchbot, twinkly, dirigera, homeAssistant]

    // MARK: §10 Tuya / Smart Life

    static let tuyaOneConnection = Problem(
        "\"Could not connect\" or the light drops offline",
        fix: "A Tuya light accepts **one local connection at a time**. Close Smart Life (and Home Assistant's local Tuya integrations) and try again."
    )
    static let tuyaKeyChanged = Problem(
        "Worked before, now \"wrong key\"",
        fix: "Re-pairing the light in Smart Life changes its local key. Read the new key from the developer project and add the light again."
    )

    public static let tuya = BrandGuide(
        id: Brand.tuya.rawValue,
        brand: .tuya,
        title: "Tuya / Smart Life",
        summary: """
        White-label brands: Feit, Globe, Merkury/Geeni, Teckin, Gosund, Treatlife, Sylvania Wi-Fi, Cree. Recommended: if the bulb has a Matter logo, add it to Apple Home.
        Otherwise (advanced): control it on your Wi-Fi with its **device ID** and **local key** from a free iot.tuya.com project.
        """,
        phase: 3,
        section: "§10",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Light set up in **Smart Life** or **Tuya Smart** (2.4 GHz, same Wi-Fi as this iPhone)."),
                    ChecklistItem("If the box shows a **Matter** logo, use Apple Home instead (see alternatives below)."),
                    ChecklistItem("A computer for the one-time key lookup."),
                ])
            ),
            GuideStep(
                id: "get-keys",
                title: "Get the device ID and local key",
                kind: .info("""
                1. Create a free account at [iot.tuya.com](https://iot.tuya.com) > Cloud > Development > **Create Cloud Project** (Smart Home, data center matching your app account's region).
                2. Subscribe the project to **IoT Core** (the free trial has to be renewed when it expires).
                3. Devices > **Link App Account** shows a QR code; scan it in Smart Life (Me > scan icon).
                4. On the computer: `pip install tinytuya`, then `python -m tinytuya wizard` with the project's Access ID/Secret. It lists each light's `id` and `key` (the local key).
                """),
                needsVerification: true,
                verifyNote: "iot.tuya.com menu names (Cloud project, Link App Account, IoT Core trial)."
            ),
            GuideStep(
                id: "scan",
                title: "Find your lights",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app listens for Tuya announcements (UDP 6666/6667) when allowed, otherwise probes TCP 6668 on your subnet. You can also skip this and enter everything by hand."
                ),
                callback: GuideCallback.discover,
                isOptional: true,
                problems: [tuyaOneConnection]
            ),
            manualIPStep("Only if a light was not found: enter its IP address (tip: reserve it in your router)."),
            GuideStep(
                id: "add",
                title: "Enter the key",
                kind: .action(
                    .confirm(button: "Add"),
                    prompt: "The app asks for the **device ID** (skipped for a scanned light), the **local key** (16 characters), the IP address and the protocol version (\"Detect automatically\" works). The key is stored in Keychain."
                ),
                callback: GuideCallback.pair,
                problems: [
                    Problem("\"Wrong key\"", fix: "Copy the key again from the tinytuya wizard output or the project's device list; it has exactly 16 characters."),
                    tuyaOneConnection,
                ]
            ),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([tuyaOneConnection, tuyaKeyChanged]),
                isOptional: true
            ),
        ],
        alternatives: [
            GuideAlternative(title: "Matter into Apple Home", detail: "If the bulb has a Matter logo.", targetGuideID: matterIntoAppleHomeID, isRecommended: true),
        ],
        verifyFlags: [
            VerifyFlag(id: "tuya-iot-menus", note: "iot.tuya.com menu names (Cloud project, Link App Account, IoT Core trial)."),
        ],
        facts: WizardFacts(vendorAppFirst: "yes (Smart Life)", asksFor: "device id + local key", settingToFlip: "—",
                           discovery: "UDP 6666/6667/7000", pairingAction: "paste key", homeKit: "no", matter: "some"),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §15 Meross

    static let merossRateLimit = Problem(
        "\"Too many sign-ins\"",
        fix: "Meross limits cloud logins. Wait an hour before trying again; the app never retries in a loop."
    )

    public static let meross = BrandGuide(
        id: Brand.meross.rawValue,
        brand: .meross,
        title: "Meross",
        summary: "Meross bulbs and strips. Sign in once to fetch your account's device key, then the lights are controlled on your Wi-Fi. \"HK\" models are HomeKit-native and \"MA\" models are Matter: prefer Apple Home for those.",
        phase: 3,
        section: "§15",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Lights set up in the **Meross** app, on the same Wi-Fi as this iPhone."),
                    ChecklistItem("Your Meross e-mail and password (the password is used once and **not stored**)."),
                    ChecklistItem("\"HK\" (HomeKit) or \"MA\" (Matter) models: use Apple Home instead."),
                ])
            ),
            GuideStep(
                id: "sign-in",
                title: "Sign in to Meross",
                kind: .action(
                    .confirm(button: "Sign in"),
                    prompt: "Choose your account region, enter your Meross e-mail and password (and the verification code if Meross sends one). The app keeps only the device key and token in Keychain, then finds your lights on this Wi-Fi. Advanced: enter the device key and IP instead."
                ),
                callback: GuideCallback.login,
                problems: [
                    Problem("\"Wrong e-mail or password\"", fix: "Check the region (US, EU, Asia) and the password you use in the Meross app."),
                    merossRateLimit,
                ]
            ),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    merossRateLimit,
                    Problem("Light not found on the Wi-Fi", fix: "Make sure the iPhone is on the same network; reserve the light's IP in the router."),
                ]),
                isOptional: true
            ),
        ],
        alternatives: [appleHomeAlternative("\"HK\" SKUs are HomeKit-native and \"MA\" SKUs are Matter: prefer Apple Home.", recommended: true)],
        facts: WizardFacts(vendorAppFirst: "yes", asksFor: "email+password once", settingToFlip: "—",
                           discovery: "IP / DHCP", pairingAction: "login", homeKit: "HK SKUs", matter: "MA SKUs"),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §16 SwitchBot

    public static let switchbot = BrandGuide(
        id: Brand.switchbot.rawValue,
        brand: .switchbot,
        title: "SwitchBot",
        summary: "SwitchBot Color Bulb, Strip Light and Ceiling Light through the SwitchBot cloud API with your token and secret (10,000 requests a day). Bluetooth-only devices need a SwitchBot Hub.",
        phase: 3,
        section: "§16",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Lights set up in the **SwitchBot** app (Bluetooth-only lights through a SwitchBot Hub)."),
                    ChecklistItem("The SwitchBot cloud is used for every command (10,000 requests a day, shared with other apps using your token)."),
                ])
            ),
            GuideStep(
                id: "developer-options",
                title: "Copy your token and secret",
                kind: .action(
                    .openApp(name: "SwitchBot", deepLink: nil),
                    prompt: "SwitchBot app > **Profile** > **Preferences** > **About** > tap **App Version 10 times** > **Developer Options** > copy the **Token** and the **Secret Key**."
                ),
                isOptional: true
            ),
            GuideStep(
                id: "token",
                title: "Paste token and secret",
                kind: .action(
                    .confirm(button: "Paste"),
                    prompt: "Paste the token, then the secret. The app checks them with SwitchBot and lists your lights. Both are stored in Keychain."
                ),
                callback: GuideCallback.login,
                problems: [
                    Problem("\"Unauthorized\"", fix: "Copy both values again from Developer Options; regenerating the token in the app invalidates the old one."),
                    Problem("\"Daily limit reached\"", fix: "The 10,000 requests a day are shared with other apps using your token; it resets after 24 hours."),
                ]
            ),
            verifyStep("light"),
        ],
        alternatives: [matterAlternative("Hub 2/3 can also expose lights as Matter (beta).")],
        facts: WizardFacts(vendorAppFirst: "yes", asksFor: "token+secret", settingToFlip: "tap version 10×",
                           discovery: "cloud", pairingAction: "paste", homeKit: "no", matter: "hub")
    )

    // MARK: §17 Twinkly

    static let twinklyTokenProblem = Problem(
        "Stops responding after using the Twinkly app",
        fix: "Each login invalidates older tokens; the app signs in again automatically. Close other Twinkly controllers (Home Assistant, other apps) if it keeps happening."
    )

    public static let twinkly = BrandGuide(
        id: Brand.twinkly.rawValue,
        brand: .twinkly,
        title: "Twinkly",
        summary: "Twinkly strings and strips, controlled directly on your network. No sign-in; upload effects in the Twinkly app.",
        phase: 3,
        section: "§17",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Set up in the **Twinkly** app, on the same Wi-Fi; upload the effects you want there."),
                    ChecklistItem("Close other Twinkly controllers: a new login invalidates older tokens."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your lights",
                kind: .action(.scan, prompt: "Tap **Scan**. The app asks on UDP 5555 (broadcast if allowed, otherwise every address on your subnet)."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a device was not found: enter its IP address."),
            addStep("Pick the devices to add. The app signs in to each one automatically; nothing to press."),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([twinklyTokenProblem]),
                isOptional: true
            ),
        ],
        alternatives: [appleHomeAlternative("Gen II is HomeKit-native (Twinkly app > device > HomeKit).")],
        facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "upload effects",
                           discovery: "UDP 5555", pairingAction: "none", homeKit: "Gen II", matter: "?"),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §18 IKEA Dirigera

    public static let dirigera = BrandGuide(
        id: Brand.dirigera.rawValue,
        brand: .dirigera,
        title: "IKEA Dirigera",
        summary: """
        Recommended: IKEA Home smart app > hub settings > Integrations > Apple Home or Matter, then the Apple Home provider.
        Direct: connect to the hub on your network (`gw2-<id>.local`, HTTPS 8443) by pressing its action button; the hub's scenes come along. Trådfri gateway (legacy): add it to Apple Home via its HomeKit code.
        """,
        phase: 3,
        section: "§18",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Hub set up in the **IKEA Home smart** app, on the same network as this iPhone."),
                    ChecklistItem(
                        "Simpler alternative: IKEA Home smart > hub settings > **Integrations** > Apple Home or Matter, then use Apple Home.",
                        needsVerification: true
                    ),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your hub",
                kind: .action(.scan, prompt: "Tap **Scan**. The app looks for `gw2-…` hubs by Bonjour and probes HTTPS port 8443 on your subnet."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if the hub was not found: enter its IP address."),
            GuideStep(
                id: "action-button",
                title: "Press the action button",
                kind: .action(
                    .confirm(button: "Continue"),
                    prompt: "When asked, **press the action button on the bottom of the hub**, then tap **Continue** within 30 seconds. The token is stored in Keychain; the hub's certificate is pinned on first use."
                ),
                callback: GuideCallback.pair,
                problems: [
                    Problem("Pairing timed out", fix: "Press the button on the bottom of the hub (not on a remote) and tap Continue right away."),
                    Problem("\"Certificate changed\"", fix: "The hub was reset or replaced. Remove it in Settings and add it again."),
                ]
            ),
            verifyStep("light"),
        ],
        alternatives: [appleHomeAlternative("IKEA Home smart app > hub settings > Integrations > Apple Home or Matter.", recommended: true)],
        verifyFlags: [VerifyFlag(id: "dirigera-integrations", note: "Dirigera Integrations menu path.")],
        facts: WizardFacts(vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
                           discovery: "`gw2-*.local`", pairingAction: "press hub button", homeKit: "yes", matter: "yes"),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: Home Assistant (HomeAssistantKit README)

    public static let homeAssistant = BrandGuide(
        id: Brand.homeAssistant.rawValue,
        brand: .homeAssistant,
        title: "Home Assistant",
        summary: "Connect to your Home Assistant server with a long-lived access token; its `light.*` entities and scenes appear here. The route for Zigbee, Sengled, Cync, Wyze and automations.",
        phase: 3,
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Home Assistant running on your network (for example `http://homeassistant.local:8123`)."),
                    ChecklistItem("A Home Assistant user whose lights SmartLights should control (an administrator is not required)."),
                ])
            ),
            GuideStep(
                id: "token",
                title: "Create a long-lived access token",
                kind: .info("""
                1. Open Home Assistant and click your **user name** (bottom left), then the **Security** tab.
                2. Under **Long-lived access tokens**, click **Create token** and name it (for example `SmartLights iPhone`).
                3. Copy the token right away: Home Assistant shows it **only once**.
                """)
            ),
            GuideStep(
                id: "scan",
                title: "Find your server",
                kind: .action(.scan, prompt: "Tap **Scan** to find Home Assistant by Bonjour (`_home-assistant._tcp`). You can skip this and type the URL in the next step."),
                callback: GuideCallback.discover,
                isOptional: true
            ),
            GuideStep(
                id: "connect",
                title: "Connect",
                kind: .action(
                    .confirm(button: "Connect"),
                    prompt: "Enter the Home Assistant URL (if not found), optionally a remote URL for away from home (Nabu Casa `https://….ui.nabu.casa` or your own `https://` address), then paste the token. It is stored in Keychain."
                ),
                callback: GuideCallback.pair,
                problems: [
                    Problem("\"Home Assistant did not answer\"", fix: "Use the address you open in a browser, including the port (usually `:8123`)."),
                    Problem("Token rejected", fix: "Create a new token and copy all of it (it is a long text starting with `eyJ`)."),
                ]
            ),
            verifyStep("light"),
        ],
        facts: WizardFacts(vendorAppFirst: "yes (HA)", asksFor: "URL + access token", settingToFlip: "—",
                           discovery: "`_home-assistant._tcp`", pairingAction: "paste token", homeKit: "bridge", matter: "via HA"),
        prerequisites: [iPhoneSetupID]
    )

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
