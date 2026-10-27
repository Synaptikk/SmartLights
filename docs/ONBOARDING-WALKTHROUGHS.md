# "Add a brand" walkthroughs

User-facing content for the onboarding wizard, one section per brand, plus the Apple-side setup that applies to all. Agents turn each section into a `BrandGuide` definition in `Packages/Onboarding`. Wording tagged **[verify]** came from secondary sources or memory and must be checked on a real device/app before shipping; everything else was verified against vendor docs, Home Assistant config-flow strings, or library source (see `research/research_onboarding.md` for URLs).

Guide step types the engine supports: `info`, `checklist`, `action(provider callback)`, `secureInput`, `fileOrQRImport`, `openApp(deepLink)`, `verifyBlink`, `troubleshoot`.

---

## 0. One-time iPhone setup (shown before the first LAN brand)

1. **Local Network permission.** The first time the app scans, iOS asks "SmartLights would like to find and connect to devices on your local network." Tap **Allow**. If it was denied: Settings > Privacy & Security > Local Network > turn SmartLights on. A denial silently breaks all discovery, so the wizard explains the prompt *before* triggering it.
2. **Same Wi-Fi.** iPhone must be on the home Wi-Fi (not cellular, not a Guest network, not a VPN). Most bulbs are 2.4 GHz-only; the phone can be on 5 GHz as long as it is the same network/subnet.
3. **Bluetooth permission** (only for Hue Bluetooth bulbs, SwitchBot BLE, Matter commissioning).
4. **HomeKit permission** (only when adding the "Apple Home" provider).
5. **Home hub** (HomePod / Apple TV) is only needed for Matter-over-Thread devices and for remote/automation via Apple Home. iOS 18+ can add Wi-Fi Matter accessories without a hub.

### 0.1 Adding any Matter light to Apple Home (generic, reused by many brands)
1. Open the Apple **Home** app > **+** > **Add Accessory**.
2. Scan the Matter QR code on the bulb/box. If the bulb is already paired to the vendor app, tap **More options** and pick it, or generate a pairing code in the vendor app (multi-admin).
3. Keep Bluetooth on, stay near the device, use the 2.4 GHz network during commissioning. Photograph the QR code; it is needed after a factory reset.
4. Back in SmartLights: **Add brand > Apple Home** and grant HomeKit access. All Apple Home lights appear.
   Note: a native HomeKit (non-Matter) accessory can be paired to only one controller; Matter devices can be in several apps at once.

---

## 1. Philips Hue (bridge)

**Before you start**
- Hue Bridge v2 (square) or Bridge Pro, on Ethernet to the same router as your Wi-Fi. Round v1 bridges are end-of-life.
- Lights already added in the Hue app. No Hue account is needed for local control.

**In this app**
1. Add brand > Philips Hue > **Scan**. The app finds bridges by Bonjour, then via discovery.meethue.com, or you can enter the IP (Hue app > Settings > Hue Bridges shows it).
2. **Press the round button on top of the Hue Bridge**, then tap **Continue** within 30 seconds. (The app sends `POST /api` with `generateclientkey:true`; error 101 means the button was not pressed in time.)
3. Lights, rooms, zones and scenes import automatically. Changes from the Hue app show up live (event stream).

**Troubleshooting**
- "No bridge found": mDNS blocked or bridge on another VLAN. Enter the IP manually.
- "Failed to register": press the button again and retry quickly.
- Certificate warning on an old bridge: the app pins the bridge's own certificate by bridge id; accept once. Updated bridges (firmware 1971060010+, May 2025) use Signify-signed certs.
- Scenes must be created in the Hue app; the app can recall them.
- Third-party Zigbee bulbs on the bridge (Innr, IKEA, etc.) appear as Hue lights; some Hue-only features (dynamic scenes, Entertainment) are unavailable on them.

**Alternative**: the bridge is a Matter bridge and native HomeKit. Hue app > Settings > Smart home > Apple Home or Matter **[verify path]**, then use the Apple Home provider. The native path is preferred because it exposes scenes/effects/gradients.

### 1b. Hue Bluetooth-only bulbs (no bridge)
- Phase 3 only. Bluetooth bulbs need BLE bonding and must be made visible (Hue app > Settings > Voice assistants > "Make visible") or factory-reset. Recommended: buy a bridge; add the bulb in the Hue app (Settings > Lights > Add light > Search or enter the serial) **[verify]**, then follow section 1. Bluetooth-connected Hue bulbs cannot use Matter.

---

## 2. WiZ

