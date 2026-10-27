# Hardware notes

Observations from real hardware (probe scripts in `tools/probe/`, raw output in `tools/probe/out/`, gitignored). Where real hardware contradicts `research/*.md`, this file wins. Newest entries first.

---

## 2026-10-27 - Meross and SwitchBot: source contradictions (T3.2, T3.3, no hardware)

No Meross or SwitchBot device was available; these are decisions taken where the sources disagree. Re-check on hardware.

- **SwitchBot `sign` case.** The SwitchBotAPI README prose says to convert the signature to upper case, but its Python and
  JavaScript samples (and Home Assistant's `switchbot_api`) send the plain base64 of HMAC-SHA256(secret, token + t + nonce).
  Upper-casing base64 changes the bytes, so SwitchBotKit sends plain base64. If real requests get 401 with a correct
  token/secret, try the upper-cased variant.
- **SwitchBot active colour mode.** Status replies carry both `color` and `colorTemperature` with no mode field. SwitchBotKit
  keeps the mode of its last command, else treats `255:255:255` as colour-temperature mode. Confirm on a Color Bulb.
- **SwitchBot 401 meaning.** Both bad credentials and the 10,000/day limit answer `Unauthorized`. After a recent success a 401
  is treated as the limit (no re-auth prompt).
- **Meross discovery.** meross_lan finds devices from Home Assistant's DHCP watcher (OUIs `48:E1:E9`, `C4:E7:AE`, `34:29:8F:1`);
  iOS apps cannot see DHCP, so MerossKit sweeps the /24 with a signed `Appliance.System.All` and maps IPs by the uuid in
  `header.from`. Check how long a full sweep takes on the home network and that devices answer a wrong-key probe with
  `ERROR 5001` (used to report "key mismatch").
- **Meross encrypted firmware.** For devices listing `Appliance.Encrypt.ECDHE`, meross_lan's config flow gets the ability in clear
  text and everything else AES-CBC encrypted; MerossKit does the same. Unverified.
- **Meross `from` header.** MerossKit sends `from`/`triggerSrc` = `MerossClient` (meross_lan's HTTP value); MerossIot uses an
  MQTT topic there. Devices are reported to accept any string over HTTP.
## 2026-10-27 - Twinkly and DIRIGERA (T3.4, T3.5): not yet seen on hardware

Neither device has been probed; both providers are built from the protocol references and tested only against in-package fakes. Check these on real hardware and correct the providers if they differ:

### Twinkly (TwinklyKit, xled-docs)
- [verify] A unicast `\x01discover` to a single device on UDP 5555 is answered (the sweep fallback depends on it; xled supports a `destination_host`).
- [verify] `/xled/v1/led/color` exists on the user's firmware (xled-docs: since 2.7.1). Older firmware is treated as brightness-only.
- [verify] How long the token lasts (`authentication_token_expires_in`, documented as 14400 s). Another controller logging in should make our next call return 401. The provider then logs in once more.
- [verify] Whether the Twinkly app switches back to `movie` on "on". The provider restores the last "on" mode, or `movie` if there is none.
- Effects: every predefined effect and the uploaded movie are flagged `isFast`, so the UI always shows the photosensitivity warning. Twinkly does not report effect speed.

### IKEA DIRIGERA (DirigeraKit, Leggin/dirigera)
- [verify] **Certificate**: TOFU pinning relies on the hub's leaf being **self-signed** (issuer == subject). NetKit `TrustEvaluator` only pins self-issued leaves. If the hub serves a chain to an IKEA CA instead, every request after pairing will be rejected. Record the issuer/subject/CN and adjust (pin the leaf without the self-issued check). The CN is deliberately not checked: its format is unknown.
- [verify] `GET /v1/hub/status` returns `{"id": ...}` with the hub id. It is used as the stable hub id and the pin key.
- [verify] Token endpoint before the button press: the provider retries on 400/401/403 for 30 s. The exact status the hub returns has not been observed.
- [verify] Whether one PATCH may carry `isOn` + `lightLevel` + colour together. The provider tries combined first and falls back to one PATCH per attribute group on HTTP 400 (remembered per hub).
- [verify] WebSocket event envelope (`type`, `data.id`, partial `data.attributes`, `isReachable`) and whether the hub needs our pings (we ping every 60 s like Leggin/dirigera).
- [verify] mDNS: Leggin/dirigera only says the hub announces `gw2-<id>.local`. The service types `_ihsp._tcp` and `_hap._tcp` that the provider browses are guesses. Manual IP and the HTTPS /24 sweep (probe `GET /v1/hub/status` -> 401) work without Bonjour.

---

## 2026-10-27 - TuyaKit (T3.1): not yet confirmed on hardware

TuyaKit was built against tinytuya 1.20.0 (byte-for-byte fixtures) and an in-package fake device; no real Tuya device has been
connected yet (`192.168.254.38`, TCP 6668 open, is the candidate). To confirm once a device id + local key are available:

| Item | Assumption in code | How to check |
|---|---|---|
| Protocol version and handshake | auto-detect 3.3 → 3.5 → 3.4 → 3.1 | `python -m tinytuya scan` shows `version`; pairing in the app reports it |
| Bulb type / dps | B (20-24) or A/C (1-5) from the first status | first `DP_QUERY` answer (`python -m tinytuya` `d.status()`) |
| `temp_value_v2` 0-1000 range | 2700-6500 K | compare with the box / Smart Life slider ends |
| Idle timeout | heartbeat every 10 s; reset after 3 unanswered | watch the session stay up for > 5 min |
| Single client | Smart Life (LAN) and SmartLights can't both hold the connection | open Smart Life while the app is connected |
| UDP announcements | 6667 ECB (3.3/3.4), 6699 GCM (3.5), every ~5 s | `python -m tinytuya scan` or a 6666/6667 listener |

---

## 2026-10-27 - TP-Link Kasa/Tapo: open protocol questions (T2.6, no hardware yet)

TPLinkKit was built from python-kasa 0.12.0 behaviour and simulator tests only; none of this has been checked on a real device. Things to confirm when a Kasa or Tapo light is reachable:

| Question | Why it matters | What the code does now |
|---|---|---|
| Does the device answer the bare 20002 header (`020000010000000000000000463cb5d3`), or only python-kasa's keyed probe? | Discovery | Sends both (keyed probe with a throwaway RSA-2048 key) |
| Is the discovery `device_id` the same as `get_device_info.device_id`? | Identity | Devices are keyed by MAC, which both report; the device id is metadata only |
| `Set-Cookie` format (`TP_SESSIONID=…;TIMEOUT=86400` in one header?) | KLAP session | Parses `;`/`,` separated pairs from every `Set-Cookie` value |
| Does a Kasa bulb on new firmware still answer UDP 9999 while only speaking KLAP on TCP? | Transport choice | A 20002 answer wins; a refused TCP 9999 during pairing falls back to a KLAP probe |
| Does plain `http://<ip>` KLAP work from the iOS app without an ATS exception? | Tapo control | Assumes numeric IPs are ATS-exempt (`App/` has no `NSAllowsLocalNetworking`) |
| Third-Party Compatibility off: what does the device answer (handshake1 hash mismatch vs HTTP error)? | Error message | Treated as wrong credentials; the retry prompt mentions the switch |

Licensing note: python-kasa is **GPL-3.0**, so no code was copied; the protocol was re-implemented from its observable behaviour (and the MIT `mihai-dinculescu/tapo` crate), and test vectors are outputs of running python-kasa (`Packages/Providers/TPLinkKit/Tests/TPLinkCodecTests/Fixtures/`).

---

## 2026-10-26 - first probe run from the dev PC (T0.8)

### Network as seen from the dev PC

| Item | Value |
|---|---|
| PC | `192.168.254.40/24`, wired Ethernet, Windows network profile **Public** (the Node.js firewall rule allows UDP/TCP inbound on Public) |
| Gateway | `192.168.254.254`, **Sagemcom F5380** (Windstream "Kinetic" gateway, SSID `KINETIC_FD5DE0`). Answers SSDP. |
| Other hosts seen (ICMP/ARP/mDNS) | `.4` (9c:8c:6e), `.9` and `.10` (3c:58:5d, Sagemcom: probably mesh extenders), `.11` (cc:08:fa, "Shane's MacBook Air", AirPlay over mDNS), `.38` (fc:3c:d7, **TCP 6668 open = likely a Tuya device**), `.82` (24:55:9a) |
| Also present | Tailscale (`100.121.63.127/32`, skipped) and a WSL Hyper-V vSwitch (`172.17.144.1/20`, probed, nothing there) |

Multicast and broadcast reach the PC in both directions: SSDP M-SEARCH got replies from the gateway, and the `_hue._tcp` mDNS query got an unrelated AirPlay answer from the MacBook. So the empty results below are not caused by the PC's firewall.

### WiZ: no bulbs reachable

- `wiz.mjs discover` (broadcast `registration register:false` + `getPilot` to `192.168.254.255` and `255.255.255.255`, resent each second for 5 s) found **0** devices. Run twice.
- `wiz.mjs sweep` (unicast `getPilot` to every host of `192.168.254.0/24`, two passes) found **0**.
- No MAC in the neighbour table has a WiZ OUI (`a8:bb:50`, `d8:a0:11`, `44:4f:8e`, `6c:29:90`).
- So there are no MACs, moduleNames or fwVersions yet, and no answer on whether reads come back signed (`hmac` in replies, which is the 1.34+ signing feature). No writes were sent.
- Tooling check: `wiz.mjs` was tested against a local fake bulb. It handles `-32601` on `getModelConfig`, detects `hmac` on read replies, explains `-32602`, and refuses `set` without a matching `TEST_DEVICE`. The HMAC-SHA256 base64 output matches Python's `hmac` byte for byte on a test vector (`{"state":true,"sigTs":1790000000}`, key `00112233445566778899aabbccddeeff` → `oVfeexiMeoOHVfY6lr7GA4t1kPID+9ioR/s8JDyLv6k=`).

### Hue: no bridge reachable

- mDNS `_hue._tcp.local`: no Hue answer.
- `https://discovery.meethue.com/` returned `[]`, so no bridge has registered from this public IP. Either the bridge is on another internet connection or it is offline or has no cloud access.
- No host on the subnet answers HTTP/HTTPS (only the gateway does), and no MAC has a Signify OUI (`00:17:88`, `ec:b5:fa`).
- So the bridge model, firmware and certificate issuer are still unknown. `hue.mjs cert` was tested against the gateway's self-signed certificate (correctly classified as self-signed / TOFU).
- **Signify Hue root CA**, fetched by `hue.mjs cert` from Hue-Sync's `signify.pem`: subject `C=NL, O=Philips Hue, CN=root-bridge`, SHA-256 `F0:BD:8E:65:09:E8:2F:77:4D:63:BC:00:9D:53:88:C9:69:FE:3D:CF:7D:6D:54:1D:63:51:B7:2B:89:8D:8A:CF`. This matches research_hue.md §1.5. T1.1 should pin this fingerprint when bundling `hue-roots.pem`.

### AiDot: discovery ran, login not possible yet

- `aidot.mjs discover` (UDP 6666, AES-256-ECB with the fixed key, sent before login with `srcAddr "0.0"`) found **0** devices.
- `aidot.mjs verify-key`: the RSA public key embedded in the probe is identical to upstream `login_const.py` (RSA 1024). The PKCS#1 v1.5 ciphertext is 128 bytes and its base64 is 172 characters, as with python-aidot.
- Wire format check: `pyDumps` (our port of Python `json.dumps` with its default `", "` / `": "` separators and `ensure_ascii`) gives the same string as Python 3.12 for a sample message. TCP framing, login, `getDevAttrReq` and `ascNumber` handling were tested against a local fake device.
- Cloud login, device list, model ids and device firmware need the user's credentials (see `docs/OPEN-QUESTIONS.md`).

### Takeaway

From this PC we can't see any of the three brands' lights. Most likely they are on another network or location, powered off at the switch, or on an SSID that isolates clients from wired LAN hosts. Everything that needs the real devices is listed in `docs/OPEN-QUESTIONS.md`. Once the devices are reachable, re-run:

```sh
cd tools/probe
node wiz.mjs discover && node wiz.mjs info <ip>          # per bulb
node hue.mjs discover [ip] && node hue.mjs cert <ip>
node aidot.mjs login && node aidot.mjs devices && node aidot.mjs discover && node aidot.mjs state <devId>
```

### Template for the next run (fill per device)

| Brand | Stable id | IP | Model / moduleName | Firmware | Notes (signing, cert issuer, capabilities) |
|---|---|---|---|---|---|
| WiZ | MAC | | `getSystemConfig.moduleName` | `fwVersion` | `hmac` on reads? `-32602` on test `set`? `cctRange` |
| Hue | bridgeid | | `modelid` (BSB002 / BSB003) | `swversion` / `apiversion` | cert issuer: self-signed vs `root-bridge` |
| AiDot | devId | | `modelId` | `firmwareVersion` | `simpleVersion` present? TCP login ok? |

## Hue Entertainment (T3.8): to verify on a real bridge

Implemented from research_hue.md §2 and HueEntertainmentKit; checked only against a Network.framework DTLS-PSK loopback server in macOS CI. Open points (research_hue.md marks the cipher detail UNVERIFIED):
- Does Apple's DTLS 1.2 stack (`NWDTLSConnector`, cipher 0x00A8 appended) complete the handshake with Bridge v2 / Bridge Pro? Expected yes (HueEntertainmentKit does the same).
- Does the bridge accept the PSK identity as the application key exactly as returned by pairing (case preserved)?
- How long the bridge keeps an area streaming without datagrams (research: "a few seconds"); the session sends every 20-40 ms, so this only matters if the app is suspended.
- Whether `status` turns `active` immediately after `{"action":"start"}` and what `active_streamer.rtype` is for our key (`auth_v1` assumed).

How to check: pair, create an Entertainment area in the Hue app, run a session with two channels alternating red/blue at 1 Hz for 30 s, then confirm the lights restore after `stop()`. Record bridge model, `swversion` and the outcome here.

## 2026-10-27 - Network fixed; first real-device sightings

- Root cause of the earlier empty probes: the Kinetic FAST 5380 gateway had the 2.4 GHz SSID renamed to `KINETIC_FD5DE0_2.4` when bands were split; bulbs were provisioned on `KINETIC_FD5DE0`. Fixed via the gateway admin UI: both 2.4 GHz and 5 GHz now broadcast `KINETIC_FD5DE0` (WPA2, same password). Client isolation is off on both bands. Note: the Apply button on this gateway shows a "Wi-Fi Settings ... Continue" popup that must be confirmed.
- Gateway 2.4 GHz client list after the fix: 3x AiDot bulbs, 2x `GE_Light_*` and 1x `GE_DIMMER_*` (GE Cync: Wi-Fi, cloud/Matter only per BRAND-RUNDOWN), a Samsung device. 5 GHz: iPhone and the Tuya-looking device `fc:3c:d7:ef:a5:ca` (192.168.254.38, TCP 6668 open).
- **AiDot LAN discovery confirmed on real hardware** (`node aidot.mjs discover`, unauthenticated `devDiscoveryReq`): 
  - 192.168.254.57 devId cfcce60e251346b799f01817860914e7 mac 64:e8:33:bb:80:10 model `LK.light.A001577` lanMode=1
  - 192.168.254.75 devId b9aedd2ec40b4edd9dea95e87bcb70f0 mac 88:56:a6:14:15:14 model `LK.light.A000183` lanMode=1
  - 192.168.254.74 devId 76a6e7c739bf47b0b3beaf5cedeb8664 mac 64:e8:33:b5:27:30 model `LK.light.A001577` lanMode=1
  Model `LK.light.A001577` is not in the python-aidot notes (A001493/A001497 were); treat capability detection via the products endpoint as required.
- WiZ: no bulbs answered broadcast or unicast sweep after the SSID fix (3 attempts over ~8 min). Either powered off at the wall or provisioned on a different SSID/password; needs user check.
- Hue bridge: not on mDNS, not registered at discovery.meethue.com; wired device, so check gateway DHCP leases / power.
