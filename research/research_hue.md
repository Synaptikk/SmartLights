# Philips Hue control from a custom iOS app: research report

Date: 2026-10-26. Scope: everything needed to drive a Hue bridge (v2 square bridge or Bridge Pro) and Hue bulbs from a native Swift/SwiftUI iPhone app.

Important caveat: every page under `developers.meethue.com/develop/...` (Getting Started, Core Concepts, API reference, Entertainment API, Remote API, HTTPS guidance, Bridge Discovery) is behind a free developer login. WebFetch returned only the login form for all of them. Everything below about the official docs is therefore reconstructed from (a) public Signify announcement pages, (b) verbatim quotes of the docs reposted in forums, and (c) actively maintained open-source clients (aiohue, Q42.HueApi, Hue-Sync, hue-entertainment, HueEntertainmentKit). Register at developers.meethue.com and read the originals before shipping; items marked UNVERIFIED should be checked there.

---

## 1. Hue Bridge local API (CLIP v2)

### 1.1 Transport, base path, auth header

- Base: `https://<bridge-ip>/clip/v2/resource` (HTTPS only, port 443). aiohue builds every URL as `https://{host}/{path}` with path `clip/v2/resource` and sends the header `hue-application-key: <app key>` on every request.
  Source: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/v2/__init__.py
- Signify's own announcement: "The V2 API does not support HTTP". HTTP on the v1 API "will be blocked when all bridges have received Signify signed certificates". HTTP was superseded by HTTPS since Nov 2018.
  Source: https://developers.meethue.com/?p=3403 (same page as https://developers.meethue.com/new-hue-api/)
- A copy of the official "Using HTTPS" page (quoted on a Homey forum): "The Hue API can currently be accessed over HTTP on port 80 and HTTP over TLS (HTTPS) on port 443" and HTTP "will be disabled in a future firmware release".
  Source: https://community.homey.app/t/philips-hue-dynamische-scenes-starten-met-logic-http-request/67913
- Resource paths follow `/clip/v2/resource/<type>` and `/clip/v2/resource/<type>/<uuid>`; GET for reads, PUT for updates (e.g. `PUT /clip/v2/resource/light/{id}` with `{"on":{"on":true},"dimming":{"brightness":50},"color":{"xy":{"x":0.3,"y":0.3}}}`), POST/DELETE for creatable types (scene, zone, etc.). Full resource list in the community OpenAPI spec (openhue-api), which covers: light, grouped_light, room, zone, bridge_home, scene, smart_scene, motion, temperature, light_level, button, relative_rotary, contact, tamper, camera_motion, grouped_motion, grouped_light_level, convenience_area_motion, security_area_motion, motion_area_candidate, motion_area_configuration, device, device_power, device_software_update, bridge, service_group, zigbee_connectivity, zgp_connectivity, wifi_connectivity, zigbee_device_discovery, entertainment, entertainment_configuration, speaker, behavior_script, behavior_instance, geofence_client, geolocation, homekit, matter, matter_fabric.
  Source: https://github.com/openhue/openhue-api (210 stars, pushed 2026-04-15, Apache-2.0). Spec bundle: https://api.redocly.com/registry/bundle/openhue/openhue/v2/openapi.yaml
- Quick "is this a v2 bridge" probe used by aiohue: `GET https://{host}/clip/v2/resource` with no key returns HTTP 403 on a v2-capable bridge (404 on a bridge that does not have the v2 API).
  Source: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/discovery.py
- Error mapping used by aiohue: eventstream 404 -> InvalidAPIVersion (firmware too old), 403 -> Unauthorized (bad key).
  Source: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/v2/controllers/events.py

### 1.2 Pairing (link button) flow

- Still done via the v1 endpoint: `POST https://<bridge-ip>/api` with body `{"devicetype":"<app>#<device>", "generateclientkey": true}`. Response is a JSON array; on success `[{"success":{"username":"<app key>","clientkey":"<32 hex chars>"}}]`. `username` is what you put in `hue-application-key`; `clientkey` is the DTLS PSK for Entertainment.
  - aiohue sends `{"devicetype": device_type}` as a POST to `{proto}://{host}/api` (tries https then http), reads `result[0]["success"]["username"]`, and raises `LinkButtonNotPressed` on error. Source: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/util.py
  - Error codes: `1` = Unauthorized (username not authorized), `101` = link button not pressed. Source: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/errors.py
  - `generateclientkey: true` and the `clientkey` field in the response are documented in a UCL project and the iotech write-up (the clientkey "is the Pre-Shared Key (PSK) used in the DTLS connection"). Sources: https://students.cs.ucl.ac.uk/2024/group1/docs/implementation/phillips-hue , https://iotech.blog/posts/philips-hue-entertainment-api/
- Physically press the round button on the bridge, then POST within ~30 s. Remote variant: see section 3.

### 1.3 Server-Sent Events (eventstream)

