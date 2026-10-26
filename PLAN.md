# SmartLights: one iPhone app for every smart light brand

Master plan. Written 2026-10-26 from the research in `research/`. This file is the contract for the implementing agents (Opus 5.5). Read `CLAUDE.md` first, then this, then `agents/TASKS.md`.

Owner: sinap (GitHub `Synaptikk`). Owns: Philips Hue bridge + Hue bulbs, WiZ bulbs, AiDot/Linkind bulbs, possibly others.

---

## 1. Goal and non-goals

**Goal.** A native iPhone app that discovers, onboards and controls smart lights from many brands through one UI: rooms, lights, groups, colour/brightness/temperature, scenes, quick actions (widgets, Control Center, Siri). Local control wherever a local protocol exists; cloud only where the vendor leaves no other path. Every supported brand ships with an in-app, step-by-step "Add brand" walkthrough.

**Non-goals (decided, see section 3).**
- Modifying or rooting the Hue bridge.
- Android / cross-platform in v1.
- 24/7 automations running on the phone (iOS does not allow it; a Home Assistant provider is the planned route for that).
- Brands with no viable path (Amazon Basics, Eufy Lumos, Ikea Trådfri gateway, GE Cync local DNS-hijack).

---

## 2. Research summary (what the online rundown found)

Full reports with URLs are in `research/`. The ten facts that shape the design:

