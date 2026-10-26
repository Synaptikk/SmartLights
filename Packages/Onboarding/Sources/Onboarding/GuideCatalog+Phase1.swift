import Foundation
import LightCore

// Phase-1 guides: docs/ONBOARDING-WALKTHROUGHS.md §1 (Hue), §1b (Hue Bluetooth), §2 (WiZ), §3 (AiDot), §4 (Apple Home).
extension GuideCatalog {
    static let manualIPField = InputField(key: "host", label: "IP address", placeholder: "192.168.1.20", contentType: .ipAddress)

    // MARK: §1 Philips Hue (bridge)

    public static let hue = BrandGuide(
        id: Brand.hue.rawValue,
        brand: .hue,
        title: "Philips Hue",
        summary: "Hue Bridge on your network. Lights, rooms, zones and scenes import automatically; no Hue account needed.",
        phase: 1,
        section: "§1",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Hue Bridge v2 (square) or Bridge Pro, on Ethernet to the same router as your Wi-Fi. Round v1 bridges are end-of-life."),
                    ChecklistItem("Lights already added in the Hue app. No Hue account is needed for local control."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your bridge",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app finds bridges by Bonjour, then via discovery.meethue.com, or you can enter the IP (Hue app > Settings > Hue Bridges shows it)."
                ),
                callback: GuideCallback.discover,
                problems: [
                    Problem("No bridge found", fix: "mDNS blocked or bridge on another VLAN. Enter the IP manually."),
                ]
            ),
            GuideStep(
                id: "manual-ip",
                title: "Add by IP",
                kind: .action(
                    .text(manualIPField),
                    prompt: "Only if the scan found nothing: enter the bridge IP shown in the Hue app > Settings > Hue Bridges."
                ),
                isOptional: true
            ),
            GuideStep(
                id: "link-button",
                title: "Press the link button",
                kind: .action(
                    .confirm(button: "Continue"),
                    prompt: "**Press the round button on top of the Hue Bridge**, then tap **Continue** within 30 seconds."
                ),
                detail: "The app sends `POST /api` with `generateclientkey:true`; error 101 means the button was not pressed in time.",
                needsVerification: true,
                verifyNote: "Link-button window length.",
                callback: GuideCallback.pair,
                problems: [
                    Problem("\"Failed to register\"", fix: "Press the button again and retry quickly."),
                    Problem(
                        "Certificate warning on an old bridge",
                        fix: "The app pins the bridge's own certificate by bridge id; accept once. Updated bridges (firmware 1971060010+, May 2025) use Signify-signed certs."
                    ),
                ]
            ),
            GuideStep(
                id: "import",
                title: "Import",
                kind: .info("Lights, rooms, zones and scenes import automatically. Changes from the Hue app show up live (event stream).")
            ),
            GuideStep(
                id: "verify",
                title: "Check a light",
                kind: .action(.verifyBlink, prompt: "Blink a light to check it responds."),
                callback: GuideCallback.verify,
                isOptional: true
            ),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    Problem("\"No bridge found\"", fix: "mDNS blocked or bridge on another VLAN. Enter the IP manually."),
                    Problem("\"Failed to register\"", fix: "Press the button again and retry quickly."),
                    Problem(
                        "Certificate warning on an old bridge",
                        fix: "The app pins the bridge's own certificate by bridge id; accept once. Updated bridges (firmware 1971060010+, May 2025) use Signify-signed certs."
                    ),
                    Problem("Scenes", fix: "Scenes must be created in the Hue app; the app can recall them."),
                    Problem(
                        "Third-party Zigbee bulbs on the bridge",
                        fix: "Innr, IKEA, etc. appear as Hue lights; some Hue-only features (dynamic scenes, Entertainment) are unavailable on them."
                    ),
                ]),
                isOptional: true
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Apple Home (Matter or HomeKit)",
                detail: "The bridge is a Matter bridge and native HomeKit. Hue app > Settings > Smart home > Apple Home or Matter, then use the Apple Home provider. The native path (this guide) is preferred because it exposes scenes/effects/gradients.",
                targetGuideID: Brand.appleHome.rawValue,
                needsVerification: true
            ),
            GuideAlternative(
                title: "Hue Bluetooth bulbs without a bridge",
                detail: "See the Hue Bluetooth guide.",
                targetGuideID: hueBluetoothID
            ),
        ],
        verifyFlags: [
            VerifyFlag(id: "hue-paths", note: "Hue app menu paths for Matter/Apple Home; link-button window length; Bluetooth-bulb-to-bridge steps."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
            discovery: "`_hue._tcp`, cloud broker, IP", pairingAction: "press bridge button",
            homeKit: "yes", matter: "yes (bridge)"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §1b Hue Bluetooth-only bulbs

    public static let hueBluetoothID = "hue-bluetooth"

    public static let hueBluetooth = BrandGuide(
        id: hueBluetoothID,
        brand: .hue,
        title: "Philips Hue Bluetooth bulbs (no bridge)",
        summary: "Bluetooth-only Hue bulbs. Direct control is phase 3; the recommended route is a Hue Bridge.",
        phase: 3,
        section: "§1b",
        steps: [
            GuideStep(
                id: "about",
                title: "Bluetooth bulbs",
                kind: .info("""
                Phase 3 only. Bluetooth bulbs need BLE bonding and must be made visible (Hue app > Settings > Voice assistants > "Make visible") or factory-reset.
                Bluetooth-connected Hue bulbs cannot use Matter.
                """)
            ),
            GuideStep(
                id: "recommended",
                title: "Recommended: use a bridge",
                kind: .info("Buy a bridge; add the bulb in the Hue app (Settings > Lights > Add light > Search or enter the serial), then follow the Philips Hue guide."),
                needsVerification: true,
                verifyNote: "Hue app path for adding a Bluetooth bulb to a bridge."
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Philips Hue (bridge)",
                detail: "Once the bulb is on a bridge, add the bridge here.",
                targetGuideID: Brand.hue.rawValue,
                isRecommended: true
            ),
        ],
        verifyFlags: [
            VerifyFlag(id: "hue-ble-to-bridge", note: "Bluetooth-bulb-to-bridge steps in the Hue app."),
        ]
    )

    // MARK: §2 WiZ

    public static let wiz = BrandGuide(
        id: Brand.wiz.rawValue,
        brand: .wiz,
        title: "WiZ",
        summary: "WiZ Wi-Fi bulbs, controlled directly on your network (UDP). Newer firmware may need the local signing key.",
        phase: 1,
        section: "§2",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Bulbs set up in the **WiZ** app on your 2.4 GHz Wi-Fi."),
                    ChecklistItem("WiZ app > menu (upper-left) > **Settings > Security**: **\"Allow local communication\"** must be ON (default)."),
                ])
            ),
            GuideStep(
                id: "control-mode",
                title: "Control mode",
                kind: .action(
                    .choose(options: ["Allow all controls", "Only verified controls"]),
                    prompt: """
                    Same screen, control mode: which one is selected?
                    If it says **"Only verified controls"**, either switch to **"Allow all controls"** or export the local key: Home settings > Integrations > **Local integrations** > export; the JSON contains `udp_signing_key`. Bulbs on firmware 1.34+ reject unsigned commands otherwise.
                    """
                ),
                needsVerification: true,
                verifyNote: "Exact wording and availability in your app version; whether \"Only verified controls\" is the default."
            ),
            GuideStep(
                id: "scan",
                title: "Find your bulbs",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app broadcasts on UDP 38899 if allowed, otherwise probes every address on your subnet (takes ~10-20 s). You can also **Add by IP**."
                ),
                callback: GuideCallback.discover,
                problems: [
                    Problem(
                        "Bulb not found",
                        fix: "It is off at the wall, on a different subnet/VLAN, or \"Allow local communication\" is off. Routers with client isolation or \"Smart Connect\" band steering cause flakiness; give bulbs DHCP reservations."
                    ),
                ]
            ),
            GuideStep(
                id: "manual-ip",
                title: "Add by IP",
                kind: .action(.text(manualIPField), prompt: "Only if a bulb was not found: enter its IP address."),
                isOptional: true
            ),
            GuideStep(
                id: "signing-key",
                title: "Signing key",
                kind: .action(
                    .importFile(allowedTypes: ["public.json", "json"]),
                    prompt: "If asked, paste or import the signing key (JSON import or 32-hex string). Stored in Keychain."
                ),
                callback: GuideCallback.importKey,
                isOptional: true,
                problems: [
                    Problem(
                        "\"Invalid params\" / \"Security error\" on commands",
                        fix: "Signing required or wrong key; re-export the key or switch to \"Allow all controls\"."
                    ),
                ]
            ),
            GuideStep(
                id: "verify",
                title: "Check a bulb",
                kind: .action(.verifyBlink, prompt: "Blink a bulb to check it responds."),
                detail: "Each bulb is identified by MAC; type/colour capabilities are read from `getSystemConfig`/`getModelConfig`.",
                callback: GuideCallback.verify,
                isOptional: true
            ),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    Problem(
                        "Bulb not found",
                        fix: "It is off at the wall, on a different subnet/VLAN, or \"Allow local communication\" is off. Routers with client isolation or \"Smart Connect\" band steering cause flakiness; give bulbs DHCP reservations."
                    ),
                    Problem(
                        "\"Invalid params\" / \"Security error\" on commands",
                        fix: "Signing required or wrong key; re-export the key or switch to \"Allow all controls\"."
                    ),
                    Problem(
                        "No live updates",
                        fix: "Push requires the bulb to reach your phone on UDP 38900; the app re-registers when it comes to the foreground."
                    ),
                    Problem("Colour and white", fix: "Colour and white modes are exclusive; brightness below 10% is clamped by the bulb."),
                ]),
                isOptional: true
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Upgrade to Matter",
                detail: "Most Wi-Fi WiZ products made since Q2 2021 can be upgraded to Matter in the WiZ app (Settings > Integrations > Matter), then add them to Apple Home. UDP keeps working alongside Matter per community reports.",
                targetGuideID: matterIntoAppleHomeID,
                needsVerification: true
            ),
        ],
        verifyFlags: [
            VerifyFlag(
                id: "wiz-wording",
                note: "Exact \"Local integrations\" export wording; whether \"Only verified controls\" is the default; Matter-migrated bulbs still accepting UDP."
            ),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "signing key (if verified-controls mode)",
            settingToFlip: "Allow local communication; control mode",
            discovery: "UDP 38899 / sweep / IP", pairingAction: "none", homeKit: "no", matter: "SKUs"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §3 AiDot / Linkind / OREiN

    public static let aidot = BrandGuide(
        id: Brand.aidot.rawValue,
        brand: .aidot,
        title: "AiDot / Linkind / OREiN",
        summary: "Also Mujoy, Winees, WELOV. Sign in once to fetch your devices and their local keys; the bulbs are then controlled directly on your network.",
        phase: 1,
        section: "§3",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Lights added in the **AiDot** app. You must use the account that **owns** the home (shared members cannot control locally)."),
                    ChecklistItem("Know the **country** you selected when logging into the AiDot app. Only username + password login is supported (no Apple/Google sign-in)."),
                    ChecklistItem("Avoid signing into the AiDot app on another device with the same account while using SmartLights: a new login invalidates the previous token (the app will ask you to re-enter your password if that happens)."),
                ])
            ),
            GuideStep(
                id: "login",
                title: "Sign in",
                kind: .action(
                    .confirm(button: "Sign in"),
                    prompt: "Enter **Country**, **Username** (AiDot account email), **Password**. The app logs in to the AiDot cloud once to fetch your devices and their local keys."
                ),
                callback: GuideCallback.login,
                problems: [
                    Problem(
                        "\"Credentials belong to a different account\" or \"token expired\" (code 21026)",
                        fix: "Re-enter the password; use the owner account."
                    ),
                ]
            ),
            GuideStep(
                id: "scan",
                title: "Find your lights",
                kind: .action(
                    .scan,
                    prompt: "The app finds each bulb on the LAN (UDP 6666 discovery; hostname `aidot`) and talks to it directly over TCP 10000. Nothing else goes through the cloud except presets/effects, which are optional."
                ),
                callback: GuideCallback.discover,
                problems: [
                    Problem(
                        "Devices listed but unreachable",
                        fix: "Bulb off, different subnet, or local control blocked. Try **Add by IP** under the device."
                    ),
                ]
            ),
            GuideStep(
                id: "verify",
                title: "Check a light",
                kind: .action(.verifyBlink, prompt: "Blink a light to check it responds."),
                callback: GuideCallback.verify,
                isOptional: true
            ),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    Problem(
                        "Login error \"credentials belong to a different account\" or \"token expired\" (code 21026)",
                        fix: "Re-enter the password; use the owner account."
                    ),
                    Problem(
                        "Devices listed but unreachable",
                        fix: "Bulb off, different subnet, or local control blocked. Try **Add by IP** under the device."
                    ),
                    Problem(
                        "BLE-mesh outdoor lights (SL5/SL5C, B1 Plus hub)",
                        fix: "Not reachable this way; use the Linkind Matter Smart Hub 2 and add it to Apple Home."
                    ),
                    Problem(
                        "What works locally",
                        fix: "Wi-Fi bulbs/strips/plugs (on/off, brightness, colour temperature, RGBW)."
                    ),
                ]),
                isOptional: true
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Matter (recommended for Matter SKUs)",
                detail: "Linkind/OREiN Matter bulbs (Matter logo on box, Matter 1.4/1.5 certified): add them to Apple Home, then use the Apple Home provider. Fully local, no AiDot account.",
                targetGuideID: matterIntoAppleHomeID,
                isRecommended: true
            ),
        ],
        verifyFlags: [
            VerifyFlag(id: "aidot-unicast", note: "AiDot local discovery reliability without broadcast entitlement (unicast fallback behaviour)."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "country, email, password", settingToFlip: "—",
            discovery: "cloud list → UDP 6666 / IP", pairingAction: "login", homeKit: "no", matter: "SKUs"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §4 Apple Home

    public static let appleHome = BrandGuide(
        id: Brand.appleHome.rawValue,
        brand: .appleHome,
        title: "Apple Home (HomeKit + Matter)",
        summary: "Everything already in Apple's Home app: Hue, Nanoleaf, LIFX, Eve, Lutron, Meross HK, IKEA Dirigera, Aqara, Twinkly Gen II and any Matter light.",
        phase: 1,
        section: "§4",
        steps: [
            GuideStep(
                id: "permission",
                title: "Allow HomeKit access",
                kind: .action(.confirm(button: "Allow HomeKit access"), prompt: "Allow HomeKit access when iOS asks."),
                callback: GuideCallback.homeKitPermission,
                problems: [
                    // Not in the walkthrough doc; standard iOS path, flagged until checked on iOS 18.
                    Problem(
                        "I denied access",
                        fix: "Settings > Privacy & Security > HomeKit > turn **SmartLights** on.",
                        needsVerification: true
                    ),
                ]
            ),
            GuideStep(
                id: "imported",
                title: "Your Home lights",
                kind: .info("Everything already in the Home app appears (Hue bridge, Nanoleaf, LIFX, Eve, Lutron, Meross HK, IKEA Dirigera, Aqara hub, Twinkly Gen II, any Matter light).")
            ),
            GuideStep(
                id: "add-new",
                title: "Adding new accessories",
                kind: .action(
                    .openApp(name: "Home", deepLink: "com.apple.home://"),
                    prompt: "To add new accessories, use the Home app (see \"Add a Matter light to Apple Home\" for Matter; scan the HomeKit code for HomeKit-native)."
                ),
                isOptional: true
            ),
            GuideStep(
                id: "limits",
                title: "Limits",
                kind: .info("""
                - Only on/off, brightness, hue/saturation and colour temperature; no vendor effects.
                - Remote access and automations need a HomePod or Apple TV hub.
                - Widgets/Siri for HomeKit lights run through the app (iOS limitation); the first tap may open the app briefly.
                """)
            ),
        ],
        alternatives: [
            GuideAlternative(
                title: "Add a Matter light first",
                detail: "Pair it in the Home app, then it appears here.",
                targetGuideID: matterIntoAppleHomeID
            ),
        ],
        facts: WizardFacts(
            vendorAppFirst: "Home app", asksFor: "HomeKit permission", settingToFlip: "—",
            discovery: "HMHomeManager", pairingAction: "none", homeKit: "—", matter: "—"
        )
    )
}
