# NanoleafKit

`LightProvider` for **Nanoleaf Wi-Fi controllers** (`Brand.nanoleaf`): Light Panels (NL22), Canvas
(NL29), Shapes (NL42), Elements (NL52), Lines (NL59), over the local **Open API v1** (plain HTTP on
TCP 16021). Nanoleaf Essentials bulbs/strips have no Open API; they go through the Apple Home
provider (docs/BRAND-RUNDOWN.md).

## Layout

| Target / file | Contents | Builds on |
|---|---|---|
| `NanoleafCodec/NanoleafModels.swift` | `NanoleafInfo` (`GET /api/v1/{token}/`), `NanoleafState`, `NanoleafRange`, `NanoleafEffects`, `NanoleafPanelLayout`, `NanoleafAuthResponse`; lenient decoding (ints sent as doubles, missing keys) | Linux, Apple |
| `NanoleafCodec/NanoleafRequests.swift` | `NanoleafAPI` request builders + decoders, `NanoleafStateUpdate` (`PUT /state` body), `NanoleafRequest.redactedPath`, token validation | Linux, Apple |
| `NanoleafCodec/NanoleafEvents.swift` | SSE event decoding (`NanoleafEventDecoder` over NetKit `SSEParser`), state merge (`NanoleafState.applying`) | Linux, Apple |
| `NanoleafCodec/NanoleafMapper.swift` | Open API ↔ LightCore: capabilities, `LightState`, `LightCommand` → `NanoleafCommandPlan`, effects → `EffectDescriptor`/`LightScene`, Bonjour TXT → `DiscoveredDevice`, manual host parsing | Linux, Apple |
| `NanoleafProvider/NanoleafTransport.swift` | `NanoleafTransport` protocol + `URLSessionNanoleafTransport` (HTTP + streaming GET) | Linux (FoundationNetworking), Apple |
| `NanoleafProvider/NanoleafProvider.swift` | `actor NanoleafProvider: LightProvider` | Linux, Apple |
| `NanoleafProvider/NanoleafBonjour.swift` | `_nanoleafapi._tcp` browse (NetKit `BonjourBrowser`) + IPv4-only resolution, `#if canImport(Network)` | Apple |

The codec depends on LightCore (mapping targets) and NetKit (its Linux-safe `SSEParser`/`HTTPMethod`);
both build on Linux. The provider does not use NetKit's `HTTPClient`/`SSEClient` because those are
`#if canImport(Darwin)`; the URLSession transport here runs on both platforms, so the Linux tests
exercise the exact code the app ships. `LINUX_OK`: the Linux CI job runs all tests; macOS CI runs
them too and compiles the Bonjour file.

## Open API surface used

| Purpose | Request | Notes |
|---|---|---|
| Pair | `POST /api/v1/new` → `{"auth_token": "..."}` | 200 only for ~30 s after holding the power button 5-7 s; 403 otherwise |
| Probe (manual host) | `GET /api/v1/` | any HTTP answer (401) means an Open API controller |
| Info | `GET /api/v1/{token}/` | name, serialNo, model, firmwareVersion, panelLayout, state, effects |
| State | `PUT /api/v1/{token}/state` | `{"on":{"value":true},"brightness":{"value":80,"duration":2},"hue":{"value":120},"sat":{"value":100},"ct":{"value":2700}}` → 204 |
| Effect | `PUT /api/v1/{token}/effects` | `{"select":"Northern Lights"}` |
| Effects list | `GET /api/v1/{token}/effects/effectsList` | (info already contains it; builder provided) |
| Identify | `PUT /api/v1/{token}/identify` | panels flash |
| Unpair | `DELETE /api/v1/{token}` | revokes the token |
| Events | `GET /api/v1/{token}/events?id=1,2,3,4` | SSE: `id:` = class (1 state, 2 layout, 3 effects, 4 touch), `data: {"events":[{"attr":2,"value":65}]}`; state attrs 1 on, 2 brightness, 3 hue, 4 sat, 5 ct, 6 colorMode; touch `{"panelId":..,"gesture":0-5}` |

Sources: `MylesMor/nanoleafapi` (`nanoleaf.py` payloads, event ids), openHAB nanoleaf binding docs,
HA `nanoleaf` integration (pairing copy, transition behaviour), research/research_brands.md and
research/research_onboarding.md §6.

## Mapping

- **Id**: `nanoleaf:<serialNo>` (from info); if a controller reports no serial, the Bonjour TXT `id`
  (MAC-like, e.g. `nanoleaf:59:7E:43:1A:2B:3C`). Never the IP. `PairedDevice.id` is the same stable id;
  `metadata["bonjourID"]` keeps the TXT id so a Bonjour sighting can refresh the cached IP.
- **Token**: `SecretStore` key `SecretKey(brand: .nanoleaf, owner: <stable id>, item: "authToken")`. It is
  never logged (`NanoleafRequest.redactedPath`, transport errors carry no URLs).
- **Capabilities**: `[.hs, .colorTemp]`, Kelvin range from `state.ct.min...max` (falls back to
  1200...6500 when missing or nonsensical, e.g. early Light Panels firmware reporting 0...100),
  transitions supported, effects = `effectsList` minus pseudo effects (`*Solid*`, `*Static*`,
  `*Dynamic*`). `isFast` is a name heuristic (strobe, flash, fireworks, party, ...) **[verify]**.
- **State**: brightness `value/100` (scaled by the reported min/max); `colorMode` `ct` → `.colorTemp`,
  `hs` → `.hs`, `effect` → `.hs` (hint) + `LightState.effect = effects.select`.
