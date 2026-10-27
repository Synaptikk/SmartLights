import Foundation
import LightCore

// Phase-2 guides (T2.10): docs/ONBOARDING-WALKTHROUGHS.md §5 (LIFX), §6 (Govee), §7 (Nanoleaf),
// §8 (TP-Link), §9 (Yeelight), §11 (Elgato), §12 (Shelly), §13 (WLED), §14 (Magic Home).
// Brands whose wizard matrix says "pairing action: none" still end with an "add" step that
// runs `GuideCallback.pair`, so the app stores the discovered device and loads its lights.
extension GuideCatalog {
    /// Every phase-2 brand guide, in doc order.
    public static let phase2: [BrandGuide] = [lifx, govee, nanoleaf, tplink, yeelight, elgato, shelly, wled, magicHome]

    /// "Add by IP" step shared by the LAN brands.
    private static func manualIPStep(_ prompt: RichText) -> GuideStep {
        GuideStep(id: "manual-ip", title: "Add by IP", kind: .action(.text(manualIPField), prompt: prompt), isOptional: true)
    }

    /// Final "add the devices the scan found" step for brands with no pairing action.
    private static func addStep(_ prompt: RichText = "Pick the devices to add. Each one is stored by its stable id; the IP address is only a hint.") -> GuideStep {
        GuideStep(id: "add", title: "Add your devices", kind: .action(.confirm(button: "Add"), prompt: prompt), callback: GuideCallback.pair)
    }

    private static func verifyStep(_ noun: String) -> GuideStep {
        GuideStep(
            id: "verify",
            title: "Check a \(noun)",
            kind: .action(.verifyBlink, prompt: RichText("Blink a \(noun) to check it responds.")),
            callback: GuideCallback.verify,
            isOptional: true
        )
    }

    // MARK: §5 LIFX

    static let lifxSubnetProblem = Problem("Bulb not found", fix: "It is on a different subnet: use **Add by IP**.")
    static let lifxSwitchProblem = Problem("LIFX Switch", fix: "The LIFX Switch is not on the LAN protocol and does not show up here.")