**Before you start**
- Bulbs set up in the **WiZ** app on your 2.4 GHz Wi-Fi.
- WiZ app > menu (upper-left) > **Settings > Security**: **"Allow local communication"** must be ON (default).
- Same screen, control mode: if it says **"Only verified controls"**, either switch to **"Allow all controls"** or export the local key: Home settings > Integrations > **Local integrations** > export; the JSON contains `udp_signing_key` **[verify exact wording and availability in your app version]**. Bulbs on firmware 1.34+ reject unsigned commands otherwise.

**In this app**
1. Add brand > WiZ > **Scan**. The app broadcasts on UDP 38899 if allowed, otherwise probes every address on your subnet (takes ~10-20 s). You can also **Add by IP**.
2. If asked, paste or import the signing key (JSON import or 32-hex string). Stored in Keychain.
3. Each bulb is identified by MAC; type/colour capabilities are read from `getSystemConfig`/`getModelConfig`.

**Troubleshooting**
- Bulb not found: it is off at the wall, on a different subnet/VLAN, or "Allow local communication" is off. Routers with client isolation or "Smart Connect" band steering cause flakiness; give bulbs DHCP reservations.
- "Invalid params" / "Security error" on commands: signing required or wrong key; re-export the key or switch to "Allow all controls".
- No live updates: push requires the bulb to reach your phone on UDP 38900; the app re-registers when it comes to the foreground.
- Colour and white modes are exclusive; brightness below 10% is clamped by the bulb.

**Alternative**: most Wi-Fi WiZ products made since Q2 2021 can be upgraded to Matter in the WiZ app (Settings > Integrations > Matter), then section 0.1. UDP keeps working alongside Matter per community reports.

---

## 3. AiDot / Linkind / OREiN (also Mujoy, Winees, WELOV)

**Before you start**
- Lights added in the **AiDot** app. You must use the account that **owns** the home (shared members cannot control locally).
- Know the **country** you selected when logging into the AiDot app. Only username + password login is supported (no Apple/Google sign-in).
- Avoid signing into the AiDot app on another device with the same account while using SmartLights: a new login invalidates the previous token (the app will ask you to re-enter your password if that happens).

**In this app**
1. Add brand > AiDot > enter **Country**, **Username** (AiDot account email), **Password**. The app logs in to the AiDot cloud once to fetch your devices and their local keys.
2. The app then finds each bulb on the LAN (UDP 6666 discovery; hostname `aidot`) and talks to it directly over TCP 10000. Nothing else goes through the cloud except presets/effects, which are optional.

**Troubleshooting**
- Login error "credentials belong to a different account" or "token expired" (code 21026): re-enter the password; use the owner account.
- Devices listed but unreachable: bulb off, different subnet, or local control blocked. Try **Add by IP** under the device.
- BLE-mesh outdoor lights (SL5/SL5C, B1 Plus hub) are not reachable this way; use the Linkind Matter Smart Hub 2 and section 0.1.
- Supported locally: Wi-Fi bulbs/strips/plugs (on/off, brightness, colour temperature, RGBW).

**Alternative (recommended for Matter SKUs)**: Linkind/OREiN Matter bulbs (Matter logo on box, Matter 1.4/1.5 certified): section 0.1, then the Apple Home provider. Fully local, no AiDot account.

---

## 4. Apple Home (HomeKit + Matter)

1. Add brand > **Apple Home** > Allow HomeKit access.
2. Everything already in the Home app appears (Hue bridge, Nanoleaf, LIFX, Eve, Lutron, Meross HK, IKEA Dirigera, Aqara hub, Twinkly Gen II, any Matter light).
3. To add new accessories, use the Home app (section 0.1 for Matter; scan the HomeKit code for HomeKit-native).
4. Limits: only on/off, brightness, hue/saturation and colour temperature; no vendor effects. Remote access and automations need a HomePod or Apple TV hub.
5. Widgets/Siri for HomeKit lights run through the app (iOS limitation); the first tap may open the app briefly.

---

## 5. LIFX

**Before you start**: bulbs set up in the LIFX app (2.4 GHz). No account or token needed for local control.
**In this app**: Add brand > LIFX > Scan (mDNS `_lifx._udp` and/or UDP 56700 broadcast, else subnet probe; Add by IP available). Optional: paste a LIFX cloud token from cloud.lifx.com/settings for away-from-home control (120 requests/min).
**Troubleshooting**: different subnet → add by IP; LIFX Switch is not on the LAN protocol.
**Alternative**: most LIFX are native HomeKit; new ones are Matter (Thread beta 2026).

## 6. Govee

