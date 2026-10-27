# DirigeraKit

IKEA **DIRIGERA** hub over its unofficial local REST API on port 8443. The hub uses a self-signed certificate. The protocol is ported from [Leggin/dirigera](https://github.com/Leggin/dirigera) (MIT, see `NOTICES.md`). Task T3.5.

For most users the recommended path is still the hub's Apple Home / Matter bridge through the HomeKit provider (`docs/ONBOARDING-WALKTHROUGHS.md` §18). This package is the direct path: no Apple Home needed, plus the hub's own scenes.

| Product | Builds on | Contains |
|---|---|---|
| `DirigeraCodec` | Linux + Apple (Foundation + LightCore + swift-crypto for SHA-256) | PKCE helpers, request builders, device/hub/scene/event models with partial-update merge, capability and state mapping, PATCH planning, ids |
| `DirigeraProvider` | Linux + Apple; real transport Apple only | `actor DirigeraProvider: LightProvider` over a `DirigeraTransport`; `URLSessionDirigeraTransport` (URLSession, `URLSessionWebSocketTask`, NetKit `TrustEvaluator`/`TrustingSessionDelegate`, `BonjourBrowser`) behind `#if canImport(Darwin) && ...` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider tests against an in-package fake hub over loopback HTTP and WebSocket.

## Setup in the app

```swift
import DirigeraProvider
let dirigera = DirigeraProvider(secrets: KeychainSecretStore(accessGroup: group),
                                pinStore: keychainBackedTOFUPinStore)   // same store type as Hue
for hub in pairedHubs { await dirigera.addHub(hub) }                    // restore on launch
let lights = try await dirigera.loadLights()                            // also opens the WebSockets
```

Call `disconnectEventStreams()` when the app goes to the background and `connectEventStreams()` when it returns. `updateHost(hubID:host:)` records a new IP.

Ids:
- light: `dirigera:<hubID>/<deviceID>`;
- scene: `dirigera:<hubID>/<sceneID>`;
- `providerRef`: `<hubID>/<deviceID>`.

The hub id is the `id` from `GET /v1/hub/status`. Device ids are the hub's own ids.

## Discovery

`discover(options:)` runs these in parallel until `options.timeout`:

- **Bonjour** (`.bonjour`): results whose name or host starts with `gw2-` (the hub announces `gw2-<id>.local`). The transport browses `_ihsp._tcp` and `_hap._tcp` **[verify]**. Both must be in `NSBonjourServices`.
- **Manual and cached hosts**: `ip`, `ip:port`, `gw2-xxxx.local`, `https://ip:8443/`.
- **HTTPS sweep** (`.sweep`) of the Wi-Fi /24, 32 probes at a time.

Probe: unauthenticated `GET /v1/hub/status`. A hub answers 401. A discovered hub is `ip:<host>` until paired, because the hub id needs the token. Metadata: `probeStatus`, `certificateSHA256`.

## Pairing (button press + PKCE)

1. `GET /v1/oauth/authorize?audience=homesmart.local&response_type=code&code_challenge=<S256>&code_challenge_method=S256` returns `{"code"}`. The verifier is 128 characters from `_-~.A-Za-z0-9`. The challenge is `base64url(SHA-256(verifier))` without padding, checked against Python output.
2. `PairingInteraction.confirm("Press the action button on the bottom of the IKEA DIRIGERA hub, then tap Continue")`. Answering "no" throws `.userCancelled`.
3. `POST /v1/oauth/token` (form `code`, `name=SmartLights`, `grant_type=authorization_code`, `code_verifier`) returns `{"access_token"}`. On 400/401/403 it retries every second for up to 30 s with a `status("Waiting for the hub's action button... N s")`, then throws `.timeout`.
4. `GET /v1/hub/status` with the token gives the hub id, name, model and firmware.
5. The token is stored as `SecretKey(brand: .dirigera, owner: <hubID>, item: "token")` and never logged. Tokens do not expire. A 401/403 later emits `needsReauthentication(accountID: hubID)` and throws `.authenticationRequired(.dirigera)`.

## TLS: trust on first use

- Pairing requests use `DirigeraTrust.pairing`: any certificate is accepted and the leaf's SHA-256 is reported. **Every pairing response must carry the same certificate**; otherwise pairing fails. That fingerprint is pinned under the hub id in the `TOFUPinStore`. If a different pin already exists, pairing fails ("remove the hub and add it again").
- Every later request and the WebSocket use `DirigeraTrust.hub(id:)`: a per-hub URLSession whose `TrustingSessionDelegate` runs NetKit `TrustEvaluator(anchors: [], expectedIdentifier: hubID, allowSelfSignedTOFU: true, requireSelfSignedCommonNameMatch: false)`. The leaf must be self-issued and match the pin.
- **[verify]** that the hub's leaf is really self-signed (see `docs/HARDWARE-NOTES.md`).

## Control

- Only devices with `type == "light"` become lights. Outlets, sensors, controllers and the gateway are ignored.
- Capabilities come from `capabilities.canReceive`:
  - `colorHue`+`colorSaturation` -> `.hs`;
  - `colorTemperature` -> `.colorTemp`, with the Kelvin range from `colorTemperatureMin/Max`. Bounds are often reversed; values below 1000 are mireds, as on KAJPLATS (Leggin `_bound_to_kelvin`);
  - otherwise `lightLevel` -> `.brightness`;
  - otherwise `.onOff`.
- `send` sends `PATCH /v1/devices/{id}` with `[{"attributes": {...}}]`:
  - off: `{isOn: false}` only;
  - otherwise `isOn: true` when asked, or implied by brightness or colour on an off light, plus `lightLevel` 1...100 and either `colorTemperature` (K) or `colorHue` (0...360) + `colorSaturation` (0...1);
  - attributes not in `canReceive` are never sent.
- Everything goes in **one PATCH**. If the hub answers 400, the provider resends one PATCH per attribute group, the way Leggin's setters do, and remembers this per hub **[verify which the hub needs]**.
- Limits: at most 3 concurrent requests per hub and 10 commands/s per light. No transitions (`supportsTransition = false`).
- Scenes: `GET /v1/scenes` -> vendor `LightScene`s; `recall` -> `POST /v1/scenes/{id}/trigger`.

## Events

One WebSocket per hub to `wss://<hub>:8443/v1` with `Authorization: Bearer`, pinged every 60 s. It handles:

- `deviceStateChanged`: partial attributes and `isReachable` are merged and emitted as `stateChanged`, `reachabilityChanged` or `lightUpdated` (name, room or capabilities);
- `deviceAdded`: refetch, `lightAdded`;
- `deviceRemoved`: `lightRemoved`;
- `scene*`: refetch scenes, `scenesChanged`.

On disconnect it reconnects with exponential backoff (1 s to 60 s, 20 % jitter). After a reconnect it refetches devices and emits the diff. A refused upgrade (401/403) emits `needsReauthentication` and stops. `connectionChanged` reports the socket state.

## Tests

```
docker run --rm -v "<repo>:/src" -w /src/Packages/Providers/DirigeraKit swift:6.1 swift test
```

- `DirigeraCodecTests` covers the PKCE vector, request bodies, models (one light from Leggin's test fixture), event merge, capabilities and PATCH plans.
- `DirigeraProviderTests` runs against `FakeDirigeraHub`, an in-package HTTP + WebSocket fake over loopback, on Linux and macOS. It covers:
  - the probe;
  - PKCE pairing with a late button press, a declined prompt, a timeout and a pin mismatch;
  - pinned trust and the bearer token on every later call;
  - light mapping;
  - combined PATCH and the split fallback;
  - scene trigger;
  - a revoked token;
  - WebSocket state, reachability, reconnect and resync;
  - scene and removal events.
- On macOS, `URLSessionDirigeraTransportTests` runs the real URLSession and `URLSessionWebSocketTask` transport against the same fake over plain http/ws. TLS evaluation itself is NetKit's (`TrustEvaluator`) and still needs a real hub.

`Tests/DirigeraProviderTests/Loopback.swift` is shared verbatim with TwinklyKit.
