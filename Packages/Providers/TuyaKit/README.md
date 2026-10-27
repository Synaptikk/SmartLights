# TuyaKit

Tuya / Smart Life white-label **Wi-Fi** lights (Feit, Globe, Merkury/Geeni, Teckin, Gosund, Treatlife, Sylvania Wi-Fi,
Cree Connected Max, ...) controlled over the Tuya **local** protocol, no cloud. It is a Swift port of the relevant
parts of [`tinytuya`](https://github.com/jasonacox/tinytuya) 1.20.0 (MIT, Jason A. Cox). Background:
`research/research_brands.md` (Tuya section), `docs/BRAND-RUNDOWN.md`, `docs/ONBOARDING-WALKTHROUGHS.md` §10.

| Target | Contents | Platforms |
|---|---|---|
| `TuyaCodec` | Ordered JSON with tinytuya formatting, AES-128-ECB/PKCS7, AES-128-GCM, HMAC-SHA256, MD5, CRC32, 55AA/6699 framing, stream splitter, request payloads per version (`payload_dict`), per-connection session codec incl. 3.4/3.5 session-key negotiation (client and device side), UDP announcement decoding, bulb-type detection, DPS ↔ `LightState`/`LightCommand` | Linux + Apple |
| `TuyaKit` | `TuyaProvider` actor (`LightProvider`), one TCP session per device, transports | Apple (NWConnection + NetKit); Linux via a POSIX fallback used by the tests |

## Protocol summary

Frames (`tinytuya/core/header.py`, `message_helper.py`):

| | 3.1 | 3.3 | 3.4 | 3.5 |
|---|---|---|---|---|
| Prefix / suffix | `000055AA` / `0000AA55` | same | same | `00006699` / `00009966` |
| Header | `>4I prefix seqno cmd length` | same | same | `>IHIII prefix 0 seqno cmd length` |
| Body | plaintext; `CONTROL` = `"3.1"` + md5hex[8:24] + base64(AES-ECB) | AES-128-ECB (local key), then `"3.3"`+12×NUL prepended (not for query/heartbeat/negotiation) | `"3.4"`+12×NUL prepended, then AES-ECB (session key) | `"3.5"`+12×NUL prepended, then AES-128-GCM (session key), 12-byte IV in the frame, AAD = header after the prefix |
| Trailer | CRC32 | CRC32 | HMAC-SHA256 (session key; local key during negotiation) | 16-byte GCM tag |
| Device→client | + 4-byte retcode before the body | same | same | retcode inside the ciphertext |

Commands: `CONTROL` 7 (`CONTROL_NEW` 13 on 3.4/3.5), `STATUS` 8 (pushes), `HEART_BEAT` 9, `DP_QUERY` 10 (`DP_QUERY_NEW` 16
on 3.4/3.5), `UPDATEDPS` 18, `SESS_KEY_NEG_START/RESP/FINISH` 3/4/5, `REQ_DEVINFO` 37. Request bodies follow tinytuya's
`payload_dict` exactly, with every space removed ("if spaces are not removed device does not respond!"):
`{"devId":…,"uid":…,"t":"<unix s>","dps":{…}}` for 3.1/3.3 control, `{"protocol":5,"t":<int>,"data":{"dps":{…}}}` for 3.4/3.5.

Session key (3.4/3.5): client sends a random 16-byte nonce (cmd 3), device answers remote nonce +
HMAC-SHA256(local key, client nonce) (cmd 4), client checks it and sends HMAC-SHA256(local key, remote nonce) (cmd 5).
Session key = AES-ECB(local key, nonce XOR) for 3.4, or the ciphertext of AES-GCM(local key, IV = client nonce [0..<12],
nonce XOR) for 3.5. A wrong local key fails the HMAC check in step 2, so pairing reports it immediately.

Discovery (UDP): devices broadcast every ~5 s. 3.1 devices send plaintext 55AA frames to **6666**; newer ones send to
**6667**, AES-ECB with `md5("yGAdlopoPVldABfn")` (3.3/3.4) or a 6699 GCM frame with the same key (3.5). We also broadcast
tinytuya's `REQ_DEVINFO` to UDP 7000 to make 3.5 devices announce sooner. The JSON carries `gwId` (device id), `ip`,
`productKey` and `version` — but never the local key.

DPS for lights (`BulbDevice`): type **B** (most current bulbs): 20 `switch_led`, 21 `work_mode` (`white`/`colour`/`scene`/
`music`), 22 `bright_value_v2` 10-1000, 23 `temp_value_v2` 0-1000 (0 = warm), 24 `colour_data_v2` `hhhhssssvvvv`
(h 0-360, s/v 0-1000), 25 scene. Legacy type **A**: 1 switch, 2 mode, 3 brightness 25-255, 4 temp 0-255, 5 colour
`rrggbbhhhhssvv`. Type **C** (dimmable/CCT filament): 1 switch, 2 brightness 25-255, 3 temp 0-255. The type is detected from
the first status like `detect_bulb`; optional dps the device did not report are treated as absent (a soft-white bulb has
no 23/24). Colour temperature is spread over 2700-6500 K (`Configuration.kelvinRange`), as in HA localtuya.

## Flow

1. **Pairing** (`pair(_:using:)`, `PairingInteraction`): `confirm(TuyaProvider.advancedExplainer)` (what a local key is and
   where to get it), then `text` device id (skipped for a broadcast-discovered device), `secureText` local key (16 characters,
   asked up to 3 times), `text` IP (skipped when known), `choose` protocol version ("Detect automatically" tries 3.3, 3.5, 3.4,
   3.1). The provider connects, negotiates (3.4/3.5), reads the status, detects the bulb type and stores the record.
   Re-pairing an existing light pauses its session first. Programmatic: `addDevice(id:localKey:host:versions:name:)`.
2. **Storage.** All records (`TuyaDeviceRecord`: id, name, **local key**, IP hint, version, device22 flag, dp set) are one JSON
   array in `SecretStore` under `SecretKey(brand: .tuya, owner: "local", item: "devices")`. `PairedDevice.metadata` holds only
   non-secret fields (version, bulb type). Lights are keyed by the Tuya device id (`tuya:<devId>`), never by IP.
3. **Sessions.** One persistent TCP 6668 connection per device (`TuyaDeviceSession`): connect → negotiate → `DP_QUERY` →
   online → `HEART_BEAT` every 10 s; `STATUS` pushes become `ProviderEvent.stateChanged`. Three unanswered heartbeats or a read
   error reset the connection (light reported unreachable) and it reconnects with exponential backoff (1 s → 60 s, jitter).
   Answers of "json obj data unvalid" switch the device to tinytuya's *device22* mode (status polled with `CONTROL_NEW` listing
   the light dps), and that is remembered.
