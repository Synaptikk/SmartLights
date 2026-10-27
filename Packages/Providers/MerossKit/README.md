# MerossKit

Meross Wi-Fi lights: MSL120 / MSL320 / MSL430 / MSL450 bulbs and strips, MSL100 white bulbs, and the
MSS560/565/570 dimmer switches (anything whose `Appliance.System.Ability` lists `Appliance.Control.Light`).
Protocol ported from [`albertogeniola/MerossIot`](https://github.com/albertogeniola/MerossIot) @ `4fc8193` and
[`krahabb/meross_lan`](https://github.com/krahabb/meross_lan) @ `bafedb4` (both MIT). Background:
`research/research_brands.md` (Meross), `docs/ONBOARDING-WALKTHROUGHS.md` §15.

| Target | Contents | Platforms |
|---|---|---|
| `MerossCodec` | `MerossJSON`, local message building/signing/parsing (`MerossRequest`, `MerossResponse`), cloud sign-in/devList request signing and decoding (`MerossCloudAPI`), `Appliance.Encrypt.ECDHE` AES-CBC body cipher, HTTP/1.1 framing, light capacity bits, ability → capabilities, state parsing, `LightCommand` → requests (`MerossCommandPlanner`) | Linux + Apple |
| `MerossProvider` | `MerossProvider` actor (`LightProvider`), transports | Apple (URLSession + NWConnection); Linux (URLSession), used by the tests |

## Flow

1. **Sign-in (cloud, once).** `pair(_:using:)` asks how to connect (`choose`): Meross account, or key + IP (advanced).
   The account path asks for the region (`choose`: Americas / Europe / Asia-Pacific), e-mail (`text`) and password
   (`secureText`), and the two-factor code if Meross answers `1033`. It posts to `https://iotx-{us,eu,ap}.meross.com/v1/Auth/signIn`
   the signed envelope `{"params": base64(json), "sign": md5("23x17ahWarFH6w29" + timestamp + nonce + params), "timestamp": ms,
   "nonce"}` with `password = md5(password)`, `encryption: 1`. A `1030` answer redirects once to the account's home domain.
   `key`, `token` and `userid` go to `SecretStore` under `SecretKey(brand: .meross, owner: <e-mail>, item: "key"|"token"|"userId")`.
   **The password is never stored.** Sign-ins are limited to 3 per hour (`signInLimit`) because Meross locks accounts that
   log in too often; nothing retries a sign-in automatically.
2. **Device list (cloud).** `POST /v1/Device/devList` (`Authorization: Basic <token>`). Devices whose `deviceType` looks like a
   light (`msl*`, `mdl*`, `mss56*/57*`) are kept with a guessed profile until the device answers its ability. The list, IP hints
   and learned abilities are cached in `SecretStore` (item `deviceCache`) so LAN control works when the cloud is down or the
   token expired (`1019/1022/1200/1003/1301` → `needsReauthentication`, key kept).
3. **Locating devices (LAN).** Meross has no LAN broadcast discovery; meross_lan relies on Home Assistant's DHCP watcher
   (OUIs `48:E1:E9`, `C4:E7:AE`, `34:29:8F:1`), which iOS cannot observe. The provider instead probes, with a signed
   `GET Appliance.System.All`: manual hosts, cached IPs, then a `/24` sweep of the current Wi-Fi (`SubnetSweeper`, 32 in flight,
   1.5 s per host). The reply's `header.from` (`/appliance/<uuid>/publish`) maps the IP to the device. Hosts that answer
   something else get a clear-text `GET Appliance.System.Ability` (encrypted firmware only answers that one in clear).
   Devices are keyed by uuid; IPs are hints.
4. **Control (LAN).** `POST http://<ip>/config` with `{"header": {messageId, namespace, method, payloadVersion: 1, triggerSrc,
   from, timestamp, timestampMs, sign = md5(messageId + key + timestamp)}, "payload": ...}`. Requests per device are paced
   (4/s). Every reply's uuid is checked; if another device answers on the cached IP the IP is dropped and discovery runs again.
   - `Appliance.System.Ability` once per device → capacity bits (`rgb 1`, `temperature 2`, `luminance 4`, `effect 8`),
     ToggleX/Toggle presence, `Appliance.Encrypt.ECDHE`.
   - `Appliance.System.All` → `digest.togglex[0].onoff` (or `control.toggle` / `light.onoff`), `digest.light`.
   - Off: `Appliance.Control.ToggleX` `{"togglex": {"channel": 0, "onoff": 0}}` (else legacy Toggle, else `light.onoff`).
   - Colour/brightness: one `Appliance.Control.Light` SET `{"light": {"channel": 0, "capacity": 5|6|4, "rgb"|"temperature",
     "luminance", "gradual": 0}}`, then a ToggleX on if the light was off (msl120j ignores `onoff` inside the light payload).
   - Scales (meross_lan `light.py`): luminance 1–100 = brightness %, temperature 1–100 = 2700–6500 K (Python rounding),
     rgb = `(r << 16) | (g << 8) | b`.
5. **Encrypted firmware.** Devices listing `Appliance.Encrypt.ECDHE` get AES-256-CBC bodies: key =
   `md5(uuid[3:22] + key[1:9] + mac + key[10:28])` as 32 ASCII hex bytes, IV `"0000000000000000"`, zero padding, base64,
   `Content-Type: application/octet-stream`. The MAC comes from `System.All` or the last 12 hex digits of the uuid.
6. **State.** `start()` polls `Appliance.System.All` every 30 s (Meross pushes only over MQTT, not used) and re-locates lights
   that went missing (a full sweep at most every 10 min). `stop()` ends polling.
7. **Manual key + IP.** The advanced path asks for the key (`secureText`) and the IP (`text`), checks the device answers with
   that key and stores it under the `manual` account. The key is the account key from the Meross cloud (meross_lan can show
   it); devices on very old firmware accept an empty key.

## Transport

The Apple LAN transport writes HTTP/1.1 itself over `NWConnection` (`MerossHTTP1`), so plain HTTP to LAN IPs does not depend on
an App Transport Security exception. It needs the Local Network permission only. The cloud uses URLSession (HTTPS).

## Unverified items (no Meross hardware yet)

- Everything is checked against meross_lan's formulas and emulator traces, not real devices.
- Whether every firmware accepts `from: "MerossClient"` (meross_lan's value) over HTTP.
- The model-type guess before the ability is known (`msl100` = dimmable white, other `msl*` = RGB + CCT).
- Encrypted (`ECDHE`) devices: the clear-text ability probe follows meross_lan's config flow; untested here.
- Effects (`capacity` bit 8, `Appliance.Control.Light.Effect`) are not implemented; `supportsEffects` is false.
- Multi-channel devices: only channel 0 is controlled.
- Local MQTT and the Meross cloud MQTT broker are not used (no pushes; polling instead).

## Tests

```
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/MerossKit swift:6.1 swift test
```

- `MerossCodecTests`: vectors in `Tests/MerossCodecTests/Fixtures/meross_fixtures.json`, generated by `gen_fixtures.py`, which
  runs meross_lan's own `compute_message_signature`, `compute_encryption_key`, cloud sign and AES-CBC code (Python
  `cryptography`). Device payloads come from meross_lan's emulator traces (msl320, msl450). Also NIST SP 800-38A CBC-AES256,
  HTTP/1.1 parsing (Content-Length, chunked, close-delimited), capacity/state mapping and the command planner.
- `MerossProviderTests`: the provider against in-package fakes (`FakeMerossCloud`, `FakeMerossLAN`) that verify signatures:
  sign-in (secrets, md5 password, region redirect, 2FA, wrong password, sign-in rate limit), sweep discovery, commands,
  invalid key → re-auth, Keychain-cache restore without cloud, expired token, IP change detection + rediscovery, encrypted
  devices, manual key + IP, polling events, sign-out.

## Attribution

Protocol constants, field names, the cloud signing salt and the light scales come from MerossIot (MIT, Copyright (c) 2018
Alberto Geniola) and meross_lan (MIT, Copyright (c) 2020 Joakim Sørensen @ludeeus, krahabb). The code here is a
reimplementation; `gen_fixtures.py` contains short verbatim excerpts of meross_lan to produce the test vectors.