- **Commands** (after `LightCommand.normalized(for:)`): brightness 0...1 → 0-100; hs → `hue` 0-359,
  `sat` 0-100; Kelvin → `ct` clamped to the range; transition → `brightness.duration` in whole seconds.
  `on: false` sends only `on` (no power fade in the API). Brightness 0 without `on` turns the panels
  off. Brightness with a transition is sent without `on` (the controller turns on and fades, as HA
  does); without a transition `on: true` is included. Everything goes in **one `PUT /state`**
  (`Configuration.combineStateWrites`, default true; set false to send one request per attribute if a
  firmware rejects combined bodies). An effect is selected with a separate `PUT /effects` after the
  state write. After each successful write the provider emits an optimistic `.stateChanged`; the
  controller's SSE echo confirms it.
- **Scenes**: every effect is a `LightScene` with `kind: .vendor`, id `nanoleaf:<stable id>/<effect name>`;
  `recall` selects it. The same effects are listed in `LightCapabilities.effects` (so
  `LightCommand(effect:)` works too).

## Provider behaviour

- `discover(options:)`: Bonjour (Apple; resolves services with an **IPv4-only** `NWConnection` because
  firmware >= 8.5.2 advertises IPv6 addresses that do not answer the API), manual and cached hosts
  (`"192.168.1.30"`, `"192.168.1.30:16021"`, host names; IPv6 literals rejected with an `.error` event)
  probed with `GET /api/v1/`. Results are de-duplicated; a Bonjour result for an already paired
  controller carries its stable id and refreshes its cached IP. The stream ends at `options.timeout`
  or when all methods finished.
- `pair(_:using:)`: `ui.confirm(NanoleafProvider.pairingMessage)` ("Hold the power button on the
  controller for 5-7 seconds until the LEDs flash, then tap Continue"); false → `.userCancelled`.
  Then `POST /api/v1/new` every second for up to 30 s (`ui.status` shows the countdown); timeout →
  `LightCoreError.timeout` after `ui.status(notInPairingModeMessage)`. Then `GET` info, store the token,
  emit `.lightAdded` + `.scenesChanged`.
- `loadLights()`: re-reads every controller; unreachable ones are returned with `reachable: false`
  (built from the last known info, or from the `PairedDevice` name with default capabilities).
- `send` / `sendGroup` (default fan-out) / `identify(_:)` / `removeDevice(_:)` (DELETE token, delete
  secret, `.lightRemoved`).
- `start()` / `stop()`: one SSE connection per controller with reconnect (exponential backoff 1 s →
  60 s, 20% jitter), idle timeout 300 s, and a full info re-read each time the stream is (re)opened.
  The re-read does not wait for the response head: on Darwin, URLSession only delivers the head
  of the close-delimited SSE response together with the first body bytes, and a controller sends
  nothing until something changes. For the same reason `.connectionChanged(connected: true)` can lag
  until the first event on Apple platforms. State events → `.stateChanged`; an unknown effect name or a layout
  event → re-read + `.lightUpdated` (+ `.scenesChanged`). Touch gestures go to `touchEvents`
  (`NanoleafTouchEvent`).
- Reachability: a transport failure (or an SSE reconnect that cannot connect) → `.reachabilityChanged(false)`;
  any later HTTP answer → `true`. HTTP 401/403 with a stored token → `.needsReauthentication(accountID:
  <stable id>)` and `LightCoreError.authenticationRequired(.nanoleaf)` (factory reset or token deleted:
  pair again).
- Persistence: pass stored devices to `init(devices:)` or call `restore(_:)`; read `pairedDevices` to
  save (`hostHint`, `port`, `metadata["bonjourID"]`, `firmware`, `panels`).

## What the app must do

1. Info.plist: `NSLocalNetworkUsageDescription` and `_nanoleafapi._tcp` in `NSBonjourServices`
   (already in the T0.1 list). Plain HTTP to IP addresses / `.local` names is exempt from ATS;
   add `NSAllowsLocalNetworking` if users type other host names.
2. Register: `NanoleafProvider(secrets: KeychainSecretStore(accessGroup: ...), devices: storedNanoleafDevices)`,
   then `start()` while foregrounded and `stop()` in the background.
3. Onboarding (docs/ONBOARDING-WALKTHROUGHS.md §7): Scan → pick controller → the provider's confirm
   prompt → wait (status lines) → done. Skylight has no power button: the user taps "Connect to API"
   in the Nanoleaf app instead, then Continue. Suggest a DHCP reservation.

## Tests

- `NanoleafCodecTests`: JSON fixtures in `Tests/NanoleafCodecTests/Fixtures` (Shapes info with
  effect mode, old Light Panels info with the bogus ct range and float brightness, auth token,
  effects list, an SSE capture with all four event classes).
- `NanoleafProviderTests`: `FakeNanoleafServer` (POSIX sockets, Linux + macOS) implements pairing
  mode, info, state/effects writes with SSE echoes, identify, delete, events; tests cover pairing
  (retry until pairing mode, timeout, cancel, serial vs Bonjour id), load, combined and split
  writes, effects as scenes, SSE events + reconnect, touch, unreachable, revoked token, restore,
  manual/Bonjour discovery and IP refresh.

```
docker run --rm -v "$PWD":/src -w /src/Packages/Providers/NanoleafKit swift:6.1 swift test
```

## Open items

- **[verify]** on hardware: combined `PUT /state` bodies with on+brightness+hue+sat+ct (nanoleafapi only
  combines hue+sat+brightness); brightness-with-duration turning panels on; behaviour of hue/sat writes
  while off; SSE keep-alives (none assumed, hence the 300 s idle timeout).
- Fast-effect flag is a name heuristic.
- No /24 sweep fallback when Bonjour is blocked (manual host entry covers it).
- UDP external control (streaming per-panel colours) and rhythm/touch-to-UDP are not implemented.
