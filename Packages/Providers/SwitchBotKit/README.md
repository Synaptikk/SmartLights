# SwitchBotKit

SwitchBot lights through the official cloud API v1.1 ([OpenWonderLabs/SwitchBotAPI](https://github.com/OpenWonderLabs/SwitchBotAPI)
@ `dc9a6b0`): Color Bulb, Strip Light, Ceiling Light (T3.3 targets), plus the types documented with the same commands
(Strip Light 3, Ceiling Light Pro, Floor Lamp, RGBICWW Strip Light / Floor Lamp, RGBIC Neon (Wire) Rope Light, Permanent
Outdoor Lights, Candle Warmer Lamp). Background: `research/research_brands.md` (SwitchBot), `docs/ONBOARDING-WALKTHROUGHS.md` §16.

| Target | Contents | Platforms |
|---|---|---|
| `SwitchBotCodec` | HMAC-SHA256 signing, request builders, `{statusCode, message, body}` decoding and error codes, device list / status models, light type table, status → `LightState`, `LightCommand` → commands | Linux + Apple |
| `SwitchBotProvider` | `SwitchBotProvider` actor (`LightProvider`), URLSession transport, daily budget | Linux + Apple |

## Flow

1. **Pairing.** `pair(_:using:)` asks for the **token** and the **secret** (`secureText`, whitespace trimmed). In the SwitchBot
   app: Profile > Preferences > About > tap *App Version* 10 times > Developer Options (secret needs app 6.14+). They are verified
   with `GET /v1.1/devices` and stored in `SecretStore` under `SecretKey(brand: .switchbot, owner: "switchbot-<sha256(token)[0..<6]>",
   item: "token"|"secret")`. The account id is derived from a hash, so it never reveals the token.
2. **Signing.** Every request carries `Authorization: <token>`, `t` (13-digit ms), `nonce` (UUID) and
   `sign = base64(HMAC-SHA256(key: secret, token + t + nonce))`.
3. **Devices.** `GET /v1.1/devices` → `body.deviceList`; only light types from `SwitchBotLightKind.table` become lights
   (stable id = `deviceId`). The list is cached (item `deviceCache`) and refreshed hourly. Lights with
   `enableCloudService: false` are shown unreachable and commands explain how to turn Cloud Services on. BLE lights need a hub
   (`hubDeviceId` ≠ `000000000000`).
4. **State.** `GET /v1.1/devices/{id}/status` → `power` (on/off, any case), `brightness` 1–100, `color` `"r:g:b"`,
   `colorTemperature` 2700–6500 K. `loadLights()` reuses a status younger than 30 s. `start()` polls every 5 min.
5. **Commands.** `POST /v1.1/devices/{id}/commands` with `{"command", "parameter", "commandType": "command"}`, one call per
   attribute, in order: `turnOn` (when the light is off or `on: true`), `setColor "r:g:b"` or `setColorTemperature <K>`,
   `setBrightness <1-100>`. Off or brightness 0 is a single `turnOff`. Colours are converted to what the lamp has
   (hs/xy → rgb, rgb → Kelvin on white-only lamps). Effects are not supported.
6. **Errors.** HTTP 401 / `{"message":"Unauthorized"}` → `needsReauthentication` unless a call succeeded in the last 24 h (then it
   is most likely the account-wide daily limit, reported as an `error` event). `161`/`171` (device/hub offline) mark the light
   unreachable. `151/152/160/190` surface as `SwitchBotError.api`.

## Request budget (10,000/day)

SwitchBot allows 10,000 calls per account per day. The provider spends a LightCore `RateLimiter` token bucket
(capacity 10,000, refill 10,000 per 24 h) before every call, plus a 5/s burst limiter. Polling stops while fewer than 2,000
requests remain, so user commands keep working. Defaults: 10 lights polled every 5 min ≈ 2,880 calls/day. The bucket is
in memory (a relaunch starts full) and other API clients on the same account (Home Assistant, scripts) are not counted;
`remainingBudget()` exposes the local count for Diagnostics.

## Not implemented / unverified

- Webhooks (would replace polling; need a public HTTPS endpoint) and BLE control (pySwitchbot GATT) are out of scope.
- `RGBICWW Ceiling Light` uses separate main/colour light commands and is not listed.
- The active colour mode is not reported: the provider keeps the mode of the last command, otherwise a white `255:255:255`
  colour on a lamp with both modes means colour-temperature mode.
- The docs say to upper-case the signature; their own Python/JS samples and Home Assistant's `switchbot_api` send plain
  base64, which is what we send (see `docs/HARDWARE-NOTES.md`).
- Whether `setBrightness` turns a light on by itself: we send `turnOn` first when the light is off.
- No SwitchBot hardware was available; behaviour is checked against the docs and a fake cloud only.

## Tests

```
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/SwitchBotKit swift:6.1 swift test
```

- `SwitchBotCodecTests`: fixtures in `Tests/SwitchBotCodecTests/Fixtures/switchbot_fixtures.json` from `gen_fixtures.py`
  (signatures computed with the README's Python 3 sample; replies shaped like the README and `devices/lighting/*.md`):
  signing, request paths/bodies, envelope and error decoding, status parsing, type table, state and command mapping.
- `SwitchBotProviderTests`: the provider against an in-package `FakeSwitchBotCloud` that verifies every signature and keeps
  device state: pairing, bad credentials, statuses, commands, offline devices, Cloud Services off, local budget, polling
  reserve, polling events, token rotation → re-auth, daily-limit 401, discovery, sign-out.

## Attribution

API behaviour from the SwitchBotAPI documentation (OpenWonderLabs; the repository declares no license, checked 2026-10-27).
No code was copied.