- Endpoint: `GET https://<bridge-ip>/eventstream/clip/v2`, headers `Accept: text/event-stream`, `hue-application-key: <key>`. aiohue also sends `Cache-Control: no-cache`, `Connection: close`, and `last-event-id: <id>` on reconnect; read timeout 90 s.
  Sources: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/v2/controllers/events.py ; https://community.openhab.org/t/hue-support-for-clip-v2-and-updates-through-streaming-http/126954
- Wire format: standard SSE. `id: <unix-ts>:<n>` lines and `data: [...]` lines. The data payload is a JSON array of events, each `{"id": "<uuid>", "creationtime": "...", "type": "update"|"add"|"delete"|"error", "data": [ {partial resource ...}, ... ]}`. The `data` objects carry the changed properties "in the same format as a GET response on the same resource type". Source (quoting the migration guide): https://support.comfortclick.com/communities/4/topics/10569-philips-hue-api-v2-events-server-side-events
- Keep-alive quirk: the bridge sends nothing when nothing changes, so clients cannot tell a dead socket from a quiet one. aiohue works around it by renaming a `geofence_client` resource named `aiohue_<random>` every 60 s to provoke an event. Reconnect backoff is `min(2 * attempts, 600)` s. Source: events.py link above.
- Home Assistant: on v2 bridges "state changes are pushed instantly over the bridge's local event stream"; v1 bridges are polled. Button/rotary events are rate-limited to one per second by the bridge. Source: https://www.home-assistant.io/integrations/hue/

### 1.4 Rate limits

- Concurrency: aiohue limits to 3 concurrent connections per host ("the bridge denies more than 3 concurrent requests"), retries on HTTP 429/503 with `0.25 * retries` s backoff, up to 25 retries, then raises BridgeBusy. Source: aiohue v2/__init__.py link above.
- Per-resource soft caps (secondary sources quoting the official migration guide; the official page is login-gated so treat as UNVERIFIED-but-consistent): "a soft cap of around 10 light commands per second to a single light" and "1 grouped_light command per second per room or zone". Source: https://jentic.com/apis/openhue.io/openhue . node-hue-api applies the same client-side limits (lights 10/s, groups 1/s). Source: https://raw.githubusercontent.com/peter-murray/node-hue-api/HEAD/Changelog.md
- Community reports of an overall ~20 requests/s bridge limit. Source: https://community.openhab.org/t/philips-hue-clip-2-api-v2-discussion-thread/142111?page=20
- Signify: "the REST API, in either version, should not be used for continuous fast light updates" -- use Entertainment streaming instead. Source: https://developers.meethue.com/?p=3403
- Practical rule for an app: coalesce slider drags, send at most ~10/s to a light and 1/s to a grouped_light, prefer scenes/grouped_light for multi-light changes.

### 1.5 TLS: certificates, root CA, pinning

- Official guidance (quoted verbatim on the Homey forum): clients must validate the bridge certificate against "the Signify private CA Certificate for Hue Bridges" and check that "the common name on the certificate matches the bridge id of the bridge you are trying to connect to". Suggested techniques: use the bridge id as hostname with a custom resolver, or inject a custom hostname verifier. "Older Hue Bridges currently still use self-signed certificates (instead of signed by Signify's Hue Bridge CA)"; those need trust-on-first-use pinning. Check with `openssl s_client -showcerts -connect <ip>:443`; if issuer CN == bridge id the cert is self-signed. Curl example: `curl --cacert huebridge_cacert.pem --resolve "<bridgeid>:443:<ipaddress>" https://<bridgeid>/api/<username>/lights`.
  Source: https://community.homey.app/t/philips-hue-dynamische-scenes-starten-met-logic-http-request/67913
- The root CA (PEM is shipped in Hue-Sync as `signify.pem`): self-signed X.509, Subject/Issuer `CN=root-bridge, O=Philips Hue, C=NL`, valid 2017-01-01 to 2038-01-19, ECDSA P-256, SHA-256, CA:TRUE. Copy the PEM from the developer portal "Using HTTPS" page or from: https://raw.githubusercontent.com/jdmg94/Hue-Sync/master/signify.pem . Hue-Sync notes "The bridge certificate uses the bridge ID as its Common Name" and patches DNS so the bridge id resolves to the IP. Source: https://github.com/jdmg94/Hue-Sync
- Bridge id format: 16 hex chars derived from the Zigbee MAC, e.g. `001788FFFExxxxxx` (returned as `bridgeid` by `GET http://<ip>/api/config`, no auth). Source: aiohue discovery.py link above.
- Swift/URLSession pattern (Apple DTS answer): in `urlSession(_:didReceive:completionHandler:)` build a `SecTrust` with `SecPolicyCreateBasicX509()` (ignores hostname mismatch), `SecTrustSetAnchorCertificates(trust, [hueRootCA])`, then `SecTrustEvaluateWithError`. Bundle the CA as DER (`.cer`). Do not blanket-`useCredential`. Source: https://developer.apple.com/forums/thread/707602
- Note: aiohue, node-hue-api and most hobby clients simply disable verification (`ssl=False`, `verify=False`). HueEntertainmentKit (Swift) does validate "against Signify Hue root CAs". Source: https://github.com/adeze/HueEntertainmentKit
- Also note App Transport Security: connecting by raw IP over HTTPS with a private CA needs the custom trust evaluation above; no ATS exception is needed if you keep HTTPS.