**Before you start**: device set up in Govee Home (2.4 GHz). For local control the model must support the LAN API (strips, lamps, panels; most plain A19 bulbs do not) and **LAN Control** must be on: Govee Home > device > Settings (gear) > **LAN Control** **[verify path]**; the toggle may take minutes to appear after a firmware update.
**In this app**: Add brand > Govee > Scan (multicast 239.255.255.250:4001; reply on 4002; commands on 4003). For non-LAN models: Govee Home > Settings > **Apply for API Key** (emailed) and paste it (Developer API, 10k requests/day).
**Troubleshooting**: "No devices found" = LAN Control off, unsupported model, multicast blocked by router/VLAN. "Port 4002 in use" = another Govee app on the phone.
**Alternative**: 2025-26 Govee bulbs/lamps are Matter → section 0.1.

## 7. Nanoleaf

**Panels (Light Panels, Canvas, Shapes, Elements, Lines)**: set up in the Nanoleaf app. In this app: Add brand > Nanoleaf > Scan (mDNS `_nanoleafapi._tcp`) > **hold the power button on the controller for 5-7 seconds until the LEDs flash**, then tap Continue within 30 seconds (Skylight: "Connect to API" in the Nanoleaf app instead). Token is stored; factory reset requires re-pairing. Use IPv4; set a DHCP reservation.
**Essentials (bulbs, strips)**: no local API; add to Apple Home (HomeKit over Thread/BLE, or Matter Essentials) and use the Apple Home provider. Thread needs a HomePod/Apple TV.

## 8. TP-Link Tapo and Kasa

**Before you start**: set up in the Tapo or Kasa app. Newer devices require your **TP-Link account email + password** for local control (case-sensitive). Some firmware needs **Tapo app > Tapo Lab > Third-Party Compatibility** turned on **[TP-Link warns it lowers security]**.
**In this app**: Add brand > TP-Link > Scan (UDP 9999/20002 broadcast or subnet probe) > when prompted, enter email + password. Legacy Kasa bulbs (KL/LB) need no credentials.
**Troubleshooting**: "Unable to authenticate" = wrong-case email, toggle off, or other TP-Link devices interfering during onboarding (unplug them briefly). Add by IP for other subnets.
**Alternative**: Tapo L535E and other Matter SKUs → section 0.1.

## 9. Yeelight

**Before you start**: Yeelight app > Device > (more) > **LAN Control** on (older firmware: "Developer mode"); update firmware if the toggle is missing. Some newer models removed it.
**In this app**: Add brand > Yeelight > Scan (SSDP to 239.255.255.250:1982, mDNS `_miio._udp`) or Add by IP. No auth.
**Troubleshooting**: 60 commands/min limit; first command after a dropped connection may be ignored.
**Alternative**: some models are HomeKit-native or Matter.

## 10. Tuya / Smart Life white-label (Feit, Globe, Merkury/Geeni, Teckin, Gosund, Treatlife, Sylvania Wi-Fi, Cree)

**Recommended**: if the bulb has a Matter logo, section 0.1. Otherwise:
**Cloud path (simpler)**: requires SmartLights to ship Tuya developer app credentials (phase 3 decision). User enters the Smart Life **User Code** (Smart Life > Me > gear > Account and Security) and scans a QR we show.
**Local path (advanced)**: user creates a project at iot.tuya.com, links the Smart Life account by QR, subscribes to IoT Core (trial expires), and runs a wizard that prints each device's **local key**; paste device id + local key + IP into the app. Only one local connection at a time (close Smart Life). Re-pairing rotates the key.

## 11. Elgato Key Light / Air / Mini / Ring / Strip
Set up in Elgato Control Center. Add brand > Elgato > Scan (mDNS `_elg._tcp`, HTTP 9123). No auth. Mireds 143-344 mapped to Kelvin.

## 12. Shelly
Set up in Shelly Smart Control (cloud optional). Add brand > Shelly > Scan (mDNS `_shelly._tcp`). If a device password was set: username is `admin` (digest auth). Gen3/4 can also do Matter (enable in device web UI) → section 0.1.

## 13. WLED
Flash WLED ≥ 0.14; join Wi-Fi `WLED-AP` (password `wled1234`), open http://4.3.2.1 > WiFi Setup, enter home SSID/password, set mDNS name, Save & Connect. Add brand > WLED > Scan (mDNS `_wled._tcp`). No auth.

## 14. Magic Home / Zengge / LEDENET
Set up in Magic Home. Add brand > Magic Home > Scan (UDP 48899, TCP 5577). No auth. Drops offline while changing colours usually mean a weak power supply.

## 15. Meross
Set up in the Meross app. Add brand > Meross > enter Meross email + password once (to fetch the per-account device key; the app can discard the password after), then local HTTP control. "HK" SKUs are HomeKit-native and "MA" SKUs are Matter → prefer Apple Home. Meross rate-limits cloud logins; do not retry in loops.

