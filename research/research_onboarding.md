# "Add a brand" onboarding research — per-brand end-user steps for a multi-brand iPhone light controller

Researched 2026-10-26. Sources are primarily Home Assistant (HA) integration docs + config-flow strings/manifests (which encode the exact user-facing steps and mDNS/DHCP matchers), library READMEs/source, and vendor/Apple support pages. Every claim is tagged:

- **[V]** = verified against a fetched page (URL given)
- **[M]** = from prior knowledge, not verified this session — confirm before shipping copy to users
- **[?]** = genuinely uncertain / conflicting

Note: the web-search budget for this session was exhausted after the first batch, so everything below came from direct fetches of known URLs. Several vendor pages (Govee LAN guide, Hue Bluetooth/Matter FAQ, Nanoleaf OpenAPI, Wyze API-key article, Elgato help, Apple developer docs) are JavaScript-rendered or returned 403/404 and could not be read; those items are marked [M].

---

## 0. Apple-side setup the user must do on iPhone (applies to every brand)

### 0.1 Local Network permission (needed for every LAN/mDNS/UDP brand)
- **What the user sees:** On iOS 14+ an app must ask permission the first time it tries to browse/talk to the local network. If the user taps "Don't Allow", the app can still use the internet and system services such as HomeKit, AirPlay, AirPrint. **[V]** https://support.apple.com/en-us/HT211870
- **How to re-enable:** Settings > Privacy & Security > Local Network > toggle the app on. **[V]** same URL
- **Developer requirements [M — TN3179 page was JS-rendered, could not be read]:** `NSLocalNetworkUsageDescription` in Info.plist; `NSBonjourServices` must list EVERY Bonjour service type the app browses (see per-brand service names below — `_hue._tcp`, `_nanoleafapi._tcp`, `_elg._tcp`, `_wled._tcp`, `_shelly._tcp`, `_http._tcp`, `_lifx._udp`, `_miio._udp`, `_lutron._tcp`, `_hap._tcp`, `_googlecast._tcp` etc.). Raw UDP broadcast/multicast (WiZ 38899, LIFX 56700, Govee 239.255.255.250:4001, Magic Home 48899, Twinkly 5555, Kasa 9999/20002, Yeelight SSDP 1982) requires the `com.apple.developer.networking.multicast` entitlement, which must be requested from Apple. Design the wizard to show an in-app explainer BEFORE the first network call so the user understands the prompt (the prompt appears once; a denial silently breaks all discovery).
- **Wizard troubleshooting copy:** "If no lights are found, check Settings > Privacy & Security > Local Network and make sure [App] is on. Also make sure your iPhone is on the same Wi-Fi network as the lights (not cellular, not a Guest network)."

### 0.2 Bluetooth permission
- Needed for: Hue Bluetooth-only bulbs (if you implement BLE control), Shelly BLE provisioning, Matter commissioning (Matter uses BLE for commissioning) **[V HA Matter docs]**. Info.plist `NSBluetoothAlwaysUsageDescription` **[M]**. Re-enable: Settings > Privacy & Security > Bluetooth > app toggle **[M]**.

### 0.3 HomeKit permission (for controlling anything added to Apple Home — HomeKit-native OR Matter)
- Apple HomeKit framework exposes everything the user added to Apple Home, including Matter accessories, via `HMHomeManager` — so one HomeKit code path covers Hue (bridge), Nanoleaf, LIFX, Eve, Meross-HK, Lutron Smart Bridge, IKEA Dirigera (HomeKit/Matter bridge), and any Matter light. **[M — Apple dev docs were JS-rendered]**
- Requirements **[M]**: `com.apple.developer.homekit` entitlement (Xcode HomeKit capability), `NSHomeKitUsageDescription`, user grants access on first use; re-enable in Settings > Privacy & Security > HomeKit. HomeKit does not work in Simulator; the device needs iCloud Keychain.

### 0.4 Home hub (HomePod / Apple TV) — when it's required
- HomePod mini / HomePod become a home hub automatically after setup; Apple TV becomes one when assigned to a room (Settings > AirPlay and Apple Home > Room). Needed for remote (away-from-home) access, automations, and sharing. **[V]** https://support.apple.com/en-us/102557
- **Matter:** Apple's older hub page says a home hub is required to add Matter accessories **[V 102557]**, while the newer Matter page says **iOS 18 or later lets you add and control Matter accessories without a home hub** (hub still recommended) **[V]** https://support.apple.com/en-us/102135. Treat as: iOS 18+ no hub needed for Wi-Fi Matter; a hub is still strongly recommended.
- **Thread:** Thread accessories need a Thread-enabled home hub (Apple TV 4K Wi-Fi+Ethernet, HomePod 2nd gen, HomePod mini, or a third-party border router); iPhone 15 Pro/Pro Max and later can control Thread accessories without a hub on iOS 18 (may need a firmware update from the manufacturer). **[V]** https://support.apple.com/en-us/102135
- Only the home owner can add a hub; needs iCloud Keychain + 2FA on. **[V 102557]**

### 0.5 Adding a Matter accessory to Apple Home (generic wizard step)
1. Home app > "+" > Add Accessory.
2. If the accessory was previously paired with another app: tap "More options" and select it. Otherwise scan the Matter QR code (or hold iPhone near the accessory when prompted) and finish on-screen setup. Multi-pack QR codes can pair the whole pack. **[V]** https://support.apple.com/en-us/102135
3. Use the 2.4 GHz Wi-Fi during commissioning; keep phone near device/border router; Bluetooth on (Matter commissions over BLE). **[V]** https://www.home-assistant.io/integrations/matter/
4. Photograph the QR code — it is needed to re-commission after a reset. **[V HA Matter docs]**

