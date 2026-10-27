# Work breakdown for implementing agents

Read `CLAUDE.md` and `PLAN.md` first. Each task lists owner scope (files), inputs, acceptance criteria, and the research to read. Tasks inside a phase marked ∥ can run in parallel; others depend on the listed prerequisites. Keep every task's output in its own package or folder to avoid merge conflicts.

Conventions: Swift 6 strict concurrency, `actor` providers, `AsyncStream` for events, `OSLog` with per-package subsystems, `swift-format` config at repo root, tests with Swift Testing (`import Testing`). Codec packages must compile on Linux (`swift:6.1` container) with no Apple frameworks.

---

## Phase 0: Foundations

### T0.1 Repository and project skeleton
- Create the GitHub repo (`gh repo create`), `.gitignore` (Xcode, SwiftPM, DerivedData), `Package.swift` workspace layout per `PLAN.md` §4, app target `SmartLights` (iOS 18, SwiftUI), bundle id placeholder `com.sinap.smartlights`, `App/Resources/Info.plist` with `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_hue._tcp`, `_nanoleafapi._tcp`, `_elg._tcp`, `_shelly._tcp`, `_wled._tcp`, `_lifx._udp`, `_miio._udp`, `_lutron._tcp`, `_http._tcp`, `_matter._tcp`, `_matterc._udp`, `_matterd._udp`), `NSHomeKitUsageDescription`, `NSBluetoothAlwaysUsageDescription`. Entitlements file with HomeKit, Keychain access group, App Groups; multicast entitlement key present but gated (CI must build without it until Apple grants it).
- Decide project generation: prefer a plain `.xcodeproj` committed, or XcodeGen/Tuist if it keeps diffs reviewable. Document in `docs/BUILD.md`.
- Accept: `swift build` of `Packages/LightCore` succeeds in the Linux container; macOS CI builds the app for the simulator.

### T0.2 CI and TestFlight pipeline ∥
- `.github/workflows/ios.yml`: on push/PR, `macos-26` runner, Xcode 27, cache SwiftPM, `xcodebuild test` for all packages + app (simulator), upload `xcresult`. Separate `linux-codecs.yml`: `swift:6.1` container runs `swift test` for every codec package.
- `tools/ci/testflight.sh` + workflow on tag: archive, export with App Store Connect API key from secrets, upload with `xcrun altool`/fastlane pilot. Document secrets needed in `docs/BUILD.md` (user supplies).
- Accept: green CI on an empty app; a tagged build reaches TestFlight once the user adds secrets.

### T0.3 LightCore domain model ∥
- Implement `PLAN.md` §4.1 types: `Brand`, `ColorMode`, `LightCapabilities`, `LightState`, `Light`, `LightID`, `LightCommand`, `Scene`, `DiscoveredDevice`, `PairedDevice`, `ProviderAccount`, `PairingInteraction` (async prompts: `confirm(message)`, `secureText(prompt)`, `text(prompt)`, `importFile`), `ProviderEvent`, `LightProvider` protocol, `ProviderRegistry`, `DeviceStore` (SwiftData on Apple, JSON file on Linux behind a protocol), `SecretStore` (Keychain on Apple, in-memory on Linux), `ColorMath` (RGB↔HSV↔CIE xy with gamut clamp, Kelvin↔mired, RGBW/RGBWW split, brightness scaling), `RateLimiter` (token bucket per key), `Log`.
- Port `ColorMath` and the `DeviceService` ideas from `0xProbabillity/house-control` (MIT; keep attribution in `THIRD_PARTY_NOTICES.md`).
- Accept: 100% Linux-testable; unit tests for ColorMath against known Hue gamut values and HA `color_util` reference vectors; tests for LightCommand normalisation ("one colour attribute per command").

### T0.4 NetKit ∥
- `UDPSocket` (BSD sockets: per-interface bind with `IP_BOUND_IF`, `SO_BROADCAST`, `SO_REUSEPORT`, async send/receive), `UDPUnicast` via `NWConnection`, `BroadcastCapability` detector (try a broadcast send; map EACCES / `localNetworkDenied`), `SubnetSweeper` (enumerate current IPv4 /24 from `getifaddrs`, concurrency-limited probes), `BonjourBrowser` (`NWBrowser` wrapper → AsyncStream), `SSEClient` (`URLSession.bytes` → events with `id`/`data`, last-event-id, reconnect backoff), `TrustEvaluator` (custom anchors + CN check + TOFU pin store), `HTTPClient` helpers, `LocalNetworkPermission` probe (TN3179 trick).
- Accept: unit tests for SSE parser and subnet enumeration (Linux-safe parts); macOS CI compiles the rest; a `NetKitDemo` CLI target on macOS that lists Bonjour services.

