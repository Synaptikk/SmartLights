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
