# ElgatoKit

Elgato Key Light / Key Light Air / Key Light Mini / Ring Light / Light Strip over the **local HTTP
API**: port 9123, JSON, no authentication, Bonjour `_elg._tcp` (python-elgato, HA `elgato`,
`research/research_brands.md` § Elgato). Task T2.5a.

| Product | Builds on | Contains |
|---|---|---|
| `ElgatoCodec` | Linux + Apple (Foundation + LightCore) | JSON models for `/elgato/lights`, `/elgato/accessory-info`, `/elgato/lights/settings`; mired <-> Kelvin; state and command mapping |
| `ElgatoProvider` | Linux + Apple; Bonjour Apple only | `actor ElgatoProvider: LightProvider` over an `ElgatoHTTPTransport`; `URLSessionElgatoTransport` (FoundationNetworking on Linux); Bonjour behind `#if canImport(Network)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider
tests against an in-process fake light over real loopback HTTP.

## Codec

- `ElgatoAPI`: `GET/PUT /elgato/lights`, `GET /elgato/accessory-info`, `GET /elgato/lights/settings`,
  `POST /elgato/identify`; default port 9123.
- `ElgatoLightsDocument` / `ElgatoLightState`: `{"numberOfLights":1,"lights":[{"on":1,"brightness":21,"temperature":297}]}`.
  Every field is optional, so the same type is the partial `PUT` body (unset fields are omitted).
  `on` is accepted as 0/1 or a JSON bool. Light Strips in colour mode report `hue` (0-360) and
  `saturation` (0-100) instead of `temperature`.
- `ElgatoAccessoryInfo`: product name, **serial number** (the stable id), display name, firmware,
  board type, `macAddress` (newer firmware), `wifi-info`.
- `ElgatoSettings`: power-on defaults and fade durations; `powerOnHue` present = Light Strip.
- `ElgatoMapping`:
  - mireds 143-344 <-> Kelvin with rounding both ways (`1e6 / x`), so 2907-6993 K and every wire
    value round-trips exactly (297 mired = 3367 K).
  - brightness 0-100 <-> `0...1` with `ColorMath.deviceValue` (1...100; 0 is never sent, off is `on: 0`).
  - capabilities: Key Light family `[.colorTemp]`; Light Strip (hue in state, `powerOnHue` in
    settings or product name "Light Strip") `[.colorTemp, .hs]`. No transitions (fade times are
    device settings) and no effects.
  - `plan(_:current:supportsColor:)`: normalises the command (`LightCommand.normalized(for:)`), puts
    brightness and colour in **one PUT**; `brightness 0` without `on` = off, `brightness > 0` on an
    off light turns it on; Kelvin -> `temperature`, HS/RGB/xy -> `hue`/`saturation` on a strip (a
    Key Light gets the nearest temperature).

## Provider

- **Identity**: `LightID` = `elgato:<serial number>` (e.g. `elgato:CN11A1A00001`). IP/host and port
  are hints refreshed by discovery; the MAC (accessory-info or Bonjour TXT `id`) goes in metadata.
- **Requests**: every request carries `Connection: close` (the firmware resets reused connections);
  requests to one light are serialised with a 100 ms gap (`minRequestInterval`) and retried once
  (`retries`) on a transport error or timeout (5 s per attempt). 404 -> `LightCoreError.unsupported`,
  other non-2xx -> `.protocolError`.
- **Discovery** (`discover(options:)`, ends at `options.timeout`):
  1. Bonjour `_elg._tcp` when `.bonjour` is allowed (any resolved host: IPv4, IPv6 or `.local` name);
  2. `cachedHosts`, known device endpoints and `manualHosts` (`"ip"`, `"ip:port"`, `"name.local"`,
     `"[v6]:port"`). There is no broadcast protocol, so no multicast entitlement is needed.
  Each responder is identified by `GET /elgato/accessory-info`, then settings and state are read.
- **Pairing**: no credentials. `pair` asks for an IP when the device has none (Add by IP), checks the
  light answers and returns a `PairedDevice` (metadata `product`, `firmware`, `firmwareBuild`,
  `boardType`, `mac`, `color` = `1` for a Light Strip). On launch the app calls `restore(_:)`.
- **State**: `loadLights()` reads `/elgato/lights` from every paired light concurrently; failures mark
  the light unreachable instead of throwing. Accessory info is re-read once after `restore`.
- **Commands**: `send` plans one `PUT /elgato/lights`; the light answers with its new state, which
  replaces the cache (falls back to merging the request), then `.stateChanged` is emitted. After the
  retry: `.reachabilityChanged(false)` and `LightCoreError.unreachable`. `sendGroup` fans out
  concurrently (`.partialFailure` lists the lights that failed). `identify(_:)` blinks the light
  (onboarding "Verify" step).
- **Events**: no push protocol. `start()` polls every 10 s (`pollInterval`) and emits `.stateChanged`,
  `.lightUpdated` (name change) and `.reachabilityChanged`; `stop()` pauses (call it when the app goes
  to the background).

## App wiring

```swift
let elgato = ElgatoProvider.live()        // URLSession + Bonjour _elg._tcp
await elgato.restore(storedElgatoDevices) // PairedDevice values from DeviceStore
await registry.register(elgato)
await elgato.start()                      // polling while foregrounded
```

`_elg._tcp` is already in `NSBonjourServices`. The package is not yet listed in `project.yml`
(out of scope for this task); add `Packages/Providers/ElgatoKit` and the `ElgatoProvider` product
when the app wires the provider and its `BrandGuide` (onboarding §11).

## Tests

- `ElgatoCodecTests` (fixtures in `Tests/ElgatoCodecTests/Fixtures`): Key Light and Light Strip
  accessory-info, lights in temperature and colour mode, settings with and without `powerOnHue`,
  bool `on`, malformed bodies, partial PUT encoding, merge rules, every mired value round-tripping,
  state mapping, command plans (one body, power rules, clamping, colour on strip vs Key Light,
  effects/transitions dropped).
- `ElgatoProviderTests`: `FakeHTTPServer` (POSIX sockets, in the test target) + `FakeElgatoLight`.
  Covers manual and Bonjour discovery, unreachable host, pairing (incl. Add by IP), load, one PUT with
  `Connection: close` on every request, Light Strip colour and back to white, retry after a dropped
  connection, unreachable after retries, polling events (state + reachability lost/regained),
  restore without discovery, identify, group partial failure, host parsing.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/ElgatoKit swift:6.1 swift test
```

## Not verified yet

- No real-hardware run (the owner has no Elgato light listed); all behaviour is from python-elgato/HA.
- Whether Apple's URLSession sends a caller-set `Connection: close` (the macOS CI test
  `everyRequestAsksToCloseTheConnection` checks it); the retry covers resets either way.
- Bonjour TXT keys (`id` = MAC, `md` = model) are [verify]; only the host/port are relied on.
- Key Light Mini battery info (`/elgato/battery-info`) and multi-light accessories (`numberOfLights > 1`)
  are not handled; index 0 is controlled.