### 0.6 Multi-admin: a device can be in the vendor app AND Apple Home (and our app via HomeKit)
- Matter supports multiple "fabrics". Sharing from Google Home: Device > Settings > "Linked Matter apps & services" > "Link apps & services" > pick app, or "Use pairing code" / "Share with QR code" (temporary code). **[V]** https://support.google.com/googlenest/answer/13127223
- Sharing from Apple Home **[M — Apple's page did not describe it]**: Home app > long-press accessory > Accessory Settings > scroll to "Turn On Pairing Mode" > a one-time setup code appears (valid ~15 min). Enter that code in the other app ("already in use" path). Verify this wording against current iOS before publishing.
- Sharing from HA: device > "Share device" > scan QR/code in the other app; no hardware button press needed. **[V HA Matter docs]**
- Key design implication: since our app controls Matter devices through HomeKit, the user never needs to commission into OUR app; they commission into Apple Home (step 0.5) and we read it via `HMHomeManager`. The vendor app remains usable (Hue, Nanoleaf, Tapo, etc. keep their own fabric/cloud path).

### 0.7 Native HomeKit (HAP) accessories — one controller per accessory
- A HAP (non-Matter) accessory can be paired with only ONE controller at a time. If it's already in Apple Home, it must be removed before another controller (e.g., HA) can pair it. **[V]** https://www.home-assistant.io/integrations/homekit_controller/
- For OUR app this is good news: pair once into Apple Home, control via HomeKit framework. Never try to HAP-pair directly from our app.
- HAP discovery service: `_hap._tcp.local.` / `_hap._udp.local.`; BLE adverts manufacturer ID 76 (Apple). **[V]** HA homekit_controller manifest.

---

## 1. Philips Hue

### Hue Bridge (Zigbee bulbs)
- **(a) Prereqs:** Hue Bridge v2 (square; v1 round is EOL) on Ethernet to the same router; lights already added in the Hue app. No cloud account needed for local API. **[V]** https://www.home-assistant.io/integrations/hue/
- **(b) Discovery:** mDNS `_hue._tcp.local.`; HomeKit model `BSB002`. **[V]** HA hue manifest. Also the cloud broker https://discovery.meethue.com and router DHCP table; the Hue app shows the bridge IP under Settings > Hue Bridges. **[V]** https://developers.meethue.com/develop/get-started-2/
- **(c) Pairing in OUR app:** POST `/api` with `{"devicetype":"ourapp#iphone name"}` → first response is error 101 "link button not pressed" → tell user "Press the round button on top of the Hue Bridge, then tap Continue" → POST again → response contains `username` (the application key). HA's copy: "Press the button on the bridge to register Philips Hue with Home Assistant." **[V]** Hue get-started + HA hue strings. Use that key as header `hue-application-key` for API v2 (`https://<bridge>/clip/v2/...`) **[M]**. Link-button window is roughly 30 s **[M]**; HA's copy does not state a time.
- **(d) Failure modes:** "No Philips Hue bridges discovered" / "Unable to discover Hue bridges" (mDNS blocked, different VLAN) → offer manual IP entry ("The hostname or IP address of your Hue bridge"). "Failed to register, please try again" = button not pressed in time. **[V]** HA hue strings. Scenes must be created in the Hue app (API v2 cannot create). **[V]** HA hue docs.
- **(e) Matter:** The Bridge (and Bridge Pro) is a Matter bridge; the Matter firmware arrives automatically. Requires Matter-logo bulbs; Bluetooth-connected Hue products can't be used via Matter; Play HDMI Sync Box and Tap Dial's dial are excluded. **[V]** https://www.philips-hue.com/en-us/explore-hue/works-with/matter. Enabling: Hue app > Settings > Smart home > Matter > "Connect" shows the QR/setup code **[M]**. The bridge keeps working in the Hue app simultaneously (multi-admin) **[M]**.
- **(f) HomeKit:** Native: Hue app > Settings > Smart home > Apple Home / or Apple Home > Add Accessory > scan the HomeKit code on the bottom of the bridge **[M]**. Once in Apple Home, our app controls via HomeKit. Recommend the local API (c) as the primary path because it exposes scenes/effects/gradient that HomeKit lacks.

### Hue Bluetooth-only bulbs (no bridge)
- **(a)** Without a bridge, Bluetooth bulbs are controlled only by the Hue (Bluetooth) app over BLE; limit ~10 lights, in-room range, no remote access, no HomeKit/Matter. **[M — Hue BT pages returned 404]** The Matter page confirms "Hue products connected via Bluetooth can't be used with Matter" **[V]**.
- **Recommended wizard path:** tell the user to buy/use a Hue Bridge; then in the Hue app: Settings > Lights > Add light > Search (or enter the 6-char serial number printed on the bulb) **[M]**. Then follow the Bridge flow above.
- **Alternative (big lift):** implement Hue BLE directly (GATT, unofficial) — not recommended.

---

## 2. WiZ (Signify)
- **(a) Prereqs:** WiZ app, bulb joined to 2.4 GHz Wi-Fi via the app **[V HA]** (2.4 GHz is implied; WiZ supports only 2.4 GHz **[M]**). No hub. One setting: **"Allow local communication"** must be on (on by default): WiZ app > settings menu (upper-left) > scroll to security settings > toggle. **[V]** https://www.home-assistant.io/integrations/wiz/
- **(b) Discovery:** UDP broadcast on port **38899** with `{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}`; bulbs reply with their MAC/module. **[V]** pywizlight discovery.py. DHCP hints: hostname `wiz_*`, OUIs A8BB50, D8A011, 444F8E, 6C2990. **[V]** HA wiz manifest. Must send to the subnet's broadcast address (e.g., 192.168.1.255) — cross-subnet discovery needs manual IP. **[V]** pywizlight README.
- **(c) In OUR app:** nothing — no auth. Just "Scanning for WiZ lights…" then list. Offer "Add by IP".
- **(d) Failures:** "Allow local communication" off; client isolation; bulb on a different subnet/VLAN; UDP packet loss (retry sends). **[V]** HA + pywizlight.
- **(e) Matter:** Newer WiZ "Matter" SKUs exist **[M]**; Matter path per 0.5. Legacy WiZ bulbs are not Matter.
- **(f) HomeKit:** Not native. Only via Matter SKUs or a bridge.

---

## 3. AiDot / Linkind / OREiN (same cloud; python-aidot)
- **(a) Prereqs:** Add the lights in the **AiDot app** first (Linkind/OREiN bulbs use the same account **[M]**). Only username + password login is supported. **[V]** https://www.home-assistant.io/integrations/aidot/
- **(c) In OUR app:** three fields exactly as HA: **Country** ("The country selected by AiDot app when logging in"), **Username** ("Account logged in through AiDot app"), **Password**. **[V]** HA aidot strings.json. Country is mapped to a region server: EU list (GB, DE, FR, … TR, UA), US list (US, CA, MX, BR, …), JP list (JP, AU, IN, SG, KR, …); default "US". **[V]** python-aidot const.py. Errors to show: invalid auth; "The credentials belong to a different AiDot account". **[V]**
- **(b) Discovery:** Device list comes from AiDot Cloud after login (re-checked every 6 h by HA); then a persistent **local TCP** connection per device for real-time state (IoT class: local polling). Local discovery is by DHCP hostname `aidot` in HA. **[V]** HA docs + manifest. The local session is encrypted with a per-device `aesKey` delivered by the cloud (config key `aesKey`, plus `accessToken`/`refreshToken`). **[V]** const.py (ports/UDP details not in fetched sources **[?]**).
- **(d) Failures:** Wrong country → login fails or devices missing (pick the country shown in the AiDot app). Token expiry (error 21026) → re-auth prompt ("The AiDot login for {username} is no longer valid. Please enter your password"). **[V]** Supported in HA: A19, BR30 bulbs (on/off, brightness, CT, RGBW). **[V]**
- **(e) Matter:** Many Linkind/AiDot/OREiN bulbs are sold as Matter-over-Wi-Fi **[M]** → prefer the Matter→Apple Home path for those; use the cloud login path for non-Matter units.
- **(f) HomeKit:** Not native.

---

## 4. LIFX
- **(a) Prereqs:** Bulb joined to Wi-Fi with the LIFX app (2.4 GHz **[M]**); no hub; no cloud token for local control. Serial number is printed on the light and shown in the LIFX app. **[V]** https://www.home-assistant.io/integrations/lifx/
- **(b) Discovery:** LIFX LAN protocol UDP broadcast (port 56700 **[M]**), Zeroconf `_lifx._udp.local.`, HomeKit models "LIFX *", DHCP OUI `D073D5`. **[V]** HA lifx manifest. Same subnet required for broadcast; else add by host (IP) and/or serial. **[V]**
- **(c) In OUR app:** none for LAN. Optional cloud: user generates a personal access token at https://cloud.lifx.com/settings and pastes it; use `Authorization: Bearer <token>` over HTTPS. **[V]** https://api.developer.lifx.com/reference/authentication
- **(d) Failures:** different subnet/VLAN (add by IP); polling every 10 s so external changes lag; LIFX Switch not on LAN protocol. **[V]**
- **(e) Matter:** LIFX Switch fw 4.100+ is Matter-over-Wi-Fi; if already in Apple/Google Home, generate a new pairing code first. **[V]** Newer LIFX bulbs are also Matter **[M]**.
- **(f) HomeKit:** Most LIFX devices support HAP natively (HA says a device can be set up with both LIFX LAN and HomeKit at once). **[V]** Steps: Apple Home > Add Accessory > scan the HomeKit code on the bulb/box (or LIFX app > Settings > "Apple Home" **[M]**).

---

## 5. Govee
- **(a) Prereqs:** Govee Home app, device on 2.4 GHz Wi-Fi **[M]**, Govee account. For local control the device must support the **LAN API** (model-specific; HA lists supported H-numbered models) and the user must enable it: Govee Home app > device > Settings (gear) > **"LAN Control"** toggle **[M — govee page https://app-h5.govee.com/user-manual/wlan-guide is JS-only; HA only says "refer to the instructions available" there]**. Govee says LAN Control requires firmware update + same Wi-Fi.
- **(b) Discovery (LAN):** send `{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}` to multicast **239.255.255.250:4001**; devices reply to our UDP **4002**; commands (`turn`, `brightness`, `colorwc`) go to the device's UDP **4003**. **[V]** govee-local-api controller.py + message.py. Requires multicast entitlement on iOS (0.1).
- **(c) In OUR app (cloud alternative):** Govee **API key**: Govee Home app > Settings > **"Apply for API Key"** > submit info; the key is emailed **[V menu path]** https://developer.govee.com/reference/apply-you-govee-api-key (email delivery **[M]**). User pastes the key (header `Govee-API-Key`) **[M]**; rate limits ~10,000/day **[M]**.
- **(d) Failures:** "No devices found" → LAN Control off / unsupported model / multicast blocked by router or VLAN; "Port 4002 already in use" (another app listening); "No enabled network adapter has an IPv4 address". **[V]** HA strings. Scenes not supported on all models. **[V]**
- **(e) Matter:** Several 2024+ Govee SKUs are Matter-over-Wi-Fi **[M]**; Matter path per 0.5.
- **(f) HomeKit:** Not native (Matter only).

---

## 6. Nanoleaf
### Panels/Canvas/Shapes/Elements/Lines (Wi-Fi, Open API)
- **(a) Prereqs:** Set up in the Nanoleaf app (Wi-Fi). No account needed for local API. **[V]** https://www.home-assistant.io/integrations/nanoleaf/
- **(b) Discovery:** mDNS `_nanoleafapi._tcp.local.` and `_nanoleafms._tcp.local.`; SSDP `nanoleaf:nl29/nl42/nl52/nl69/nl81`, `Nanoleaf_aurora:light`; HomeKit models NL29, NL42, NL47, NL48, NL52, NL59, NL69, NL81. **[V]** HA nanoleaf manifest. API port 16021 **[M]**.
- **(c) In OUR app:** HA copy: **"Press and hold the power button on your Nanoleaf for 5 seconds until the button LEDs start flashing."** Devices without a power button (e.g., Skylight) use **"Connect to API"** in the Nanoleaf app instead. The user then has **30 seconds** to tap Continue (POST `/api/v1/new` → `auth_token`). Error: "Nanoleaf is not allowing new tokens, follow the instructions above." **[V]** HA nanoleaf strings.json. (Nanoleaf's own doc says 5–7 s **[M]**; the OpenAPI page redirected to a forum that returned 403.)
- **(d) Failures:** token invalid after factory reset → re-pair; mDNS blocked → manual IP ("The hostname or IP address of your Nanoleaf device"); "different Nanoleaf device at this address" (DHCP reuse → set static IP). **[V]**
- **(e)/(f):** All these panels are native HomeKit (Apple Home > Add Accessory > scan code in app/on controller). Newer Shapes/Lines/Elements/4D are also Matter **[M]**.

### Nanoleaf Essentials (bulbs, lightstrips; Thread/BLE)
- Not supported by the Open API; control over Thread/Bluetooth via HomeKit (HA uses homekit_controller). **[V]** HA nanoleaf docs. Essentials Matter versions: commission into Apple Home (needs Thread border router = HomePod mini / Apple TV 4K) **[V 0.4]**. Our app then controls via HomeKit. Older HomeKit-only Essentials: add via HomeKit code in the Nanoleaf app / on the bulb **[M]**.

---

## 7. TP-Link Tapo & Kasa
- **(a) Prereqs:** Provision with the Kasa or Tapo app (Deco app also works); 2.4 GHz **[M]**. **Tapo and newer Kasa devices require the TP-Link cloud account email + password for LOCAL authentication**; older Kasa devices (HS100/HS200/HS220/EP25 old firmware) do not. Some firmware additionally requires **"Third-Party Compatibility"** enabled in the vendor app (Tapo app: Tapo Lab > Third-Party Compatibility; Kasa app: Settings) — or factory reset + block internet. **[V]** https://www.home-assistant.io/integrations/tplink/ + python-kasa README.
- **(b) Discovery:** UDP broadcast to 255.255.255.255 on port **9999** (legacy) and **20002** (newer; also 20004). **[V]** python-kasa discover.py. DHCP hostname patterns `hs*`, `k[lps]*`, `lb*`, `l[59]*`, `tp*`, `p1*`, `s5*` with TP-Link OUIs. **[V]** HA tplink manifest. No cross-subnet discovery; add by IP + static IP. **[V]**
- **(c) In OUR app:** When a device needs auth, show HA's copy: "Authenticate — this device requires TP-Link credentials. Note that both email and password are case-sensitive." Fields: TP-Link cloud username = full email (case-sensitive), password. **[V]** HA tplink strings.
- **(d) Failures:** "Unable to authenticate" → wrong-case email, Third-Party Compatibility off, or the TSS protocol between TP-Link devices breaking auth (unplug other TP-Link devices during onboarding); device not found → different subnet; removing/re-adding in the Tapo app choosing the exact model fixes some models. Kasa bulbs have no effects. **[V]**
- **(e) Matter:** Many Tapo bulbs/strips (e.g., L535E, L900/L920 Matter variants) and some Kasa are Matter-over-Wi-Fi **[M]** → Matter path 0.5. The local-credential path still works alongside.
- **(f) HomeKit:** A few Tapo/Kasa models are native HomeKit (e.g., Tapo P125/P125M plug, Kasa KP125M?) **[?]**; bulbs generally are not. Prefer Matter.

---

## 8. Yeelight
- **(a) Prereqs:** Yeelight app (or Xiaomi Home **[M]**), bulb set up, firmware updated. Enable **LAN Control**: Yeelight app > Device tab > select device > tap the "more" icon > **LAN Control** > turn on. (Older firmware: "Developer mode".) **[V]** https://www.yeelight.com/faqs/lan_control + HA yeelight docs.
- **(b) Discovery:** SSDP-like multicast to **239.255.255.250:1982** with search target `wifi_bulb` (non-standard, so generic UPnP browsers miss it); also mDNS `_miio._udp.local.` name `yeelink-*`, DHCP hostname `yeelink-*`, HomeKit models `YL*`. The Mijia desk lamp `lamp1` has no mDNS. **[V]** HA yeelight docs + manifest.
- **(c) In OUR app:** none (no auth); allow manual IP.
- **(d) Failures:** LAN Control missing until firmware update; ~60 requests/min limit (use "music mode" to bypass — bulb connects back to a socket we host; after a dropped connection the first command is ignored; bulb doesn't go "unavailable"). **[V]** Some newer Yeelight models dropped LAN Control entirely **[?]**.
- **(e) Matter:** Some 2023+ Yeelight products are Matter **[M]**.
- **(f) HomeKit:** Several Yeelight models are native HomeKit (`YL*` HomeKit matcher confirms) **[V manifest]**; add via HomeKit code in the Yeelight app.

---

## 9. Tuya / Smart Life white-label (Feit, Merkury, Globe, Geeni, etc.)
### Cloud path (official OpenAPI, as HA does it)
- **(a) Prereqs:** Tuya Smart or Smart Life app account with devices added. **[V]** https://www.home-assistant.io/integrations/tuya/ (Feit/Merkury/Globe have their own re-skinned apps on the Tuya cloud; devices usually can also be added to Smart Life **[M]**.)
- **(c) In OUR app:** HA's flow: user enters their **User Code** (Smart Life app > Me > gear > Account and Security > "User Code"), we show a QR code, user scans it with Smart Life's "+"/scanner to authorize. **[V]** HA tuya docs. This uses Tuya's Smart Home SDK / "Smart Life login via QR" which requires a Tuya developer project **[M]**. Cloud push only; reload after adding devices in the app. **[V]**
### Local path (tinytuya / localtuya style) — power-user only
1. Pair devices in Smart Life (not a guest account).
2. Create a Tuya IoT account at iot.tuya.com; create a Cloud project, pick the data-center region matching the app; note Access ID/Secret.
3. Project > Devices > **Link Tuya App Account** > scan QR with the Smart Life app (Me tab QR button); choose Automatic + Read Only Status.
4. Subscribe to **IoT Core** and Authorization APIs (free trial ~1 month; renew under Project Management or key fetching stops).
5. Run the tinytuya wizard with API ID/Secret/region (cn, us, us-e, eu, eu-w, sg, in) → prints each device's **local key**. **[V]** https://github.com/jasonacox/tinytuya README
- **(b) Discovery:** devices broadcast on UDP 6666 (v3.1), 6667 (encrypted, v3.3+), 7000; control TCP 6668; protocol versions 3.1–3.5. **[V]**
- **(d) Failures:** local key changes on reset/re-pair; **only ONE local TCP connection at a time** (close Smart Life app); wrong data-center region → no devices listed; IoT Core trial expired; battery devices don't answer. **[V]**
- **Recommendation for consumers:** steer Tuya-based Feit/Merkury/Globe users to **Matter** when the SKU supports it (many 2023+ Feit/Globe bulbs are Matter **[M]**) or to the cloud QR login; keep local-key as "Advanced".
- **(e)/(f):** No native HomeKit on Tuya white-label except specific Matter/HomeKit SKUs.

---

## 10. GE Cync (Savant)
- **(a) Prereqs:** Cync app, Cync account, every device added in the Cync app; the account must have **at least one Wi-Fi-connected device** (Bluetooth-only older bulbs need a Cync bridge/Wi-Fi device). **[V]** https://www.home-assistant.io/integrations/cync/
- **(c) In OUR app:** Email + Password, then a **"Two-factor code"** — "the code was sent to the user's Cync account email". **[V]** HA cync strings.json.
- **(b) Discovery:** Cloud push (device list from Cync servers; HA IoT class Cloud Push). **[V]** Local Bluetooth-mesh/TCP control exists in community projects (cync-lan, cync_lights) but is unofficial **[M]**.
- **(d) Failures:** **"Cync servers only allow one instance of your account to connect at a time"** — opening the Cync app disconnects our session for ~10 s. Effects/light shows/segments unsupported. **[V]**
- **(e) Matter:** GE Cync announced Matter support for some products **[?]**.
- **(f) HomeKit:** none native.

---

## 11. Sengled
- No official HA core integration (manifest 404). Community `ha-sengledapi` uses an **unofficial cloud API** mimicking the app: Sengled Home/Element account **email**, **password**, **country** (`us`, `au`, `it`, `eu`), `wifi: true` for Wi-Fi bulbs; MQTT (paho) for cloud push. Author stopped maintaining it. **[V]** https://github.com/jfarmer08/ha-sengledapi
- **(a) Prereqs:** Sengled Home app + account; Wi-Fi bulbs on 2.4 GHz **[M]**; Zigbee bulbs need the Sengled hub (or any Zigbee coordinator — out of scope for iPhone).
- **(e) Recommended path:** Sengled sells **Matter** Wi-Fi bulbs (2023+) **[M]** → Apple Home → HomeKit control. Non-Matter Sengled Wi-Fi: cloud-only, fragile; mark as "best-effort".
- **(f) HomeKit:** none native.

---

## 12. Wyze
- No official HA integration (404). Community `ha-wyzeapi`: Wyze **email + password + API Key ID + API Key** created at the Wyze developer portal (Wyze support article "Creating an API Key"; the page returned 403 — from memory: https://developer-api-console.wyze.com, log in, Create Key, name it, keys expire after 1 year **[M]**). 2FA supported. Unofficial API — Wyze can break it anytime. **[V]** https://github.com/SecKatie/ha-wyzeapi
- **(a) Prereqs:** Wyze app, account, bulbs on 2.4 GHz **[M]**.
- **(b):** cloud list only; no local protocol.
- **(e) Matter:** Wyze has very limited Matter (Matter bulbs announced 2024?) **[?]**. **(f):** none.

---

## 13. Meross
- **(a) Prereqs:** Meross app + account; device on 2.4 GHz **[M]**. Local control requires the per-account **device key**: obtained by logging in with the Meross cloud account (meross_lan downloads it) or entered manually "from your Meross profile". **[V]** https://github.com/krahabb/meross_lan README
- **(b) Discovery:** DHCP-based (power-cycle the device for 10 s if not seen); then local **HTTP** on the LAN, or MQTT (local broker or Meross cloud brokers); "Auto" protocol switches between them. **[V]**
- **(c) In OUR app:** Meross email + password (to fetch the key) — or advanced "enter key + IP". **[V]**
- **(d) Failures:** wrong/empty key → retry/recover from account; unreliable → force HTTP; device reboots → "disable multiple requests"; needs NTP. **[V]**
- **(e)/(f):** Meross sells **HomeKit-native** SKUs (suffix "HK", e.g., MSL120HK bulb, MSS110/MSS210 plugs) and **Matter** SKUs (suffix "MA") **[M]** → Apple Home path; scan the HomeKit/Matter code on the device.

---

## 14. IKEA — DIRIGERA and TRÅDFRI gateway
### DIRIGERA
- **(a) Prereqs:** Hub set up in the IKEA Home smart app; lights paired there. **[M]** (README only says adaptive profiles come from the IKEA app.)
- **(b) Discovery:** hub announces itself as `gw2-<id>.local` (mDNS); HTTPS API on port 8443 **[M]**. **[V name]** https://github.com/Leggin/dirigera
- **(c) In OUR app (local API):** "Press the **action button on the bottom of the hub**, then tap Continue" → token returned; store it. Timeout tip: MTU 1500 mismatch. **[V]** dirigera README.
- **(e)/(f) Recommended path:** DIRIGERA is a **HomeKit bridge and a Matter bridge** (hub ≥ 2.615.8 exposes lights, plugs, blinds, sensors via Matter). HA explicitly says: no core integration — use HomeKit Device or Matter. **[V]** https://www.home-assistant.io/integrations/tradfri/ → user: IKEA Home smart app > hub settings > Integrations > Apple Home / Matter > get code **[M]**; add to Apple Home; our app controls via HomeKit.
### TRÅDFRI gateway (legacy)
- Enter the **security code printed on the sticker on the bottom of the gateway**; auto-discovered via mDNS (CoAP/DTLS, port 5684 **[M]**); if "Unable to connect", restart gateway and give it a static IP. Groups not imported. **[V]** HA tradfri docs. Also HomeKit-native.

---

## 15. Twinkly
- **(a) Prereqs:** First setup in the Twinkly app: after factory reset the device runs an AP (Gen I open; Gen II WPA2 password "Twinkly2019"), DHCP at 192.168.4.1; app sends Wi-Fi creds. **[V]** https://xled-docs.readthedocs.io/en/latest/protocol_details.html. Effects must be uploaded in the Twinkly app before they're selectable (fw > 2.7.1). **[V]** HA twinkly docs.
- **(b) Discovery:** UDP broadcast to port **5555**, payload `0x01` + `discover`; reply contains IP (reversed), "OK", device ID. DHCP hostname `twinkly_*` / `twinkly-*`. **[V]** xled docs + HA manifest.
- **(c) In OUR app:** none visible; internally POST login (challenge) → token → verify; a new login invalidates prior tokens. **[V]**
- **(d) Failures:** IP change (set DHCP reservation); music/RT modes unsupported. **[V]**
- **(e)/(f):** Twinkly Gen II supports HomeKit natively (Twinkly app > device > HomeKit) **[M]**; Matter on newest gen **[?]**.

---

## 16. Magic Home / flux_led (Zengge, Arilux, LEDENET, Surp Life, Magic Hue…)
- **(a) Prereqs:** Provision Wi-Fi with the Magic Home (or Surp Life) app; 2.4 GHz **[M]**. If it works in Magic Home, it likely works. **[V]** https://www.home-assistant.io/integrations/flux_led/
- **(b) Discovery:** UDP broadcast port **48899**, message `HF-A11ASSISTHREAD`; control TCP 5577 **[M port]**. DHCP hostnames `[ba][lk]*`, `hf-lpb100-zj*`, `zengge*`, `lwip*`, `sta*` with OUIs 18B905/249494/7CB94C/ACCF23/B4E842/F0FE6B/8CCE4E/C82E47. **[V]** flux_led scanner.py + HA manifest.
- **(c):** none. **(d):** controller drops offline while changing colors → weak power supply; some model IDs unsupported (0x18/0x19/0x1B/0x1D/0x94–0x96/0xD1). **[V]**
- **(e)/(f):** none (some Zengge "Magic Home Pro" bulbs ship Matter/HomeKit variants **[?]**).

---

## 17. SwitchBot (Color Bulb, Strip Light, Ceiling lights, Floor Lamp…)
- **(a) Prereqs:** SwitchBot app + account; a **SwitchBot Hub** is required for cloud API control of Bluetooth devices (Wi-Fi bulbs/strips don't need it **[M]**). **[V]** https://www.home-assistant.io/integrations/switchbot_cloud/
- **(c) In OUR app:** user pastes **Token** and **Secret Key**: SwitchBot app > Profile > Preferences > About > tap **App Version 10 times** > **Developer Options** > Get Token (secret requires app ≥ 6.14). **[V]** https://github.com/OpenWonderLabs/SwitchBotAPI. Auth headers: `Authorization: <token>`, `sign` = base64(HMAC-SHA256(secret, token + t + nonce)) uppercased, `t` (13-digit ms), `nonce` (UUID). **[V]**
- **(b) Discovery:** cloud device list (`/v1.1/devices`); 10,000 requests/day; HA polls every 10 min; only one webhook URL per account. **[V]**
- **(d):** rate limit returns "Unauthorized"; BLE-only devices need a hub. **[V]**
- **(e)/(f):** SwitchBot Hub 2 / Hub Mini Matter act as Matter bridges (expose only some device types). **[V HA Matter docs]** Some bulbs are directly Matter **[?]**.

---

## 18. Shelly (Bulb, Duo, Vintage, RGBW2, Plus RGBW PM, Dimmer…)
- **(a) Prereqs:** Shelly Smart Control app provisions Wi-Fi (Gen2+ via Bluetooth; Gen1 via device AP) **[M]**; cloud account optional — local control needs no cloud. Gen1 needs fw ≥ 1.9 (bulb/duo/RGBW2/dimmer ≥ 1.11); Gen2 ≥ 1.0. **[V]** https://www.home-assistant.io/integrations/shelly/
- **(b) Discovery:** mDNS `_shelly._tcp.local.` and `_http._tcp.local.` (name `shelly*`); BLE adverts local name `Shelly*`, manufacturer ID 2985. **[V]** HA shelly manifest.
- **(c) In OUR app:** none by default. If the user set a device password: Gen2+ uses **digest auth, username must be `admin`** (RFC 7616, SHA-256); auth is off until configured via `Shelly.SetAuth`. **[V]** https://shelly-api-docs.shelly.cloud/gen2/General/Authentication. Gen1 push (CoIoT) needs Internet & Security > Advanced developer settings > Enable CoIoT + peer IP:5683 **[V]** — not applicable to a phone app; poll instead.
- **(d):** fw 2.0.0+ factory devices serve HTTPS by default (port 443, self-signed) **[V]**; devices behind a Shelly range extender use a custom port; different VLAN → allow UDP 5683 (Gen1) / mDNS reflector.
- **(e)/(f):** Shelly has no HomeKit/Matter on stock firmware (Matter announced for Gen3/Gen4 in 2025 **[?]**).

---

## 19. WLED (DIY ESP32/ESP8266)
- **(a) Prereqs:** Flash WLED ≥ 0.14 (web installer). First boot: join Wi-Fi **`WLED-AP`**, password **`wled1234`**; open **http://4.3.2.1** (or wled.me); Config (gear) > **WiFi Setup** > Scan/enter SSID + password (2.4 GHz only — ESP chips **[M]**); set mDNS name (e.g., `wled-livingroom`); change AP password; **Save & Connect**; rejoin home Wi-Fi; open `http://wled-livingroom.local`. **[V]** https://kno.wled.ge/basics/getting-started/ + HA wled docs.
- **(b) Discovery:** mDNS `_wled._tcp.local.`; JSON API over HTTP (port 80). **[V]** HA manifest/docs.
- **(c):** none (no auth). **(d):** "MAC address mismatch" after DHCP reuse → reconfigure IP / set reservation; builds without JSON API unsupported. **[V]**
- **(e)/(f):** none native (HomeKit via Homebridge/ESPHome only).

---

## 20. Lutron Caséta
- **(a) Prereqs:** Caséta Smart Hub (L-BDG2-WH), Smart Bridge PRO (L-BDGPRO2-WH), RA2 Select, RadioRA 3 processor, or HomeWorks QSX; devices paired in the Lutron app; give the bridge a DHCP reservation. **[V]** https://www.home-assistant.io/integrations/lutron_caseta/
- **(b) Discovery:** mDNS `_lutron._tcp.local.` with `SYSTYPE` = `smartbridge*`, `ra2select*`, `radiora3*`, `hwqs*`; HomeKit model "Smart Bridge". **[V]** HA manifest. LEAP protocol over TLS on port **8081**. **[V]** pylutron-caseta README.
- **(c) In OUR app (LAP pairing):** HA copy: "To pair with {name} ({host}), after submitting this form, **press the black button on the back of the bridge**." → the bridge issues a client certificate (`caseta.key`, `caseta.crt`, `caseta-bridge.crt`) that we must store securely (Keychain) and present for every LEAP connection; each hub has its own set. **[V]** HA strings + pylutron-caseta. (Older guide required logging into a Lutron account to generate certs — now replaced by the button-press flow. **[V]**)
- **(d):** "Discovered device is not a Lutron device"; "Invalid certificate used to connect to bridge" → re-pair. **[V]**
- **(f) HomeKit:** Smart Bridge and PRO are **native HomeKit** (HomeKit code on the bottom of the bridge; add in Lutron app > Settings > Apple HomeKit or Apple Home > Add Accessory) **[V model match; steps M]**. Best path for a consumer app: HomeKit. **(e)** Matter: no (Lutron uses HomeKit, not Matter, as of 2025 **[?]**).

---

## 21. Elgato (Key Light, Key Light Air/Mini, Ring Light, Light Strip)
- **(a) Prereqs:** Elgato Control Center app (iOS/macOS/Windows) provisions Wi-Fi (2.4 GHz; Bluetooth-assisted setup **[M — Elgato help page returned 403]**). Firmware ships inside Control Center. **[V]** https://www.home-assistant.io/integrations/elgato/
- **(b) Discovery:** mDNS `_elg._tcp.local.`; HTTP API on port **9123** (`/elgato/lights`); hostnames like `elgato-key-light.local`. **[V]** HA manifest + python-elgato README.
- **(c):** none (no auth). **(d):** entities unavailable if device unreachable; color only on Light Strip; firmware check needs internet; mDNS blocked → enter IP. **[V]**
- **(e)/(f):** none (no HomeKit/Matter).

---

## 22. Quick matrix for the wizard designer

| Brand | Vendor app first? | Account needed by OUR app? | Setting user must flip | Discovery we use | In-app auth step | HomeKit native | Matter |
|---|---|---|---|---|---|---|---|
| Hue Bridge | Yes (Hue) | No | — | mDNS `_hue._tcp` | Press bridge link button | Yes | Yes (bridge) |
| Hue BT-only | Yes (Hue BT) | — | Buy bridge | — | — | No | No |
| WiZ | Yes | No | "Allow local communication" (default on) | UDP 38899 bcast | none | No | Matter SKUs |
| AiDot/Linkind/OREiN | Yes (AiDot) | Yes: Country+Username+Password | — | cloud list → local TCP | login | No | Matter SKUs |
| LIFX | Yes | No (optional cloud token) | — | UDP 56700 / `_lifx._udp` | none | Yes | newer SKUs |
| Govee | Yes | API key (cloud) | "LAN Control" toggle | multicast 239.255.255.250:4001→4002, cmd 4003 | paste API key (cloud) | No | some SKUs |
| Nanoleaf panels | Yes | No | — | mDNS `_nanoleafapi._tcp` | hold power 5 s → 30 s window | Yes | newer SKUs |
| Nanoleaf Essentials | Yes | No | — | HomeKit/Matter only | — | Yes (Thread/BLE) | Yes |
| Tapo/Kasa | Yes | TP-Link email+password (case-sensitive) | "Third-Party Compatibility" (some fw) | UDP 9999/20002 | enter cloud creds | rare | many SKUs |
| Yeelight | Yes | No | "LAN Control" | SSDP 239.255.255.250:1982 / `_miio._udp` | none | some | some |
| Tuya white-label | Yes (Smart Life) | User Code + QR scan (cloud) / IoT platform for local keys | — | UDP 6666/6667/7000 (local) | QR scan or local key | No | many SKUs |
| GE Cync | Yes | Email+Password+emailed 2FA code | — | cloud | login + 2FA | No | some |
| Sengled Wi-Fi | Yes | Email+Password+country (unofficial) | — | cloud | login | No | Matter SKUs |
| Wyze | Yes | Email+Password+API Key ID+Key | — | cloud | login + keys | No | ? |
| Meross | Yes | Email+Password (to fetch key) | — | DHCP/IP + local HTTP | login or key | HK SKUs | MA SKUs |
| IKEA Dirigera | Yes | No | — | mDNS `gw2-*.local` | press hub action button | Yes (bridge) | Yes (bridge) |
| IKEA Trådfri GW | Yes | No | — | mDNS | gateway security code (sticker) | Yes | No |
| Twinkly | Yes | No | upload effects in app | UDP 5555 bcast | none (internal login) | Gen II | ? |
| Magic Home | Yes | No | — | UDP 48899 | none | No | No |
| SwitchBot | Yes | Token+Secret | tap App Version 10x | cloud | paste token+secret | No | Hub bridges |
| Shelly | Yes (Shelly Smart Control) | No | optional device password | mDNS `_shelly._tcp` | admin password if set | No | No |
| WLED | No (captive portal) | No | WiFi Setup via WLED-AP | mDNS `_wled._tcp` | none | No | No |
| Lutron Caséta | Yes | No | — | mDNS `_lutron._tcp` | press black button on bridge back (cert) | Yes | No |
| Elgato | Yes (Control Center) | No | — | mDNS `_elg._tcp` | none | No | No |

---

## 23. Items flagged uncertain / to verify before writing user-facing copy
1. Govee Home app exact menu path for "LAN Control" and the firmware prerequisite (vendor page is JS-only). **[M]**
2. Hue: Bluetooth-bulb-to-bridge steps, 10-light BLE limit, Hue app Matter menu path, link-button 30 s window. **[M]**
3. Nanoleaf: 5 s (HA) vs 5–7 s (Nanoleaf docs) hold time; port 16021. **[M]**
4. Apple Home "Turn On Pairing Mode" wording and the ~15-minute code validity. **[M]**
5. Apple: iOS 18 "no hub needed for Matter" (102135) vs "hub required" (102557) — the two Apple pages disagree; 102135 is newer. **[?]**
6. iOS entitlement details (TN3179, HomeKit docs) came from memory — the pages were JS-rendered. **[M]**
7. AiDot local protocol port / discovery method (library README is one line; HA only says "persistent TCP connection" + DHCP hostname `aidot`). **[?]**
8. Wyze API-key creation steps/expiry (support article 403). **[M]**
9. Elgato Wi-Fi provisioning details (help page 403). **[M]**
10. Matter availability per brand (WiZ, Govee, Yeelight, Cync, Sengled, Wyze, Twinkly, Shelly) is SKU-specific; always key off the Matter logo on the box rather than brand. **[M]**
11. Lutron Caséta HomeKit setup steps and Matter status. **[M/?]**
12. Tapo/Kasa native-HomeKit model list. **[?]**

---

## 24. Sources (fetched this session)
- HA AiDot: https://www.home-assistant.io/integrations/aidot/ ; strings https://raw.githubusercontent.com/home-assistant/core/dev/homeassistant/components/aidot/strings.json ; manifest …/aidot/manifest.json ; python-aidot const.py https://raw.githubusercontent.com/Aidot-Development-Team/python-aidot/main/aidot/const.py
- HA Govee local: https://www.home-assistant.io/integrations/govee_light_local/ ; govee-local-api controller.py + message.py https://github.com/Galorhallen/govee-local-api ; Govee API key https://developer.govee.com/reference/apply-you-govee-api-key
- HA Yeelight: https://www.home-assistant.io/integrations/yeelight/ ; Yeelight LAN control FAQ https://www.yeelight.com/faqs/lan_control
- HA TP-Link: https://www.home-assistant.io/integrations/tplink/ ; strings …/tplink/strings.json ; manifest ; python-kasa README + kasa/discover.py https://github.com/python-kasa/python-kasa
- HA WiZ: https://www.home-assistant.io/integrations/wiz/ ; pywizlight README + discovery.py https://github.com/sbidy/pywizlight
- HA LIFX: https://www.home-assistant.io/integrations/lifx/ ; manifest ; LIFX HTTP API auth https://api.developer.lifx.com/reference/authentication
- HA Nanoleaf: https://www.home-assistant.io/integrations/nanoleaf/ ; strings ; manifest
- HA Hue: https://www.home-assistant.io/integrations/hue/ ; strings ; manifest ; Hue developer get-started https://developers.meethue.com/develop/get-started-2/ ; Hue Matter https://www.philips-hue.com/en-us/explore-hue/works-with/matter
- HA SwitchBot Cloud: https://www.home-assistant.io/integrations/switchbot_cloud/ ; SwitchBotAPI README https://github.com/OpenWonderLabs/SwitchBotAPI
- HA Lutron Caséta: https://www.home-assistant.io/integrations/lutron_caseta/ ; strings ; manifest ; pylutron-caseta README https://github.com/gurumitts/pylutron-caseta
- HA Shelly: https://www.home-assistant.io/integrations/shelly/ ; manifest ; Shelly Gen2 auth https://shelly-api-docs.shelly.cloud/gen2/General/Authentication
- HA WLED: https://www.home-assistant.io/integrations/wled/ ; manifest ; WLED getting started https://kno.wled.ge/basics/getting-started/
- HA Magic Home: https://www.home-assistant.io/integrations/flux_led/ ; manifest ; flux_led scanner.py https://github.com/Danielhiversen/flux_led
- HA Twinkly: https://www.home-assistant.io/integrations/twinkly/ ; manifest ; xled protocol docs https://xled-docs.readthedocs.io/en/latest/protocol_details.html
- HA Elgato: https://www.home-assistant.io/integrations/elgato/ ; manifest ; python-elgato README https://github.com/frenck/python-elgato
- HA Tuya: https://www.home-assistant.io/integrations/tuya/ ; tinytuya README https://github.com/jasonacox/tinytuya
- HA Cync: https://www.home-assistant.io/integrations/cync/ ; strings …/cync/strings.json
- HA HomeKit Device: https://www.home-assistant.io/integrations/homekit_controller/ ; manifest
- HA Matter: https://www.home-assistant.io/integrations/matter/
- HA Trådfri (incl. Dirigera note): https://www.home-assistant.io/integrations/tradfri/ ; dirigera README https://github.com/Leggin/dirigera
- ha-wyzeapi README https://github.com/SecKatie/ha-wyzeapi ; ha-sengledapi README https://github.com/jfarmer08/ha-sengledapi ; meross_lan README https://github.com/krahabb/meross_lan
- Apple: Matter in Home app https://support.apple.com/en-us/102135 ; Home hub https://support.apple.com/en-us/102557 ; Local Network privacy https://support.apple.com/en-us/HT211870
- Google: Matter multi-admin sharing https://support.google.com/googlenest/answer/13127223