4. **One connection at a time.** A Tuya device serves a single local client. The provider never opens a second connection to
   a device it holds: pairing stops the running session first and waits `connectionHandoffDelay` (300 ms) before reconnecting,
   and discovery never TCP-probes hosts that have a session. `stop()` (app in background) closes every connection so the
   Smart Life app can connect again; `start()` reopens them.
5. **Discovery.** With the multicast entitlement (`broadcastAvailable`): listen on UDP 6666/6667 for `options.timeout` and send
   `REQ_DEVINFO`; announcements update the IP hint of paired lights. Without it (unicast fallback): TCP connect probes to 6668
   on manual and cached hosts and, if allowed, a `/24` `SubnetSweeper` sweep. An open port is reported as
   `ip:<host>` ("Possible Tuya device"), and pairing then asks for the device id. Manual IP entry always works.
6. **Commands.** `send` maps a `LightCommand` (normalised for the detected capabilities) to **one** `CONTROL` with all changed
   dps (e.g. `{"20":true,"21":"white","22":505,"23":500}`), so brightness and colour never flash separately. Brightness 0
   turns the light off. The state is applied optimistically and confirmed by the device's `STATUS` push.

## Getting the device id and local key (advanced)

This is the "Local path (advanced)" of `docs/ONBOARDING-WALKTHROUGHS.md` §10. If the bulb has a **Matter** logo, add it to
Apple Home instead (§0.1) and use the HomeKit provider. Menu names marked [verify] come from community guides, not from a
device in hand.

1. **Set up the light in the Smart Life (or Tuya Smart) app** as usual (2.4 GHz Wi-Fi, same network as the iPhone). Note the
   app account's region.