### 1.6 Discovery

- mDNS/Bonjour: service type `_hue._tcp.local.` (Home Assistant manifest `"zeroconf": ["_hue._tcp.local."]`; HomeKit model `BSB002`). TXT records include `bridgeid` and `modelid`. Signify: "Developers should use mDNS and discovery.meethue.com, which have been supported since January 2018, instead of UPnP"; UPnP/SSDP was deprecated and scheduled for disablement Q2 2022.
  Sources: https://raw.githubusercontent.com/home-assistant/core/dev/homeassistant/components/hue/manifest.json ; https://developers.meethue.com/?p=3403 ; https://developer.smartthings.com/edge-device-drivers/mdns.html
- Cloud broker ("N-UPnP"): `GET https://discovery.meethue.com/` returns `[{"id":"<bridgeid>","internalipaddress":"192.168.x.y","port":443}]` for bridges that have phoned home from the caller's public IP (aiohue parses `internalipaddress`). It replaced the old nupnp endpoint on 2018-07-01. UNVERIFIED: the endpoint is reported to rate-limit aggressive polling (HTTP 429); poll at most once per minute.
  Sources: https://raw.githubusercontent.com/home-assistant-libs/aiohue/master/aiohue/discovery.py ; https://developers.meethue.com/news/
- Confirm a candidate IP with unauthenticated `GET http://<ip>/api/config` (returns `bridgeid`, `modelid`, `swversion`, `apiversion`). Source: aiohue discovery.py.
- iOS specifics: use `NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil))` or `NetServiceBrowser`; you need the `NSLocalNetworkUsageDescription` key and `NSBonjourServices` = `_hue._tcp` in Info.plist (iOS 14+ local network privacy). HueEntertainmentKit implements "Discovery via Bonjour streaming, one-shot Bonjour scan, cloud broker lookup, or manual host entry". Source: https://github.com/adeze/HueEntertainmentKit

### 1.7 Legacy v1 API status (2025-2026)

- v1 (`/api/<username>/lights` etc.) is still present on v2 bridges and still used for pairing (`POST /api`). No public Signify announcement of a shutdown date was found; the official position is that v2 runs "next to the V1 API", new features (dynamic scenes, gradients, events) are v2-only, and v1-over-HTTP will be blocked once all bridges have CA-signed certs. Source: https://developers.meethue.com/?p=3403 ; openHAB docs: "in the long term API v1 will eventually be removed" https://www.openhab.org/addons/bindings/hue/
- Bridge v1 (round) hardware: software updates and cloud services ended 2020-04-30; local control only; its dedicated app retired 2022-04-30. Sources: https://developers.meethue.com/important-news-about-bridge-v1/ ; https://www.philips-hue.com/en-us/support/legal/end-of-support-policy
- Bridge v2 firmware is still being updated (e.g. v6.3.1978545030 on 2026-10-22; version scheme relabelled to 6.x in Sept 2026). None of the 2026 release notes mention API changes. Source: https://www.philips-hue.com/en-us/support/release-notes/bridge
- Recommendation: build on CLIP v2 only, keep v1 solely for `POST /api` pairing.

---

## 2. Hue Entertainment API (DTLS/UDP streaming)

### 2.1 How it works

1. Pair with `generateclientkey: true` to obtain `username` (PSK identity) and `clientkey` (32 hex = 16-byte PSK).
2. Create or pick an `entertainment_configuration` in CLIP v2 (`GET /clip/v2/resource/entertainment_configuration`), which lists `channels` (each with `channel_id` and position).
3. `PUT /clip/v2/resource/entertainment_configuration/<id>` with `{"action":"start"}` and the `hue-application-key` header. The bridge then opens DTLS on UDP 2100. `{"action":"stop"}` when done.
4. DTLS 1.2, PSK mode, cipher `TLS_PSK_WITH_AES_128_GCM_SHA256`, PSK identity = `username`, PSK = hex-decoded `clientkey`.
5. Send HueStream v2 frames continuously. The area "will quickly stop if there is no streaming activity to it (within a few seconds)".
   Sources: https://iotech.blog/posts/philips-hue-entertainment-api/ ; https://github.com/adeze/HueEntertainmentKit ; https://github.com/paxswill/hue-dansen ("Hue Entertainment also uses DTLS with pre-shared keys, not certificates")

### 2.2 HueStream v2 frame layout (big-endian)

| Offset | Size | Content |
|---|---|---|
| 0 | 9 | ASCII `HueStream` |
| 9 | 2 | version `0x02 0x00` |
| 11 | 1 | sequence id (ignored by bridge) |
| 12 | 2 | reserved `0x00 0x00` |
| 14 | 1 | color space: `0x00` RGB, `0x01` CIE xy + brightness |
| 15 | 1 | reserved |
| 16 | 36 | entertainment_configuration id as ASCII UUID |
| 52 | 7 x N | per channel: 1 byte channel_id + three 16-bit values (R,G,B or x,y,bri) |

