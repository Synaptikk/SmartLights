# Hardware notes

Observations from real hardware (probe scripts in `tools/probe/`, raw output in `tools/probe/out/`, gitignored). Where real hardware contradicts `research/*.md`, this file wins. Newest entries first.

---

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