1. **No existing open-source iOS app does this.** Closest is `0xProbabillity/house-control` (Swift, MIT, 772 stars, active): provider-protocol architecture with working Hue, HomeKit and Home Assistant back ends. We borrow its patterns and port pieces; we do not fork it (reasons in section 3).
2. **Hue:** local CLIP v2 HTTPS API + Server-Sent Events, link-button pairing, no account needed. 2025 firmware moved bridges to Signify-CA-signed certs (two Signify roots now: v2 bridge and Bridge Pro); CN == bridge id. No maintained Swift CLIP v2 library; we write a thin client. Entertainment streaming (DTLS-PSK, UDP 2100) and BLE are optional extras.
3. **WiZ:** JSON over UDP 38899/38900, no account. **Firmware 1.34+ (2026) rejects unsigned writes** unless the WiZ app's security mode is "Allow all controls"; otherwise writes need HMAC-SHA256 with a per-home `udp_signing_key` exported from the WiZ app. We implement signing with CryptoKit plus the fallback instruction.
4. **AiDot/Linkind/OREiN:** vendor-published `python-aidot` library backs an official Home Assistant integration (2026.6). One cloud login (RSA-encrypted password, `prod-{us,eu,jp}-api.arnoo.com`) fetches devices + per-device AES keys; then **fully local** control: UDP 6666 discovery (AES-256-ECB, fixed key) and TCP 10000 control (AES-128-ECB). Only the owner account works. Matter SKUs exist and are the better path for those bulbs.
5. **HomeKit framework is the universal back door.** Any accessory the user has added to Apple Home, native HomeKit or Matter, is controllable from a third-party app with the HomeKit entitlement. This covers Matter SKUs from every brand, Nanoleaf Essentials, Lutron, Eve, IKEA Dirigera, Aqara and more. Limitation: only generic on/off/brightness/hue/sat/colour-temp; no vendor effects.
6. **Matter on iOS:** a third-party app may commission into its own fabric via the MatterSupport extension, but **Thread devices fail without a border router** (iPhone's Thread radio is not exposed). Wi-Fi Matter devices work. Defer own-fabric Matter to phase 3; use HomeKit for Matter devices in v1.
7. **UDP broadcast/multicast on iOS requires the managed `com.apple.developer.networking.multicast` entitlement** (request from Apple, paid team only) **and BSD sockets** (Network.framework broadcast is broken on iOS 26). Unicast UDP needs no entitlement. Design: request the entitlement; always ship a unicast fallback (sweep the /24, cached IPs, manual IP).
8. **No background execution.** Quick actions via interactive widgets, iOS 18 Control Center controls and App Intents. HomeKit calls from widget extensions fail since iOS 18.4; route them through the app via `ForegroundContinuableIntent`.
9. **Brand landscape clusters into five patterns** (documented local API; official cloud API with user key; reverse-engineered with cloud credentials; HomeKit/Matter only; dead ends). `docs/BRAND-RUNDOWN.md` has every brand.
10. **Hue bridge rooting gains nothing**: last documented in 2022, UART + NAND-short, yields a shell but no Zigbee coordinator access; the official local API already exposes everything. Bridge Pro has no public root. Third-party Zigbee 3.0/ZLL bulbs (Innr, IKEA, Gledopto, Cree, GE Link) can join the bridge and appear as Hue lights to us; Sengled and US Osram cannot.

---

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Native Swift 6 / SwiftUI, iOS 18 minimum**, Xcode 27. | Every hard requirement (Network.framework, Bonjour plist, HomeKit, MatterSupport extension, WidgetKit/Controls, CoreBluetooth) is native-only; no maintained Flutter/RN wrappers exist. iOS 18 gives Control Center controls. |
| D2 | **Greenfield repo, modular SwiftPM packages**; port code from `house-control` (MIT, attribute) rather than fork. | house-control bundles a macOS target, XcodeGen, 3D floor plan, AC devices and a loose `[String: Any]` patch model. We want a typed light model (copied from Home Assistant's `ColorMode`) and codec packages that compile on Linux so agents can test without a Mac. |
| D3 | **Direct-to-device, local-first architecture**; HomeKit framework as the universal second path; Home Assistant provider in phase 3 for automations. | The user asked for one app, not a server. HomeKit covers every Matter SKU for free. HA remains the escape hatch for Zigbee-only and cloud-only brands and for 24/7 automations. |
| D4 | **Do not modify the Hue bridge.** | See fact 10. |
| D5 | **Paid Apple Developer Program assumed** ($99/yr). | Needed for the multicast entitlement, TestFlight, 1-year profiles, HomeKit without weekly re-signing. |
| D6 | **Codec/transport split in every brand package.** `XxxCodec` = pure Swift (Foundation only, Linux-testable). `XxxProvider` = Apple-only transport + provider conformance. | Agents work on Windows; they can run codec tests in a Linux Swift container via Docker. Transport and UI are verified by macOS CI. |
| D7 | **Unified light model = Home Assistant's `LightEntity`/`ColorMode` semantics.** | Battle-tested across every brand here; mandatory in HA since 2024. |
| D8 | **Onboarding is data-driven.** One wizard engine renders per-brand `BrandGuide` definitions (steps, actions, troubleshooting). | The user explicitly requires per-brand walkthroughs; data-driven keeps 20+ brands maintainable. |
| D9 | **Brand phasing by (a) what the user owns, (b) protocol simplicity.** | Phase 1 = Hue, WiZ, AiDot, HomeKit. See section 6. |
| D10 | **Secrets in Keychain, device registry in SwiftData, keyed by stable ids (Hue uuid, WiZ MAC, AiDot devId), never by IP.** | IPs change; every research report flags it. |

---

## 4. Architecture

```
SmartLights.xcodeproj (generated from Package + app target; or Tuist/XcodeGen if agents prefer, decide in T0.2)
├─ App/                      iOS app target (SwiftUI, iOS 18+)
│  ├─ Features/              Rooms, LightDetail, Scenes, QuickActions, Settings, Diagnostics
│  ├─ Onboarding/            Wizard UI (renders BrandGuide)
│  └─ Resources/             Info.plist keys: NSLocalNetworkUsageDescription, NSBonjourServices,
│                            NSHomeKitUsageDescription, NSBluetoothAlwaysUsageDescription
├─ Extensions/
│  ├─ Widgets/               Interactive widgets (toggle, scene) + Control Center controls (iOS 18)
│  ├─ Intents/               App Intents (Siri/Shortcuts); HomeKit intents use ForegroundContinuableIntent
│  └─ MatterSetup/           MatterSupport extension (phase 3)
├─ Packages/
│  ├─ LightCore/             Domain model, LightProvider protocol, registry, store, ColorMath, Keychain, logging
│  ├─ NetKit/                UDP unicast/broadcast (BSD sockets + entitlement detection), /24 sweep,
│  │                         Bonjour browser, SSE client, custom TLS trust evaluator, HTTP helpers
│  ├─ Onboarding/            BrandGuide model + all brand guide definitions (content, not UI)
│  ├─ Providers/
│  │  ├─ HueKit/             HueCodec (CLIP v2 models, SSE parsing, HueStream frames) + HueProvider
│  │  ├─ WiZKit/             WiZCodec (JSON, HMAC signing, moduleName decoding, scenes) + WiZProvider
│  │  ├─ AiDotKit/           AiDotCodec (RSA login, AES-ECB frames, discovery) + AiDotProvider
│  │  ├─ HomeKitProvider/    HMHomeManager mapping (no codec)
│  │  ├─ LIFXKit, NanoleafKit, GoveeKit, YeelightKit, ElgatoKit, ShellyKit, WLEDKit, MagicHomeKit,
│  │  │  TPLinkKit, TuyaKit, MerossKit, SwitchBotKit, TwinklyKit, DirigeraKit, HomeAssistantKit
│  └─ Simulators/            Fake devices per protocol (UDP/TCP/HTTP servers) for tests + UI previews
├─ tools/
│  ├─ probe/                 Node scripts to hit real devices on the LAN from the Windows PC (HIL checks)
│  └─ ci/                    fastlane / xcodebuild scripts, TestFlight upload
└─ docs/, research/, agents/
```

### 4.1 Unified domain model (LightCore)

```swift
enum ColorMode: String, Codable { case onOff, brightness, colorTemp, hs, rgb, rgbw, rgbww, xy, white }

struct LightCapabilities: Codable {
  var supportedColorModes: Set<ColorMode>
  var minKelvin: Int?, maxKelvin: Int?
  var supportsTransition: Bool, supportsEffects: Bool
  var effects: [EffectDescriptor]           // vendor effects/scenes exposed as named effects
  var gamut: Gamut?                         // Hue gamut A/B/C for xy conversions
}

struct LightState: Codable, Equatable {
  var isOn: Bool
  var brightness: Double?                   // 0...1
  var colorMode: ColorMode?
  var kelvin: Int?
  var hs: (h: Double, s: Double)?           // 0..360, 0..1  (store as struct for Codable)
  var rgb: RGB?, rgbw: RGBW?, rgbww: RGBWW?, xy: XY?
  var effect: String?
  var reachable: Bool
  var updatedAt: Date
}

struct Light: Identifiable, Codable {
  var id: LightID          // "<brand>:<stable-id>"  e.g. "wiz:a8bb5006033d", "hue:<uuid>"
  var brand: Brand
  var name: String
  var roomHint: String?
  var capabilities: LightCapabilities
  var state: LightState
  var providerRef: String  // provider-specific handle (bridge id + resource id, IP cache, etc.)
}

struct LightCommand {        // exactly one colour attribute per command, provider converts the rest
  var on: Bool?
  var brightness: Double?
  var color: ColorAttribute? // .kelvin / .hs / .rgb / .rgbw / .xy
  var effect: String?
  var transition: Duration?
}

protocol LightProvider: Actor {
  static var brand: Brand { get }
  var account: ProviderAccount? { get }               // credentials/keys, Keychain-backed
  func discover(options: DiscoveryOptions) -> AsyncStream<DiscoveredDevice>
  func pair(_ device: DiscoveredDevice, using ui: PairingInteraction) async throws -> PairedDevice
  func loadLights() async throws -> [Light]
  func send(_ command: LightCommand, to light: LightID) async throws
  func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws   // default: fan-out
  var events: AsyncStream<ProviderEvent> { get }      // state changes, reachability, errors
  func scenes() async throws -> [Scene]               // vendor scenes if any
  func recall(_ scene: Scene.ID) async throws
}
```

Rules: providers normalise colour (ColorMath) so that the light receives one attribute it supports. Brightness and colour go in one wire command where the protocol allows (WiZ, Hue, AiDot all do) to avoid flashes. Rate limits live in the provider (Hue 10/s per light, 1/s per group; Yeelight 60/min; WiZ serialised per bulb).

### 4.2 Cross-brand features (App layer)

- **Rooms** (user-defined, any brand), **Groups** (fan-out with per-provider group optimisation: Hue `grouped_light`, LIFX group), **Scenes** (app-level snapshot of states across brands; plus vendor scenes surfaced per light).
- **Quick actions**: widgets, Control Center controls, App Intents, Siri. All route through the app process for HomeKit.
- **Diagnostics**: in-app log viewer + export (OSLog), network self-test (local network permission state, entitlement present?, subnet, reachability per device). Essential because the developer has no Mac for on-device debugging.

### 4.3 Discovery strategy (NetKit)

1. Bonjour via `NWBrowser` for brands with mDNS (`_hue._tcp`, `_nanoleafapi._tcp`, `_elg._tcp`, `_shelly._tcp`, `_wled._tcp`, `_lifx._udp`, `_miio._udp`, `_lutron._tcp`, `_http._tcp`). All listed in `NSBonjourServices`.
2. UDP broadcast/multicast via BSD sockets **only if** the multicast entitlement is present (detect at runtime via `NWConnection` path `unsatisfiedReason` / EACCES). WiZ 38899, LIFX 56700, Govee 239.255.255.250:4001, AiDot 6666, Magic Home 48899, Twinkly 5555, TP-Link 9999/20002, Yeelight SSDP 1982.
3. **Unicast fallback** (always available): remembered IPs first, then sweep the current /24 with brand-specific unicast probes (WiZ `getPilot`, LIFX `GetService`, Govee scan, AiDot discovery datagram), rate-limited, with ARP/hostname hints where available.
4. Manual IP entry in every brand wizard.
5. Hue also uses `https://discovery.meethue.com/` (poll at most once per minute).

### 4.4 Security

- Hue TLS: custom `URLSessionDelegate` trusting both Signify roots (v2 bridge + Bridge Pro), leaf CN must equal bridge id; accept legacy self-signed cert whose CN == bridge id (TOFU, pinned per bridge).
- All keys/tokens in Keychain, shared via access group with extensions.
- Cloud credentials (AiDot, TP-Link, Meross, Govee key, LIFX token, SwitchBot token) stored only in Keychain; never logged.
- Photosensitivity warning before any strobe/fast-effect feature (Hue terms require it).

---

## 5. Build and test workflow (no Mac on the dev machine)

The developer machine is Windows 11 with git, gh, Node 24 and Docker; no Swift, no Xcode. Agents must work as follows:

1. **Codec packages** (pure Swift) are tested locally in a Linux Swift container: `docker run --rm -v "$PWD":/src -w /src/Packages/Providers/WiZKit swift:6.1 swift test`. Every codec package must build with `swift build` on Linux. Guard Apple-only code with `#if canImport(Network)` etc.
2. **App, transports, UI** are built and unit-tested on **GitHub Actions macOS runners** (`macos-26`, Xcode 27) on every push; `tools/ci/` holds the scripts. Alternative: Xcode Cloud (25 free hours/month with the dev program). Agents read CI logs with `gh run view --log`.
3. **TestFlight** uploads from CI with an App Store Connect API key (fastlane `pilot` or `xcrun altool`). The user installs on iPhone and reports via the in-app diagnostics export.
4. **Hardware-in-the-loop from Windows**: `tools/probe/*.mjs` Node scripts (Node has full LAN access incl. UDP broadcast on Windows) to validate protocol assumptions against the user's real Hue bridge, WiZ and AiDot bulbs before porting to Swift. Agents run these with the user's consent; they only read state or toggle a named test bulb.
5. **Simulators** make UI previews and provider tests deterministic without hardware.

A Mac (even a used Mac mini) or a cloud Mac (MacStadium, AWS EC2 Mac) would make on-device debugging far easier; flagged as a user decision in section 8, not a blocker.

---

## 6. Phases and brand priority

### Phase 0: Foundations (agents + user setup)
Repo, package skeleton, CI, Linux codec test loop, TestFlight pipeline, Info.plist privacy keys, multicast entitlement request, Hue developer registration, LightCore model + ColorMath + Keychain + store, Simulators harness, Onboarding engine (empty guides), Diagnostics screen.

### Phase 1: The user's own gear (MVP)
| Provider | Path | Key work |
|---|---|---|
| **Hue** | CLIP v2 + SSE, link-button pairing | TLS trust (two roots + TOFU), discovery (Bonjour, cloud broker, manual), lights/rooms/zones/grouped_light/scenes, event stream with keepalive + reconnect, rate limiting |
| **WiZ** | UDP 38899/38900 | Discovery (broadcast or sweep), `getPilot/setPilot/getSystemConfig/getModelConfig`, moduleName capability decoding, scene table, **HMAC signing + key import**, push registration on foreground |
| **AiDot** | Cloud login then LAN | RSA login + token refresh/reauth, device/product list, UDP 6666 discovery, TCP 10000 AES frames, loginReq/setDevAttrReq/getDevAttrReq/ping, RGBW packing, owner-account check |
| **HomeKit** | `HMHomeManager` | Map accessories/services/characteristics to `Light`; write coalescing; covers all Matter SKUs the user adds to Apple Home |
| **App** | | Rooms/lights list, light detail (on/off, brightness, colour wheel, temp slider, effects), app scenes, onboarding wizard for the four providers, settings, diagnostics, TestFlight build |

Exit criteria: user controls every light they own from the app on home Wi-Fi; state stays in sync when changed from vendor apps (Hue SSE, WiZ push, AiDot push, HomeKit notifications).

### Phase 2: Common local-API brands + system integration
LIFX (binary UDP 56700, official `swift-lifx-protocol` codec), Nanoleaf panels (REST 16021, button pairing), Govee (LAN UDP 4001/4002/4003 + Developer API key), Yeelight (TCP 55443, SSDP), Elgato (HTTP 9123), Shelly (RPC), WLED (JSON HTTP), Magic Home (TCP 5577), TP-Link Kasa/Tapo (KLAP with cloud creds). Widgets, Control Center controls, App Intents/Siri, cross-brand groups and scene transitions, Apple Watch (optional).

### Phase 3: Hard or niche
Tuya local (tinytuya port; cloud QR login optional), Meross (cloud key + local HTTP), SwitchBot (cloud API + BLE), Twinkly, IKEA Dirigera (REST + token), Home Assistant provider (WebSocket, `HAKit`), own-fabric Matter commissioning via MatterSupport, Hue Entertainment streaming (DTLS-PSK), Hue Bluetooth bulbs (CoreBluetooth).

### Explicitly not planned
GE Cync local (DNS hijack), Wyze and Sengled Wi-Fi (unofficial cloud only; use their Matter SKUs via HomeKit), Amazon Basics, Eufy Lumos, Trådfri gateway (CoAP/DTLS), Lutron LEAP (bridge is native HomeKit, use that), Hue bridge rooting.

---

## 7. Onboarding ("Add a brand") requirement

Every provider ships a `BrandGuide` consumed by the wizard engine. See `docs/ONBOARDING-WALKTHROUGHS.md` for the content of each guide and `agents/TASKS.md` T1.8 for the engine. Common structure:

1. **Before you start** (vendor app set up, 2.4 GHz, same Wi-Fi, account/owner, hub present).
2. **Vendor-app / device steps** (toggles to flip, keys to export, buttons to press), with exact menu paths (marked "verify on device" where research could not confirm wording).
3. **In this app** (scan, press link button, paste key, log in, enter IP), driven by `PairingInteraction` prompts from the provider.
4. **Verify** (blink the light, show state).
5. **Troubleshooting** (local network permission, client isolation/VLAN, bulb off at wall, IP changed, token expired).
6. **Alternative path** (Matter into Apple Home, then HomeKit provider) where the SKU supports it.

The guide engine must support: info step, checklist step, action step with a provider callback (e.g. "Press the bridge button, then tap Continue"), secure text entry, QR/JSON import, open-vendor-app deep link where known, and a per-step "It didn't work" expander.

---

## 7b. Voice assistants ("Hey Siri", "Hey Google", "Alexa")

Requirement added 2026-10-26: voice control baked in.

| Assistant | How it can reach our lights | Plan |
|---|---|---|
| **Siri** | App Intents + Shortcuts run in-app with no cloud ("Hey Siri, turn on the kitchen lights in SmartLights", plus custom phrases via App Shortcuts). HomeKit lights also get Siri natively through Apple Home. | **Phase 1 (T1.10)**: App Intents for toggle light/room, set brightness, set colour/temperature, recall scene; `AppShortcutsProvider` phrases; entity queries so Siri can resolve light and room names; HomeKit-backed lights route through the app process. |
| **Google Assistant / Google Home** | Cannot invoke an iPhone app. Needs a Google Smart Home Action: OAuth account linking + a hosted fulfillment webhook (SYNC/QUERY/EXECUTE), or the Local Home SDK on a Google speaker. | Three routes, user picks: (a) keep each vendor's existing Google link (works today for Hue, WiZ, AiDot, LIFX, Govee, TP-Link...); (b) Home Assistant + Nabu Casa Cloud exposes every light to Google and Alexa with no code (fits the phase 3 HA provider); (c) **T3.11**: our own cloud bridge (Google Action + Alexa Smart Home Skill, OAuth server, device relay) — requires hosting and a relay from the home network since the phone is not always on. |
| **Alexa** | Same constraint: Alexa Smart Home Skill with account linking and a Lambda/webhook. | Same three routes as Google. |

Decision D11: Siri is native and in phase 1. Google/Alexa default to routes (a) now and (b) when the HA provider lands; route (c) is scoped in T3.11 and only built if the user wants a server-free, single-app experience badly enough to run a cloud service.

## 8. What only the user can do (prerequisites)

1. Enrol in the Apple Developer Program ($99/yr) and create an App Store Connect API key for CI.
2. Decide on Mac access: none (CI + TestFlight only), cloud Mac, or a physical Mac. Default assumption: none.
3. Create the GitHub repo (private is fine; macOS CI minutes cost 10x on private repos, so budget or make it public).
4. Register at developers.meethue.com (free) and download the two Signify root CA PEMs and the HTTPS/Entertainment pages; the docs are login-gated.
5. In the WiZ app: Settings > Security: check the control mode. Export the Local-integrations key (Home settings > Integrations > Local integrations) if available. Report the firmware version of one bulb.
6. AiDot: confirm which account is the **owner** of the home, and the country selected in the app. Note the model numbers of the bulbs (Matter logo or not).
7. List every light model owned (brand, model, Matter logo yes/no, already in Apple Home yes/no). This decides HomeKit-vs-native per device.
8. Approve hardware-in-the-loop probes from the Windows PC (the scripts only read state and toggle a designated test bulb).

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Multicast entitlement denied or delayed | Unicast sweep + manual IP shipped from day one; HomeKit path needs no entitlement |
| WiZ signing key export unavailable in user's app version | "Allow all controls" fallback documented in the guide; both paths implemented |
| AiDot cloud token invalidation (second login kills first) | Dedicated reauth flow; advise user to avoid logging into AiDot app on another device with the same account, or create a second owner account |
| Hue cert changes again | Trust evaluation keeps roots in a data file; TOFU by bridge id; diagnostics show the cert chain |
| No Mac: on-device bugs hard to see | Diagnostics screen with log export; simulators; CI unit tests; probe scripts validate protocols before Swift |
| iOS 26/27 regressions in NWConnection broadcast | BSD sockets for broadcast (Apple's own advice) |
| Scope creep across 20+ brands | Phase gates; each brand is its own package and task with acceptance criteria |

---

## 10. References

- `research/research_hue.md`, `research_wiz.md`, `research_aidot.md`: protocol detail with sources.
- `research/research_brands.md`: every other brand, tiers, difficulty.
- `research/research_existing_projects.md`: libraries to port, apps to study.
- `research/research_ios_platform.md`: entitlements, HomeKit, Matter, background, TLS, distribution, Hue bridge modding.
- `research/research_onboarding.md`: per-brand user steps, mDNS/DHCP matchers, HA wizard copy.
- `docs/BRAND-RUNDOWN.md`: the condensed brand table.
- `docs/ONBOARDING-WALKTHROUGHS.md`: the user-facing walkthrough content per brand.
- `agents/TASKS.md`: the work breakdown.