### T0.5 Simulators harness ∥
- `Packages/Simulators`: `FakeWiZBulb` (UDP 38899/38900 JSON server mirroring pywizlight `fake_bulb.py`, incl. signing mode), `FakeHueBridge` (HTTPS CLIP v2 subset + SSE + pairing with link-button flag; self-signed cert with CN = fake bridge id), `FakeAiDotDevice` (UDP 6666 discovery + TCP 10000 AES frames) + a stub cloud (`/users/loginWithFreeVerification`, `/houses`, `/devices`), extensible for later brands. Runs on macOS and Linux (SwiftNIO or Foundation sockets).
- Accept: each provider's integration tests run against its simulator in CI.

### T0.6 Onboarding engine ∥
- `Packages/Onboarding`: `BrandGuide` model (`steps: [GuideStep]`, step kinds per `docs/ONBOARDING-WALKTHROUGHS.md`), markdown-ish rich text, `verify` flags surfaced as a "please confirm wording" badge in debug builds, troubleshooting expanders, link-outs. SwiftUI `GuideFlowView` in the app renders any guide and drives `PairingInteraction` prompts from the provider.
- Accept: a snapshot test renders the generic Apple-side guide (§0) and a dummy brand guide.

### T0.7 Diagnostics ∥
- Settings > Diagnostics: local-network permission state, multicast entitlement present/working, Wi-Fi subnet, Bonjour browse results, per-device last-seen/latency/error, OSLog export (share sheet), "send test command" per device. Redact secrets.
- Accept: exportable log bundle from TestFlight builds.

### T0.8 Hardware probes (Node) ∥
- `tools/probe/wiz.mjs` (broadcast registration, getPilot, getSystemConfig, getModelConfig, signed setPilot test with key from env), `hue.mjs` (discovery.meethue.com + mDNS, pairing, CLIP v2 list, SSE tail, cert chain dump), `aidot.mjs` (login, houses, devices, UDP discovery, TCP login + getDevAttrReq, optional toggle of `TEST_DEVICE`). Read-only by default; writes only to a device named in env `TEST_DEVICE`.
- Accept: scripts run from the user's Windows PC with Node 24; output saved to `tools/probe/out/` (gitignored) and summarised in `docs/HARDWARE-NOTES.md` (firmware versions, moduleNames, cert issuer, AiDot model ids).

---

## Phase 1: MVP for the user's gear

### T1.1 HueKit (depends T0.3, T0.4, T0.5)
- `HueCodec`: Codable models for CLIP v2 resources used (`light`, `grouped_light`, `room`, `zone`, `scene`, `device`, `bridge`, `zigbee_connectivity`, `entertainment_configuration`), partial-update merge for SSE events, request bodies (`on`, `dimming`, `color.xy`, `color_temperature.mirek`, `dynamics.duration`, `effects`, scene `recall`), gamut handling, error mapping (101 link button, 403, 429/503). Optionally generate from `openhue-api` OpenAPI spec; hand-write if generation is noisy.
- `HueProvider`: discovery (Bonjour `_hue._tcp`, `https://discovery.meethue.com/` ≤1/min, manual), `GET /api/config` bridge id probe, pairing `POST /api {devicetype:"SmartLights#iphone", generateclientkey:true}`, Keychain storage of app key + client key, TLS trust (both Signify roots from `Resources/hue-roots.pem`, CN == bridge id; TOFU for self-signed), CLIP v2 client with 3-connection limit and 10/s per light, 1/s per grouped_light token buckets, SSE event stream with 90 s read timeout, keepalive via renaming a `geofence_client`, reconnect with backoff and full resync after >60 s gap, mapping to `Light`/`Scene`/rooms.
- Accept: integration tests against `FakeHueBridge`; manual test plan in `docs/TESTPLAN.md`; user confirms on real bridge: pair, list, toggle, colour, scene recall, external change appears within 1 s.
- Read: `research/research_hue.md` §1, §5, §6, §9.

### T1.2 WiZKit (depends T0.3, T0.4, T0.5)
- `WiZCodec`: request/response Codable (`getPilot`, `setPilot`, `setState`, `getSystemConfig`, `getModelConfig`, `getUserConfig`, `registration`, `syncPilot`, `firstBeat`), error codes (-32601, -32602 with `sigTs`, -32605), **HMAC-SHA256 signing** (compact JSON of `params` incl. `sigTs`, 16-byte key from 32-hex, base64), `moduleName` capability decoder (RGB/TW/DW/SOCKET/FANDIM/DH/SH), `cctRange` from `getModelConfig`, scene table (ids 1-36, 40, 256-265, 1000 with TW/DW subsets), RGB/temp mode exclusivity, dimming clamp 10-100.
- `WiZProvider`: discovery (broadcast `registration register:false` if entitlement, else sweep with `getPilot`), key by MAC with IP cache, per-bulb serialised requests with retry schedule (0.75/1.5/3/3/3 s), push: listen on 38900, `registration register:true` every 20 s while foregrounded, fall back to polling; signing key import (JSON or hex) via `PairingInteraction`; combined brightness+colour in one `setPilot`.
- Accept: codec tests on Linux incl. signing vectors from pywizlight PR #216; integration against `FakeWiZBulb` in both modes; user confirms on real bulbs incl. a 1.34+ bulb.
- Read: `research/research_wiz.md` §1, §7, §8.

