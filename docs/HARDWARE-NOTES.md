# Hardware notes

Observations from real hardware (probe scripts in `tools/probe/`, raw output in `tools/probe/out/`, gitignored). Where real hardware contradicts `research/*.md`, this file wins. Newest entries first.

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