Max 20 channels per message (constants in hue-entertainment: `HUESTREAM_HEADER = b"HueStream"`, `HUESTREAM_VERSION = bytes([0x02,0x00])`, `MAX_LIGHTS_PER_MESSAGE = 20`, `HUE_ENTERTAINMENT_PORT = 2100`, `COLOR_SPACE_RGB = 0x00`, `COLOR_SPACE_XY = 0x01`, `TARGET_UPDATE_RATE_HZ = 25`, `KEEPALIVE_INTERVAL_S = 5.0`).
Sources: https://iotech.blog/posts/philips-hue-entertainment-api/ ; https://raw.githubusercontent.com/music-assistant/hue-entertainment/main/hue_entertainment/constants.py

- Update rate: the docs reportedly recommend sending 50-60 Hz while the bridge forwards over Zigbee at ~25 Hz; HueEntertainmentKit pumps 50 Hz, hue-entertainment targets 25 Hz. Older community notes say "up to 25 times per second" and "up to 10 lights per Zigbee command". Sources: iotech.blog ; https://github.com/enwi/hueplusplus/issues/60 ; https://github.com/adeze/HueEntertainmentKit
- Signify: the v1 Entertainment API cannot address Gradient segments; move to v2 Entertainment. The C++ Entertainment Development Kit (EDK) remains available and is v2-compatible. Source: https://developers.meethue.com/?p=3403
- Only one streamer at a time per area; HueEntertainmentKit defaults to `.failIfActive` to avoid hijacking another app's stream.

### 2.3 Open-source implementations

| Project | Lang | Stars | Last push | Notes |
|---|---|---|---|---|
| adeze/HueEntertainmentKit https://github.com/adeze/HueEntertainmentKit | Swift 6 | 1 | 2026-09-29 | iOS 18+/macOS 15+/tvOS/visionOS. DTLS via Network.framework through swift-nio `NIOTransportServices` (`NIOTSDTLSTransport`). CLIP v2 client, Bonjour + cloud discovery, pushlink pairing, Keychain, root-CA validation, 50 Hz, gamut A/B/C conversion, photosensitivity limiter. Apache-2.0. Requires Swift 6.4/Xcode 27. Very new, 1 star: evaluate carefully but it is the most relevant Swift reference. |
| music-assistant/hue-entertainment https://github.com/music-assistant/hue-entertainment | Python | 0 | 2026-06-28 | Pure-Python DTLS-PSK + HueStream v2; works with V2 and Pro bridges. Good readable reference for the wire format. |
| michielpost/Q42.HueApi https://github.com/michielpost/Q42.HueApi | C# | 421 | 2026-10-01 | `HueApi.Entertainment` streaming client; docs/EntertainmentApi.md (path moved; 404 on master). |
| jdmg94/Hue-Sync https://github.com/jdmg94/Hue-Sync | TypeScript | 51 | 2026-03-09 | CLIP v2 + Entertainment via node-dtls-client; bundles `signify.pem`. |
| nakajima/HueEntertainmentSwift https://github.com/nakajima/HueEntertainmentSwift | Swift | 6 | 2023-12-17 | Old, 0.0.1, failing SPI builds. |
| rschio/huestream https://github.com/rschio/huestream | Go | 0 | 2025-10-07 | Go implementation. |
| paxswill/hue-dansen https://github.com/paxswill/hue-dansen | C/OpenSSL | 1 | 2020 | Minimal PSK DTLS example (v1-era). |

- iOS DTLS options: Network.framework `NWProtocolTLS` with PSK via `sec_protocol_options_add_pre_shared_key` over `NWParameters(dtls:)`, which is what NIOTransportServices wraps; alternatives are vendoring mbedTLS/OpenSSL. UNVERIFIED detail: whether Apple's DTLS stack negotiates `TLS_PSK_WITH_AES_128_GCM_SHA256` by default; HueEntertainmentKit's existence suggests it does, but check its source.

---

## 3. Hue cloud / Remote API (OAuth2)

- Registration: free developer account at developers.meethue.com, then "Add new Hue Remote API app" at https://developers.meethue.com/my-apps/ with name, description, callback URL; you receive AppId, ClientId, ClientSecret. Apps "must be approved before their credentials work" (Signify news item). Each new credential request requires re-accepting the terms.
  Sources: https://docs.n8n.io/credentials/philipshue/ ; https://developers.meethue.com/news/ ; https://developers.meethue.com/?p=820
