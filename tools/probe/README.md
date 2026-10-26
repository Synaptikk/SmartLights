# Hardware probes (Node)

Small Node 22+ scripts (built-ins only, no `npm install`) that check our protocol assumptions against the real WiZ bulbs, Hue bridge and AiDot bulbs before the Swift providers are written. Results go to `docs/HARDWARE-NOTES.md`.

## Safety rules

- Everything is **read-only by default**.
- Every write (`set`) is refused unless env `TEST_DEVICE` names the exact target:
  - WiZ: bulb IP or MAC (`a8bb50…` or `a8:bb:50:…`)
  - Hue: the CLIP v2 light id (uuid)
  - AiDot: the devId or MAC
- Secrets (Hue app key/clientkey, AiDot tokens, device aesKey/password) are written only to `out/` (gitignored, mode 0600 where the OS supports it) and are never printed. The AiDot password is not stored at all.
- Raw replies are appended to `out/*.log.jsonl` for later analysis.

Run from this folder (`cd tools/probe`). PowerShell: set env vars with `$env:TEST_DEVICE = "192.168.1.50"`; Git Bash: `TEST_DEVICE=192.168.1.50 node …`.

## WiZ (`wiz.mjs`, UDP 38899)

```sh
node wiz.mjs discover              # broadcast registration(register:false) + getPilot on every interface, 5 s
node wiz.mjs sweep [192.168.1]     # unicast getPilot to x.1-254 (the iOS no-entitlement path)
node wiz.mjs info  <ip>            # getSystemConfig, getModelConfig, getUserConfig, getPilot (-32601 tolerated)
node wiz.mjs state <ip>            # getPilot
TEST_DEVICE=<ip|mac> node wiz.mjs set <ip> '{"state":true,"dimming":40}'
TEST_DEVICE=<ip|mac> WIZ_SIGNING_KEY=<32 hex> node wiz.mjs set <ip> '{"state":false}'
```

`info` reports whether read replies carry a top-level `hmac`, which means the firmware has the 1.34+ signing feature. Read replies can't show whether writes will be rejected; only a `set` to the test bulb can. `-32602` + `sigTs` means signing is required, and `-32605` means the signature was wrong or stale. With `WIZ_SIGNING_KEY` set, `set` adds `sigTs` (unix seconds) to `params` and a top-level `hmac` = base64(HMAC-SHA256(key16, compact JSON of params)).

## Hue (`hue.mjs`, HTTPS 443)

```sh
node hue.mjs discover [ip]         # mDNS _hue._tcp + discovery.meethue.com + manual IP -> GET /api/config
node hue.mjs cert <ip>             # TLS chain, fingerprints, verifies against the Signify root (fetched once to out/)
node hue.mjs pair <ip>             # PRESS THE LINK BUTTON, then run within ~30 s; stores out/hue.json
node hue.mjs list <ip>             # lights, devices, rooms, scenes, grouped_light, zones -> out/hue-list.json
node hue.mjs events <ip> [60]      # tail /eventstream/clip/v2; toggle a light in the Hue app meanwhile
TEST_DEVICE=<light uuid> node hue.mjs set <ip> <light uuid> '{"on":{"on":false}}'
```

## AiDot / Linkind (`aidot.mjs`)

Port of `python-aidot` 0.3.59 (MIT): RSA PKCS#1 v1.5 password, `prod-<region>-api.arnoo.com/v35`, UDP 6666 discovery (AES-256-ECB, fixed key), TCP 10000 frames (`0x1EED`, msgtype, u32 len, AES-128-ECB with `aesKey[0]`). JSON bodies on the wire use Python's `json.dumps` spacing.

```sh
node aidot.mjs verify-key          # embedded RSA key == upstream login_const.py?
AIDOT_COUNTRY=US AIDOT_USER=you@example.com node aidot.mjs login   # password prompted (hidden) or AIDOT_PASS
node aidot.mjs devices             # houses -> devices -> products; console redacted, full record in out/aidot.json
node aidot.mjs discover [secs]     # UDP 6666 broadcast
node aidot.mjs state <devId> [ip]  # TCP loginReq + getDevAttrReq
TEST_DEVICE=<devId> node aidot.mjs set <devId> '{"OnOff":1,"Dimming":50}' [ip]
```

Caveats: logging in again with the same account may invalidate the AiDot app's token. Use the owner account (shared-home members are rejected by the bulb's TCP login). Attr keys are `OnOff` 0/1, `Dimming` 0-100, `CCT` kelvin, and `RGBW` as a signed int32 of `(r<<24)|(g<<16)|(b<<8)|w`.

## Outputs (`out/`, gitignored)

`wiz-discover.json`, `wiz-sweep.json`, `wiz-info.json`, `hue-discover.json`, `hue-cert.json`, `hue.json` (secret), `hue-list.json`, `signify-root.json`, `aidot.json` (secret), `aidot-discover.json`, `*.log.jsonl`.