## 16. SwitchBot
SwitchBot app > Profile > Preferences > About > tap **App Version 10 times** > Developer Options > copy **Token** and **Secret**. Add brand > SwitchBot > paste both (cloud API, 10k/day; BLE-only devices need a SwitchBot Hub). Hub 2/3 can also expose lights as Matter (beta) → section 0.1.

## 17. Twinkly
Set up in the Twinkly app (upload effects there). Add brand > Twinkly > Scan (UDP 5555). Internal login/token handled automatically; a new login invalidates older tokens, so close other Twinkly controllers. Gen II is HomeKit-native (Twinkly app > device > HomeKit) → Apple Home provider also works.

## 18. IKEA Dirigera
Recommended: IKEA Home smart app > hub settings > Integrations > Apple Home or Matter **[verify path]** → Apple Home provider. Direct (phase 3): Add brand > IKEA Dirigera > Scan (`gw2-<id>.local`, HTTPS 8443) > **press the action button on the bottom of the hub** > Continue; token stored.
Trådfri gateway (legacy): not supported directly; add to Apple Home via its HomeKit code.

## 19. Lutron Caséta
Add the Smart Bridge to Apple Home (HomeKit code on the bridge; Lutron app > Settings > Apple HomeKit) and use the Apple Home provider. No Matter.

## 20. Eve, Aqara, Sylvania Bluetooth, Nanoleaf Essentials, other HomeKit/Matter-only
Add to Apple Home per the vendor's instructions, then the Apple Home provider.

## 21. GE Cync, Sengled Wi-Fi, Wyze
Not controllable locally from a phone. Buy/use their **Matter** SKUs (Cync "Matter" line, Sengled Matter bulbs) → section 0.1. Wyze has no Matter/HomeKit; only Home Assistant with an unofficial cloud integration. The wizard explains this plainly instead of pretending to support them.

---

## Wizard matrix (engine input summary)

| Brand | Vendor app first | Our app asks for | Setting to flip | Discovery | Pairing action | HK | Matter |
|---|---|---|---|---|---|---|---|
| Hue bridge | yes | nothing | — | `_hue._tcp`, cloud broker, IP | press bridge button | yes | yes (bridge) |
| WiZ | yes | signing key (if verified-controls mode) | Allow local communication; control mode | UDP 38899 / sweep / IP | none | no | SKUs |
| AiDot | yes | country, email, password | — | cloud list → UDP 6666 / IP | login | no | SKUs |
| Apple Home | Home app | HomeKit permission | — | HMHomeManager | none | — | — |
| LIFX | yes | optional cloud token | — | `_lifx._udp` / UDP 56700 / sweep | none | yes | new SKUs |
| Govee | yes | API key (cloud models) | LAN Control | multicast 4001 | paste key | no | new SKUs |
| Nanoleaf panels | yes | nothing | — | `_nanoleafapi._tcp` | hold power 5-7 s | yes | some |
| TP-Link (provider implemented (PR), T2.6) | yes | TP-Link email+password (KLAP devices only) | Third-Party Compatibility | UDP 9999/20002 / sweep / IP | enter creds | rare | some |
| Yeelight | yes | nothing | LAN Control | SSDP 1982 / `_miio._udp` | none | some | some |
| Tuya | yes (Smart Life) | user code + QR, or local key | — | UDP 6666/6667/7000 | QR or key | no | some |
| Elgato | yes | nothing | — | `_elg._tcp` | none | no | no |
| Shelly | yes | admin password if set | — | `_shelly._tcp` | none | no | Gen3/4 |
| WLED | captive portal | nothing | — | `_wled._tcp` | none | no | no |
| Magic Home | yes | nothing | — | UDP 48899 | none | no | no |
| Meross | yes | email+password once | — | IP / DHCP | login | HK SKUs | MA SKUs |
| SwitchBot | yes | token+secret | tap version 10× | cloud | paste | no | hub |
| Twinkly | yes | nothing | upload effects | UDP 5555 | none | Gen II | ? |
| Dirigera | yes | nothing | — | `gw2-*.local` | press hub button | yes | yes |

## Items to verify on real hardware before finalising copy
1. Govee "LAN Control" menu path and firmware prerequisite.
2. Hue app menu paths for Matter/Apple Home; link-button window length; Bluetooth-bulb-to-bridge steps.
3. WiZ: exact "Local integrations" export wording; whether "Only verified controls" is the default; Matter-migrated bulbs still accepting UDP.
4. Nanoleaf hold time (5 s per HA vs 5-7 s per Nanoleaf).
5. Apple Home "Turn On Pairing Mode" wording for Matter multi-admin sharing.
6. AiDot local discovery reliability without broadcast entitlement (unicast fallback behaviour).
7. Dirigera Integrations menu path.