### T1.3 AiDotKit (depends T0.3, T0.4, T0.5)
- `AiDotCodec`: RSA PKCS#1 v1.5 password encryption with the public key from `python-aidot/login_const.py` (use `swift-crypto`/`_CryptoExtras` so it builds on Linux), login/refresh/houses/devices/products models, country→region map, discovery datagram (AES-256-ECB, fixed key `T54uednca587` zero-padded, PKCS7), TCP frame (`0x1EED`, msgtype, u32 length) + AES-128-ECB body with `aesKey[0]`, `loginReq`/`setDevAttrReq`/`getDevAttrReq`/`pingreq` builders, `ascNumber` tracking, RGBW int32 packing, error codes 21026/21025/560080.
- `AiDotProvider`: login via `PairingInteraction` (country, username, password), token persistence + refresh + reauth event, house filter `isOwner`, device list with 6 h refresh, UDP 6666 broadcast discovery if entitled else unicast probe/sweep + cached IPs + manual IP, one TCP session per device with 30 s ping (10 s `getDevAttrReq` for `lk.WIFI-RGBWLight-D0006`), status push parsing, capability mapping (OnOff/Dimming/CCT/RGBW).
- Accept: Linux codec tests with vectors generated from python-aidot (agents may run python-aidot in a Docker `python:3.12` container to produce fixtures); integration against `FakeAiDotDevice`; user confirms on real bulbs.
- Read: `research/research_aidot.md` §2, §8.

### T1.4 HomeKitProvider (depends T0.3)
- `HMHomeManager` lifecycle, authorization status, map `HMAccessory`/`HMService` (lightbulb) with characteristics power/brightness/hue/saturation/colour temperature into `Light` + capabilities; `enableNotification` for live updates; write coalescing; room names from `HMRoom`; reachability. Expose Matter-backed accessories identically. Mark `Light.brand = .appleHome(vendor: accessory.manufacturer)`.
- Accept: compiles and unit tests with protocol-abstracted HomeKit wrappers; user confirms with any Apple Home light.
- Read: `research/research_ios_platform.md` A2.

### T1.5 App shell and light control UI ∥ (depends T0.3)
- Tabs: Lights (by room, all brands mixed), Scenes, Add (wizard), Settings. Light detail: on/off, brightness slider, colour wheel (HS) with gamut awareness, temperature slider (Kelvin, clamped to capabilities), effects/vendor scenes list, transition picker. Group actions per room. Optimistic UI with reconciliation from provider events. Drag-coalescing to respect rate limits (send ≤10/s).
- Accept: previews against simulators; accessibility labels; works offline from cloud.

### T1.6 Provider registry, store, secrets wiring (depends T0.3, T1.1-T1.4)
- Register providers, persist paired devices/accounts, restore on launch, reconcile discovery with stored ids, background/foreground handling (re-register WiZ push, reconnect Hue SSE, reopen AiDot TCP), per-provider health in Diagnostics.

### T1.7 Brand guides for phase-1 providers (depends T0.6)
- Encode `docs/ONBOARDING-WALKTHROUGHS.md` §0-§4 as `BrandGuide`s; wire provider `PairingInteraction` prompts (Hue link button confirm, WiZ key import, AiDot login form, HomeKit permission).
- Accept: end-to-end add flow for each provider against simulators; copy marked `[verify]` shows a debug badge.

### T1.8 App scenes (depends T1.5, T1.6)
- Snapshot current state of selected lights across brands into an app scene; recall with per-provider optimised writes (Hue grouped_light where a whole room, WiZ back-to-back datagrams).

### T1.10 Siri and Shortcuts (depends T1.5, T1.6)
- App Intents: `ToggleLightIntent`, `SetBrightnessIntent`, `SetColorIntent`, `SetColorTemperatureIntent`, `RecallSceneIntent`, `SetRoomIntent`; `AppEntity` + `EntityQuery` for lights, rooms and scenes so Siri resolves names ("Hey Siri, set the lamp to 30% in SmartLights"); `AppShortcutsProvider` with natural phrases; `ForegroundContinuableIntent` for HomeKit-backed lights; intents run against cached device IPs with a fast unicast path (no discovery). Explain in Settings how to say the phrases and how Apple Home lights also respond to plain Siri.
- Accept: intents appear in Shortcuts; Siri executes toggle and brightness against the simulators; CI builds the intents extension.

