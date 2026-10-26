# Survey: existing multi-brand smart-light projects (for a Swift iOS app)

Research date: 2026-10-26. Star counts / last-push dates come from the GitHub REST API on that date. App Store facts come from the public listings. Items marked **[uncertain]** could not be verified directly (the session's web-search budget ran out part-way through; GitHub API and direct page fetches still worked).

Target brands: Philips Hue, WiZ, AiDot/Linkind, LIFX, Govee, Nanoleaf, TP-Link (Kasa/Tapo), Tuya/Smart Life.

---

## 0. Executive summary

- **There is no mature open-source Swift iOS app that already unifies Hue + WiZ + LIFX + Govee + Nanoleaf + Tuya.** The closest is **0xProbabillity/house-control** (772 stars, MIT, Swift, pushed 2026-10-24): an iPhone + macOS app with a `DeviceService` provider protocol and working Hue (local), Home Assistant (local), Smart Life/Tuya (cloud) and Apple Home (HomeKit) back-ends. It is the best fork base found.
- Per-brand Swift libraries exist but are mostly small/old: SwiftyHue (84 stars, Hue v1 API, just modernised to 0.6.0 in June 2026), HueKit by ahmedayoub95 (Hue v2 CLIP + WLED, 0 stars, June 2026), LIFXHTTPKit (41), RxLifx-Swift (10, LAN), LIFX/swift-lifx-protocol (official codec), reddavis/Nanoleaf (8), MillerTechnologyPeru/Govee (0, BLE-oriented), ahmetcanaltun/YeelightKit (0, 2026). There is **no Swift WiZ library**, only several tiny macOS menu-bar apps that embed a 100-line UDP client. There is **no Swift Tuya-local library** beyond Tuya's official (cloud, closed-source binary) SDK. There is **no Swift AiDot code at all.**
- The multi-brand *protocol* knowledge lives in Python/TypeScript: Home Assistant core (91.7k stars; has integrations for every brand on the list incl. a new `aidot` integration in HA 2026.6), diyHue (1.8k; emulates a Hue bridge in front of WiZ, Yeelight, Govee, Tasmota, WLED, Shelly, TP-Link Kasa, Elgato, HA, MQTT...), Homebridge plugins (homebridge-hue 924, homebridge-govee 592, homebridge-tplink-smarthome 521, homebridge-tuya 438, homebridge-wiz-lan 136, homebridge-lifx-plugin 44), and pywizlight (559), tinytuya (1.8k), python-aidot.
- **Strategic fork in the road:** (A) write native local-protocol drivers in Swift (ports of pywizlight / LIFX LAN / Govee LAN / Nanoleaf REST / Hue CLIP v2 / tinytuya), or (B) let a hub do the unification (Home Assistant, Homebridge/HAP, diyHue or a Matter bridge) and make the iOS app a thin client of HomeKit / HA WebSocket / Hue API. Most *shipping* multi-brand iOS apps that work reliably (Controller for HomeKit, Luminair 4, house-control's Apple Home mode) use approach B via Apple's HomeKit framework; the "Led Light Controller" subscription apps that claim 20 brands have poor reviews.

---

## 1. Open-source Swift (iOS/macOS) apps and packages

### 1.1 Multi-brand Swift apps

| Project | Stars | Last push | License | Brands / transport | Notes |
|---|---|---|---|---|---|
| [0xProbabillity/house-control](https://github.com/0xProbabillity/house-control) | 772 | 2026-10-24 | MIT | Philips Hue (local bridge, link-button pairing, auto-discovery), Home Assistant (local, long-lived token, auto-discovery), Smart Life/Tuya (cloud, QR login; Swift port of Tuya's `tuya-device-sharing-sdk`; excluded from App Store build), Apple Home/HomeKit (iPhone only) | macOS 13+ menu-bar app + iOS 17+ SwiftUI app (XcodeGen). Shared SwiftPM package `core/` with modules `HouseCore` and `HouseSmartLife`. `HouseCore` contains `DeviceService` protocol (`devices()`, `read(ids)`, `send(kind:id:patch:state:)`, `watch`, `disconnect`), `DeviceHub`, `HueService`, `HomeAssistantService`, `HomeKitService`, `HomeKitMapper`, `ColorMath` (hex/HSV/xy/mired conversions), `ServiceDiscovery`, `SecretStore`, Bonjour+TLS Mac-iPhone sync, lab simulators for HA/Hue/HomeKit. Lights + ACs only. 3D Three.js floor plan UI. **Best existing Swift fork base.** |
| [SeanPVera/LumenDesk](https://github.com/SeanPVera/LumenDesk) | 1 | 2026-10-26 | MIT | LIFX + Govee | macOS only, brand new, tiny. Worth reading for Govee LAN in Swift. |
| [hugoinformatique/LampControl](https://github.com/hugoinformatique/LampControl) / [lampcontrol.app](https://lampcontrol.app/en/) | 1 | 2026-08-06 | MIT (repo) | Hue, LIFX, Govee, Yeelight, Tuya/Smart Life (also Ledvance/Sylvania via Tuya), Nanoleaf, WiZ | macOS 13+ menu-bar app, native Swift; free up to 2 lights, EUR 5.99 lifetime. **[uncertain]** whether the GitHub repo contains the full source or only releases; the website does not say which brands are local vs cloud. |
| [pkivolowitz/lifx-provision](https://github.com/pkivolowitz/lifx-provision) | 4 | 2026-03-19 | MIT | LIFX | macOS CLI + iOS app for bulk WiFi provisioning. |
| [JoKeks2023/smartlightsMac](https://github.com/JoKeks2023/smartlightsMac) | 3 | 2026-09-18 | MIT | Govee | macOS. |
| [wreyniers/lightsync](https://github.com/wreyniers/lightsync) | 0 | 2026-10-21 | none | Elgato, Govee, Hue, LIFX | TypeScript desktop (not Swift) — listed for protocol reference. |

### 1.2 Per-brand Swift libraries

**Philips Hue**

| Project | Stars | Last push | License | API | Notes |
|---|---|---|---|---|---|
| [Spriter/SwiftyHue](https://github.com/Spriter/SwiftyHue) | 84 | 2026-06-17 (v0.6.0) | MIT | Hue API **v1** (legacy CLIP) over HTTPS | 0.6.0 modernised it: HTTPS, Bridge Pro self-signed cert handling, `discovery.meethue.com`, Alamofire 5, removed Gloss. CocoaPods + Carthage only, **no Package.swift**. BridgeFinder, BridgeAuthenticator (push-link), lights/groups/scenes/schedules/sensors heartbeats. Depends on Alamofire + CocoaAsyncSocket. Usable but dated architecture (delegates, NotificationCenter). |
| [ahmedayoub95/HueKit](https://github.com/ahmedayoub95/HueKit) | 0 | 2026-07-22 (created 2026-06-16) | MIT | Hue **CLIP v2** + WLED | SPM, Swift 5.9, iOS 15+. async/await; cloud discovery or direct IP; link-button pairing; light control; SSE eventstream; `UnifiedLightController` fans out to multiple vendors. Grouped lights/rooms/scenes still on roadmap, no releases yet. Small but the only v2-native Swift client found. |
| [jnewc/Hue](https://github.com/jnewc/Hue) | 16 | 2020-02-16 | Apache-2.0 | v1 | Combine-based; abandoned. |
| [jurre/huebar](https://github.com/jurre/huebar) | 39 | 2026-08-13 | MIT | v1/v2? **[uncertain]** | macOS menubar app, active; readable example of a modern Swift Hue client. |
| [davier26/HuueyRemote](https://github.com/davier26/HuueyRemote) | 18 | 2015 | none | v1 | dead. |
| (zenangst/Hue, louisdh/huekit, 3.5k/216 stars) | — | — | — | — | **Not smart-light libraries** — colour utilities. Ignore. |

**LIFX**

| Project | Stars | Last push | License | Transport | Notes |
|---|---|---|---|---|---|
| [LIFX/swift-lifx-protocol](https://github.com/LIFX/swift-lifx-protocol) | 4 | 2021-07-30 | none stated | LAN binary codec | Official LIFX Swift implementation of the binary protocol: serialises/deserialises all message types (`Messages.read(data:)`). SPM + CocoaPods. No sockets/discovery — you add UDP. Generated from [LIFX/public-protocol](https://github.com/LIFX/public-protocol) (18 stars, pushed 2026-09-10, machine-readable YAML of the LAN protocol). Docs: https://lan.developer.lifx.com (UDP, packed binary; bound by LIFX Developer Terms). |
| [tatey/LIFXHTTPKit](https://github.com/tatey/LIFXHTTPKit) | 41 | 2021-01-11 | MIT | HTTP cloud API | iOS/watchOS/macOS, no deps. Cloud only (needs LIFX token). |
| [tatey/Lighting](https://github.com/tatey/Lighting) | 109 | 2019 | GPL-3.0 | HTTP cloud | Mac widget using LIFXHTTPKit. |
| [flowsprenger/RxLifx-Swift](https://github.com/flowsprenger/RxLifx-Swift) | 10 | 2021-06-23 | MIT | LAN UDP | RxSwift; full LAN SDK incl. discovery. |
| [dclelland/LIFXClient](https://github.com/dclelland/LIFXClient) | 10 | 2019 | MIT | LAN UDP | + companion iOS app [dclelland/3LED](https://github.com/dclelland/3LED) (7). |
| [PSchmiedmayer/Swift-NIO-LIFX](https://github.com/PSchmiedmayer/Swift-NIO-LIFX) | 3 | 2021 | MIT | LAN (SwiftNIO) | |
| [glennschmidt/swift-lifx](https://github.com/glennschmidt/swift-lifx), [frajaona/LiFXSwiftKit](https://github.com/frajaona/LiFXSwiftKit) | 3 / 4 | 2020 / 2017 | none / Apache-2.0 | LAN | |

**WiZ** — no library; only app-embedded clients (protocol: JSON over UDP 38899, `getPilot`/`setPilot`, registration/discovery reply on 38900; "Allow Local Communication" must be on in the WiZ app).

| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [rryuliu/WizLightControl](https://github.com/rryuliu/WizLightControl) | 20 | 2023-09-20 | none | Mac menubar. |
| [ENez7/ligthswitch](https://github.com/ENez7/ligthswitch) | 3 | 2026-02-18 | MIT | macOS, pure SwiftUI + raw UDP; auto-discovery, power/brightness/colour, online monitoring. Cleanest small Swift WiZ reference. |
| [MegaManSec/wiz-light-controller](https://github.com/MegaManSec/wiz-light-controller) | 2 | 2026-06-10 | GPL-3.0 | macOS menubar + CLI with a shared "engine"; repo is a pnpm monorepo (TS + Swift) — **[uncertain]** how much is Swift. GPL. |
| [bettersandeep/lumo](https://github.com/bettersandeep/lumo), [arshzip/wizard](https://github.com/arshzip/wizard), [idlivada/wiz-mac-control](https://github.com/idlivada/wiz-mac-control), [Smugcurve13/wiz-mac-control](https://github.com/Smugcurve13/wiz-mac-control) (Network.framework + WidgetKit + App Intents), [subh-chaturvedi/Wiz-SmartBulb-Controller](https://github.com/subh-chaturvedi/Wiz-SmartBulb-Controller), [prerit-spec/Mood-Lamp](https://github.com/prerit-spec/Mood-Lamp) | 0-2 | 2026 | MIT/none | A wave of 2026 vibe-coded macOS WiZ apps; any of them is a 1-file UDP client to crib. |
| Reference impl. (Python): [sbidy/pywizlight](https://github.com/sbidy/pywizlight) | 559 | 2026-08-05 | MIT | Canonical WiZ protocol library (used by HA core). Port this. |

**Nanoleaf** (Open API: local REST on port 16021, hold power button to get auth token)

| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [reddavis/Nanoleaf](https://github.com/reddavis/Nanoleaf) | 8 | 2022-08-03 | MIT | Swift API client; small, likely SPM. |
| [blacklizard/Iris](https://github.com/blacklizard/Iris) | 4 | 2020 | MIT | macOS screen mirror. |
| [renancaldas/SwiftWatchNanoleaf](https://github.com/renancaldas/SwiftWatchNanoleaf), [inigo/nanoleaf-widget-swift](https://github.com/inigo/nanoleaf-widget-swift) | 0 | 2020 / 2023 | — | |

**Govee** (LAN API: multicast 239.255.255.250:4001 discovery, replies on 4002, commands to device UDP 4003, plaintext JSON; only some models, "LAN Control" must be enabled in Govee Home app; A19 bulbs generally NOT LAN-capable; otherwise cloud OpenAPI with API key, or BLE)

| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [MillerTechnologyPeru/Govee](https://github.com/MillerTechnologyPeru/Govee) | 0 | 2026-10-26 | MIT | Swift library; same author has [Govee-Reverse-Engineering](https://github.com/MillerTechnologyPeru/Govee-Reverse-Engineering), a Swift [HAP](https://github.com/MillerTechnologyPeru/HAP) implementation and a Swift [Matter](https://github.com/MillerTechnologyPeru/Matter) library. README is one line; **[uncertain]** whether it is BLE or LAN (screenshot suggests BLE scanning). |
| [maxrross/goveemac](https://github.com/maxrross/goveemac) | 1 | 2026-10-09 | MIT | macOS, BLE + local WiFi. |
| [xybl3/SwiftyGovee](https://github.com/xybl3/SwiftyGovee), [ha1lie/SwiftGovee](https://github.com/ha1lie/SwiftGovee) | 1 / 0 | 2025 / 2023 | — | Cloud API wrappers. |
| Reference impl. (Python): [JimmyJammed/govee-lan-api-plus](https://github.com/JimmyJammed/govee-lan-api-plus) (16), [blakete/govee-lan](https://github.com/blakete/govee-lan) (1) | | 2026 | MIT | |

**Yeelight** (local TCP 55443 JSON, SSDP discovery)

| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [ahmetcanaltun/YeelightKit](https://github.com/ahmetcanaltun/YeelightKit) | 0 | 2026-10-06 | MIT | SPM, async/await, LAN discovery + control, no cloud. |
| [voltangle/YeelightKit](https://github.com/voltangle/YeelightKit) | 4 | 2022 | none | |
| [xs0521/EasyYeelight](https://github.com/xs0521/EasyYeelight) | 48 | 2024-12-11 | none | macOS app. |

**Tuya / Smart Life** (local protocol 3.1-3.5 needs device-id + local key obtained from Tuya cloud; else cloud OpenAPI / Tuya app SDK)

| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [tuya/tuya-home-ios-sdk-sample-swift](https://github.com/tuya/tuya-home-ios-sdk-sample-swift) | 38 | 2026-07-20 | MIT | Official Tuya Smart Life App SDK sample (SDK itself is closed-source binary, requires Tuya IoT developer account/App key, cloud). |
| [lunaperegrina/open-bulb](https://github.com/lunaperegrina/open-bulb) | 3 | 2026-10-14 | MIT | macOS menubar, Tuya local protocol in Swift. |
| [Nischay19/wipro-smart-bulb-app](https://github.com/Nischay19/wipro-smart-bulb-app) | 0 | 2026-10-25 | none | "pure Swift, Tuya LAN protocol 3.5" macOS + CLI. |
| [DevnisG/DomoHome](https://github.com/DevnisG/DomoHome) | 0 | 2026-10-23 | MIT | macOS, Tuya local lights. |
| [pkielblock/TuyaLights](https://github.com/pkielblock/TuyaLights) | 1 | 2026-10-22 | MIT | iPhone, Tuya **BLE beacon** lamps, replays recorded frames. |
| Reference impl. (Python): [jasonacox/tinytuya](https://github.com/jasonacox/tinytuya) | 1,781 | 2026-10-13 | MIT | Canonical local Tuya protocol (3.1-3.5, AES-ECB/GCM). Port this. |
| house-control `HouseSmartLife` | — | — | MIT | Swift port of Tuya's `tuya-device-sharing-sdk` (cloud, QR-code login via Smart Life app). Already written. |

**TP-Link Kasa/Tapo** — no Swift lib found. Reference: [plasticrake/homebridge-tplink-smarthome](https://github.com/plasticrake/homebridge-tplink-smarthome) (521, MIT, TS; uses tplink-smarthome-api), HA `tplink` integration (python-kasa). Kasa = XOR-obfuscated JSON on TCP 9999; Tapo = KLAP/AES over HTTP.

**AiDot / Linkind** — no Swift code anywhere. Only reference: [AiDot-Development-Team/python-AiDot](https://github.com/AiDot-Development-Team/python-AiDot) (3 stars, MIT, pushed 2026-09-30; modules `client.py`, `device_client.py`, `discover.py`, `aes_utils.py`, `login_const.py`; `CONF_AES_KEY`). Pattern: cloud login (country + username/password) to fetch device list + per-device AES key, then local LAN control (discovery via DHCP hostname `aidot`). It backs the official HA `aidot` integration (added HA 2026.6, `iot_class: local_polling`, quality scale bronze, `python-aidot==0.3.59`, supports A19/BR30: on/off, brightness, CT, RGBW). Custom component: [AiDot-Development-Team/hass-AiDot](https://github.com/AiDot-Development-Team/hass-AiDot) (42 stars). **Newer Linkind bulbs are Matter-certified (CSA, Aug 2025)** — so for those, HomeKit/Matter is the simpler path.

**HomeKit / Matter in Swift**
- Apple `HomeKit.framework` (`HMHomeManager`) — any accessory already paired into Apple Home (Hue bridge, LIFX, Nanoleaf, WiZ-Matter, Linkind-Matter, Govee-Matter, Tapo-Matter) is controllable by a third-party iOS app with the HomeKit entitlement. house-control's `HomeKitService.swift` / `HomeKitMapper.swift` is a ready example. Apple's `MatterSupport` framework lets an app commission Matter devices into Apple Home. Standalone `Matter.framework` controllers outside Apple Home are entitlement-gated and poorly documented (Apple dev forum thread 823198, April 2026).
- [MillerTechnologyPeru/HAP](https://github.com/MillerTechnologyPeru/HAP) (Swift HAP accessory impl.), [MillerTechnologyPeru/Matter](https://github.com/MillerTechnologyPeru/Matter) (3 stars) — niche.
- [omarshahine/HomeClaw](https://github.com/omarshahine/HomeClaw) (185, MIT, 2026) — Swift HomeKit control via MCP; shows modern HomeKit usage.

### 1.3 Large Swift hub-client apps (fork candidates for approach B)
| Project | Stars | Last push | License | Notes |
|---|---|---|---|---|
| [home-assistant/iOS](https://github.com/home-assistant/iOS) | 2,388 | 2026-10-26 | Apache-2.0 | Official HA iPhone/Watch app. Huge; uses [home-assistant/HAKit](https://github.com/home-assistant/HAKit) (55 stars, Swift WebSocket client for HA) which is the reusable piece. |
| [openhab/openhab-ios](https://github.com/openhab/openhab-ios) | 210 | 2026-10-26 | EPL-2.0 | Official openHAB iOS client (sitemap renderer). |

---

## 2. Cross-platform open-source multi-brand apps

| Project | Stack | Stars | Last push | License | Brands | Notes |
|---|---|---|---|---|---|---|
| [vasmarfas/universal-ambient-light](https://github.com/vasmarfas/universal-ambient-light) | Kotlin (Android/Android TV) | 101 | 2026-10-20 | custom ("other") | Hue (local bridge), WiZ, Yeelight, LIFX, Govee (all local), Nanoleaf, WLED, Hyperion/HyperHDR, Adalight, Zigbee2MQTT, Home Assistant, DDP/E1.31/Art-Net/tpm2/OPC | Ambient-light streamer, not a controller, but the most complete set of local light drivers in a mobile codebase. Android only. Driver modules not documented as reusable. |
| [vladdemorcy/photon](https://github.com/vladdemorcy/photon) | JavaScript | 0 | 2026-10-21 | other | Hue, Govee, LIFX, WiZ, Nanoleaf, IKEA, Tuya, Lutron, HA | Media-reactive lights (Plex/Jellyfin). Protocol reference only. |
| Corluma ([App Store id1636211895](https://apps.apple.com/us/app/corluma/id1636211895), [Flathub net.corluma.Corluma](https://github.com/flathub/net.corluma.Corluma)) | Qt/C++ **[uncertain]** | — | iOS v1.23 Sep 2025 | **[uncertain]** (source repo not found on GitHub; flathub manifest exists) | Hue (bridge), LIFX, Nanoleaf (not Essentials), Arduino (ArduCor) | Free, no account, all local. iOS + Linux + Android. Closest "free local multi-brand iOS app" that exists. |
| Flutter single-brand: [devkav/flutter_hue](https://github.com/devkav/flutter_hue), [nathanielgreen/lifx_flutter](https://github.com/nathanielgreen/lifx_flutter) (cloud), [mogenson/wiz-color](https://github.com/mogenson/wiz-color) | Flutter | small | old | — | one brand each | No Flutter or React Native project unifying several brands was found. GitHub searches for "smart light flutter", "smart light react native", "smart home lights kotlin multiplatform" returned nothing relevant. |
| [SritharBoss/WizBulb](https://github.com/SritharBoss/WizBulb) | Kotlin/Compose | 1 | 2026-05 | GPL-3.0 | WiZ LAN | Android. |

---

## 3. Unification layers (any language)

### 3.1 Home Assistant
- [home-assistant/core](https://github.com/home-assistant/core): 91,744 stars, Apache-2.0, Python. Has first-party integrations for **every** brand on the list: `hue` (aiohue, v2 API), `wiz` (pywizlight), `lifx` (aiolifx), `govee_light_local` (LAN) + `govee_ble`, `nanoleaf` (aionanoleaf), `tplink` (python-kasa), `tuya` (cloud) + community `localtuya`, `aidot` (python-aidot, new in 2026.6), `yeelight`, `wled`, `matter`, `homekit_controller`.
- **Light platform abstraction** (https://developers.home-assistant.io/docs/core/entity/light): `LightEntity` with `supported_color_modes` from the `ColorMode` enum (ONOFF, BRIGHTNESS, COLOR_TEMP, HS, RGB, RGBW, RGBWW, WHITE, XY), `color_mode`, brightness 0-255, `color_temp_kelvin`, `effect`/`effect_list`, `supported_features` (TRANSITION, FLASH, EFFECT). Core guarantees the integration receives exactly one colour attribute it supports and converts the rest (e.g. CT to xy). Mandatory since 2024.2; non-compliant lights stopped working in 2025.3. **This is the best-documented, battle-tested model for a cross-brand `Light` type — copy it into Swift.**
- Client path for iOS: HA WebSocket API via `HAKit` (Swift) or REST; HA also exposes everything to Apple Home via its `homekit` bridge integration.

### 3.2 openHAB
- [openhab/openhab-addons](https://github.com/openhab/openhab-addons): 2,067 stars, EPL-2.0, Java. Bindings for hue, wiz, lifx, govee (LAN), nanoleaf, tplinksmarthome, tuya (community), yeelight, wled. Item/Channel model with `Color` (HSB), `Dimmer`, `Switch` types. Less relevant than HA for a Swift app; the openHAB iOS app is a sitemap renderer.

### 3.3 Homebridge (exposes everything as HomeKit -> native `HomeKit.framework` on iOS)
- [homebridge/homebridge](https://github.com/homebridge/homebridge) 25,531 stars, Apache-2.0, TS; [homebridge/HAP-NodeJS](https://github.com/homebridge/HAP-NodeJS) 2,721.
- Plugins (all TS/JS, run on a Pi/NAS, 24/7):

| Plugin | Stars | Last push | License | Transport |
|---|---|---|---|---|
| [ebaauw/homebridge-hue](https://github.com/ebaauw/homebridge-hue) | 924 | 2026-08-29 | Apache-2.0 | Hue v1 API, deCONZ |
| [ebaauw/homebridge-hue2](https://github.com/ebaauw/homebridge-hue2) | 100 | 2026-08-29 | Apache-2.0 | Hue v2 API |
| [homebridge-plugins/homebridge-govee](https://github.com/homebridge-plugins/homebridge-govee) | 592 | 2026-10-24 | MIT | OpenAPI (key), LAN (no creds, select models), AWS MQTT, BLE; Node 22/24/26; verified |
| [plasticrake/homebridge-tplink-smarthome](https://github.com/plasticrake/homebridge-tplink-smarthome) | 521 | 2026-03-08 | MIT | Kasa local |
| [iRayanKhan/homebridge-tuya](https://github.com/iRayanKhan/homebridge-tuya) | 438 | 2024-06-28 | MIT | Tuya local (needs local keys) |
| [tuya/tuya-homebridge](https://github.com/tuya/tuya-homebridge) | 396 | 2024-07-21 | MIT | official, cloud |
| [AMoo-Miki/homebridge-tuya-lan](https://github.com/AMoo-Miki/homebridge-tuya-lan) | 211 | 2023 | MIT | local |
| [nubisco/homebridge-tuya-local-platform](https://github.com/nubisco/homebridge-tuya-local-platform) | 9 | 2026-10-24 | MIT | local, active |
| [kpsuperplane/homebridge-wiz-lan](https://github.com/kpsuperplane/homebridge-wiz-lan) | 136 | 2026-10-24 | Apache-2.0 | WiZ UDP 38899/38900 registration broadcast; bulbs, strips, plugs; author warns limited support beyond RGB bulbs; CT 2200-6500K |
| [devbobo/homebridge-lifx-lan](https://github.com/devbobo/homebridge-lifx-lan) | 86 | 2020-12 | MIT | LIFX LAN (unmaintained) |
| [calvarium/homebridge-lifx-plugin](https://github.com/calvarium/homebridge-lifx-plugin) | 44 | 2026-03-01 | Apache-2.0 | LIFX LAN, auto-discovery |
| Nanoleaf: [felipehjcosta/homebridge-nanoleaf-scenes](https://github.com/felipehjcosta/homebridge-nanoleaf-scenes), [zozika/homebridge-nanoleaf-scene-bridge](https://github.com/zozika/homebridge-nanoleaf-scene-bridge) | 1 / 0 | 2026 | Apache/MIT | Nanoleaf already has native HomeKit, so plugins only add scenes |
| AiDot | — | — | — | **none found** (use HA's `aidot` + HA's HomeKit bridge, or the bulbs' native Matter) |

### 3.4 diyHue (Hue bridge emulator)
- [diyhue/diyHue](https://github.com/diyhue/diyHue): 1,829 stars, pushed 2026-10-23, Python, licence mixed (GPLv3 / Apache-2.0 / CC BY-NC-SA 4.0 badges — **check before redistributing**). Runs on a Pi/Docker.
- Verified protocol drivers in `BridgeEmulator/lights/protocols/`: `wiz.py`, `yeelight.py`, `govee.py`, `tpkasa.py`, `wled.py`, `tasmota.py`, `shelly.py`, `esphome.py`, `elgato.py`, `milight.py`, `mqtt.py`, `hue.py` (real Hue bridge passthrough), `hue_bl.py`, `deconz.py`, `tradfri.py`, `homeassistant_ws.py`, `hyperion.py`, `jeedom.py`, `domoticz.py`, `flex.py`, `mi_box.py`, `native*.py`. **No LIFX, Tuya, Nanoleaf or AiDot driver** (LIFX requires writing a protocol file per forum; Tuya/Nanoleaf/AiDot reachable only indirectly through HA/MQTT).
- Appeal: a Swift app that speaks Hue CLIP (v1 and, increasingly, v2) to one endpoint gets WiZ/Yeelight/Govee/Kasa/WLED "for free", and Hue Essentials / official Hue app work against it. Cost: another always-on box, and v2-API emulation completeness is **[uncertain]**.
- Siblings: [mariusmotea/diyHue](https://github.com/mariusmotea/diyHue) (638, original), [probonopd/ESP8266HueEmulator](https://github.com/probonopd/ESP8266HueEmulator) (413), [SteveyO/Hue-Emulator](https://github.com/SteveyO/Hue-Emulator) (172, Java), Bifrost (Zigbee2MQTT-only Hue emulator, mentioned in reviews).

### 3.5 Matter bridges (expose non-Matter lights as Matter -> Apple Home)
| Project | Stars | Last push | License | Plugins relevant to lights |
|---|---|---|---|---|
| [Luligu/matterbridge](https://github.com/Luligu/matterbridge) | 996 | 2026-10-26 | Apache-2.0 | Official: shelly, zigbee2mqtt, **hass** (bridges any HA entity incl. all brands above), somfy-tahoma, webhooks, bthome, irobot. Community: elgato (Key Light), loxone, daikin, roborock, etc. **No native Hue/WiZ/LIFX/Govee/Tuya/Nanoleaf plugin**; route is matterbridge-hass or zigbee2mqtt. Bridge limit 150 accessories. |
| [matter-js/matter.js](https://github.com/matter-js/matter.js) | 922 | 2026-10-26 | Apache-2.0 | Full TS Matter stack; its README mentions Tuya/Smart Life (as a controller target). |
| [matter-js/python-matter-server](https://github.com/matter-js/python-matter-server) | 1,046 | 2026-06-23 | Apache-2.0 | **archived** (superseded by matter.js-based server inside HA). |
- Practical note: many of the target brands already ship Matter natively (Hue bridge, WiZ, Nanoleaf Essentials/Shapes, Linkind/AiDot Matter bulbs, some Govee, Tapo), so Apple Home can be the "bridge" without any server.

### 3.6 Other
- [lopter/lightsd](https://github.com/lopter/lightsd): 130 stars, C, GPL-3.0, last commit 2017. LIFX-only JSON-RPC daemon; its README articulates the "daemon as abstraction layer / unified API across bulb kinds" idea, but it never grew beyond LIFX. Dead.
- [LedFx/LedFx](https://github.com/LedFx/LedFx): 2,087, GPL-3.0, Python — audio-reactive effects engine; outputs to WLED, Hue, LIFX, Govee, Nanoleaf, OpenRGB, E1.31 etc. Its `devices/` package is another readable set of per-brand drivers.
- [hyperion-project/hyperion.ng](https://github.com/hyperion-project/hyperion.ng): 3,925, MIT, C++ — ambient light; LED device drivers for Hue (incl. Entertainment), Nanoleaf, Yeelight, WLED, Govee **[uncertain]**, Cololight, Razer, etc. (`libsrc/leddevice/dev_net/`). Good C++ reference for Hue Entertainment DTLS streaming.
- [wled/WLED](https://github.com/wled/WLED): 18,922, EUPL-1.2 — DIY ESP firmware; JSON HTTP + DDP/UDP realtime. A "brand" worth supporting for the maker crowd; HueKit (ahmedayoub95) already has a Swift WLED client.
- [Koenkk/zigbee2mqtt](https://github.com/Koenkk/zigbee2mqtt) 15,759 — for Zigbee Hue bulbs without a Hue bridge (needs a coordinator dongle).

---

## 4. Commercial multi-brand iOS apps (competitive reference)

| App | Brands | Approach | Price / notes |
|---|---|---|---|
| [Hue Essentials](https://apps.apple.com/us/app/hue-essentials/id1462943921) (SmartFusionLabs) | Hue bridge, Hue Bluetooth, deCONZ/ConBee, diyHue, LIFX (iOS); IKEA Tradfri gateway on Android only | Local Hue API; LIFX added later (4.7.x fixes LIFX connection) | Freemium. Android + iOS + Wear OS + Android TV. No WiZ/Nanoleaf/Govee. |
| [iConnectHue](https://apps.apple.com/us/app/iconnecthue-for-philips-hue/id639343132) | Hue only | Local bridge, "everything non-music runs on the bridge"; remote access | Paid + IAP. iOS only. |
| [Corluma](https://apps.apple.com/us/app/corluma/id1636211895) | Hue (bridge), LIFX, Nanoleaf (not Essentials), Arduino/ArduCor | 100% local, no account | Free, no IAP; v1.23 Sep 2025. Also Linux (Flathub) and Android. |
| [Luminair 4](http://luminair.app/) (Synthe FX) | DMX/Art-Net/sACN fixtures + **Apple HomeKit** (so Hue, LIFX, Eve, any HomeKit-certified light) | HomeKit framework for consumer bulbs | Subscription tiers (Standard/Pro). iPad/iPhone. |
| [Controller for HomeKit](https://controllerforhomekit.com/) | Anything in Apple Home (HomeKit + Matter) | HomeKit framework; adds workflows, dashboards, floor plans, backups, logs, "Controller AI" | 7-day trial, "Controller Plus" paid. iPhone/iPad/Mac/TV/Watch. **The reference for approach B.** |
| [The Home Remote](https://apps.apple.com/app/id1015015446) | Broad integration list (Hue, LIFX, HA, Homebridge, SmartThings, Hubitat, etc.) **[uncertain: full list not retrievable]** | Designer-built custom UI; local/API drivers | Free + one-time Pro license. Also Android/Windows. |
| [Light DJ](https://lightdjapp.com/) / [iLightShow](https://ilightshow.net/) | Hue (Entertainment), LIFX, Nanoleaf | Local; music sync focus | Paid/IAP. |
| [Scintillator](https://www.flamingpear.com/scintillator/) | Hue, Nanoleaf, LIFX, Avea; mixed groups | Local animation designer | Paid. |
| [SmartHue](https://apps.apple.com/us/app/smarthue-for-philips-hue-light/id6478839736) | Hue, LIFX, Tuya | **[uncertain]** | iPhone only. |
| "Led Light Controller / LedRemote / Smart Led Light Controller" family ([id1587679090](https://apps.apple.com/us/app/led-light-controller-ledremote/id1587679090), [id1670269554](https://apps.apple.com/us/app/led-light-controller-home-app/id1670269554), [id6477579584](https://apps.apple.com/us/app/led-light-remote-controller/id6477579584); Kain Suite Pte. Ltd.) | Claims Hue, CYNC, LIFX, WiZ, Nanoleaf, Feit, Tuya, Kasa, Wyze, Sengled, Merkury, Linkind, **AiDot**, Geeni, Govee, Yeelight... plus "Matter and HomeKit" | Appears to be HomeKit/Matter + some cloud; paywall immediately after choosing a brand | $8.99/week, $49.99/yr, $59.99 lifetime; 3.9/5 from 60K ratings with many "doesn't actually control the bulb / refund denied" reviews. **This is the gap in the market: a trustworthy, local-first, one-time-price multi-brand app.** |
| LampControl (macOS, not iOS) | Hue, LIFX, Govee, Yeelight, Tuya/Smart Life, Nanoleaf, WiZ | native Swift; per-ecosystem credentials in Keychain | Free (2 lights) / EUR 5.99 lifetime |
| HomeHabit | — | Android-only dashboard (Hue, LIFX, HA, SmartThings...) | Not iOS. |
| Lumio, LampUX, Colorful, "Lights (LIFX/Hue)" | **[uncertain / not found]** | Could not be located in the App Store search before the search budget ran out; LampUX is likely the AiDot/Linkind companion app (Linkind's app is also named "AiDot"). | |

Observed: official Philips Hue app is itself absorbing Nanoleaf modules via the "Hue Wall Light Module" (Hueblog, Aug 2026).

---

## 5. Write-ups / lessons learned

No blog post describing exactly "I built one iOS app for Hue + WiZ + LIFX + ..." was found before the search budget ran out. Relevant partial sources:

- **lightsd README** (2014-2017): argues for a daemon as the unified abstraction; project stalled at one brand — a warning that per-brand driver maintenance is the real cost.
- **house-control README/architecture**: lessons baked into the code — provider protocol (`DeviceService`) with `devices/read/send/watch`, a `ColorMath` module converting hex <-> HSV <-> CIE xy <-> mired because every brand uses a different colour space, local simulators for each provider for testing, and a note that **macOS only grants HomeKit access to App Store builds** (so HomeKit lives in the iPhone target).
- **homebridge-wiz-lan README**: WiZ CT range 2200-6500K, switching between colour and CT modes causes brightness jumps; offline detection needs a refresh interval.
- **homebridge-govee README**: four transports (OpenAPI/LAN/AWS/BLE) per device model; LAN works without credentials only on some models.
- **HA color-mode architecture discussion** (home-assistant/architecture#519) and the 2024-02-12 "light color mode mandatory" blog: the unified light model must declare per-device supported colour modes and normalise colour before dispatch.
- **Corluma / OMG Ubuntu article**: "control all lights from one app without IFTTT or assistants; all local; no accounts" is the user-facing promise that resonates.
- **Protocol security notes**: Govee LAN and WiZ UDP are unauthenticated plaintext; Tuya local needs secret local keys fetched from the cloud; AiDot likewise needs cloud login for AES keys (python-aidot `aes_utils.py`, `login_const.py`).

---

## 6. Ranked top-5 starting points for a Swift iOS app

1. **[0xProbabillity/house-control](https://github.com/0xProbabillity/house-control)** (772 stars, MIT, Swift, active this week). Fork the `core/` SwiftPM package: it already has the provider abstraction (`DeviceService`), Hue local client, Home Assistant client, HomeKit client, a Tuya/Smart Life cloud client, colour-space maths, Keychain secret store, Bonjour discovery, and iOS 17 SwiftUI shell. Add `WiZService`, `LIFXService`, `GoveeService`, `NanoleafService`, `AiDotService` conforming to `DeviceService`. Drop the 3D floor plan if not wanted. Risk: lights-only device model is simplistic (`patch: [String: Any]`), XcodeGen build, single-author project.

2. **Apple HomeKit framework + Matter (approach B, zero servers)** — model after Controller for HomeKit / Luminair. Hue bridge, Nanoleaf, LIFX, WiZ (Matter), Linkind/AiDot (Matter bulbs), newer Govee and Tapo all pair into Apple Home; `HMHomeManager` gives one uniform `HMCharacteristicTypeHue/Saturation/Brightness/ColorTemperature` model. Use `MatterSupport` to commission Matter bulbs in-app. house-control's `HomeKitService.swift` + `HomeKitMapper.swift` are a ready implementation. Gaps: older non-Matter WiZ/Govee/Tuya bulbs, Hue Entertainment, per-brand effects.

3. **Home Assistant as the unifier + [HAKit](https://github.com/home-assistant/HAKit) (Swift, 55 stars) client** — HA has first-party, maintained integrations for every brand including AiDot (2026.6). Copy HA's `LightEntity`/`ColorMode` model into Swift as the app's canonical `Light`. Needs a running HA instance; the official HA iOS app (2.4k stars, Apache-2.0) is a reference for auth/websocket/widgets.

4. **Native Swift protocol drivers, ported from the canonical Python/TS libs** — if the goal is "no hub, pure local": Hue -> [ahmedayoub95/HueKit](https://github.com/ahmedayoub95/HueKit) (v2 CLIP, SSE, SPM) or SwiftyHue 0.6.0 (v1, CocoaPods); LIFX -> [LIFX/swift-lifx-protocol](https://github.com/LIFX/swift-lifx-protocol) codec + Network.framework UDP (see RxLifx-Swift for discovery flow); WiZ -> port [pywizlight](https://github.com/sbidy/pywizlight) (ENez7/ligthswitch shows it in ~1 file of Swift); Govee -> port LAN API (SeanPVera/LumenDesk, MillerTechnologyPeru/Govee); Nanoleaf -> [reddavis/Nanoleaf](https://github.com/reddavis/Nanoleaf); Yeelight -> [ahmetcanaltun/YeelightKit](https://github.com/ahmetcanaltun/YeelightKit); Tuya -> port [tinytuya](https://github.com/jasonacox/tinytuya) 3.3/3.5 (lunaperegrina/open-bulb, Nischay19/wipro-smart-bulb-app have Swift starts); AiDot -> port [python-aidot](https://github.com/AiDot-Development-Team/python-AiDot) (cloud login -> AES key -> LAN). Highest effort, highest control, no server dependency; AiDot/Tuya still need cloud for keys.

5. **[diyHue](https://github.com/diyhue/diyHue) behind a Hue-only Swift client** — run diyHue on a Pi; it fronts WiZ, Yeelight, Govee, Kasa, WLED, Tasmota, Shelly, Elgato, HA and real Hue bridges as one Hue API; the iOS app then needs only one protocol (HueKit/SwiftyHue) and gains compatibility with Hue Essentials etc. Missing LIFX/Tuya/Nanoleaf/AiDot natively (route via HA), licence is mixed (GPL/Apache/CC-BY-NC-SA — check), Hue v2 emulation completeness uncertain.

Recommended hybrid: start from (1) house-control's `core` package, keep its HomeKit and Home Assistant services as the "everything else" fallbacks (2)+(3), and add native local drivers (4) brand by brand in order of protocol simplicity: WiZ (UDP JSON) -> Nanoleaf (REST) -> LIFX (binary UDP, official codec exists) -> Govee LAN -> Yeelight -> Tuya local -> AiDot.

---

## 7. Open questions / things to verify before committing
- house-control's Tuya module uses Tuya's device-sharing login flow and is excluded from its App Store build — App Review risk for Tuya cloud in a shipped app.
- AiDot local protocol details (ports, encryption) must be read from `python-aidot/aidot/device_client.py` and `discover.py`; not yet inspected.
- MillerTechnologyPeru/Govee: BLE vs LAN scope unverified.
- diyHue licence terms for a commercial app; whether its v2 API emulation satisfies HueKit.
- Corluma source location/licence (GitHub search only finds the Flathub manifest; main repo may be GitLab or private).
- Which specific WiZ / Govee / Linkind models the user owns support Matter (determines how far approach B alone gets).
- Apple: HomeKit entitlement is free, but a standalone Matter controller (no Apple Home) is entitlement-gated and undocumented (Apple forum thread 823198, 2026-04).
