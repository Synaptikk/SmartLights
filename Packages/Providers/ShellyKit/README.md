# ShellyKit

Shelly lights over the **local API**: Gen1 REST and Gen2+ (Plus, Pro, Gen3, Gen4) JSON-RPC, with the
optional device password. Task T2.5 (T2.5b, together with MagicHomeKit).

| Product | Builds on | Contains |
|---|---|---|
| `ShellyCodec` | Linux + Apple (Foundation + LightCore + swift-crypto) | JSON value + parser, `/shelly` device info, RPC frames and notifications, HTTP Digest (RFC 7616, SHA-256/MD5) and the RPC `auth` object, Gen1 query strings, channel discovery, status <-> `LightState`/`LightCommand` mapping |
| `ShellyProvider` | Linux + Apple; Bonjour/WebSocket Apple only | `actor ShellyProvider: LightProvider` over `ShellyNetworkEnvironment`; `URLSessionShellyTransport` (Apple + Linux); Bonjour and `URLSessionWebSocketTask` behind `#if canImport(Darwin)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider tests
against in-process fake devices.

Sources: the aioshelly library and Home Assistant's `shelly` integration (both Apache-2.0) for field
names and the RPC auth formula; RFC 7616 for digest. The Shelly API docs site was not reachable from
the agent sandbox; items that come from secondary sources are listed under "Not verified yet".

## Codec

- **Device info** (`GET /shelly`, never needs auth): Gen1 `type`/`mac`/`auth`/`fw`; Gen2+ `id`/`mac`/
  `model`/`gen`/`app`/`ver`/`auth_en`/`auth_domain`. The MAC (12 lowercase hex) is the stable id.
- **RPC**: request `{"id","src","method","params"[,"auth"]}`; frames parse into result, error (401 =
  auth) or notification (`NotifyStatus` partial, `NotifyFullStatus`, `NotifyEvent`).
- **Digest**: `WWW-Authenticate: Digest qop="auth", realm=<device id>, nonce=..., algorithm=SHA-256`
  -> `Authorization: Digest username="admin", ..., nc=00000001, cnonce=...` (RFC 7616 `auth` qop,
  stale nonces refreshed). WebSocket frames carry
  `auth = {realm, username, nonce, cnonce, response, algorithm, nc}` with
  `response = H(H(admin:realm:pass):nonce:nc:cnonce:auth:H(dummy_method:dummy_uri))` (decimal `nc`).
  Gen1 uses HTTP Basic.
- **Channels**:
  - Gen2+: config/status keys `light:N` (brightness), `cct:N` (brightness + `ct`, `ct_range` from config),
    `rgb:N`, `rgbw:N` (+ `white`), `rgbcct:N` (`mode` `rgb`/`cct`); set with `Light.Set`, `CCT.Set`,
    `RGB.Set`, `RGBW.Set`, `RGBCCT.Set` (`id`, `on`, `brightness` 1-100, `rgb`, `white`, `ct`,
    `transition_duration` s >= 0.5).
  - Gen1: SHBDUO-1 Duo `/light/0` brightness + `temp` (2700-6500 K); SHVIN-1, SHDM-1/2 `/light/N`
    brightness; SHBLB-1/SHCB-1 bulbs `/light/0` colour mode (`red/green/blue/white` + `gain`) or white mode
    (`temp` 3000-6500 + `brightness`, `mode=` switches); SHRGBW2 colour mode `/color/0`, white mode
    `/white/0..3`. `transition` in ms (<= 5000).
- **Mapping**: brightness and colour in one request; `brightness 0` without `on` = off; RGB at full value
  with separate brightness.

## Provider

- **Identity**: `LightID` = `shelly:<mac>` for the first (primary) output, `shelly:<mac>-<kind><n>` for
  others (e.g. `shelly:e8db84aabbcc-white1`). Channels are stored in `PairedDevice.metadata["channels"]`
  so ids survive relaunch; IP and port are hints.
- **Discovery**: Bonjour `_shelly._tcp` and `_http._tcp` instances named `shelly*` (Gen1 advertises only
  `_http._tcp`); if Bonjour stays silent for `sweepDelay` (1.5 s) a unicast `GET /shelly` sweep of the
  Wi-Fi /24 (24 in flight, 800 ms); always cached hosts, known devices and manual hosts (`ip[:port]`).
- **Pairing**: asks for an IP when none is known. If `/shelly` reports a password: Gen2+ asks
  `PairingInteraction.secureText` (user `admin`), Gen1 asks the user name (`text`) and the password; a
  rejected password is asked again (3 tries, then `authenticationRequired`). Reads the outputs
  (Gen2+ `Shelly.GetConfig` + `Shelly.GetStatus`, Gen1 `/settings` + `/status`). The password goes to
  `SecretStore` (`com.sinap.smartlights.shelly`, `<mac>/password`) and is never logged.
- **Requests**: 3 s timeout, one retry for reads; digest challenge cached per device with an
  incrementing nonce count. A rejected stored password emits `.needsReauthentication(accountID: mac)`.
- **Events**: `start()` opens the Gen2+ `/rpc` WebSocket (sends `Shelly.GetStatus`, answering the 401
  challenge with the `auth` object) and merges `NotifyStatus` patches -> `.stateChanged`. Devices
  without a live socket (all Gen1, or when the socket fails) are polled every `pollInterval` (10 s);
  sockets are retried every round. `stop()` closes sockets and stops polling.

## App wiring

```swift
let shelly = ShellyProvider.live()          // URLSession + Bonjour + WebSocket + Keychain
await shelly.restore(storedShellyDevices)
await registry.register(shelly)
await shelly.start()
```

Info.plist already lists `_shelly._tcp` and `_http._tcp` in `NSBonjourServices`.

## Tests

- `ShellyCodecTests`: JSON parser (booleans stay booleans on Linux and Apple), device info for both
  generations, RFC 7616 MD5 and SHA-256 vectors, Shelly challenge parsing, the `/rpc` Authorization
  header and the RPC `auth` object (both cross-checked with Python `hashlib`), frames, Gen1 queries,
  channel discovery, state mapping and command plans.
- `ShellyProviderTests`: `FakeShellyDevice` (in the test target) is a Gen1 or Gen2+ device behind an
  in-memory HTTP transport; it verifies digest and the WebSocket `auth` object with its own swift-crypto
  code. Covers Bonjour filtering, sweep fallback, pairing with/without password (wrong password retry,
  give-up, Keychain storage), stale nonce refresh, one `RGBW.Set` per command, Gen1 Duo with Basic auth,
  RGBW2 white mode with four lights, WebSocket notifications with auth, polling fallback, offline and
  recovery, restore after relaunch and re-authentication events.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/ShellyKit swift:6.1 swift test
```

## Not verified yet

- No real-hardware run: the owner has not listed a Shelly device.
- From aioshelly / Home Assistant rather than the Shelly docs: the `cct` status field `ct` and config
  `ct_range`, the `rgbcct` component, the Gen1 Kelvin ranges, and whether Gen3 bulbs (Duo Bulb Gen3,
  Multicolor Bulb Gen3) expose `cct`/`rgbcct` or `light`/`rgbw` components. Unknown components are ignored.
- Gen2+ devices with "Enhanced Security" (HTTPS on 443) are not supported; plain HTTP only.
- Gen1 CoIoT push is not used (polling instead). Gen1 effects are not exposed.
- `URLSessionShellyWebSocket` and the Bonjour mapping compile only on macOS CI.