- Endpoints (current v2 flow):
  - Authorize: `https://api.meethue.com/v2/oauth2/authorize?client_id=...&response_type=code&state=...` (older form also had `appid`, `deviceid`, `devicename`).
  - Token: `POST https://api.meethue.com/v2/oauth2/token` (`grant_type=authorization_code&code=...`), client auth via HTTP Basic (ClientId:ClientSecret) or the Hue "Digest" variant; refresh with `grant_type=refresh_token` to the same endpoint (v1 used `/oauth2/refresh`).
  - The legacy `/oauth2/auth` + `/oauth2/token` endpoints are "deprecated since July 2020 and will be disabled on short term". Source: https://developers.meethue.com/?p=3403
  - Token lifetimes reported in 2020: access token 7 days (168 h), refresh token 112 days; refresh tokens rotate. Source: https://gotoguy.blog/2020/05/21/remote-authentication-and-controlling-philips-hue-api-using-postman/
  - Remote pairing: `PUT https://api.meethue.com/route/api/0/config` body `{"linkbutton":true}` with `Authorization: Bearer <token>` (virtual link-button press, ~30 s window), then `POST https://api.meethue.com/route/api` `{"devicetype":"app#server"}` returns the `username`.
  - Remote CLIP v2: `https://api.meethue.com/route/clip/v2/resource/<type>` with both `Authorization: Bearer <access_token>` and `hue-application-key: <username>`. Legacy v1 route: `https://api.meethue.com/bridge/<username>/lights` (older guides) or `/route/api/<username>/...`.
  Sources: https://github.com/joakimlandegren/RainHue ; https://gist.github.com/leoherzog/5971698e3db9f034ef05cc279ce2aafc ; https://pipedream.com/apps/philips-hue ; gotoguy.blog above
- Quota: "upgrade all Remote Hue API apps quota from 5.000 calls per 24h to 50.000 calls per 24h" (Signify notice); the Terms state "The limit is currently set to a total of 50000 calls per day" and access is revoked after 6 months of no traffic. Sources: https://developers.meethue.com/?p=2233 ; https://developers.meethue.com/?p=820
- Hobbyist access in 2026: registration is open and free; approval is manual and historically granted to hobby projects, but one commercial Windows app reported that Philips "doesn't let third-party apps reach the bridge from outside the local network without a contract". No source confirms current approval turnaround. UNVERIFIED: whether new hobbyist remote apps are still being approved in 2026 -- apply early and plan the app so remote is optional. Source: https://apps.microsoft.com/detail/9pmmr5zb4qp4
- The remote API is no longer SSE-capable in any source found; eventstream is local only (UNVERIFIED).

---

## 4. Hue Bluetooth (BLE) direct control

- Hue bulbs with the Bluetooth logo expose a vendor GATT service; control requires BLE pairing/bonding (the OS handles it; macOS prompts, iOS will prompt on first encrypted characteristic access). A bulb already on a Zigbee bridge can still be controlled over BLE, but the official Hue app refuses to set it up over BT while it is bound to a known hub; put the bulb in pairing mode via Hue app > Settings > Voice assistants > Amazon Alexa/Google Home > "Make visible", or factory reset (which also randomises the BLE address).
  Sources: https://hueble.readthedocs.io/en/latest/usage.html ; https://www.home-assistant.io/integrations/hue_ble/ ; https://github.com/alexhorn/libhueble
