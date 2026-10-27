# LIFXKit

LIFX over the official **LAN protocol**: binary UDP on port 56700, no authentication
(https://lan.developer.lifx.com, machine-readable spec
https://github.com/LIFX/public-protocol/blob/master/protocol.yml). Task T2.1.

| Product | Builds on | Contains |
|---|---|---|
| `LIFXCodec` | Linux + Apple (Foundation + LightCore) | 36-byte header, messages, HSBK, product registry, HSBK <-> `LightState`/`LightCommand` mapping |
| `LIFXProvider` | Linux + Apple; real transport Apple only | `actor LIFXProvider: LightProvider` over a `LIFXTransport`; `UDPSocketLIFXTransport` + Bonjour behind `#if canImport(Darwin)` / `#if canImport(Network)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider
tests against an in-process fake bulb over real loopback UDP.

## Codec

- `LIFXHeader` / `LIFXPacket`: frame header (size, protocol 1024, addressable, tagged, source),
  frame address (target serial, res_required, ack_required, sequence), protocol header (type).
  Little-endian. `LIFXPacket.encode()` always recomputes `size` and `type`.
- `LIFXMessage`: GetService 2 / StateService 3, GetHostFirmware 14 / StateHostFirmware 15,
  GetPower 20 / SetPower 21 / StatePower 22, GetLabel 23 / StateLabel 25, GetVersion 32 /
  StateVersion 33, Acknowledgement 45, StateUnhandled 223, Light Get 101 / SetColor 102 /
  SetWaveform 103 / State 107, Light GetPower 116 / SetPower 117 / StatePower 118, multizone
  SetColorZones 501 / GetColorZones 502 / StateZone 503 / StateMultiZone 506, extended multizone
  510 / 511 / 512. Anything else decodes as `.unknown(type:payload:)`.
- `HSBK`: hue `round(deg / 360 * 65536) mod 65536`, saturation and brightness `0...1 -> 0...65535`,
  kelvin as is (clamped to the product range when mapping).
- `LIFXProduct`: trimmed table generated from
  https://github.com/LIFX/products/blob/master/products.json (`Scripts/gen_products.py`):
  vendor/product id, name, features (color, infrared, multizone, extended multizone, chain,
  matrix, hev, relays, buttons), Kelvin range and firmware upgrades (e.g. LIFX Z gains extended
  multizone at 2.77; many bulbs widen to 1500-9000 K at 2.80 and 1000-10000 K at 4.148).
  `resolved(firmware:)` applies upgrades. Unknown ids fall back to a colour bulb, 1500-9000 K.
  Regenerate:

  ```sh
  curl -sSL -o /tmp/products.json https://raw.githubusercontent.com/LIFX/products/master/products.json
  python3 -I Scripts/gen_products.py /tmp/products.json > Sources/LIFXCodec/LIFXProductTable.swift
  ```

- `LIFXMapping`:
  - capabilities: colour -> `[.hs, .colorTemp]` (+ effects `breathe`, `pulse`); tunable white ->
    `[.colorTemp]`; fixed white -> `[.brightness]`; Switch (relays) -> `[.onOff]`; transitions on.
  - state: saturation 0 means white (`.colorTemp` with the HSBK kelvin), otherwise `.hs` plus an RGB
    hint from `ColorMath`.
  - `plan(_:current:isOn:product:)`: normalises the command (`LightCommand.normalized(for:)`),
    merges brightness and colour into **one SetColor**, adds Light SetPower (117) with the
    transition when power changes. Turning on: SetColor with duration 0 first, then SetPower fades
    in (no fade from the old colour). `brightness 0` without `on` = power off, colour kept.
    `brightness > 0` on an off light turns it on. Effects use a transient SetWaveform.

## Provider

- **Identity**: `LightID` = `lifx:<serial hex>` (the MAC, e.g. `lifx:d073d5001337`). IP and port
  are hints, updated from every reply (`handle`), so a bulb that changes IP is found again by
  discovery or by its next reply.
- **Requests**: one UDP socket; replies are matched by `source` (random per provider) and
  `sequence` (wrapping, skips in-flight numbers). Each attempt waits 1 s; 3 retries with a new
  sequence each; per-device token bucket of 20 messages/s. `StateUnhandled` ->
  `LightCoreError.unsupported`. Sets use `ack_required` and wait for Acknowledgement 45
  (the docs warn the State reply to a Set may be stale).
- **Discovery** (`discover(options:)`, ends at `options.timeout`):
  1. Bonjour `_lifx._udp` (fw >= 4.110; TXT `id` serial, `p` product, `fw` firmware) when
     `.bonjour` is allowed;
  2. tagged GetService broadcast to the Wi-Fi directed broadcast and 255.255.255.255 (3 rounds)
     when `options.broadcastAvailable`;
  3. otherwise a unicast GetService sweep of the Wi-Fi /24 via `SubnetSweeper` (500 ms, 1 attempt
     per host, 32 in flight);
  4. always: `cachedHosts`, known device endpoints and `manualHosts` (`"ip"` or `"ip:port"`).
  Each responder is identified by serial, then GetVersion / GetHostFirmware / GetLabel fill in
  model, capabilities and name.
- **Pairing**: no credentials. `pair` asks for an IP when the device has none (Add by IP), checks
  the device answers, and returns a `PairedDevice` with metadata `vendor`, `product`, `firmware`,
  `features`. On launch the app calls `restore(_:)` with the stored `PairedDevice`s.
- **State**: `loadLights()` sends Light Get (101) to every paired device concurrently; failures
  mark the light unreachable instead of throwing.
- **Commands**: `send` plans with `LIFXMapping.plan` and sends SetColor (+ Light SetPower with
  duration, + SetWaveform), each acknowledged; on success the cache is updated and
  `.stateChanged` emitted; after all retries `.reachabilityChanged(false)` and
  `LightCoreError.unreachable`. `sendGroup` fans out concurrently (`.partialFailure` lists the
  lights that failed).
- **Strips**: `zones(of:)` / `setZones(_:on:transition:)` use extended multizone 510-512 (82
  colours per message) when the product+firmware has it, else 501/502/506.
- **Events**: there is no push protocol. `start()` polls every 10 s (`pollInterval`) and emits
  `.stateChanged`, `.lightUpdated` (label change) and `.reachabilityChanged`; `stop()` pauses
  (call it when the app goes to the background).
- **Cloud token (optional)**: `configureCloudToken(using:)` / `setCloudToken(_:)` store the
  personal token from cloud.lifx.com/settings in `SecretStore` (`com.sinap.smartlights.lifx`,
  `cloud/accessToken`); `account` then reports a `lifx-cloud` `ProviderAccount`. The HTTP API
  fallback is **not implemented** (TODO T3.10 in `LIFXProvider.setCloudToken`).

## App wiring

```swift
let lifx = LIFXProvider.live()            // NetKit UDP socket + Keychain
await lifx.restore(storedLIFXDevices)     // PairedDevice values from DeviceStore
await registry.register(lifx)
await lifx.start()                        // polling while foregrounded
```

`DiscoveryOptions.broadcastAvailable` should come from `BroadcastCapability.detect()` (multicast
entitlement). Info.plist already lists `_lifx._udp` in `NSBonjourServices`.

## Tests

- `LIFXCodecTests`: byte-exact GetService broadcast header; the documented SetColor example from
  the LAN docs (49 bytes); flag bits; State* decoding vectors; payload sizes vs `protocol.yml`;
  round trip of every message; malformed packets; product table; HSBK and plan mapping.
- `LIFXProviderTests`: `FakeLIFXDevice` (in the test target) is a LIFX bulb/strip on a real
  127.0.0.1 UDP socket. Covers manual, broadcast and sweep discovery, pairing (incl. Add by IP),
  load, send (one SetColor; power fade order), retries after dropped packets, unreachable after
  4 attempts, group partial failure, legacy and extended multizone, polling events, endpoint
  refresh after a stale cached port, cloud token storage.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/LIFXKit swift:6.1 swift test
```

## Not verified yet

- Apple transport (`UDPSocketLIFXTransport`) and Bonjour mapping compile only on macOS CI; no
  real-hardware run yet (the owner has no LIFX device listed in phase 1).
- Bonjour results that resolve to an IPv6 address or host name are skipped (the transport needs
  IPv4); broadcast/sweep/manual still find those devices.
- Matrix/tile (chain) messages, infrared and HEV are not implemented; such devices work as single
  colour lights.