2. **Create a Tuya developer account** at [iot.tuya.com](https://iot.tuya.com) and a cloud project: Cloud → Development →
   Create Cloud Project, industry "Smart Home", development method "Smart Home", and the **data center that matches the app
   account** (e.g. "Western America" for US accounts) [verify].
3. **Subscribe the project to IoT Core** (plus "Authorization Token Management" / "Smart Home Basic Service" if offered). The
   free trial expires (about a month); renew it with "Extend trial" under Cloud → Cloud Services when key queries start failing [verify].
4. **Link the Smart Life account:** in the project, Devices → Link App Account (Link Tuya App Account) → Add App Account shows a
   QR code; in Smart Life go to Me → scan icon (top right) and scan it. Your devices then appear in the project's device list [verify].
5. **Read the keys**, either:
   - **tinytuya wizard** (recommended): on a computer, `pip install tinytuya`, then `python -m tinytuya wizard` and enter the
     project's Access ID and Access Secret (Overview tab) and one device id. It writes `devices.json` with each device's `id`,
     `key` (the local key) and `version`; `python -m tinytuya scan` shows each device's IP and protocol version.
   - or the platform's **API Explorer**: Device Management → "Query Device Details" (`/v1.0/devices/{device_id}`) shows
     `local_key` [verify].
6. **In SmartLights:** Add a brand → Tuya → read the advanced explainer → enter the device id, local key and IP (or pick the
   discovered light, then only the key is asked) → protocol "Detect automatically". Reserve the light's IP in the router.
7. **Close Smart Life** (and any Home Assistant localtuya/tuya-local integration) while SmartLights is connected: the light
   accepts one local connection.

Caveats: **re-pairing the light in Smart Life changes its local key** (pair it again in SmartLights); some white-label apps
(Sylvania, Feit) are separate clouds whose devices cannot be linked to a Tuya developer project; the local key is a secret,
so never paste it into chats or issues.

## Requirements and caveats

- Ports: TCP 6668 (control), UDP 6666/6667 (announcements), UDP 7000 (`REQ_DEVINFO`). Local Network permission is needed;
  receiving broadcasts needs the multicast entitlement (`com.apple.developer.networking.multicast`). Without it, manual/cached
  IPs and the TCP sweep still work.
- Not implemented: Tuya cloud (QR login with our own Tuya developer app, T3.1 follow-up), scenes/effects (`scene_data_v2`,
  music mode; a running scene is reported as `LightState.effect`), protocol 3.2, gateways and Zigbee/BLE sub-devices
  (`cid`), non-light dps (plugs, sensors).

## Unverified items

- Nothing here has run against a real Tuya device yet. The wire format is checked byte for byte against tinytuya, and the
  provider against the in-package fake device. See `docs/HARDWARE-NOTES.md` and `docs/OPEN-QUESTIONS.md`.
- 2700-6500 K for `temp_value_v2` 0-1000: Tuya does not report the range; real bulbs vary (2200-6500 K is also common).
- Heartbeat cadence (10 s) and the reset after 3 unanswered heartbeats: tinytuya examples send one every ~10 s; devices
  are said to drop idle connections after ~30 s.
- device22 query list (`TuyaDPS.lightQuery`: dps 1-5 and 20-25 requested as `null`).
- We reject frames with a bad CRC/HMAC (tinytuya only logs them, but does reject bad GCM tags).
- Colour V is written in 10...1000 (hsv16) or 1...255 (rgb8) using LightCore's brightness stepping.
- Everything Apple-specific (NWConnection, NetKit UDP listening on 6666/6667) is compiled first on macOS CI.

## Tests

```
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/TuyaKit swift:6.1 swift test
```

- `TuyaCodecTests`: vectors in `Tests/TuyaCodecTests/Fixtures/tuya_fixtures.json` come from the real tinytuya 1.20.0
  (`gen_fixtures.py`, clock and randomness pinned): `CONTROL`/`DP_QUERY`/`HEART_BEAT`/`UPDATEDPS` frames for 3.1, 3.3, 3.4,
  3.5 byte for byte (incl. the 3.1 MD5 signature and the device22 query), device responses and pushes decoded as tinytuya
  decodes them, the full 3.4 and 3.5 negotiation (step frames, session key) from both sides, UDP announcements on 6666/6667
  (plain, ECB, GCM), `REQ_DEVINFO`, CRC32, `BulbDevice` colour strings and default dp sets; plus FIPS-197 AES, GCM tamper
  checks, the stream splitter, bulb-type detection (tinytuya's documented examples) and DPS ↔ LightState/LightCommand mapping.
- `TuyaKitTests`: `TuyaProvider` against `FakeTuyaDevice` (in this package; real TCP on 127.0.0.1; protocol 3.3 and 3.5,
  single client like real devices): manual pairing with version auto-detect, wrong key, cancelling, discovered-device pairing
  from a UDP announcement, unicast fallback, combined control frames, external changes, reconnect, heartbeats and the
  missed-heartbeat reset, no second connection, stop/start, restore from the secret store, device22 fallback, removal.

## Attribution

Protocol logic, constants and payload formats are ported from tinytuya (MIT License, Copyright (c) 2024 Jason Cox);
test fixtures are generated with it. See `THIRD_PARTY_NOTICES.md`.