- Characteristic UUIDs and encodings (from HueBLE source, pushed 2026-10-25, 32 stars, MIT, basis of Home Assistant's `hue_ble` integration):

```
UUID_POWER          932c32bd-0002-47a2-835a-a8d455b859dd   1 byte: 0x00/0x01
UUID_BRIGHTNESS     932c32bd-0003-47a2-835a-a8d455b859dd   1 byte: 1..254
UUID_TEMPERATURE    932c32bd-0004-47a2-835a-a8d455b859dd   uint16 LE mirek, 153..500
UUID_XY_COLOUR      932c32bd-0005-47a2-835a-a8d455b859dd   two uint16 LE = x*0xFFFF, y*0xFFFF
UUID_EFFECTS        932c32bd-0007-47a2-835a-a8d455b859dd   TLV: 0101<on> 0201<bri> 0302<mirek LE> 0404<x,y LE> 0502<transition in 100ms units LE> 0601<effect id> 0801<speed>
UUID_NAME           97fe6561-0003-4f62-86e9-b71ee2da3d22   UTF-8 string
UUID_HUE_IDENTIFIER 0000fe0f-0000-1000-8000-00805f9b34fb   16-bit UUID 0xFE0F in advertisement service data (discovery filter)
```
  Service UUID is `932c32bd-0001-47a2-835a-a8d455b859dd` (UNVERIFIED: not stated in the file; inferred from the 0002..0007 numbering). Source: https://raw.githubusercontent.com/flip-dots/HueBLE/main/HueBLE.py
- Notifications: once connected the light pushes state changes; connecting does not populate state (poll once). Tested models include LCA004/006/011, LCL009, LCX029, LWA021/031, LTO002, LOM007. Source: https://www.home-assistant.io/integrations/hue_ble/
- Other references: alexhorn/libhueble (Python, 27 stars, last push 2021-08); walter5138/hue_ble_bash (`hue_debug` file documents characteristics, 15 stars, 2020); Nordic DevZone thread confirms reads/writes require bonding. Sources: https://github.com/alexhorn/libhueble ; https://github.com/walter5138/hue_ble_bash/blob/master/README.md ; https://devzone.nordicsemi.com/f/nordic-q-a/111190/ble-bonding-to-philips-hue/483551
- iOS: CoreBluetooth; filter scans on service UUID 0xFE0F (Signify's 16-bit SIG-assigned UUID); add `NSBluetoothAlwaysUsageDescription`. BLE bulbs cannot be used via Matter ("Products connected via Bluetooth cannot be used with Matter"). Source: https://www.philips-hue.com/en-us/explore-hue/works-with/matter

---

## 5. Matter, Bridge Pro, account requirement

### 5.1 Matter via the bridge
- Hue Bridge (v2) gained Matter on 2023-09-14 ("The Philips Hue Bridge has been updated to support Matter"); Bridge Pro ships with Matter. The bridge is certified as a Matter bridge, so "every device connected to the bridge also appears through Matter", including third-party Zigbee bulbs (useful for Apple Home, which hides non-Hue bulbs on the HomeKit path). Not exposed: Play HDMI Sync Box, the dial of the Tap dial switch, BLE-only bulbs, Adaptive Lighting on the Matter path, scenes/entertainment (per user reports).
  Sources: https://www.philips-hue.com/en-us/support/release-notes/bridge ; https://www.philips-hue.com/en-us/explore-hue/works-with/matter ; https://homekitnews.com/2022/11/08/hue-bridge-matter-update-will-expose-third-party-lights-to-homekit/ ; https://community.openhab.org/t/hue-bridge-now-certified-for-matter-will-this-break-the-hue-binding/140593
- Matter did not change the local CLIP API; v2 exposes `matter` and `matter_fabric` resources for status. Source: openhue-api resource list. Nov 2025 firmware fixed "pairing over Matter failed as a result of connected third party devices". Source: https://hueblog.com/2025/11/07/new-software-update-for-hue-bridge-pro-and-hue-bridge/
- For a custom iOS app, Matter is a poor control path: iOS apps cannot act as a Matter controller except through Apple Home (HomeKit framework / MatterSupport for commissioning into Apple's fabric). Stick with CLIP v2 locally.

### 5.2 Hue Bridge Pro (launched Sept 2025)
- Specs: 1.7 GHz quad-core "Hue Chip Pro", 8 GB RAM, "150+ lights, 50+ accessories" (vs 50 lights / ~63 technical on Bridge v2), Wi-Fi plus Ethernet, Matter, MotionAware (uses existing bulbs as RF motion sensors, needs 3+ bulbs per area), launch price $139.99 / EUR 99.99 (US page later showed $98.99). Firmware line is separate (e.g. 2071127010 in Nov 2025).
  Sources: https://www.philips-hue.com/en-us/p/hue-bridge-pro/046677582111 ; https://mightygadget.com/philips-hue-bridge-pro-review/ ; https://homekitnews.com/2025/08/15/hue-bridge-pro-faster-performance-motion-sensing-and-more/ ; https://hueblog.com/2025/11/07/new-software-update-for-hue-bridge-pro-and-hue-bridge/ ; https://www.domo-blog.fr/philips-hue-plusieurs-nouveaux-produits-mais-toujours-une-limite-50-lampes/
- API: no official announcement of API changes was found; Q42.HueApi states it "works with the Hue Bridge Pro", hue-entertainment "works with both V2 and Pro bridges", and the openhue-api spec added MotionAware resources (`motion_area_configuration`, `convenience_area_motion`, `security_area_motion`, `motion_area_candidate`) plus `wifi_connectivity`. So: same CLIP v2 / eventstream / Entertainment, plus new resource types. Bridge v2 continues to receive firmware (Oct 2026). Sources: https://github.com/michielpost/Q42.HueApi ; https://github.com/music-assistant/hue-entertainment ; https://github.com/openhue/openhue-api
- Zigbee: Bridge Pro "only allows connection to Zigbee lights that are equipped with Trust Center functionality"; "Devices without Zigbee 3.0 or devices with SmartLink are no longer compatible" (includes first-gen LivingColors). See section 7. Source: hueblog 2025-11-07 above.

### 5.3 Account requirement
- Announced 2023: a Hue account becomes mandatory for the official Hue app (sign-up by email or Sign in with Apple). Signify CTO George Yianni: "the use of the system will continue to work completely locally and without an active internet connection". The official accounts page still says "Soon, you'll need to create a Philips Hue account" and "you'll always be able to control the lights -- even when the internet is down" (page copyright 2018-2026, so enforcement wording is still forward-looking as of 2026).
  Sources: https://hueblog.com/2023/02/27/philips-hue-soon-only-usable-with-account/ ; https://www.philips-hue.com/en-us/explore-hue/accounts ; https://www.t3.com/news/philips-hue-now-requires-users-to-make-an-account-heres-everything-you-need-to-know ; https://wiki.rossmanngroup.com/Philips_Hue_starts_requiring_an_account_for_the_hue_app
- Impact on your app: none for local CLIP v2. Link-button pairing and `hue-application-key` auth are bridge-local and need no Hue account (Home Assistant, openHAB, aiohue all run this way). The account matters only for the official app and the Remote API. The account's permission system can list and revoke third-party app access, so expect users to see your app key under "applications" in their Hue account.

---

## 6. Open-source libraries

### Swift / Apple
| Library | Stars | Last push | API | Verdict |
|---|---|---|---|---|
| adeze/HueEntertainmentKit https://github.com/adeze/HueEntertainmentKit | 1 | 2026-09-29 | CLIP v2 + Entertainment, Swift 6, iOS 18+ | Only modern Swift option; new and unproven, Apache-2.0. Good reference for Bonjour, pairing, Keychain, TLS and DTLS on Apple platforms. |
| Spriter/SwiftyHue https://github.com/Spriter/SwiftyHue | 84 | 2026-06-17 (small maintenance) | v1 only (`/api/<username>`, Lights/Groups/Scenes/Sensors polling "heartbeat") | Carthage/CocoaPods, old Swift style, no CLIP v2, no SPM mentioned. Not recommended for new work. |
| nakajima/HueEntertainmentSwift https://github.com/nakajima/HueEntertainmentSwift | 6 | 2023-12-17 | Entertainment | Abandoned, SPI builds failing. |
| jnewc/Hue https://www.swiftpackageregistry.com/jnewc/Hue | small | >5 yrs ago | v1, Combine | Unmaintained. |
| PhilipsHue/PhilipsHueSDK-iOS-OSX https://github.com/PhilipsHue/PhilipsHueSDK-iOS-OSX | 581 | archived 2021 | v1, Obj-C | Official SDK, deprecated July 2019, "will not be updated for v2". |
| zenangst/Hue, softin-tech/huekit | - | - | - | Not Hue-bridge libraries (UIColor utilities / colour-picker UI). |

Conclusion: there is no mature, maintained Swift CLIP v2 library. Plan to write a thin client (URLSession + Codable + `URLSession.bytes(for:)` for SSE) and optionally generate models from the openhue-api OpenAPI spec (e.g. with swift-openapi-generator).

### Reference implementations in other languages
| Library | Lang | Stars | Last push | Notes |
|---|---|---|---|---|
| home-assistant-libs/aiohue https://github.com/home-assistant-libs/aiohue | Python | 75 | 2026-10-26 | Best-structured CLIP v2 reference (controllers per resource, SSE, keepalive workaround, throttling). Powers Home Assistant (aiohue==4.9.0 pinned). Python 3.10+. |
| openhue/openhue-api https://github.com/openhue/openhue-api | OpenAPI | 210 | 2026-04-15 | Community OpenAPI 3 spec of CLIP v2; generate clients. |
| openhue/openhue-cli https://github.com/openhue/openhue-cli | Go | 157 | 2026-07-24 | CLI built from the spec; discover/pair/list/set; has MCP server. |
| michielpost/Q42.HueApi (HueApi) https://github.com/michielpost/Q42.HueApi | C# | 421 | 2026-10-01 | CLIP v2 local + remote + Entertainment; Bridge Pro supported. |
| jdmg94/Hue-Sync https://github.com/jdmg94/Hue-Sync | TS | 51 | 2026-03-09 | CLIP v2 + Entertainment; ships Signify root CA. |
| music-assistant/hue-entertainment https://github.com/music-assistant/hue-entertainment | Python | 0 | 2026-06-28 | Clean DTLS/HueStream reference. |
| peter-murray/node-hue-api https://github.com/peter-murray/node-hue-api | TS | 1196 | 2026-07-12 | v1 REST only; README: "no longer being actively maintained". |
| sqmk/huejay https://github.com/sqmk/huejay | JS | 422 | 2022-02 | v1 (API 1.19). Historical. |
| enwi/hueplusplus https://github.com/enwi/hueplusplus | C++ | 61 | 2026-08-15 | v1; Entertainment unimplemented (issue #60). |
| flip-dots/HueBLE https://github.com/flip-dots/HueBLE | Python | 32 | 2026-10-25 | BLE GATT reference (section 4). |

---

## 7. Non-Hue Zigbee bulbs on the Hue bridge

- Standards: the bridge has accepted Zigbee Light Link (ZLL) third-party devices since 2012 and added Zigbee 3.0 light support in firmware on 2018-02-05 ("Zigbee 3.0 is backward compatible" with ZLL). Devices using the ZHA profile (notably US-market Osram/Sylvania) do not join. Sources: https://developers.meethue.com/zigbee3 ; https://www.philips-hue.com/en-us/support/release-notes/bridge ; https://community.smartthings.com/t/hue-bridge-zigbee-3rd-party-light-integrations/135441
- Brands commonly reported working on Bridge v2: Innr (recognised "just like Hue originals"), IKEA Tradfri (only bulbs with updated firmware; pair by toggling power six times; colour bulbs dimmer), Ledvance/Osram Smart+ (EU ZLL units only), Sengled, Cree, AduroSmart and other Zigbee-3.0-certified lights "even without the Friends of Hue badge". Gledopto is often cited but unconfirmed here. Sources: https://www.schieb.de/nutzen-von-innr-geraeten-mit-hue-bridges ; https://mightygadget.com/compatible-third-party-bulbs-for-philips-hue/ ; https://www.smart-secure.co.uk/blog/news/philips-hue-beyond-the-eco-system-and-compatible-devices/ ; https://developers.meethue.com/zigbee3
- Limitations: no firmware updates for third-party bulbs through Hue; some features (dynamic scenes, colour loops, Entertainment/sync, gradient) are reserved for Hue/Friends-of-Hue devices; third-party bulbs are hidden from Apple Home on the HomeKit path but visible via the Matter path. Friends of Hue is a certification/marketing program (today mostly switches, e.g. Niko, Feller, Senic); "Zigbee certified" alone is a weaker guarantee. Sources: mightygadget, smart-secure, homekitnews links above.
- Bridge Pro (2025): only Zigbee 3.0 devices with Trust Center support can join; non-3.0 and SmartLink devices are rejected. hueblog paired an Innr E27 fine; users reported some Innr ceiling spots, Hoftronic actuators and Feller switches failing. Source: https://hueblog.com/2025/11/07/new-software-update-for-hue-bridge-pro-and-hue-bridge/
- History worth knowing: Dec 2015 firmware 1.11 blocked newly added third-party bulbs and was reversed after backlash. Sources: https://www.techhive.com/article/600088/philips-hue-users-outraged-after-firmware-update-blocks-third-party-lightbulbs.html ; https://techcrunch.com/2015/12/15/philips-hue-drm-update-blocks-third-party-light-bulbs
- From the API side, third-party bulbs appear as ordinary `light`/`device` resources; capabilities differ (`color`/`color_temperature` sections absent on white bulbs, no `gradient`, no `effects`).

---

## 8. Developer program terms (developers.meethue.com)

Terms of Use - Developer Content, Signify Netherlands B.V. (https://developers.meethue.com/?p=820). Key points:
- Register (free) to get API Content; "if applicable" remote credentials; under-18s prohibited; "you will not share your account and/or your access credentials, unless authorized by Signify in advance and in writing".
- License is "limited, revocable, non-transferable, non-exclusive (without the right to sublicense)". Hobby/personal vs commercial is not distinguished; both are allowed under the "Developer Purpose".
- App must tell users "that it is not a Signify app, product or service". May say "works with Philips Hue" / "for Philips Hue"; may not use Hue/Signify logos or trade dress; may not create a unitary name/mark incorporating "Hue" (descriptive use like "<Name> for Hue" is OK).
- Must not "aggregate control of the Philips Hue ... products" across multiple end users (i.e. no multi-tenant cloud controller), must add photosensitivity/health warnings for certain light effects, and must not build security/surveillance functionality (Article 8).
- Remote API: 50,000 calls/day; throttling or revocation for exceeding; access ends after 6 months without traffic; Signify may terminate at any time and amend terms without notice.
- Older coverage: the program launched in 2013 as free and open (https://signify.com/en-us/our-company/news/press-release-archive/2013/20130311-philips-hue-launches-sdk).
- Also relevant for iOS: Apple's own requirements (Local Network privacy prompt, Bluetooth usage string, no raw IP ATS exceptions needed if using HTTPS with custom trust).

---

## 9. Recommended architecture for the iPhone app (synthesis)

1. Discovery: Bonjour `_hue._tcp` first (NWBrowser), fall back to `https://discovery.meethue.com/`, then manual IP. Verify with `GET http://<ip>/api/config` and store `bridgeid`.
2. Pairing: `POST https://<ip>/api` `{"devicetype":"SmartLights#iphone","generateclientkey":true}` after the user presses the link button; store `username` + `clientkey` in Keychain.
3. TLS: custom `URLSessionDelegate` anchoring the Signify `root-bridge` CA and checking leaf CN == bridgeid; fall back to TOFU pinning for old self-signed bridges.
4. Control: CLIP v2 `PUT /clip/v2/resource/light/{id}` / `grouped_light/{id}` / `scene/{id}` `{"recall":{"action":"active"}}`; throttle to 10/s per light and 1/s per group; use `dynamics.duration` for transitions.
5. State: single SSE connection to `/eventstream/clip/v2` with `URLSession.bytes(for:)`, last-event-id on reconnect, full refetch after >60 s outage; add a keepalive probe as aiohue does.
6. Fast effects: Entertainment via DTLS-PSK on UDP 2100 (Network.framework or vendor from HueEntertainmentKit), 25-50 Hz, 20 channels max.
7. BLE fallback for bulbs without a bridge: CoreBluetooth with the UUIDs in section 4.
8. Remote: optional; register a Remote API app, OAuth2 `/v2/oauth2/*`, `/route/clip/v2`, 50k calls/day.

Items to verify once logged into developers.meethue.com: exact rate-limit text, eventstream keep-alive semantics, the HTTPS page PEM, the Entertainment API v2 page (max channels, recommended Hz), and Remote API approval status for hobby apps.
