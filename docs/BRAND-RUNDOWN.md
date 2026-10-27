# Brand rundown (US market, October 2026)

Condensed from `research/`. Difficulty 1 = documented local API, 5 = cloud-only reverse engineering or no path. "HK" = native HomeKit. Star counts and dates are from the GitHub API on 2026-10-26. Items marked (?) were not confirmed from a primary source.

## Tier legend

- **T0 HomeKit**: already in Apple Home (HomeKit-native or Matter) → our HomeKit provider, zero protocol work.
- **T1 Local, documented or stable reverse-engineered, no credentials.**
- **T2 Official cloud API with a key the user pastes.**
- **T3 Reverse-engineered, needs the vendor account credentials or a cloud-fetched key.**
- **T4 Own-fabric Matter (phase 3).**
- **T5 Via Home Assistant only.**
- **X Not planned.**

## The user's brands

| Brand | Hub | Radio | Local control | Cloud | Matter | HK | Best reference | Diff. | Tier / phase |
|---|---|---|---|---|---|---|---|---|---|
| **Philips Hue** (bridge) | Bridge v2 / Bridge Pro | Zigbee → bridge on LAN | CLIP v2 HTTPS `/clip/v2/resource/*`, header `hue-application-key`; SSE `/eventstream/clip/v2`; pairing `POST /api` after link button; Entertainment DTLS-PSK UDP 2100; mDNS `_hue._tcp` + discovery.meethue.com | Remote API (OAuth2, manual approval, 50k calls/day) optional | Yes, bridge is a Matter bridge (2023) | Yes | aiohue (Py, HA), openhue-api OpenAPI spec (210★), HueEntertainmentKit (Swift 6, 1★, Sept 2026), Q42.HueApi (C#) | 2 | T1, phase 1 |
| Hue Bluetooth-only bulbs | none | BLE | GATT `932c32bd-00xx-...` (HueBLE, 32★) | no | no | no | flip-dots/HueBLE | 3 | phase 3 (recommend buying a bridge) |
| **WiZ** | none | Wi-Fi 2.4 GHz (+BLE setup) | JSON UDP 38899 (`getPilot/setPilot/setState/getSystemConfig/getModelConfig/registration`), push on 38900; **fw 1.34+ needs HMAC-SHA256 signed writes or "Allow all controls"** | WiZ Pro only (commercial) | Most Wi-Fi products since Q2 2021 (upgrade in app); Wi-Fi only | no | pywizlight (559★, MIT, 2026-08), homebridge-wiz-lan (136★) | 2 (3 with signing) | T1, phase 1 |
| **AiDot / Linkind / OREiN** (also Mujoy, Winees, WELOV; Leedarson "Arnoo" cloud, not Tuya) | none for Wi-Fi; Matter Smart Hub 2 for BLE-mesh outdoor lights | Wi-Fi + BLE; BLE-mesh outdoor line | Cloud login `prod-{us,eu,jp}-api.arnoo.com/v35` (RSA password, Appid header) to get devices + `aesKey`/`password`; then UDP 6666 discovery (AES-256-ECB fixed key) + TCP 10000 control (AES-128-ECB, `loginReq`, `setDevAttrReq` with OnOff/Dimming/CCT/RGBW) | Same undocumented API; no developer program | Many Linkind/OREiN SKUs Matter-over-Wi-Fi (Matter 1.4/1.5 certs 2025-26) | Matter only | python-aidot 0.3.59 (vendor, MIT, 2026-09-30), HA `aidot` (2026.6) | 3 | T3, phase 1; Matter SKUs via T0 |

## Everything else

| Brand | Hub | Local control | Cloud | Matter | HK | Reference | Diff. | Tier / phase |
|---|---|---|---|---|---|---|---|---|
| **LIFX** | none | Binary UDP 56700, no auth; broadcast `GetService` or mDNS `_lifx._udp` (fw ≥4.110) | Official `api.lifx.com/v1`, personal token, 120 req/min | All new products (Wi-Fi; Thread beta 2026) | Yes (most) | LIFX/swift-lifx-protocol (official codec), lifxlan (536★), aiolifx | 1 | T1 + T2, phase 2; **implemented (PR)**: LAN provider `Packages/Providers/LIFXKit` (T2.1), cloud fallback pending |
| **Nanoleaf panels** (Light Panels, Canvas, Shapes, Elements, Lines) | none | REST TCP 16021, token via power-button hold + `POST /api/v1/new` (30 s); mDNS `_nanoleafapi._tcp` | none | newer Shapes/Lines (?) | Yes | reddavis/Nanoleaf (Swift), nanoleafapi (Py) | 1-2 | T1, phase 2 |
| **Nanoleaf Essentials** (bulbs/strips) | Thread border router for Thread | **No Open API** | none | Matter Essentials (Thread) | Yes | — | 1 via HK | T0 |
| **Govee** | none | LAN API: multicast 239.255.255.250:4001 scan → 4002 reply → UDP 4003 commands, JSON, no auth; **only ~150 SKUs, plain A19 bulbs mostly excluded**; "LAN Control" toggle per device | Official Developer API, key from app (`openapi.api.govee.com`, 10k/day) | 2025-26 bulbs/lamps/strips | no | govee2mqtt (Rust, 1.5k★), homebridge-govee (592★) | 2 | T1 + T2, phase 2 |
| **Yeelight** | none | TCP 55443 JSON-RPC, no auth; "LAN Control" toggle; SSDP 239.255.255.250:1982; ~60 req/min | none usable | some 2025 SKUs | some | python-yeelight (268★), ahmetcanaltun/YeelightKit (Swift) | 2 | T1, phase 2 |
| **Elgato** Key Light family | none | HTTP 9123 `/elgato/lights`, no auth, mDNS `_elg._tcp` | none | no | no | python-elgato | 1 | T1, phase 2 |
| **Shelly** bulbs/RGBW | none | Gen1 REST; Gen2+ JSON-RPC `/rpc`, optional digest auth (user `admin`); mDNS `_shelly._tcp` | official cloud (key) | Gen3/4 (fw 1.6+) | no | aioshelly | 1-2 | T1, phase 2 |
| **WLED** (DIY) | none | JSON HTTP, mDNS `_wled._tcp` | none | no | no | ahmedayoub95/HueKit has a Swift WLED client | 1 | T1, phase 2 |
| **Magic Home / Zengge / LEDENET / Daybetter** | none | Binary TCP 5577; UDP 48899 discovery | unofficial | no | no | flux_led (169★) | 2 | T1, phase 2 |
| **TP-Link Tapo / Kasa** | none | Legacy Kasa: XOR JSON TCP 9999 no auth; Tapo/new Kasa: **KLAP over HTTP 80, needs TP-Link email+password even on LAN**, "Third-Party Compatibility" toggle on some fw; discovery UDP 9999/20002 | none public | Tapo L535E etc. | rare | python-kasa (1.8k★), mihai-dinculescu/tapo (Rust) | 2-3 | T3, phase 2 |
| **Tuya white-label** (Feit, Globe, Merkury/Geeni, Teckin, Gosund, Treatlife, Sylvania Wi-Fi, Cree Connected Max) | none | TCP 6668 AES with per-device **local key** (needs Tuya IoT developer project with expiring trial) ; protocol 3.1-3.5 | Tuya OpenAPI / Smart Life QR login (needs our own Tuya developer app credentials) | some SKUs | no | tinytuya (1.8k★), tuya-local (3.6k★), house-control's HouseSmartLife (Swift cloud port) | 4 | T3 advanced, phase 3; Matter SKUs via T0; **implemented (PR)**: local provider `Packages/Providers/TuyaKit` (T3.1, protocol 3.1/3.3/3.4/3.5, device id + local key entry), cloud QR login pending |
| **Meross** | none | Local HTTP `/config` signed with MD5(messageId+key+ts); key from cloud login | unofficial, rate-limited | plug only (?) | "HK" SKUs | meross_lan (756★), MerossIot | 3 | T3, phase 3 |
| **SwitchBot** lights | Hub for BLE-only via cloud | BLE GATT (pySwitchbot, no key needed) | Official v1.1 API, token+secret (tap app version 10×), HMAC-SHA256, 10k/day | via Hub 2/3 bridge (beta) | no | pySwitchbot, OpenWonderLabs/SwitchBotAPI | 2 | T2, phase 3 |
| **Twinkly** | none | HTTP challenge login, `X-Auth-Token`; UDP 5555 discovery | none | no | Gen II | xled (233★) | 2 | T1, phase 3 (or T0) |
| **IKEA Dirigera** | hub | Unofficial HTTPS 8443 + token (press hub button) | none | Yes, Matter bridge 1.3 (Oct 2025) | Yes | Leggin/dirigera (221★) | 2 | T0 recommended; T1 phase 3 |
| **IKEA Trådfri gateway** | hub | CoAP/DTLS 5684 PSK | none | no | Yes | pytradfri | 3 | X (use HK) |
| **Lutron Caséta** | Smart Bridge | LEAP TLS 8081 with client cert from button pairing | none | no | Yes | pylutron-caseta | 3 | T0 only |
| **Eve** | home hub for Thread | HAP only | none | Thread devices yes | Yes | — | 1 via HK | T0 |
| **Aqara** bulbs | Aqara hub | none (hub bridges to HK/Matter) | enterprise API | via hub | Yes | — | 2 | T0 |
| **Sengled** | Zigbee hub for Zigbee line | Zigbee: not from iPhone; Wi-Fi: cloud only | unofficial | Wi-Fi Matter bulbs since 2023 | no | ha-sengledapi (unmaintained) | 5 / 2 (Matter) | T0 for Matter SKUs; else T5 |
| **GE Cync** | Wi-Fi device bridges BLE bulbs | Only by DNS-hijacking the cloud (cync-lan) — not feasible on a phone | unofficial, one session per account, 2FA by email | new SKUs Matter 1.3; old units never | no | cync-lan (19★) | 5 / 2 (Matter) | T0 for Matter SKUs; else X |
| **Wyze** | none | none | unofficial (wyze-sdk, email+password+API key) | no, confirmed never | no | wyze-sdk (358★) | 4 | T5 or X |
| **Sylvania Smart+** | three lines | BLE line = HomeKit-over-BLE; Wi-Fi = Tuya; Zigbee = any coordinator | Tuya | none found | BLE line | — | 1 via HK / 4 | T0 / T3 |
| **Lepro** | none | proprietary app; a Matter OEM SKU may exist (?) | none | ? | no | — | 5 | X unless Matter |
| **Amazon Basics** | none | none, Alexa-only | none | none found | no | — | 5 | X |
| **Eufy Lumos** | none | legacy "lakeside" broke in HA 2026.10 | unofficial | no | no | — | 4-5 | X |
| **Ring** | — | no consumer bulbs | — | — | — | — | — | X |

## Unification layers considered

| Layer | What it gives | Verdict |
|---|---|---|
| **Apple HomeKit framework** | One API for everything in Apple Home incl. Matter; needs HomeKit entitlement only; Thread works through the user's HomePod/Apple TV | **Use in v1** as the second provider |
| **MatterSupport + Matter.framework (own fabric)** | Direct Wi-Fi Matter control without Apple Home | Phase 3; Thread impossible without border router; extra extension + fabric storage |
| **Home Assistant** (91.7k★) | Integrations for every brand incl. AiDot; REST + WebSocket (`HAKit` Swift client, 55★); HomeKit Bridge re-export; 24/7 automations | Phase 3 provider; recommended to the user if they want automations |
| **Homebridge** (25.5k★) + plugins (hue 924★, govee 592★, tplink 521★, tuya 438★, wiz-lan 136★) | Everything becomes HomeKit | Alternative to HA for the HomeKit-only route; no AiDot plugin |
| **diyHue** (1.8k★) | Emulates a Hue bridge in front of WiZ, Yeelight, Govee, Kasa, WLED, Shelly, Elgato, HA | Mixed licence, no LIFX/Tuya/Nanoleaf/AiDot; not adopted |
| **Matterbridge** (996★) | Exposes HA/Zigbee2MQTT entities as Matter | Only useful with HA; not adopted |

## Existing apps worth studying

- **house-control** (Swift, MIT, 772★, pushed 2026-10-24): `DeviceService` protocol, `HueService`, `HomeKitService`+`HomeKitMapper`, `ColorMath`, `SecretStore`, Bonjour discovery, per-provider simulators. Primary code reference.
- **Lumen** (iPhone, WiZ-only, iOS 26, 2026-10): unicast /24 discovery, widgets/Controls via App Intents, Keychain-shared config.
- **LumaBar** (macOS, 2026-10): WiZ + Tuya + Yeelight + LIFX + Hue + HA local drivers in Swift.
- **HueEntertainmentKit** (Swift 6, Sept 2026): CLIP v2, Bonjour, pairing, Signify-CA validation, DTLS via NIOTransportServices.
- **Controller for HomeKit**, **Luminair 4**: commercial reference for the HomeKit-only approach.
- **Corluma** (free, local: Hue, LIFX, Nanoleaf), **Hue Essentials** (Hue, deCONZ, diyHue, LIFX): the local-first competitive set.
- The "Led Light Controller / LedRemote" subscription family claims 20 brands incl. AiDot at $8.99/week with poor reviews: the market gap is a trustworthy local-first multi-brand app.
