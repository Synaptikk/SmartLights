# AiDot / Linkind ecosystem: controlling lights from a custom iOS app

Research date: 2026-10-26. Every claim carries a URL. Items marked **[UNCERTAIN]** are inferences or single-source reports.

---

## 1. What AiDot is

**Platform / company**
- AiDot describes itself as "a smart home platform that connects devices across brands and ecosystems"; the AiDot app is the control hub for "Works with AiDot" devices (lights, switches, outlets, cameras, sensors, appliances). Source: PR Newswire, 2022-11-30, "AiDot officially Joins the Connectivity Standards Alliance" — https://www.prnewswire.com/news-releases/aidot-officially-joins-the-connectivity-standards-alliance-301690308.html
- Legal entity on Matter certificates is **AiDot Inc.** (CSA member page: https://csa-iot.org/member/aidot-inc/ ; the member profile names "Linkind, OREiN, Winees, WELOV, and more"). LinkedIn lists AiDot Smart Home as privately held, founded 2018 — https://www.linkedin.com/company/aidot-smart-home
- **Parent: Leedarson IoT Technology Inc. (Xiamen, China; SSE 605365; formerly Xiamen Leedarson Lighting Group, renamed Jan 2020)** — https://www.leedarson.com/about-leedarson and https://www.investing.com/equities/leedarson-iot-tech. Evidence tying AiDot/Linkind to Leedarson:
  - Linkind smart plug manual lists "Manufacturer: Leedarson IoT Technology, Inc." at a Xiamen address — https://device.report/manual/12946002
  - Matter Alpha calls Leedarson "AiDot's parent firm" (their phrasing: "likely") — https://www.matteralpha.com/news/aidot-and-linkind-roll-out-matter-1-4-firmware-for-lightbulbs
  - The AiDot cloud API lives on `*.arnoo.com`; **Arnoo is Leedarson's IoT cloud platform** ("cloud-based single-app IoT solution from LEEDARSON") — https://www.arnoo.com/why-arnoo , https://www.leedarson.com/news/arnoo-iot-platform-debuts-at-ifa-in-germany , Arnoo iOS app developer = "Leedarson Lighting Co., Ltd." — https://apps.apple.com/us/app/arnoo/id1418855856
  - The AiDot Alexa skill is published by "Arnoo" — https://www.amazon.com/Arnoo-AiDot/dp/B09CTB9K49
  - CSA "Matter over Thread Plug" cert by Leedarson says it "will be sold under different brands, such as LEEDARSON, Mujoy, Orein, Linkind" — https://csa-iot.org/csa_product/matter-over-thread-plug-21/
  - **[UNCERTAIN]** No ownership filing found that literally says "AiDot Inc. is a subsidiary of Leedarson"; the chain above is strong circumstantial evidence.

**Brands using the AiDot app** (from the CSA press release above, 2022): Linkind, OREiN, Mujoy, Winees, WELOV, Syvio, GoGonova, Ganiza. Confirmed roles:
- Linkind: smart lighting brand (bulbs, strips, solar outdoor lights, hubs) — https://linkind.com
- OREiN: bulbs, ceiling lights, exhaust fan — Amazon B0BJK8561K https://www.amazon.com/OREiN-Smart-Light-Bulbs-Matter/dp/B0BJK8561K ; CSA https://csa-iot.org/csa_product/orein-smart-ceiling-light-64/
- Winees: security cameras/sensors — https://www.prnewswire.com/news-releases/winees-announces-the-first-solar-powered-security-camera-to-be-ioxt-certified-301840146.html
- WELOV: Matter air purifiers — https://homekitnews.com/tag/welov
- Mujoy: appears on the Leedarson Thread plug cert (above). Ganiza, GoGonova, Syvio: named in the press release only; no product pages found. **[UNCERTAIN]** "Ganiude" from the brief is likely a misspelling of Ganiza.
- "Consciot" ceiling lights also certified under AiDot Inc. — https://csa-iot.org/csa_product/consciot-smart-ceiling-light-54/
- **Not AiDot:** GE Lighting/Cync (own app) and Lepro (own app, https://www.lepro.com/collections/ai-smart-lighting) — no AiDot relationship found.

**Product types**
- Wi-Fi (2.4 GHz) + BLE bulbs/strips (BLE used for provisioning; "does not support Matter or Apple Home") — https://linkind.com/products/linkind-wi-fi-smart-light-bulb-a19-rgbtw
- Matter-over-Wi-Fi bulbs (A19, BR30, ST19/ST64 filament, E12 B11), plugs, downlights, ceiling lights — https://www.aidot.com/matter
- Bluetooth-mesh outdoor/solar lights (SL5/SL5C spotlights etc.) controlled via phone BLE or the B1 Plus BLE-mesh hub — https://www.amazon.com/Linkind-BLE-Mesh-HUB/dp/B0C744MNWY , https://www.pcworld.com/article/2683130/linkind-smart-solar-spotlight-sl5c-review.html
- Linkind Matter Smart Hub 2: a Matter **bridge** that exposes BLE-mesh outdoor lights as Matter devices (up to 200 lights; Apple Home/Alexa/Google/SmartThings) — https://linkind.com/products/linkind-matter-smart-hub-2 , https://www.amazon.com/Linkind-Smart-Matter-Multi-Device-Control/dp/B0GHM1FZRQ
- Older Zigbee gear exists (Linkind 1-key remote ZS232000178) — https://zigbee.blakadder.com/Linkind_ZS232000178.html
- Cameras (Winees / "LK.IPC" models) — https://github.com/cbrightly/python-aidot-cameras

---

## 2. Local control: YES for Wi-Fi lights (officially published library)

### Official Home Assistant core integration
- Added in **Home Assistant 2026.6** (release blog: "Control your AiDot Wi-Fi smart lights, including A19 and BR30 bulbs ... Communication happens locally over your network, so no cloud connection is required", author @s1eedz) — https://www.home-assistant.io/blog/2026/06/03/release-20266/
- Docs: https://www.home-assistant.io/integrations/aidot/ — light platform only; on/off, brightness, CCT, RGBW; "Only login with username and password is supported"; device list pulled from cloud, re-checked every 6 h; quality scale Bronze.
- `manifest.json` (dev): `iot_class: local_polling`, `requirements: ["python-aidot==0.3.59"]`, `dhcp: [{hostname: "aidot"}]`, codeowners @s1eedz @HongBryan — https://raw.githubusercontent.com/home-assistant/core/dev/homeassistant/components/aidot/manifest.json
- Original PR #137504 (Feb 2025) was closed, but the integration still landed (a later PR; not located). Reviewer thread confirms architecture: "cloud supplies the device list and control stays local" — https://github.com/home-assistant/core/pull/137504
- Reauth flow merged 2026-10-14 (PR #186395) because cloud tokens get invalidated server-side — https://github.com/home-assistant/core/pull/186395
- Open issue #177283 (July 2026, still open): tokens go stale (401 code 21026 on `/houses`, refresh returns 400 code 21025), then local TCP handshakes fail ("0 bytes read on a total of 8 expected") — https://github.com/home-assistant/core/issues/177283

### Library: `python-aidot` (vendor-published, MIT)
- GitHub: https://github.com/AiDot-Development-Team/python-AiDot — 3 stars, 6 forks, created 2024-05-11, **last push 2026-09-30**, MIT, description "Can control the WiFi lights of AIDOT in the local area network" (GitHub API: https://api.github.com/repos/AiDot-Development-Team/python-AiDot)
- PyPI: https://pypi.org/project/python-aidot/ — latest **0.3.59, 2026-09-30**; deps aiohttp, cryptography, dacite, requests (https://pypi.org/pypi/python-aidot/json)
- The GitHub org `AiDot-Development-Team` is the vendor's own (HA codeowners are the same people) — https://github.com/AiDot-Development-Team
- Companion custom component: https://github.com/AiDot-Development-Team/hass-AiDot — 42 stars, 17 forks, last push 2026-10-15, 27 open issues. Fork https://github.com/toxuin/hass-AiDot (13 stars, HACS name "AiDot Lights Local", last push 2025-07-13) fixed a 2025 login bug; https://github.com/sulibot/hass-AiDot adds manual-IP when UDP discovery fails.
- Camera-capable fork: https://github.com/cbrightly/python-aidot-cameras (1 star, pushed 2026-10-25, topics include `leedarson`) + https://github.com/cbrightly/hass-aidot-cameras ; PyPI `python-aidot-cameras` 1.0.0rc62.

### Protocol as implemented in python-aidot (source-read 2026-10-26)

**Cloud (needed only for login + device list + per-device AES key/password)**
- Base URL: `https://prod-{region}-api.arnoo.com/v35`, regions `us`, `eu`, `jp` (country -> region map in `const.py`) — https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/login_const.py
- `APP_ID = "1383974540041977857"`; headers: `Appid: <APP_ID>`, `Terminal: app`, `Token: <accessToken>` (no Authorization header) — const.py https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/const.py
- Password is **RSA PKCS#1 v1.5** encrypted with a hardcoded 1024-bit public key (in `login_const.py`), base64 encoded.
- `POST /users/loginWithFreeVerification` body: `countryKey: "region:<Country Name>"`, `username`, `password` (RSA), `terminalId` (md5 of a machine id), `webVersion: "0.5.0"`, `area: "Asia/Shanghai"`, `UTC: "UTC+8"`. Response includes `id` (userId), `accessToken`, `refreshToken`. — client.py https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/client.py
- `POST /users/refreshToken` body `{refreshToken}`. Error codes: 21026 TOKEN_EXPIRED, 21025 LOGIN_INVALID, 560080 USER_PWD_INCORRECT (also 21027/21041 treated as auth failure).
- `GET /houses` (skip houses where `isOwner == false`), `GET /devices?houseId=…`, `GET /products/{ids}`, effects: `GET /devices/{id}/v4.0/favoriteEffectMode`, `GET /models/{modelId}/v3.0/effectModes?libraryId=aidot.preset`, `GET /devices/{id}/v3.0/effectModeParams?...`, cloud-side effect run: `POST /devices/execute/diffCommand` (body list of `{devId, effectUniqueID, action:"runLScript", in:{sessionId}}`).
- Device record fields: `id, name, mac, type, modelId, productId, houseId, roomId, online, firmwareVersion, hardwareVersion, protocolVersion, aesKey[] , password, properties{ssidName, ipAddress, macAddress, OnOff, Dimming, CCT, RGBW, EffectMode,...}, product{isDirectDevice,...}` — https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/models/device_model.py
- **Important: a second login with the same account invalidates the first token** (cbrightly README) — https://github.com/cbrightly/python-aidot-cameras . Use a dedicated account for the app or persist/refresh tokens carefully.

**LAN discovery (UDP)**
- Broadcast to `255.255.255.255:6666`, payload = JSON AES-encrypted with fixed key `"T54uednca587"` zero-padded to 32 bytes (AES-256-ECB, PKCS7). Request: `{protocolVer:"2.0.0", service:"device", method:"devDiscoveryReq", seq, srcAddr:"0.<userId>", tst, payload:{extends:{}, localCtrFlag:1, timestamp}}`. Response payload: `ip, mac, devId, productModel, bindFlag, conMode, lanMode, wifiMode, wifiBand, version, extends.srvHost`. Repeats 6 s x5 then every 120 s. — https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/discover.py , https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/models/discover_model.py
- Device also advertises DHCP hostname `aidot` (HA manifest).

**LAN control (TCP 10000)**
- Frame: 8-byte header `>H magic 0x1EED`, `>H msgtype` (1 = login/action, 2 = ping), `>I bodysize`, then body = JSON encrypted **AES-128-ECB + PKCS7** with key = `device.aesKey[0]` (string, padded into 16 bytes). No IV. — device_client.py https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/device_client.py , aes_utils.py https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/aes_utils.py
- Login: `{service:"device", method:"loginReq", seq, srcAddr:"<userId>", deviceId, payload:{userId, password:<device.password from cloud>, timestamp:"YYYY-MM-DD HH:MM:SS.ffffff", ascNumber:1}}`; success = `ack.code == 200`; store `payload.ascNumber + 1`. Device will **only accept the owning account's userId**, not shared-home members (cbrightly README, verified on 10 devices 2026-08-08).
- Action: `{method:"setDevAttrReq", service:"device", clientId:"ha-<userId>", srcAddr:"0.<userId>", seq:"ha93NNNNN", deviceId, tst(ms), payload:{devId, parentId, userId, password, channel:"tcp", ascNumber, attr:{...}}}`. Attr keys: `OnOff` 0/1, `Dimming` 0-100 (%), `CCT` kelvin int, `RGBW` = signed int32 of `(r<<24)|(g<<16)|(b<<8)|w`. State read: `getDevAttrReq`. Status pushes arrive as frames with `payload.attr` (same keys) and `effectUniqueID`.
- Keepalive: `{service:"test", method:"pingreq", seq:"123456", srcAddr:"123456", payload:{}}` with msgtype 2 every 30 s; reset after 3 missed. Model `lk.WIFI-RGBWLight-D0006` (1st gen) needs `getDevAttrReq` as ping every 10 s.
- Model IDs seen: `LK.light.A001493`, `LK.light.A001497`, `LK.plug.A001535`, `LK.IPC.A000088` (cbrightly README).

**Scope limits**: Wi-Fi lights (and plugs via fork) only. BLE-only / BLE-mesh devices are not reachable by this library (forum reports: SL5C and B1 Plus hub yield no entities) — https://community.home-assistant.io/t/aidot-linkind-bulbs-integration/765212?page=2

### Community reverse-engineering
- HA community thread (Aug 2024 ->): OP captured ~18-20 app API calls and replayed in Postman (cloud control works for groups), later superseded by the vendor library — https://community.home-assistant.io/t/aidot-linkind-bulbs-integration/765212
- "LINKIND WiFi bulb support?" thread: bulbs believed ESP32 (unverified), FCC ID 2AW95LS0102111261, teardown; blocking Wi-Fi at the router makes the AiDot app fall back to **Bluetooth** control; nobody has reflashed one — https://community.home-assistant.io/t/linkind-wifi-bulb-support/259995
- Unrelated: https://github.com/RitwikGupta/ha-linkind-ble is for a Linkind BLE *button* (HCRZ12FBM071), not bulbs.

---

## 3. Cloud API / developer program
- **No public developer program, OAuth, or API docs found.** aidot.com has no developer section (https://www.aidot.com/aidot-app.html, https://www.aidot.com/page/partner/index/ returned 404). The only "official" API surface is the vendor-published python-aidot library above, which hardcodes the app ID and RSA key (effectively an app-token-style private API on Leedarson's Arnoo cloud).
- Arnoo offers white-label/B2B contact (`enquiry@leedarson.com`) but no self-serve API — https://www.arnoo.com/about/contact-us
- Camera fork documents additional cloud pieces: MQTT signaling, ICE/TURN, vendor relay for WebRTC — https://github.com/cbrightly/python-aidot-cameras

---

## 4. Bluetooth
- Wi-Fi bulbs have BLE used for provisioning; the official app can also control them over BLE when Wi-Fi is blocked (forum, above). **No published GATT/BLE protocol for AiDot/Linkind bulbs was found** on GitHub or forums (searches: "aidot ble", "linkind gatt", "linkind telink", "linkind sig mesh").
- Outdoor SL5/SL5C lines are "Bluetooth mesh" (PCWorld review, above); the vendor hub is the B1 Plus (32 lights) or Matter Smart Hub 2 (bridge, 200 lights). Chipset/stack (Telink vs. SIG mesh vs. proprietary) **[UNCERTAIN]** - not documented anywhere found; Telink's SIG-mesh SDK is a plausible but unconfirmed candidate (https://wiki.telink-semi.cn/wiki/protocols/Bluetooth-Mesh/).
- Practical iOS implication: BLE-mesh lights are best reached via the Matter Smart Hub 2 (then they are ordinary Matter lights) or via cloud (SmartThings linkage works per forum).

---

## 5. Matter certification
- AiDot Inc. is a CSA member with many certified products (bulbs, plugs, downlights, ceiling lights, air purifier) — https://csa-iot.org/member/aidot-inc/ (listing page timed out repeatedly on 2026-10-26; individual product pages gathered via search snippets):
  - Linkind Smart Light Bulb, Matter 1.4, cert CSA25421MAT45939-24, certified 2025-06-25 (E12 B11 family; Matter Alpha shows "Thread: beta" placeholder — actual transport Wi-Fi) — https://www.matteralpha.com/aidot-inc/linkind-smart-light-bulb-p3776
  - Linkind Smart Light Bulb, **Matter 1.5, Wi-Fi + Bluetooth**, certified 2026-01-30, certs CSA26079MAT49669-24 and CSA2608RMAT49723-24 — https://csa-iot.org/csa_product/linkind-smart-light-bulb-101/ , https://csa-iot.org/csa_product/linkind-smart-light-bulb-102/
  - Linkind Smart Flame Bulb https://csa-iot.org/csa_product/linkind-smart-flame-bulb-6/ ; Linkind Smart Plug https://csa-iot.org/csa_product/linkind-smart-plug-4/ ; Linkind Smart Downlight https://csa-iot.org/csa_product/linkind-smart-downlight/ ; OREiN Smart Ceiling Light (2026-02-26) https://csa-iot.org/csa_product/orein-smart-ceiling-light-64/
  - Leedarson "Matter over Thread Plug", Matter 1.0, Thread+BLE, VID **0x1168**, PID 0x9000, cert CSA23767MAT41280-24, sold as LEEDARSON/Mujoy/Orein/Linkind — https://csa-iot.org/csa_product/matter-over-thread-plug-21/ (**[UNCERTAIN]** whether AiDot Inc. certs use the same VID 0x1168 or a separate AiDot VID; the AiDot pages hide VID behind login).
- Retail Matter SKUs: Linkind Matter A19 800/1100 lm RGBTW & CCT, ST19, BR30, OREiN BR30/ST58/A19, Matter plug — https://www.aidot.com/matter ; Amazon https://www.amazon.com/Linkind-Matter-SmartThings-Changing-Lighting/dp/B0C58MCNXL , https://www.amazon.com/OREiN-Reliable-Changing-Assistant-SmartThings/dp/B0BLTWFJWY
- Transport: shipping bulbs are **Matter over Wi-Fi** (BLE for commissioning); TechWalls review: "do not support Thread" — https://www.techwalls.com/aidot-orein-linkind-matter-smart-light-bulb-review/ . A "Matter Version with Thread" RGBW bulb is listed as pre-sale — https://www.aidot.com/aidot-thread-smart-wifi-rgbw-light-bulb-matter-version.html
- Matter 1.4 OTA firmware (v3.0.0) rolled out Nov 2025 for Linkind A19 and BR30, adds Apple Home Adaptive Lighting — https://www.matteralpha.com/news/aidot-and-linkind-roll-out-matter-1-4-firmware-for-lightbulbs
- HA users confirm Matter bulbs commission fine into HA (and can be multi-admin shared with the AiDot app, but AiDot-specific presets/music sync and firmware updates don't flow through the HA fabric) — https://community.home-assistant.io/t/linkind-aidot-workflow/910309 ; one Aqara-hub user saw only on/off + brightness via Matter — https://community.home-assistant.io/t/aidot-linkind-bulbs-integration/765212?page=2

---

## 6. Platform relationships (not Tuya)
- **Not Tuya.** The stack is Leedarson's own Arnoo cloud (`prod-{us,eu,jp}-api.arnoo.com`), own app ID, own LAN protocol. No Tuya/Smart Life references anywhere in the library or listings.
- Alexa: official "AiDot" skill by Arnoo ("works with WiFi/Zigbee smart light bulbs, and WiFi smart plug") — https://www.amazon.com/Arnoo-AiDot/dp/B09CTB9K49 (also an older "Arnoo Smart home" skill https://www.amazon.com/Arnoo-Smart-home/dp/B07JWHSP5C)
- Google Home: AiDot bulbs were among the first "Works with Google Home" Matter certifications (CES 2023) — https://www.techtimes.com/articles/287064/20230201/aidot-is-teaming-up-with-google-to-showcase-the-new-matter-certified-smart-bulb-at-ces-2023.htm ; non-Matter devices link via account linking (AiDot app page lists Google Home) — https://www.aidot.com/aidot-app.html
- SmartThings: cloud-to-cloud linked service ("Connected services > AiDot") — https://aidot.zendesk.com/hc/en-us/articles/54484370033305-How-to-delete-the-SmartThings-Integration ; partnership blog https://blog.smartthings.com/matter/qa-smartthings-and-aidot-on-how-matter-creates-a-more-seamless-smart-home/
- IFTTT: service `LDS_AiDot` ("LDS" = Leedarson) with 5 polling triggers (door, motion, IPC event, water leak, scene run) and 5 actions (activate scene, change color, change color temperature, turn on/off, change brightness) — https://ifttt.com/LDS_AiDot
- The AiDot app page lists ecosystems: Matter, Alexa, Apple Home, Google Home, SmartThings, IFTTT — https://www.aidot.com/aidot-app.html

---

## 7. Apple Home (HomeKit)
- Only via Matter. AiDot's Matter page: "fully compatible with Apple Home", requires iOS/iPadOS 16.4+, Apple TV 4K / HomePod as controller; Matter "works locally, without using the cloud" — https://www.aidot.com/matter
- Linkind's own Matter setup guide covers adding to Apple Home with the setup code — https://linkind.com/blogs/matter/a-comprehensive-guide-how-to-set-up-your-matter-smart-light-bulbs
- Non-Matter Wi-Fi bulbs explicitly "do not support Matter or Apple Home" — https://linkind.com/products/linkind-wi-fi-smart-light-bulb-a19-rgbtw
- No native HomeKit (HAP) certification found for any AiDot brand.

---

## 8. Implications for a custom iOS app (synthesis)

1. **Matter SKUs (best path):** commission with HomeKit/Matter via Apple's `MatterSupport` framework into the Home fabric, then control with HomeKit APIs (or use Apple's Matter commissioning for your own fabric). Fully local, no AiDot account. Loses AiDot preset/music-sync effects.
2. **Non-Matter Wi-Fi bulbs/strips/plugs:** port python-aidot's protocol to Swift. Needs a one-time cloud login (RSA-encrypted password -> accessToken) to fetch `/houses` + `/devices` (gets `aesKey`, `password`, `id`), then **UDP 6666 discovery + TCP 10000 AES-ECB control entirely on LAN**. Caveats: must be the *owner* account; a second login elsewhere invalidates tokens; iOS local-network permission + UDP broadcast entitlement (`NWConnection` with broadcast, or use the DHCP hostname `aidot`/Bonjour-less mDNS absent, so broadcast is the only discovery; store IPs as fallback). Effects require cloud `POST /devices/execute/diffCommand`.
3. **BLE-mesh outdoor lights:** no reverse-engineered protocol. Use Linkind Matter Smart Hub 2 (bridge -> Matter) or the SmartThings/Alexa cloud routes.
4. **Cloud-only fallback:** the same arnoo.com REST API; no official terms for third-party use. **[RISK]** undocumented, could change; stale-token bugs seen in HA issue #177283.