    public static let lifx = BrandGuide(
        id: Brand.lifx.rawValue,
        brand: .lifx,
        title: "LIFX",
        summary: "LIFX Wi-Fi bulbs, controlled directly on your network. No account or token needed for local control.",
        phase: 2,
        section: "§5",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Bulbs set up in the **LIFX** app (2.4 GHz)."),
                    ChecklistItem("No account or token needed for local control."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your bulbs",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app looks for bulbs by mDNS (`_lifx._udp`) and/or UDP 56700 broadcast, otherwise probes every address on your subnet. You can also **Add by IP**."
                ),
                callback: GuideCallback.discover,
                problems: [lifxSubnetProblem]
            ),
            manualIPStep("Only if a bulb was not found (different subnet): enter its IP address."),
            addStep(),
            GuideStep(
                id: "cloud-token",
                title: "Away-from-home control (optional)",
                kind: .action(
                    .secureText(InputField(key: "token", label: "LIFX cloud token", contentType: .token)),
                    prompt: "Optional: paste a LIFX cloud token from [cloud.lifx.com/settings](https://cloud.lifx.com/settings) for away-from-home control (120 requests/min). Stored in Keychain."
                ),
                isOptional: true
            ),
            verifyStep("bulb"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([lifxSubnetProblem, lifxSwitchProblem]),
                isOptional: true
            ),
        ],
        alternatives: [
            appleHomeAlternative("Most LIFX are native HomeKit; new ones are Matter (Thread beta 2026)."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "optional cloud token", settingToFlip: "—",
            discovery: "`_lifx._udp` / UDP 56700 / sweep", pairingAction: "none", homeKit: "yes", matter: "new SKUs"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §6 Govee

    static let goveeNotFound = Problem(
        "\"No devices found\"",
        fix: "LAN Control is off, the model is not supported, or multicast is blocked by the router/VLAN."
    )
    static let goveePortInUse = Problem("\"Port 4002 in use\"", fix: "Another Govee app on the phone is using the port; close it.")

    public static let govee = BrandGuide(
        id: Brand.govee.rawValue,
        brand: .govee,
        title: "Govee",
        summary: "Govee strips, lamps and panels with LAN Control, controlled directly on your network. Other models use your Govee API key.",
        phase: 2,
        section: "§6",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Device set up in **Govee Home** (2.4 GHz)."),
                    ChecklistItem("For local control the model must support the LAN API (strips, lamps, panels; most plain A19 bulbs do not)."),
                    ChecklistItem(
                        "**LAN Control** is on: Govee Home > device > Settings (gear) > **LAN Control**. The toggle may take minutes to appear after a firmware update.",
                        needsVerification: true
                    ),
                ])
            ),
            GuideStep(
                id: "path",
                title: "Your model",
                kind: .action(
                    .choose(options: ["LAN Control is on", "My model has no LAN Control"]),
                    prompt: "Does your device have the **LAN Control** toggle? Models without it are controlled through the Govee Developer API with your own key."
                )
            ),
            GuideStep(
                id: "scan",
                title: "Find your devices",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app asks on multicast 239.255.255.250:4001; devices reply on 4002 and take commands on 4003."
                ),
                callback: GuideCallback.discover,
                problems: [goveeNotFound, goveePortInUse]
            ),
            addStep(),
            GuideStep(
                id: "api-key",
                title: "API key (models without LAN Control)",
                kind: .action(
                    .secureText(InputField(key: "apiKey", label: "Govee API key", contentType: .token)),
                    prompt: "Govee Home > Settings > **Apply for API Key** (it arrives by email), then paste it here (Developer API, 10k requests/day). Stored in Keychain."
                ),
                callback: GuideCallback.importKey,
                isOptional: true
            ),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([goveeNotFound, goveePortInUse]),
                isOptional: true
            ),
        ],
        alternatives: [
            matterAlternative("2025-26 Govee bulbs/lamps are Matter."),
        ],
        verifyFlags: [
            VerifyFlag(id: "govee-lan-control", note: "Govee \"LAN Control\" menu path and firmware prerequisite."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "API key (cloud models)", settingToFlip: "LAN Control",
            discovery: "multicast 4001", pairingAction: "paste key", homeKit: "no", matter: "new SKUs"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §7 Nanoleaf

    static let nanoleafEssentialsProblem = Problem(
        "Essentials bulbs or strips",
        fix: "They have no local API. Add them to Apple Home (HomeKit over Thread/BLE, or Matter Essentials) and use the Apple Home provider. Thread needs a HomePod/Apple TV."
    )

    public static let nanoleaf = BrandGuide(
        id: Brand.nanoleaf.rawValue,
        brand: .nanoleaf,
        title: "Nanoleaf",
        summary: "Nanoleaf panels (Light Panels, Canvas, Shapes, Elements, Lines), paired once with the controller's power button. Essentials bulbs and strips go through Apple Home.",
        phase: 2,
        section: "§7",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Panels (Light Panels, Canvas, Shapes, Elements, Lines) set up in the **Nanoleaf** app."),
                    ChecklistItem("Use IPv4 and set a DHCP reservation for the controller."),
                    ChecklistItem("**Essentials** bulbs and strips have no local API: use the Apple Home route instead."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your panels",
                kind: .action(.scan, prompt: "Tap **Scan**. The app finds controllers by mDNS (`_nanoleafapi._tcp`)."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if the scan found nothing: enter the controller's IP address."),
            GuideStep(
                id: "hold-power",
                title: "Hold the power button",
                kind: .action(
                    .confirm(button: "Continue"),
                    prompt: "**Hold the power button on the controller for 5-7 seconds until the LEDs flash**, then tap **Continue** within 30 seconds. Skylight: tap \"Connect to API\" in the Nanoleaf app instead."
                ),
                detail: "The token is stored in Keychain; a factory reset requires pairing again.",
                needsVerification: true,
                verifyNote: "Hold time (5 s per Home Assistant vs 5-7 s per Nanoleaf).",
                callback: GuideCallback.pair,
                problems: [
                    Problem("Pairing failed", fix: "Hold the button again until the LEDs flash and tap Continue quickly (30-second window)."),
                ]
            ),
            verifyStep("panel"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    Problem("Pairing failed", fix: "Hold the button again until the LEDs flash and tap Continue quickly (30-second window)."),
                    Problem("Stopped working after a factory reset", fix: "The stored token is gone; pair again."),
                    Problem("Controller changes address", fix: "Use IPv4 and set a DHCP reservation."),
                    nanoleafEssentialsProblem,
                ]),
                isOptional: true
            ),
        ],
        alternatives: [
            appleHomeAlternative("Essentials bulbs/strips: add to Apple Home (HomeKit over Thread/BLE, or Matter Essentials). Thread needs a HomePod/Apple TV."),
        ],
        verifyFlags: [
            VerifyFlag(id: "nanoleaf-hold-time", note: "Nanoleaf hold time (5 s per HA vs 5-7 s per Nanoleaf)."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
            discovery: "`_nanoleafapi._tcp`", pairingAction: "hold power 5-7 s", homeKit: "yes", matter: "some"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §8 TP-Link Tapo and Kasa

    static let tplinkAuthProblem = Problem(
        "\"Unable to authenticate\"",
        fix: "Email typed in the wrong case, Third-Party Compatibility off, or other TP-Link devices interfering during onboarding (unplug them briefly)."
    )
    static let tplinkSubnetProblem = Problem("Device on another subnet", fix: "Use **Add by IP**.")

    public static let tplink = BrandGuide(
        id: Brand.tplink.rawValue,
        brand: .tplink,
        title: "TP-Link Tapo and Kasa",
        summary: "Tapo and Kasa bulbs, strips and plugs, controlled on your network. Newer devices need your TP-Link account email and password; legacy Kasa bulbs need nothing.",
        phase: 2,
        section: "§8",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Set up in the **Tapo** or **Kasa** app."),
                    ChecklistItem("Newer devices require your **TP-Link account email + password** for local control (case-sensitive)."),
                    ChecklistItem("Some firmware needs **Tapo app > Tapo Lab > Third-Party Compatibility** turned on. TP-Link warns that it lowers security."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your devices",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app broadcasts on UDP 9999/20002 if allowed, otherwise probes every address on your subnet."
                ),
                callback: GuideCallback.discover,
                problems: [tplinkSubnetProblem]
            ),
            manualIPStep("Only if a device is on another subnet: enter its IP address."),
            GuideStep(
                id: "credentials",
                title: "Sign in",
                kind: .action(
                    .confirm(button: "Continue"),
                    prompt: "When prompted, enter your TP-Link account **email + password** (case-sensitive). Legacy Kasa bulbs (KL/LB) need no credentials. Stored in Keychain."
                ),
                callback: GuideCallback.pair,
                problems: [tplinkAuthProblem]
            ),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([tplinkAuthProblem, tplinkSubnetProblem]),
                isOptional: true
            ),
        ],
        alternatives: [
            matterAlternative("Tapo L535E and other Matter SKUs."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "TP-Link email+password", settingToFlip: "Third-Party Compatibility",
            discovery: "UDP 9999/20002", pairingAction: "enter creds", homeKit: "rare", matter: "some"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §9 Yeelight

    static let yeelightRateProblem = Problem("Commands ignored when changing fast", fix: "Yeelight allows 60 commands per minute; the app spaces commands out.")
    static let yeelightReconnectProblem = Problem(
        "First command does nothing",
        fix: "The first command after a dropped connection may be ignored; try again."
    )

    public static let yeelight = BrandGuide(
        id: Brand.yeelight.rawValue,
        brand: .yeelight,
        title: "Yeelight",
        summary: "Yeelight bulbs and strips with LAN Control, controlled directly on your network. No sign-in.",
        phase: 2,
        section: "§9",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Yeelight app > Device > (more) > **LAN Control** on (older firmware: \"Developer mode\")."),
                    ChecklistItem("Toggle missing? Update the firmware. Some newer models removed it."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your lights",
                kind: .action(
                    .scan,
                    prompt: "Tap **Scan**. The app searches by SSDP (239.255.255.250:1982) and mDNS (`_miio._udp`). No sign-in needed."
                ),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a light was not found: enter its IP address."),
            addStep(),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([
                    Problem("Light not found", fix: "Turn on **LAN Control** in the Yeelight app (update the firmware if the toggle is missing), or **Add by IP**."),
                    yeelightRateProblem,
                    yeelightReconnectProblem,
                ]),
                isOptional: true
            ),
        ],
        alternatives: [
            appleHomeAlternative("Some models are HomeKit-native or Matter."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "LAN Control",
            discovery: "SSDP 1982 / `_miio._udp`", pairingAction: "none", homeKit: "some", matter: "some"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §11 Elgato

    public static let elgato = BrandGuide(
        id: Brand.elgato.rawValue,
        brand: .elgato,
        title: "Elgato Key Light / Air / Mini / Ring / Strip",
        summary: "Elgato lights, controlled directly on your network. No sign-in.",
        phase: 2,
        section: "§11",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Set up in **Elgato Control Center**."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your lights",
                kind: .action(.scan, prompt: "Tap **Scan**. The app finds lights by mDNS (`_elg._tcp`) and talks to them over HTTP port 9123. No sign-in needed."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a light was not found: enter its IP address."),
            addStep(),
            GuideStep(
                id: "temperature",
                title: "Colour temperature",
                kind: .info("The lights use mireds 143-344; the app shows them in Kelvin.")
            ),
            verifyStep("light"),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
            discovery: "`_elg._tcp`", pairingAction: "none", homeKit: "no", matter: "no"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §12 Shelly

    public static let shelly = BrandGuide(
        id: Brand.shelly.rawValue,
        brand: .shelly,
        title: "Shelly",
        summary: "Shelly dimmers, RGBW controllers and bulbs, controlled directly on your network. Only asks for the device password if you set one.",
        phase: 2,
        section: "§12",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Set up in **Shelly Smart Control** (the Shelly cloud is optional)."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your devices",
                kind: .action(.scan, prompt: "Tap **Scan**. The app finds devices by mDNS (`_shelly._tcp`)."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a device was not found: enter its IP address."),
            GuideStep(
                id: "add",
                title: "Add your devices",
                kind: .action(
                    .confirm(button: "Add"),
                    prompt: "If you set a device password, the app asks for it: the username is `admin` (digest auth). Stored in Keychain."
                ),
                callback: GuideCallback.pair,
                problems: [
                    Problem("Password rejected", fix: "The username is always `admin`; use the password set in the device's web UI or Shelly app."),
                ]
            ),
            verifyStep("light"),
        ],
        alternatives: [
            matterAlternative("Gen3/4 can also do Matter (enable in device web UI)."),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "admin password if set", settingToFlip: "—",
            discovery: "`_shelly._tcp`", pairingAction: "none", homeKit: "no", matter: "Gen3/4"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §13 WLED

    public static let wled = BrandGuide(
        id: Brand.wled.rawValue,
        brand: .wled,
        title: "WLED",
        summary: "LED controllers running WLED 0.14 or newer, controlled directly on your network. No sign-in.",
        phase: 2,
        section: "§13",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Controller flashed with **WLED 0.14** or newer."),
                ])
            ),
            GuideStep(
                id: "wifi-setup",
                title: "Connect WLED to your Wi-Fi",
                kind: .action(
                    .openApp(name: "Settings", deepLink: nil),
                    prompt: """
                    1. In iPhone Settings > Wi-Fi, join **WLED-AP** (password `wled1234`).
                    2. Open http://4.3.2.1 > **WiFi Setup**, enter your home SSID and password, set an mDNS name.
                    3. Tap **Save & Connect**, then rejoin your home Wi-Fi.
                    """
                ),
                detail: "Skip this if the controller is already on your Wi-Fi.",
                isOptional: true
            ),
            GuideStep(
                id: "scan",
                title: "Find your controllers",
                kind: .action(.scan, prompt: "Tap **Scan**. The app finds controllers by mDNS (`_wled._tcp`). No sign-in needed."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a controller was not found: enter its IP address."),
            addStep(),
            verifyStep("light"),
        ],
        facts: WizardFacts(
            vendorAppFirst: "captive portal", asksFor: "nothing", settingToFlip: "—",
            discovery: "`_wled._tcp`", pairingAction: "none", homeKit: "no", matter: "no"
        ),
        prerequisites: [iPhoneSetupID]
    )

    // MARK: §14 Magic Home / Zengge / LEDENET

    static let magicHomePowerProblem = Problem(
        "Drops offline while changing colours",
        fix: "Usually a weak power supply; use one rated for the strip."
    )

    public static let magicHome = BrandGuide(
        id: Brand.magicHome.rawValue,
        brand: .magicHome,
        title: "Magic Home / Zengge / LEDENET",
        summary: "Magic Home-compatible LED controllers and bulbs, controlled directly on your network. No sign-in.",
        phase: 2,
        section: "§14",
        steps: [
            GuideStep(
                id: "before",
                title: "Before you start",
                kind: .checklist([
                    ChecklistItem("Set up in the **Magic Home** app."),
                ])
            ),
            GuideStep(
                id: "scan",
                title: "Find your devices",
                kind: .action(.scan, prompt: "Tap **Scan**. The app searches on UDP 48899 and controls devices over TCP 5577. No sign-in needed."),
                callback: GuideCallback.discover
            ),
            manualIPStep("Only if a device was not found: enter its IP address."),
            addStep(),
            verifyStep("light"),
            GuideStep(
                id: "troubleshooting",
                title: "Troubleshooting",
                kind: .troubleshoot([magicHomePowerProblem]),
                isOptional: true
            ),
        ],
        facts: WizardFacts(
            vendorAppFirst: "yes", asksFor: "nothing", settingToFlip: "—",
            discovery: "UDP 48899", pairingAction: "none", homeKit: "no", matter: "no"
        ),
        prerequisites: [iPhoneSetupID]
    )
}
