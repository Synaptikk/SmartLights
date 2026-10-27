# TwinklyKit

Twinkly LED strings and strips over the unofficial local **xled** REST API (plain HTTP on port 80) with UDP 5555 discovery. Local only, no Twinkly account. Task T3.4. Protocol reference: https://xled-docs.readthedocs.io (source: scrool/xled-docs, MIT; see `NOTICES.md`). The vendor says this API "hasn't been made public yet, so it may change at any time".

| Product | Builds on | Contains |
|---|---|---|
| `TwinklyCodec` | Linux + Apple (Foundation + LightCore) | Discovery datagrams, login/verify models, gestalt/firmware/mode/color/brightness/effects models, application-code errors, MAC ids, state and capability mapping, the command planner |
| `TwinklyProvider` | Linux + Apple; real transport Apple only | `actor TwinklyProvider: LightProvider` over a `TwinklyTransport`; `URLSessionTwinklyTransport` (URLSession + NetKit `UDPSocket`) behind `#if canImport(Darwin)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider tests against an in-package fake device over real loopback HTTP and UDP.

## Setup in the app

```swift
import TwinklyProvider
let twinkly = TwinklyProvider.live(secrets: KeychainSecretStore(accessGroup: group))
for device in pairedTwinklies { await twinkly.addDevice(device) }   // restore on launch
let lights = try await twinkly.loadLights()                          // also starts polling
```

Call `stopPolling()` when the app goes to the background and `startPolling()` when it returns. `updateHost(deviceID:host:)` records a new IP; discovery also updates it. Info.plist needs `NSLocalNetworkUsageDescription`; broadcast discovery needs the multicast entitlement.

Ids:
- light: `twinkly:<mac>`, lower-case hex without separators, taken from `/gestalt` `mac`. Gen II reports its access-point-mode MAC, which is still unique and stable.
- `providerRef`: `<mac>`.

## Discovery

`discover(options:)` runs these in parallel until `options.timeout`, deduplicating by MAC:

- **Broadcast** (`broadcastAvailable` + `.broadcast`): sends `0x01 "discover"` to UDP 5555 at the directed and limited broadcast addresses. A reply is `<IPv4 reversed> "OK" <device id> 0x00`.
- **Unicast sweep** (`.sweep`, only when broadcast is unavailable): sends the same datagram from one socket to every host of the Wi-Fi /24. Unicast needs no entitlement.
- **Manual and cached hosts**: `ip`, `ip:port`, `http://ip/`.

Every candidate is confirmed with `GET /xled/v1/gestalt` (no token needed) and `GET /xled/v1/fw/version`. Metadata: `hw_id`, `fw_family`, `led_profile`, `number_of_led`, `uuid`, `firmware`, `discovery_id`. Hosts that are not Twinkly are dropped.

## Pairing and tokens

The device needs no button press. `pair` checks the MAC behind the host (if the discovered id was a MAC, it must match), then:

1. `POST /xled/v1/login {"challenge": <32 random bytes, base64>}` returns `authentication_token`, `authentication_token_expires_in` and `challenge-response`.
2. `POST /xled/v1/verify {"challenge-response": ...}` with `X-Auth-Token: <token>`. **A successful verify invalidates the previous token**: logging in from another controller (the Twinkly app, Home Assistant) knocks us out, and the reverse is also true.
3. The token is stored in `SecretStore` under `SecretKey(brand: .twinkly, owner: <mac>, item: "token")` as `{value, expiresAt}`, so app extensions can reuse it. It is never logged (`Log.redact`).

Refresh:
- the provider logs in again 60 s before `expiresAt` (default lifetime 14400 s);
- on any 401 it logs in **once** and retries the call;
- a second 401 throws `LightCoreError.authenticationRequired(.twinkly)`.

## Control

Requests to one device are serialised (the ESP controllers handle one connection at a time). `send` normalises the command (`LightCommand.normalized(for:)`) and plans:

| Command | Requests |
|---|---|
| off (`on: false`, or `brightness: 0` without `on`) | `POST /led/mode {"mode":"off"}` |
| colour (HS; RGB, xy and Kelvin are converted) | `POST /led/color {"hue","saturation","value":255}`, then `mode color` if not already in it |
| effect `movie` | `mode movie` (the effect uploaded in the Twinkly app) |
| effect `effect:<n>` | `POST /led/effects/current {"effect_id":n}`, `mode effect` + `effect_id` |
| brightness | `POST /led/out/brightness {"mode":"enabled","type":"A","value":1...100}`, sent **before** the mode switch |
| bare `on` while off | restores the last "on" mode (`movie` by default) |

Capabilities:
- `[.hs]` when `/led/color` exists (firmware 2.7.1 or later);
- otherwise `[.brightness]` (firmware 2.3.5 or later);
- otherwise `[.onOff]`.

Effects are `movie` plus `effect:0..n-1` from `/led/effects`. All are `isFast`, because Twinkly doesn't report animation speed and the UI must warn about photosensitivity.

## State

There is no push on the LAN. `loadLights()` reads `/led/mode`, `/led/out/brightness`, `/led/color` (colour mode only) and `/led/effects/current` (effect mode only). A poll loop (`Configuration.pollInterval`, default 30 s) emits `stateChanged` when something changed elsewhere. Transport failures emit `reachabilityChanged`.

| Device says | Thrown to callers |
|---|---|
| 401 twice in a row | `.authenticationRequired(.twinkly)` |
| 404 `Resource not found.` | `.unsupported` (endpoint missing on this firmware) |
| HTTP 200 with `code != 1000` | `.protocolError("Twinkly error 1101 (invalid argument value)")` |
| connection refused / timeout | `.unreachable` / `.timeout` |

## Tests

```
docker run --rm -v "<repo>:/src" -w /src/Packages/Providers/TwinklyKit swift:6.1 swift test
```

- `TwinklyCodecTests` covers datagrams, models (gestalt and login fixtures from xled-docs), firmware gates, mapping and the planner.
- `TwinklyProviderTests` runs against `FakeTwinkly`, an in-package HTTP + UDP fake over loopback, on Linux and macOS. It covers:
  - sweep, broadcast and manual discovery;
  - pairing and token storage;
  - colour, brightness, effect and off;
  - re-login after another controller took the token;
  - proactive renewal before expiry;
  - token reuse across provider instances;
  - old firmware;
  - polling;
  - unreachable devices.
- On macOS, `URLSessionTwinklyTransportTests` runs the real URLSession/UDPSocket transport against the same fake.

`Tests/TwinklyProviderTests/Loopback.swift` (POSIX HTTP/WebSocket/UDP test networking) is shared verbatim with DirigeraKit.

Open items to check on hardware are listed in `docs/HARDWARE-NOTES.md`.
