# WLEDKit

WLED (DIY ESP8266/ESP32 LED controllers) over the **JSON HTTP API**: port 80, no authentication,
Bonjour `_wled._tcp` (https://kno.wled.ge/interfaces/json-api/). Task T2.5a.

| Product | Builds on | Contains |
|---|---|---|
| `WLEDCodec` | Linux + Apple (Foundation + LightCore) | JSON models for `/json/state`, `/json/info`, `/json/effects`, `/json/cfg`; identity; effects; state and command mapping |
| `WLEDProvider` | Linux + Apple; Bonjour Apple only | `actor WLEDProvider: LightProvider` over a `WLEDHTTPTransport`; `URLSessionWLEDTransport` (FoundationNetworking on Linux); Bonjour behind `#if canImport(Network)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider
tests against an in-process fake controller over real loopback HTTP.

## Codec

- `WLEDAPI`: `GET/POST /json/state`, `GET /json/info`, `GET /json/effects`, `GET /json/cfg`; port 80.
- `WLEDState` / `WLEDSegment`: master `on`, `bri` (0-255), `transition`, `ps`, `seg[]` with `col`
  (up to three slots, `[r,g,b]` or `[r,g,b,w]`; hex strings are accepted too), `fx`, `sx`, `ix`, `pal`.
- `WLEDStateUpdate`: the POST body; unset fields are omitted. `tt` is the **one-shot** transition in
  100 ms units (`transition` would change the controller's default, so it is never sent). `v: true`
  makes WLED answer with the new state.
- `WLEDInfo`: version, build id, `leds.count`, `leds.lc` (1 RGB, 2 white, 4 CCT), legacy
  `leds.rgbw`, name, **MAC**, IP, arch. `WLEDConfig`: `id.mdns` only.
- `WLEDMapping`:
  - identity: `LightID` = `wled:<mDNS name>`, normalised (lower case, no `.local`):
    `wled:wled-kitchen`. Default name when nothing else is known: `wled-` + last 6 MAC hex digits
    (what WLED itself uses).
  - effects: `/json/effects` names -> `EffectDescriptor(id: "<index>", name:)`; "RSVD"/"-" skipped
    (ids stay the array index), metadata after `@` stripped; strobe/blink/lightning/flash/police/glitter
    effects are `isFast` (photosensitivity warning).
  - capabilities: `[.rgb]`, `[.rgbw]` when `lc & 2` (or legacy `rgbw`), `[.brightness]` for white-only
    (`lc == 2`); transitions on; effects as above. CCT (`lc & 4`) is not mapped yet (colour
    temperature is sent as RGB).
  - state: master `on`/`bri`, `seg[0].col[0]` as `.rgb`/`.rgbw` (+ HS hint), `seg[0].fx` as the effect
    (0 = Solid = none).
  - `plan(_:current:capabilities:)`: normalises the command, puts master brightness, colour, effect
    and `tt` in **one POST**; `brightness 0` without `on` = off (keeps `bri`); `brightness > 0` on an
    off light turns it on; a colour without an effect selects Solid (`fx: 0`) so the colour shows;
    an effect selects `fx` and turns an off light on.

## Provider

- **Identity**: keyed by the mDNS name (Bonjour instance name, else `/json/cfg` `id.mdns`, else the
  `wled-<mac>` default), with the MAC from `/json/info` stored alongside (`metadata["mac"]`). A
  controller renamed after pairing is matched by MAC and keeps its id (the new name is in
  `metadata["mdns"]`). IP/host and port are hints refreshed by discovery.
- **Requests**: serialised per controller with a 50 ms gap (ESP8266 has few connection slots),
  retried once on a transport error or timeout (5 s per attempt). 404 -> `.unsupported`, other
  non-2xx -> `.protocolError`.
- **Discovery** (`discover(options:)`, ends at `options.timeout`): Bonjour `_wled._tcp` when allowed,
  plus `cachedHosts`, known endpoints and `manualHosts` (`"ip"`, `"ip:port"`, `"wled-x.local"`). No
  broadcast, so no multicast entitlement is needed. Each responder: `/json/info`, (`/json/cfg`),
  `/json/effects`, `/json/state`.
- **Pairing**: no credentials. `pair` asks for an IP or `.local` name when the device has none, checks
  the controller answers and returns a `PairedDevice` (metadata `mdns`, `mac`, `version`, `arch`,
  `leds`, `lc`, `rgbw`, `effects`). `restore(_:)` re-registers stored devices; capabilities come from
  the stored `lc`/`rgbw` until `/json/info` has been read again.
- **State**: `loadLights()` reads `/json/state` from every paired controller concurrently (info and
  effects once after `restore`); failures mark the light unreachable instead of throwing.
  `effects(of:)` returns the effect list.
- **Commands**: `send` plans one `POST /json/state` with `v: true` and caches the echoed state (falls
  back to merging the update), then emits `.stateChanged`; after the retry `.reachabilityChanged(false)`
  and `LightCoreError.unreachable`. `sendGroup` fans out concurrently (`.partialFailure`).
- **Events**: `start()` polls every 10 s (`pollInterval`) and emits `.stateChanged`, `.lightUpdated`
  (name or capability change) and `.reachabilityChanged`; `stop()` pauses.

## App wiring

```swift
let wled = WLEDProvider.live()           // URLSession + Bonjour _wled._tcp
await wled.restore(storedWLEDDevices)    // PairedDevice values from DeviceStore
await registry.register(wled)
await wled.start()                       // polling while foregrounded
```

`_wled._tcp` is already in `NSBonjourServices`. The package is not yet listed in `project.yml` (out of
scope for this task); add `Packages/Providers/WLEDKit` and the `WLEDProvider` product when the app
wires the provider and its `BrandGuide` (onboarding §13).

## Tests

- `WLEDCodecTests` (fixtures in `Tests/WLEDCodecTests/Fixtures`): 0.14 state and info, RGBW state with
  an effect, hex colour slots, legacy 0.12 RGBW info, cfg identity, a 0.14-style effect list with
  reserved slots and `@` metadata, malformed bodies, update encoding, merge, identity normalisation,
  capabilities per `lc`, brightness round trips, command plans (one body, power rules, colour
  conversion, RGBW, effects, `tt` rounding and limit, no-ops).
- `WLEDProviderTests`: `FakeHTTPServer` (POSIX sockets, in the test target) + `FakeWLEDController`.
  Covers manual discovery with `/json/cfg`, the MAC-based default name, Bonjour instance name, pairing
  (incl. Add by IP), load with effects, one POST with `bri`/`col`/`fx`/`tt`/`v`, effect selection and
  unknown effect dropped, RGBW, off/on keeping brightness, retry, unreachable, polling events, renamed
  controller keeps its id, restore, unknown light, group partial failure, host parsing.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/WLEDKit swift:6.1 swift test
```

## Not verified yet

- No real-hardware run (the owner has no WLED controller listed).
- Multi-segment setups are driven through segment 0 only; WLED's live/realtime UDP (DDP, E1.31),
  presets as vendor scenes, palettes and effect speed/intensity are not exposed.
- CCT strips (`lc & 4`) get colour temperature as RGB, not via `seg.cct`.
