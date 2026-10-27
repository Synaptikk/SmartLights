# AiDotKit

AiDot / Linkind (and other "Works with AiDot" brands: OREiN, Mujoy, ...) **Wi-Fi** lights.
It is a Swift port of the vendor-published [`python-aidot`](https://github.com/AiDot-Development-Team/python-AiDot)
0.3.59 (MIT, AiDot-Development-Team). Background: `research/research_aidot.md` §2 and §8.

| Target | Contents | Platforms |
|---|---|---|
| `AiDotCodec` | Ordered JSON with Python `json.dumps` formatting, AES-ECB/PKCS7, RSA PKCS#1 v1.5 login, country→region map, cloud request builders/models/error codes, discovery datagram, TCP frames, `loginReq`/`setDevAttrReq`/`getDevAttrReq`/`pingreq`, `ascNumber`/seq counters, attr ↔ `LightState`/`LightCommand`, capability inference | Linux + Apple |
| `AiDotKit` | `AiDotProvider` actor (`LightProvider`), per-device TCP session, transports | Apple (NWConnection + NetKit); Linux via a POSIX fallback used by the tests |

## Flow

1. **Sign-in (cloud, once).** `pair(_:using:)` asks for Country (`choose`), e-mail (`text`) and password (`secureText`).
   The password is RSA-encrypted (PKCS#1 v1.5, hardcoded 1024-bit key from `login_const.py`) and sent to
   `POST https://prod-{us|eu|jp}-api.arnoo.com/v35/users/loginWithFreeVerification` with headers `Appid`, `Terminal: app`.
   The response's `id` (userId), `accessToken` and `refreshToken` go to `SecretStore` under
   `SecretKey(brand: .aidot, owner: <username>, item: "userId"|"accessToken"|"refreshToken")`. **The password is never stored.**
   `terminalId` is md5 of a random per-install id (item `terminalId`).
2. **Device list (cloud).** `GET /houses` (houses with `isOwner == false` are skipped) → `GET /devices?houseId=` →
   `GET /products/<ids>`. Only `type == "light"` records with `aesKey[0]` become lights. The list (with the per-device
   `aesKey` and `password`) is cached in `SecretStore` (item `deviceCache`) and refreshed when older than 6 h, so LAN control
   keeps working when the cloud is down or the sign-in expired.
3. **Discovery (LAN, UDP 6666).** AES-256-ECB (key `T54uednca587` zero-padded to 32 bytes) `devDiscoveryReq`. Broadcast to
   `255.255.255.255` and the directed broadcast if `broadcastAvailable` (multicast entitlement); otherwise unicast to cached
   IPs, the cloud `properties.ipAddress`, manual hosts, and a `/24` `SubnetSweeper` probe. Replies update the IP hint of the
   matching session. Lights known to the account but silent on the LAN are reported with method `.cloud`.
4. **Control (LAN, TCP 10000).** One persistent session per device: 8-byte header (`0x1EED`, msgtype 1 action / 2 ping, u32 length)
   + AES-128-ECB/PKCS7 body with `aesKey[0]`. `loginReq` (userId + device password) → `ack.code == 200` → `getDevAttrReq` →
   `pingreq` every 30 s (`getDevAttrReq` every 10 s for `lk.WIFI-RGBWLight-D0006`). 3 unanswered keepalives or a read error reset
   the session (light reported unreachable) and it reconnects with exponential backoff (1 s → 60 s, jitter).
   `send` builds **one** `setDevAttrReq` with all changed attributes (`OnOff`, `Dimming` 0-100, `CCT` K, `RGBW` signed int32
   `(r<<24)|(g<<16)|(b<<8)|w`); status pushes (`payload.attr`) become `ProviderEvent.stateChanged`.
5. **Tokens.** A `21026` answer triggers one `POST /users/refreshToken` and a retry. If the refresh fails (`21025`) or the cloud answers
   `21025`/`21027`/`21041`, the access token is dropped and `ProviderEvent.needsReauthentication(accountID:)` is emitted.
   LAN sessions are unaffected.
6. **Lifecycle.** `start()` (foreground) opens the sessions and a maintenance task (re-discovery for offline lights every 120 s,
   device list refresh after 6 h); `stop()` (background) closes everything. `loadLights()` opens sessions unless stopped.

## Requirements and caveats

- **Owner account only.** Devices accept a LAN `loginReq` only with the userId of the account that owns the home. Houses
  shared with you are skipped. Sign in with the owner's account.
- **A second sign-in can invalidate the first token.** Signing in to the same account elsewhere (another app instance, HA,
  sometimes the AiDot app) may make our token fail with `21025`, so the app asks to sign in again. Use a dedicated account
  (then the devices must be in a house it owns) or accept occasional re-auth. LAN control keeps working meanwhile.
- **Local ports:** UDP 6666 (discovery), TCP 10000 (control). The app needs Local Network permission; broadcast needs the
  multicast entitlement (`com.apple.developer.networking.multicast`). Without it discovery falls back to unicast/sweep.
- **Effects / scenes need the cloud** (`POST /devices/execute/diffCommand` with `runLScript`, plus the effect lists).
  Not implemented: `LightCapabilities.supportsEffects` is false and commands with only an effect throw `.unsupported`.
- Not supported: BLE / BLE-mesh lights (SL5/SL5C, B1 hub), cameras, plugs. Matter SKUs should go through Apple Home.

## Unverified items

- The active colour mode when a full status reports both `CCT` and `RGBW`: the previous mode is kept; python-aidot has no
  notion of an active mode either.
- Discovery before sign-in sends `srcAddr: "0.0"` (python would send `0.None`); devices are reported to answer anyway.
- `aesKey[0]` longer than 16 bytes and not 24/32: Python would raise; we truncate to 16.
- Reply method names (`loginResp`, `devAttrNotify`) are not relied upon; only `ack.code` and `payload.attr`/`ascNumber` are used.
- Whether bulbs accept `Dimming: 0`. We send `OnOff: 0` for brightness 0 and clamp other values to 1...100.
- RGBW `0` is read as "default red" (255, 0, 0, 0), as python-aidot does.
- Everything Apple-specific (NWConnection, NetKit UDP) is compiled first on macOS CI, and the protocol is unconfirmed on real bulbs.

## Tests

```
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/AiDotKit swift:6.1 swift test
```

- `AiDotCodecTests`: fixtures in `Tests/AiDotCodecTests/Fixtures/aidot_fixtures.json` come from the real python-aidot
  0.3.59 (`gen_fixtures.py`, run in `python:3.12`): discovery datagram ciphertext, login/set/get/ping frames byte-for-byte,
  key padding, status push decoding, RGBW packing, region map, error codes. RSA uses random padding, so it is checked by length
  (128 bytes, 172 base64 chars) and a round-trip through a generated 1024-bit key pair. AES is checked against FIPS-197 vectors.
- `AiDotKitTests`: the provider against `FakeAiDotCloud` and `FakeAiDotDevice` from `Packages/Simulators` (sign-in, secrets,
  shared-house filter, TCP control, pushes, reconnect, pings, stop/start, unicast discovery, token refresh/reauth,
  restoring from the Keychain cache without the cloud), plus a scripted silent device for the missed-ping reset.

## Attribution

Protocol constants, field names and the RSA public key come from python-aidot (MIT License,
Copyright (c) AiDot-Development-Team). The code here is a reimplementation, not a copy.