### T1.9 Phase-1 release
- TestFlight build; `docs/TESTPLAN.md` executed by the user with the diagnostics export; fix list; tag `v0.1`.

---

## Phase 2: Common brands + system integration (all ∥ after phase 1)

- **T2.1 LIFXKit**: wrap `LIFX/swift-lifx-protocol` codec (or regenerate from `LIFX/public-protocol` YAML), UDP 56700 discovery (broadcast/mDNS/sweep), `SetColor`/`SetPower`/`SetWaveform`, HSBK mapping, multizone/extended multizone for strips, optional cloud token provider.
- **T2.2 NanoleafKit**: REST 16021, `POST /api/v1/new` pairing with 30 s window UI, state/effects, SSE events (`/events?id=1,2,3,4`), mDNS `_nanoleafapi._tcp`.
- **T2.3 GoveeKit**: LAN (multicast scan, `turn`/`brightness`/`colorwc`/`devStatus`), Developer API with key (`/user/devices`, `/device/control` capabilities), rate limits, model allow-list for LAN.
- **T2.4 YeelightKit**: TCP 55443 JSON, SSDP 1982 discovery, `set_power`/`set_bright`/`set_rgb`/`set_ct_abx`/`set_hsv`, notifications, 60/min limiter; evaluate reusing `ahmetcanaltun/YeelightKit`.
- **T2.5 ElgatoKit, ShellyKit, WLEDKit, MagicHomeKit**: small HTTP/TCP providers per `docs/BRAND-RUNDOWN.md`.
- **T2.6 TPLinkKit**: legacy XOR protocol + KLAP handshake (port from python-kasa / `tapo` crate), credentials via PairingInteraction, discovery 9999/20002.
- **T2.7 Widgets, Controls, App Intents**: interactive widget (toggle light/room, recall scene), iOS 18 Control Center/Lock Screen controls, Siri/Shortcuts intents; HomeKit-backed intents use `ForegroundContinuableIntent`; extensions share Keychain/App Group and use cached IPs (no discovery in extensions).
- **T2.8 Cross-brand groups and transitions**; **T2.9 Apple Watch** (optional); **T2.10 guides for all phase-2 brands**.

## Phase 3: Hard or niche (∥)

- **T3.1 TuyaKit** (tinytuya port 3.3/3.5; local key entry; optional cloud QR login if the user registers Tuya developer credentials).
- **T3.2 MerossKit** (implemented (PR): `Packages/Providers/MerossKit`), **T3.3 SwitchBotKit** (cloud + BLE; cloud API implemented (PR): `Packages/Providers/SwitchBotKit`, BLE pending), **T3.4 TwinklyKit**, **T3.5 DirigeraKit**.
- **T3.6 HomeAssistantKit**: WebSocket via `HAKit`, `light.*` entities, `call_service`, long-lived token guide; this is the route for Zigbee/Sengled/Cync/Wyze and automations.
- **T3.7 Matter own fabric**: MatterSupport extension, `MTRDeviceControllerFactory`, iCloud Keychain IPK, Wi-Fi only; guide explains the Thread limitation.
- **T3.8 Hue Entertainment**: DTLS-PSK via NIOTransportServices (see HueEntertainmentKit), HueStream v2 frames, 25-50 Hz, photosensitivity warning.
- **T3.9 Hue BLE**: CoreBluetooth with HueBLE characteristics.
- **T3.11 Google Assistant and Alexa cloud bridge** (only if the user chooses route (c) in `PLAN.md` §7b): design doc first — OAuth 2.0 server, Google Smart Home Action fulfillment (SYNC/QUERY/EXECUTE) and Alexa Smart Home Skill handlers, a device relay from the home (phone cannot be the relay; needs a small always-on service or the HA provider), device/trait mapping from `Light`. Compare with Home Assistant + Nabu Casa before building.
- **T3.10 Remote access**: Hue Remote API (if approved) and cloud fallbacks per brand; otherwise document Tailscale/VPN.

---

## Definition of done (every provider task)
1. Codec package builds and tests on Linux.
2. Provider integration test against its simulator passes in macOS CI.
3. `BrandGuide` exists and the add flow works end-to-end in the app.
4. Diagnostics shows the provider's devices with last-seen and errors.
5. `docs/BRAND-RUNDOWN.md` row updated with "implemented" status and any protocol surprises recorded in `docs/HARDWARE-NOTES.md`.
6. User-confirmed on real hardware where they own it (Hue, WiZ, AiDot in phase 1).
