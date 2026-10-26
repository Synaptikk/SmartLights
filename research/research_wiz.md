# WiZ (Signify) smart lights: controlling them from a custom iOS app

Research date: 2026-10-26. Sources are linked inline. Items marked **[UNCERTAIN]** could not be fully verified.

---

## 0. Executive summary

- WiZ has **no official consumer API**. All third-party control is via a reverse-engineered **JSON-over-UDP protocol on port 38899** (commands) and **38900** (bulb-initiated push). The canonical reference implementation is Python's `pywizlight` (559 stars, MIT, last push 2026-08-05, v0.6.6), which Home Assistant uses.
- **Breaking change in 2026:** bulbs on firmware **1.34+** (observed 1.34.1, 1.38.0, 1.39.0 on ESP25 modules) reject unsigned write commands (`setPilot`) with `-32602 Invalid params` unless the WiZ app's security setting is set to "Allow all controls". Otherwise writes must carry an **HMAC-SHA256 signature** (`sigTs` + `hmac`) keyed with a per-home `udp_signing_key` exported from the WiZ app (Home settings → Integrations → Local integrations). Reads (`getPilot`, `getSystemConfig`, `getModelConfig`, `registration`) stay unsigned. pywizlight PR #216 implementing this is still **unmerged** as of 2026-10-26. Any new iOS app must implement signing or instruct users to change the setting.
- The only official API is **WiZ Pro** (GraphQL at `api.pro.wizconnected.com`, OAuth 2.0 + PKCE, needs a WiZ-issued `clientId`). It targets commercial buildings/organizations, not consumer homes; access criteria aren't published.
- **BLE** is used only for onboarding (and Matter commissioning); no BLE control protocol is documented.
- **Matter**: WiZ Wi-Fi bulbs/lamps/plugs made since Q2 2021 (plus specific always-compatible models) can be migrated to Matter in the WiZ app; new strips/lamps (2024-2025) ship Matter-certified. Matter is Wi-Fi only (no Thread). Both UDP and Matter appear to work on the same bulb, but that is based on community reports, not an official statement.
- **Onboarding** requires the WiZ app (BLE auto-detect, "smart pairing", or manual SoftAP `WiZConfig_xxxx`). No documented third-party provisioning protocol. After setup, bulbs work local-only (even internet-blocked), but with reduced features.
- **iOS specifics**: UDP *broadcast* on iOS requires the managed `com.apple.developer.networking.multicast` entitlement and BSD sockets (Network.framework can't broadcast). Shipping iPhone apps (Lumen, LumaBar) instead unicast `getPilot` to every host on the subnet. Local Network privacy prompt (`NSLocalNetworkUsageDescription`) is required.

---

## 1. WiZ local UDP protocol

### 1.1 Transport and ports

| Port | Direction | Use | Source |
|---|---|---|---|
| **UDP 38899** | app → bulb (and bulb replies) | All request/response methods; discovery broadcast target | [pywizlight bulb.py `PORT = 38899`](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py), [pywizlight discovery.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/discovery.py) |
| **UDP 38900** | bulb → app | Bulb-initiated `syncPilot` push and `firstBeat` after registration | [pywizlight push_manager.py `LISTEN_PORT = 38900`](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/push_manager.py), [homebridge-wiz-lan README](https://github.com/kpsuperplane/homebridge-wiz-lan) |
| TCP 8883 | bulb → cloud | MQTT/TLS to `*.mqtt.wiz.world`; not used for local control | [wiz_light discussion #85](https://github.com/sbidy/wiz_light/discussions/85), [Cycling74 thread](https://cycling74.com/forums/controlling-wiz-wifi-led-rgb-lightbulbs) |

- Requests are a single JSON object per datagram: `{"id":1,"method":"...","params":{...}}` (`id` is optional). Responses echo `"method"`, add `"env":"pro"`, and carry either `"result"` or `"error"`. ([Rogozin blog](https://aleksandr.rogozin.us/blog/2021/8/13/hacking-philips-wiz-lights-via-command-line), [pywizlight README](https://github.com/sbidy/pywizlight))
- Invalid JSON → `{"env":"pro","error":{"code":-32700,"message":"Parse error"}}`. Unknown method → `{"method":"getModelConfig","env":"pro","error":{"code":-32601,"message":"Method not found"}}`. ([pywizlight tests/fake_bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/tests/fake_bulb.py))
- The Dart `wiz` package, `wikari` (Node), `cB-Sigma/wiz` (Go), openHAB binding and homebridge plugin all use the same protocol. ([pub.dev wiz](https://pub.dev/packages/wiz), [openHAB WiZ binding](https://www.openhab.org/addons/bindings/wiz))

### 1.2 Methods

From the [pywizlight README](https://github.com/sbidy/pywizlight) and [bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py):

| Method | Purpose |
|---|---|
| `getPilot` | Read current light state (`state`, `r,g,b,c,w`, `temp`, `dimming`, `sceneId`, `speed`, `rssi`, `mac`, `src`). Dual-head devices accept `{"params":{"devices":n}}`. |
| `setPilot` | Set state/colour/temp/dimming/scene. **Requires signature on fw 1.34+ unless "Allow all controls" is set** (see 1.7). |
| `setState` | Same params as `setPilot` but, per pywizlight, keeps the current on/off state. Community examples use `{"method":"setState","params":{"state":true}}` to toggle power. |
| `getSystemConfig` | `mac`, `homeId`, `roomId`, `groupId`, `moduleName`, `fwVersion`, `drvConf`, `ewf`, `ewfHex`, `ping`, (older: `typeId`, `homeLock`, `pairingLock`). `moduleName` absent on fw 1.8.0. |
| `getModelConfig` | fw > 1.22: `ps`, `pwmFreq`, `pwmRange`, `wcr` (white-to-colour ratio), `nowc` (number of white channels), `cctRange` (4 ints: ext-min, min, max, ext-max), `extRange`, `renderFactor`, `hasAdjMinDim`, `hasTapSensor`, `pm`, `fanSpeed`. Returns -32601 on older firmware. |
| `getUserConfig` | `fadeIn`, `fadeOut`, `dftDim`, `whiteRange`, `extRange`, `opMode`, `po` (power-on behaviour). |
| `getPower` | Smart plugs with metering only; `result.power` in milliwatts. |
| `registration` | Ask the bulb to push `syncPilot` heartbeats to `phoneIp` on 38900. Also used (with `register:false`) as the broadcast discovery probe. |
| `pulse` | `{"method":"pulse","params":{"delta":-15,"duration":300}}` (brief dim pulse). |
| `syncPilot` / `firstBeat` | Bulb → app push messages (not requests). |
| Also listed (undocumented): `setSystemConfig`, `setSchd`, `setWifiConfig`, `reset`, `reboot`, `getWifiConfig`, `getDevInfo`, `setUserConfig`. |

pywizlight's author admits the method list was reverse-engineered; there's no vendor spec ([issue #155](https://github.com/sbidy/pywizlight/issues/155)).

### 1.3 Parameters (for `setPilot` / `setState`)

Sources: [pywizlight README](https://github.com/sbidy/pywizlight), [bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py), [WiZ Pro API docs (same parameter model)](https://docs.pro.wizconnected.com/).

| Param | Range | Notes |
|---|---|---|
| `state` | bool | On/off. |
| `r`,`g`,`b` | 0-255 | Colour mode. Sending RGB clears a running scene and leaves white mode. |
| `c`,`w` | 0-255 | Cold / warm white channel (not supported on original Philips-WiZ bulbs). |
| `temp` | Kelvin | pywizlight clamps 1000-10000; real bulbs typically 2200-6500 (`cctRange`). White mode is exclusive with RGB mode: a bulb is in either colour or temp mode and a command switches it ([openHAB binding](https://www.openhab.org/addons/bindings/wiz)). |
| `dimming` | 10-100 (%) | Many sources say <10 is ignored/clamped; pywizlight sends min 1. |
| `sceneId` | 1-36, 40, 256-265, 1000 | See 1.5. |
| `speed` | 10-200 (pywizlight) / 20-200 (Pro API) | Dynamic-scene speed. Only meaningful in a scene. |
| `ratio` | 0-100 | Dual-zone split; one tester reported it had no visible effect on their lamp ([issue #191](https://github.com/sbidy/pywizlight/issues/191)). |
| `devices` | 1-3 | Dual-head zone index (`{"devices":2,"state":true}`), added in pywizlight 0.6.x ([PR #193](https://github.com/sbidy/pywizlight/pull/193)). |
| `fanState`,`fanMode`,`fanSpeed`,`fanRevrs` | | Smart fan modules (`FANDIM`, `DDTW`). |
| `schdPsetId` | | Appears in `getPilot` in rhythm mode (read-only in practice). |

Example payloads:

```json
{"id":1,"method":"setPilot","params":{"r":0,"g":0,"b":255,"dimming":100}}
{"id":1,"method":"setPilot","params":{"temp":3000,"dimming":75}}
{"id":1,"method":"setPilot","params":{"sceneId":23,"speed":145,"dimming":100}}
{"id":1,"method":"setState","params":{"state":false}}
{"method":"getPilot","params":{}}
{"method":"registration","id":105,"params":{"phoneIp":"192.168.1.20","phoneMac":"aabbccddeeff","register":true}}
```

Example responses ([fake_bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/tests/fake_bulb.py), [Rogozin blog](https://aleksandr.rogozin.us/blog/2021/8/13/hacking-philips-wiz-lights-via-command-line)):

```json
{"method":"setPilot","env":"pro","result":{"success":true}}
{"method":"getPilot","env":"pro","result":{"mac":"6c29906a1b2c","rssi":-46,"src":"","state":true,"sceneId":0,"r":255,"g":238,"b":0,"c":0,"w":0,"dimming":100}}
{"method":"getSystemConfig","env":"pro","result":{"mac":"a8bb5006033d","homeId":653906,"roomId":989983,"moduleName":"ESP01_SHRGB_03","fwVersion":"1.25.0","groupId":0,"drvConf":[30,1],"ewf":[255,0,255,255,0,0,0],"ewfHex":"ff00ffff000000","ping":0}}
{"method":"getModelConfig","env":"pro","result":{"ps":1,"pwmFreq":2000,"pwmRange":[0,100],"wcr":20,"nowc":2,"cctRange":[2200,2700,6500,6500],"renderFactor":[200,255,255,150,0,0,40,0,0,0],"hasAdjMinDim":0,"hasTapSensor":1,"pm":0,"fanSpeed":0}}
```

### 1.4 Discovery

- **Broadcast:** send `{"method":"registration","params":{"phoneMac":"AAAAAAAAAAAA","register":false,"phoneIp":"1.2.3.4","id":"1"}}` to `255.255.255.255:38899` (or the subnet broadcast); every bulb replies with `result.mac`; pywizlight re-sends every 1 s and listens 5 s ([discovery.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/discovery.py)). Sending `getPilot` to broadcast also works and returns state in the same pass ([Rogozin](https://aleksandr.rogozin.us/blog/2021/8/13/hacking-philips-wiz-lights-via-command-line), [wizbar](https://github.com/maxamly/wizbar)).
- **DHCP/OUI:** Home Assistant also discovers via DHCP: MAC OUIs `A8:BB:50`, `D8:A0:11`, `44:4F:8E`, `6C:29:90` and hostname `wiz_*` ([HA wiz manifest.json](https://raw.githubusercontent.com/home-assistant/core/dev/homeassistant/components/wiz/manifest.json)). Useful for an iOS app that scans ARP/hostnames instead of broadcasting.
- **firstBeat:** bulbs announce themselves with a `firstBeat` message on 38900 when they (re)join the network ([push_manager.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/push_manager.py), [openHAB binding](https://www.openhab.org/addons/bindings/wiz)).
- **iOS constraint:** see section 8. Lumen (iPhone app) explicitly avoids broadcast and unicasts to every address on the /24 ([Lumen README](https://github.com/its2107org/Lumen)).
- Identify bulbs by **MAC**, not IP; IPs change after power cycles unless DHCP reservations are set ([SmartThings thread](https://community.smartthings.com/t/edge-virtual-udp-sender-eases-sending-wiz-lights-control-commands/308637), [HA thread](https://community.home-assistant.io/t/wiz-lights-unavailable/463037)).

### 1.5 Scene IDs

From [pywizlight scenes.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/scenes.py):

1 Ocean, 2 Romance, 3 Sunset, 4 Party, 5 Fireplace, 6 Cozy, 7 Forest, 8 Pastel colors, 9 Wake-up, 10 Bedtime, 11 Warm white, 12 Daylight, 13 Cool white, 14 Night light, 15 Focus, 16 Relax, 17 True colors, 18 TV time, 19 Plantgrowth, 20 Spring, 21 Summer, 22 Fall, 23 Deep dive, 24 Jungle, 25 Mojito, 26 Club, 27 Christmas, 28 Halloween, 29 Candlelight, 30 Golden white, 31 Pulse, 32 Steampunk, 33 Diwali, 34 White, 35 Alarm, 36 Snowy sky, 40 Dim-to-warm, 256-265 Custom Mode 1-10, 1000 Rhythm.

- Tunable-white (TW) bulbs support 17 of these (6, 9-16, 18, 29-33, 35, 40); dimmable-white (DW) support 8 (9, 10, 14, 29, 31, 32, 34, 35).
- WiZ HDMI Sync Box exposes scenes 201-204 (open PR #218, 2026-10-26) ([issue search](https://api.github.com/search/issues?q=repo:sbidy/pywizlight+verified+OR+security+key+OR+securityKey)).
- `sceneId: 0` means no scene (custom colour). A scene stays active until a colour/temp command replaces it ([SmartThings thread](https://community.smartthings.com/t/edge-virtual-udp-sender-eases-sending-wiz-lights-control-commands/308637)).

### 1.6 Push updates (state changes made elsewhere)

- Send `registration` (with your real `phoneIp` and a MAC-like 12-hex `phoneMac`, `register:true`) to each bulb on 38899 and bind a listener on **UDP 38900**. The bulb then sends `{"method":"syncPilot","params":{...state...,"mac":...}}` on every change plus heartbeats. pywizlight re-registers every **20 s** and falls back to polling if nothing arrives within 33 s; openHAB re-registers every 5 s ([bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py), [openHAB](https://www.openhab.org/addons/bindings/wiz)).
- Push `params` can include `src` values such as `pir` (motion sensor) and `wizmote` (remote) ([bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py)).
- **Without registration there is no push**; you must poll `getPilot`. Registration is unsigned even on fw 1.39 ([PR #216](https://github.com/sbidy/pywizlight/pull/216)).
- **[UNCERTAIN]** Whether an iOS app in the background can keep a 38900 listener alive; iOS will suspend sockets, so plan for re-registration on foreground (pywizlight draft PR #217 handles source-address changes for the same reason).

### 1.7 Request signing on firmware 1.34+ (critical, 2026)

Source: [pywizlight issue #213](https://github.com/sbidy/pywizlight/issues/213) (opened 2026-09-07, open) and [PR #216](https://github.com/sbidy/pywizlight/pull/216) (opened 2026-09-26, unmerged, no reviews as of 2026-10-26).

- Observed on `ESP25_SHRGB_01` fw 1.34.1 and 1.38.0, `ESP25_SHORGB_01` strip fw 1.39.0 (auto-updated from 1.31.0). Reads work; every unsigned `setPilot` returns `{"code":-32602,"message":"Invalid params","sigTs":1788786272}`. A wrong signature returns `-32605 "Security error"`.
- Responses from these firmwares include a top-level `"hmac"` and `sigTs` inside `result`/`error`.
- **Signed request format** (confirmed working by two users):
  ```json
  {"method":"setPilot","env":"pro","params":{"state":true,"sigTs":1790000000},"hmac":"<base64 HMAC-SHA256>"}
  ```
  HMAC-SHA256 over the compact JSON of `params` (including `sigTs`, no spaces), key = hex-decoded 32-hex-char `udp_signing_key` (16 bytes), output base64. Replies are signed the same way over `result`/`error`. A `sigTs` 30 s old was accepted, 60 s old rejected; future timestamps and replays were accepted in testing.
- **Key source:** WiZ app → Home settings → Integrations → **Local integrations** → export; the JSON export contains `udp_signing_key` (one per home, delivered via a presigned S3 link valid ~15 min). **[UNCERTAIN]** exact menu wording and whether every region/app version has it.
- **Workaround:** WiZ app → Settings → Security → set control mode to **"Allow all controls"** (vs "Only verified controls"); unsigned writes then work. The official FAQ describes "Only verified controls" as accepting only messages from WiZ or from a local third-party integration holding the **home security key**, which can be rotated to revoke access ([WiZ FAQ 548](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/548-disabling-local-network-communication)).
- **[UNCERTAIN]** Whether "Only verified controls" is the default on new firmware/app installs. The issue reporters hit it without changing anything, which suggests it may now default on for some homes.
- Implication for an iOS app: implement HMAC signing with a user-pasted/imported key (or a QR/JSON import), plus a clear fallback message explaining the app setting.

### 1.8 Reliability, retries, rate limiting

- UDP is lossy; pywizlight sends up to 6 datagrams with backoff 0.75→1.5→3→3→3 s, 13 s total timeout, serialises requests per bulb with a lock, and discards late replies whose `method` doesn't match ([bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulb.py)). `setPilot` is retried fewer times to avoid flicker ([README](https://github.com/sbidy/pywizlight)).
- openHAB warns: "Sending commands too quickly can make devices stop responding temporarily"; parameters can't be changed while off (changing them turns the light on); power-on behaviour and fade times are app-only ([openHAB](https://www.openhab.org/addons/bindings/wiz)).
- A 2021 report had a lamp dropping Wi-Fi every ~4 minutes, prompting longer retry windows ([issue #67](https://github.com/sbidy/pywizlight/issues/67)).
- Set brightness and colour in **one** `setPilot` to avoid flashes; with many bulbs send packets back-to-back to avoid a "popcorn" effect ([SmartThings thread](https://community.smartthings.com/t/edge-virtual-udp-sender-eases-sending-wiz-lights-control-commands/308637)).
- No documented numeric rate limit. **[UNCERTAIN]**

---

## 2. Reference implementations

| Project | Language | Stars | Last push | Notes |
|---|---|---|---|---|
| [sbidy/pywizlight](https://github.com/sbidy/pywizlight) | Python 3.11+ | 559 (108 forks) | 2026-08-05 (v0.6.6) | MIT. Canonical; used by Home Assistant (`pywizlight==0.6.3` pinned in HA core manifest). 28 open issues incl. signing (#213/#216). ([GitHub API](https://api.github.com/repos/sbidy/pywizlight), [latest release](https://api.github.com/repos/sbidy/pywizlight/releases/latest)) |
| [Home Assistant `wiz` integration](https://www.home-assistant.io/integrations/wiz/) | Python | n/a | active (core) | IoT class local_push; DHCP + UDP discovery; lights, sockets (power metering on `ESP25_SOCKET_01`, `ESP20_SHDW_31R`, `ESP20_SHRGB_31R`, `ESP20_SHTW_31R`), occupancy via PIR push. Maintainers @sbidy, @arturpragacz. Used by 4.1% of HA installs. |
| [kpsuperplane/homebridge-wiz-lan](https://github.com/kpsuperplane/homebridge-wiz-lan) | TypeScript | 136 (41 forks) | 2026-10-24 | Apache-2.0. Bulbs (RGB/TW/DW), strips, string lights, poles, plugs `ESP10_SOCKET_06`, `ESP25_SOCKET_01`. 40 open issues. No signing support found. ([GitHub API](https://api.github.com/repos/kpsuperplane/homebridge-wiz-lan)) |
| [uditkarode/wikari](https://github.com/uditkarode/wikari) | TypeScript (Node) | 25 | 2025-10-26 | GPL-3.0; discovery + turn/color/brightness. ([GitHub API](https://api.github.com/repos/uditkarode/wikari)) |
| [heleon19/wiz-local-control](https://github.com/heleon19/wiz-local-control) + node-red-contrib | TypeScript | 1 | 2022-12 / 2024-01 | Fork lineage of Signify's old `wiz-local-control` npm package. ([GitHub search](https://api.github.com/search/repositories?q=wikari+OR+wiz-local-control+OR+wiz-lan+in:name&sort=stars&per_page=20)) |
| [openHAB WiZ binding](https://www.openhab.org/addons/bindings/wiz) | Java | n/a | in openHAB 4.x/5.x | Good protocol notes (firstBeat, heartbeats, mode-exclusivity). |
| [cB-Sigma/wiz](https://github.com/cB-Sigma/wiz) | Go | 0 | 2026-10-11 | Apache-2.0; covers requests, scenes, discovery and pushes incl. fan keys. ([GitHub API](https://api.github.com/repos/cB-Sigma/wiz)) |
| [pub.dev `wizlight`](https://pub.dev/packages/wizlight) / [`wiz`](https://pub.dev/packages/wiz) | Dart | n/a | n/a | Ports of pywizlight; useful if Flutter is considered. |

**Swift / iOS (none is a reusable package; all tiny, zero stars):**

| Project | Platform | Stars | Pushed | Notes |
|---|---|---|---|---|
| [its2107org/Lumen](https://github.com/its2107org/Lumen) | iPhone, iOS 26+, SwiftUI | 0 | 2026-10-13 | Full iPhone app: no account, UDP 38899 `getPilot/setPilot/getSystemConfig/getModelConfig`, discovery by unicasting to every host (no broadcast entitlement), remembers lights by MAC, widgets/Control Centre/Shortcuts via `LiveActivityIntent`, keychain-shared config. No license stated. ([GitHub API](https://api.github.com/repos/its2107org/Lumen)) |
| [maxamly/wizbar](https://github.com/maxamly/wizbar) | macOS 26 menu bar, SwiftUI | 0 | 2026-10-21 | MIT. Broadcasts `getPilot` per interface, uses `registration` every 20 s and listens for `syncPilot` on 38900. Good Swift reference for push. |
| [12utkarsh-s/WizBar](https://github.com/12utkarsh-s/WizBar) | macOS, Swift | 0 | 2026-09-30 | `WizClient.swift` uses Network.framework `NWConnection` for one-shot UDP with 1 s timeout. |
| [Jotharsh/LumaBar](https://github.com/Jotharsh/LumaBar) | macOS, Swift | 0 | 2026-10-21 | Multi-brand (WiZ, Tuya, Yeelight, LIFX, Hue, HA) local control; closest analogue to a multi-brand app. ([GitHub search](https://api.github.com/search/repositories?q=wiz+bulb+swift&sort=stars&per_page=20)) |

No published Swift Package for WiZ was found; expect to write ~300 lines (UDP client, JSON codec, discovery, push listener, HMAC signing with CryptoKit).

---

## 3. WiZ cloud / official APIs

- **Consumer:** no public API, no developer portal. Third-party voice/hub integrations (Alexa, Google, SmartThings) are cloud-to-cloud partner links; WiZ's FAQ lists what data partners receive (home/room/group/scene IDs, product state, firmware) but names no public developer program ([WiZ FAQ 758](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/758-data-shared-with-integration-partners)). Bulbs talk to the cloud via MQTT/TLS 8883 at `*.mqtt.wiz.world`; since ~fw 1.23 certificates are verified, so local MQTT spoofing no longer works ([wiz_light #85](https://github.com/sbidy/wiz_light/discussions/85)). Not viable for an app.
- **WiZ Pro API** ([docs.pro.wizconnected.com](https://docs.pro.wizconnected.com/), [FAQ 24](https://faq.wizconnected.com/hc/en/5-wiz-pro-dashboard/faq/24-where-can-i-find-information-regarding-pro-apis/)):
  - GraphQL at `https://api.pro.wizconnected.com/api/graphql`; OAuth 2.0 Authorization Code + PKCE (S256), authorize URL `https://pro.wizconnected.com/dashboard/#/oauth/authorize`, token endpoint `POST https://api.pro.wizconnected.com/api/oauth/token`; Bearer access tokens valid 3 h with refresh tokens. Requires a **`clientId` issued by WiZ** (no self-service registration documented).
  - Queries: `buildings`, `buildingTopology(buildingId)`; mutations: `changeLightState`, `changeGroupState`, `changeRoomState`, `changeFloorState`, `changeBuildingState`, `applyRoomScene`. Light params: `r,g,b,cw,ww` 0-255, `dimming` 10-100, `sceneId` 1-32/33, `speed` 20-200, `ratio` 0-100, `temperature` K. Webhooks (`STATUSCHANGE`) to HTTPS.
  - Scope: devices must be commissioned into a WiZ Pro **organization / building / location** (commercial/installer product, "Pro Setup" app uses BLE commissioning) ([pro.wizconnected.com](https://pro.wizconnected.com), [FAQ 26](https://faq.wizconnected.com/hc/en/5-wiz-pro-dashboard/faq/26-what-is-a-wiz-pro-organization), [FAQ 337](https://faq.wizconnected.com/hc/en/5-wiz-pro-dashboard/faq/337-installing-a-device-for-wiz-pro)). A consumer "home" is not a Pro building. **[UNCERTAIN]** whether a consumer could create a Pro organization and obtain a clientId; nothing suggests it is intended for consumers, and rate limits/terms aren't published.
  - Verdict: not a practical path for a consumer iPhone app.

---

## 4. Bluetooth

- Since 2019 almost all WiZ products include BLE, used for **onboarding only** (the app auto-detects nearby bulbs) and for **Matter commissioning** (BLE+Wi-Fi). After setup, control is Wi-Fi ([WiZ getting-started FAQ](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/767-smart-lighting---how-to-get-started), [Pairing troubleshooting FAQ 489](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/489-pairing-troubleshooting-1691160082), [HA Matter thread](https://community.home-assistant.io/t/feedback-wiz-bulbs-a-product-to-avoid-to-use-with-matter/774987)).
- WiZ Pro Setup app uses BLE for commissioning ([pro.wizconnected.com](https://pro.wizconnected.com)).
- No documented or reverse-engineered BLE GATT control protocol for WiZ was found in any library (pywizlight, HA, homebridge, openHAB are Wi-Fi only). Treat BLE control as **unavailable**. **[UNCERTAIN]** whether anyone has reverse-engineered the BLE provisioning GATT; nothing public surfaced.

---

## 5. Matter

- **Which products:** per the official list, WiZ and "Philips Smart LED Connected by WiZ" retrofit lamps, filament bulbs, table lamps, 6" downlights (US) and smart plugs with power meter **manufactured from Q2 2021** are Matter-upgradable; always-compatible regardless of date: US A23/R20/BR40, Bar linear, Mobile portable, Pole floor, **Squire table lamp**, 13 ft LED strip; EU P45/A60 frosted/A80, same lamps, Up&Down wall, Panel/Adria/Super Slim/Rune ceiling, 4 m ambience strip, all Philips-branded retrofit/filament. Identify by "10-digit number + A" on the box or a Bluetooth logo ([WiZ FAQ 539](https://faq.wizconnected.com/hc/en/3-wiz/faq/539-matter-compatible-product-list)). WiZ accessories (WiZmote, Smart Button, Motion Sensor) are handled separately and are not Matter devices **[UNCERTAIN]**.
- **Timeline:** Signify committed in 2022 to OTA-update everything made since Q2 2021 ([Signify 2022 PR](https://www.signify.com/global/our-company/news/press-releases/2022/20221103-wiz-smart-lighting-platform-first-support-matter-standard)); rollout via the WiZ v2 app in April 2023 (initially North America) ([HomeKit News](https://homekitnews.com/2023/04/26/wiz-gains-matter-support-for-most-products-via-app-update/), [MacRumors](https://macrumors.com/2023/04/26/wiz-smart-lights-apple-home-support/)). June 2024 strips/neon/fairy lights/GU10 "all LED strips are Matter compatible" ([Signify June 2024](https://www.signify.com/global/our-company/news/press-releases/2024/20240617-wiz-launches-music-sync-feature-and-expands-led-strip-portfolio)); Aug 2025 HDMI Sync Box TV Lightstrip, 15 m RGB strip, 5 m RGBIC strip, Gradient Floor, Dial Switch, all Matter-certified ([Korea Times 2025-08-28](https://www.koreatimes.co.kr/business/companies/20250828/signify-unveils-new-lineup-of-wiz-smart-lighting-products)).
- **Transport:** Matter over **Wi-Fi only**; no WiZ Thread products found (Thread is a Hue thing) ([CSA case study](https://csa-iot.org/newsroom/signify-shaping-the-future-of-connected-lighting/), [HA thread](https://community.home-assistant.io/t/philips-wiz-with-matter/791212)).
- **How it works:** WiZ app → Settings → Integrations → Matter generates a per-device pairing code; commissioning works via BLE+Wi-Fi with Apple Home / HA. Matter devices report hard-coded "V1.0" firmware; real fw (e.g. 1.33.0) only visible in WiZ app. Power-on-behaviour/transition attributes reportedly didn't stick via Matter ([HA Matter feedback thread](https://community.home-assistant.io/t/feedback-wiz-bulbs-a-product-to-avoid-to-use-with-matter/774987)).
- **UDP vs Matter for your app:** community reports indicate the local UDP API keeps working on Matter-migrated bulbs and non-Matter bulbs alike; a SmartThings developer notes UDP can set colour+brightness atomically and honours WiZ "rhythms", whereas Matter needs two commands, has retransmission, and supports off-with-effect ([SmartThings thread](https://community.smartthings.com/t/edge-virtual-udp-sender-eases-sending-wiz-lights-control-commands/308637)). **[UNCERTAIN]** no official statement that both coexist; also unknown whether Matter-paired bulbs enforce the 1.34+ signing for UDP (likely yes, since it's firmware-wide).
- For an iPhone app, Matter means going through **HomeKit/Matter via Apple Home** (HomeKit framework), not a direct connection; that's a separate code path from UDP and only applies to bulbs the user has migrated.

---

## 6. Onboarding / provisioning

- Official flow (WiZ app): grant Location, Local Network, Bluetooth; power the bulb (pulses blue/cool-white in pairing mode); app auto-detects via BLE or "+" → devices found → pick room → enter **2.4 GHz** SSID/password (WPA2/WPA3-Personal, no WEP/enterprise/open) → wait. Alternative "smart pairing" (device type) and **manual pairing**: phone joins the bulb's own AP `WiZConfig_xxxx` (bulb pulses purple) and the app pushes credentials. Force pairing mode by power-cycling 3-5 times with 1-2 s gaps. Firmware update after pairing takes 1-5 min offline ([FAQ 489](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/489-pairing-troubleshooting-1691160082), [FAQ 146](https://faq.wizconnected.com/hc/en/3-wiz/faq/146-what-type-of-networks-does-wiz-support)).
- **Third-party provisioning:** no public spec for the BLE or `WiZConfig` SoftAP provisioning exchange; every integration (HA, homebridge, openHAB, Lumen) states the bulb must first be set up with the WiZ app with "Allow local communication" enabled ([HA docs](https://www.home-assistant.io/integrations/wiz/), [homebridge-wiz-lan](https://github.com/kpsuperplane/homebridge-wiz-lan), [openHAB](https://www.openhab.org/addons/bindings/wiz)). The undocumented `setWifiConfig` UDP method exists in pywizlight's method list but is unexplored **[UNCERTAIN]**; a bulb in pairing mode isn't on your LAN anyway.
- **Account:** the WiZ app's final pairing stage registers the bulb to a cloud "home" (homeId). The FAQ doesn't explicitly state an account is mandatory, but every reported flow uses one **[UNCERTAIN]**. After pairing, bulbs can be firewalled from the internet and still controlled by UDP; firmware updates then stop and the WiZ app misbehaves (2 s refresh loops, deletes don't factory-reset) ([wiz_light #85](https://github.com/sbidy/wiz_light/discussions/85), [HA Matter thread](https://community.home-assistant.io/t/feedback-wiz-bulbs-a-product-to-avoid-to-use-with-matter/774987)).
- **"Local only" mode:** there's no official local-only toggle; the only relevant settings are Security → "Allow local communication" (on by default; off = cloud-only, no LAN UDP accepted) and the control mode "Allow all controls" vs "Only verified controls" (signed) ([FAQ 548](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/548-disabling-local-network-communication)).

---

## 7. Known gotchas and product-line notes

- **Firmware drift breaks parsers:** fw 1.18.0 removed a `getSystemConfig` field; 1.22.0 broke kelvin auto-detection (hence `getModelConfig`); 1.8.0 lacks `moduleName` (use `typeId`); 1.34+ requires signed writes ([openHAB forum](https://community.openhab.org/t/overhaul-and-rebmission-of-wiz-lighting-binding/89828?page=2), [pywizlight changelog via search](https://pypi.org/project/pywizlight), [issue #213](https://github.com/sbidy/pywizlight/issues/213)). Always feature-detect from `moduleName` + `getModelConfig` and tolerate -32601.
- **moduleName decoding** (`ESPxx_<ID>_<rev>`): ID contains `RGB` → full colour; `DDTW` → fan + TW; `TW` → tunable white; `SOCKET` → plug; `FANDIM` → fan + dimmer; otherwise dimmable white; `DH` = dual-head, `SH` = single-head/strip. Examples seen: `ESP01_SHRGB_03`, `ESP01_SHRGB1C_31`, `ESP20_SHRGB_01ABI`, `ESP20_SHRGB_01BT`, `ESP20_SHRGBC_01`, `ESP20_DHRGB_01(B)`, `ESP21_SHTW_01`, `ESP14_SHTW1C_01`, `ESP05_SHTW_21`, `ESP05_SHDW_21`, `ESP06_SHDW9_01`, `ESP03_SHRGB3_01ABI`, `ESP03_FANDIMS_31`, `ESP01_DIMTRIACS_01`, `ESP10_SOCKET_06`, `ESP25_SOCKET_01`, `ESP25_SHRGB_01`, `ESP25_SHORGB_01`, `ESP27` (HDMI sync box) ([bulblibrary.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/bulblibrary.py), [fake_bulb.py](https://raw.githubusercontent.com/sbidy/pywizlight/master/pywizlight/tests/fake_bulb.py)). The `ESP01` family docstring says "WiFi only bulb" (older, no BLE); newer ESP20/21/25 modules are the Wi-Fi + BLE generation **[UNCERTAIN: inferred]**.
- **Wi-Fi-only vs Wi-Fi+BLE:** pre-2019 bulbs lack BLE and must be paired via SoftAP/manual; Matter eligibility roughly coincides with the Bluetooth-logo (Q2 2021+) hardware ([FAQ 539](https://faq.wizconnected.com/hc/en/3-wiz/faq/539-matter-compatible-product-list)). Both generations speak the same UDP protocol.
- **Colour vs white mode exclusivity:** RGB LEDs and the two white channels are separate; sending `temp` leaves colour mode and vice versa; `c`/`w` unsupported on original Philips-WiZ bulbs ([openHAB](https://www.openhab.org/addons/bindings/wiz), [pywizlight README](https://github.com/sbidy/pywizlight)).
- **Scene + state quirk:** while a scene runs, `{"state":true}` may return success without visible change; send colour/temp to clear the scene ([issue #213](https://github.com/sbidy/pywizlight/issues/213)).
- **Bulbs "sleeping"/unavailable:** commonly caused by IP changes after power cycling (use DHCP reservations and key by MAC), router features (band steering/"Smart Connect", airtime fairness), 5 GHz-only SSIDs, and polling timeouts; bulbs that are off at the wall are simply unreachable ([HA thread 463037](https://community.home-assistant.io/t/wiz-lights-unavailable/463037), [openHAB offline thread](https://community.openhab.org/t/wiz-bulb-offline-but-can-control-it-normally/164175)). No evidence of a deliberate low-power sleep mode on mains bulbs; portable/battery products (Mobile lamp, Smart Button, Dial Switch) behave differently and the Dial Switch works without Wi-Fi via BLE **[UNCERTAIN]**.
- **Subnets/VLANs:** broadcast discovery doesn't cross subnets; unicast to a known IP works if UDP 38899 is routed, and push needs the bulb to reach your `phoneIp` on 38900. The WiZ app's own network test checks UDP broadcast ([FAQ 489](https://faq.wizconnected.com/hc/en/7-wiz-v2/faq/489-pairing-troubleshooting-1691160082), [HA community](https://community.home-assistant.io/t/feedback-wiz-bulbs-a-product-to-avoid-to-use-with-matter/774987)).
- **Product line (all one UDP protocol):** A19/A60/E14/GU10/BR30/BR40/A23/filament bulbs; LED strips (RGB, RGBIC 5-20 m, Neon Flex), Fairy Light; table/floor lamps (Squire dual-zone, Hero, Mobile portable, Pole, Bar); ceiling/wall luminaires; downlights; smart plugs (metering on `ESP25_SOCKET_01`); ceiling fans (via `FANDIM`/`DDTW` modules); HDMI Sync Box; accessories WiZmote, Smart/Portable Button, Motion Sensor, Dial Switch ([WiZ Squire page](https://www.wizconnected.com/en-us/p/wiz-luminaire-squire/046677604240), [Signify 2024](https://www.signify.com/global/our-company/news/press-releases/2024/20240617-wiz-launches-music-sync-feature-and-expands-led-strip-portfolio), [Signify 2022](https://signify.com/en-gb/our-company/news/press-releases/2022/20220726-Smart-lighting-for-daily-living-and-convenience-new-products-launched)). "Hero" lamp: no source found in this session **[UNCERTAIN]**. Dual-zone products use `devices`/`ratio`.
- **WiZ ↔ Hue:** no interoperability. Hue uses Zigbee via Bridge; WiZ is Wi-Fi. Signify keeps the brands separate; May 2025 web-store listings showing "Hue Bridge" on WiZ pages were confirmed by Signify to be display errors. The only theoretical path is Matter (WiZ as Matter device, Hue Bridge as Matter bridge is for Hue devices, not a controller) ([Hueblog 2025-05-16](https://hueblog.com/2025/05/16/will-wiz-soon-be-directly-compatible-with-philips-hue), [Hue Essentials forum](https://community.hueessentials.com/t/philips-wiz-zigbee-hue-bridge/7038)).

---

## 8. iOS-specific implementation notes

- **Local Network privacy:** any unicast/broadcast/multicast to LAN addresses triggers the iOS 14+ Local Network prompt; add `NSLocalNetworkUsageDescription`. Denial surfaces as send failures / no route ([Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Local Network Privacy FAQ](https://developer.apple.com/forums/thread/663858)).
- **Broadcast:** Apple (Quinn) states broadcasts and multicasts on iOS are gated by the managed entitlement `com.apple.developer.networking.multicast` (request via Apple form), and that Network.framework's broadcast support is "useless in practice" — use BSD sockets with `SO_BROADCAST` and `IP_BOUND_IF` per interface ([Apple forums: Broadcasts and Multicasts, Hints and Tips](https://developer.apple.com/forums/thread/772642), [entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)). Developers report EACCES on iPadOS 26 even with the entitlement ([forum thread](https://developer.apple.com/forums/thread/805719)) **[UNCERTAIN: unresolved]**.
- **Practical discovery without the entitlement:** unicast `getPilot` to every host in the Wi-Fi /24 (Lumen's approach), or use the cached MAC→IP map plus ARP/hostname `wiz_*` hints, then verify with `getSystemConfig`. Unicast UDP works fine with `NWConnection` (WizBar) ([Lumen](https://github.com/its2107org/Lumen), [12utkarsh-s/WizBar](https://github.com/12utkarsh-s/WizBar)).
- **Push listener:** bind UDP 38900 with `NWListener`; expect suspension in background, re-send `registration` with the device's current Wi-Fi IP on foreground; pywizlight re-registers every 20 s.
- **Signing:** CryptoKit `HMAC<SHA256>` over the compact `params` JSON; keep the key in Keychain; accept user-entered 32-hex key or the Local-integrations export JSON.
- **Multi-brand app context:** LumaBar shows WiZ coexisting with LIFX/Tuya/Yeelight/Hue local drivers in Swift; WiZ is the easiest of these (plain JSON UDP) apart from the new signing step.

---

## 9. Open questions / things to verify on real hardware

1. Whether "Only verified controls" is now the default for new homes (determines how many users hit signing).
2. Exact in-app path/wording for the Local-integrations key export and whether it exists outside the US/EU apps.
3. Whether Matter-migrated bulbs still accept UDP writes (signed or unsigned).
4. Behaviour of `sigTs` windows across firmware (30 s accepted / 60 s rejected observed once).
5. Whether `setWifiConfig`/`reset` UDP methods could support re-provisioning (undocumented).
6. iOS 26 broadcast behaviour with the multicast entitlement (EACCES reports).

Note: this session's web-search budget ran out before I could search for an official WiZ FAQ describing the "Local integrations" export; the key-export details above come solely from pywizlight issue #213 / PR #216.
