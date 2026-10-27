# YeelightKit

Yeelight Wi-Fi lights (bulbs, strips, ceiling lights, desk/bedside lamps) over the documented LAN
protocol: SSDP-style discovery on `239.255.255.250:1982` and line-delimited JSON-RPC on TCP
`55443`. No account, no cloud, no authentication. Task T2.4 (`agents/TASKS.md`).

| Product | Builds on | Contents |
|---|---|---|
| `YeelightCodec` | Linux + Apple | SSDP search request / response + NOTIFY parsing, JSON-RPC request encoding, result / error / `props` parsing, line framer, method builders with spec ranges, model table, `LightState` / `LightCommand` mapping |
| `YeelightProvider` | Linux + Apple (transport Apple-only) | `YeelightProvider` actor (`LightProvider`), `YeelightSession` (persistent connection, id matching, reconnect), `NWYeelightConnector` and `LiveYeelightDiscovery` under `#if canImport(Network)` |

`LINUX_OK` is present: `swift build` / `swift test` run in the `swift:6.1` container
(`docker run --rm -v "$PWD":/src -w /src/Packages/Providers/YeelightKit swift:6.1 swift test`).

## Before you start: LAN Control

The bulb ignores third-party apps until **LAN Control** is on:

Yeelight app > Device > (light) > "more" icon > **LAN Control** > on. Older firmware calls it
**Developer Mode**. If the toggle is missing, update the firmware in the Yeelight app; a few newer
models removed it entirely (use Apple Home / Matter for those if they support it).

When LAN Control is off the bulb still answers discovery but **refuses the TCP connection**. The
provider detects `ECONNREFUSED` and, during `pair`, asks the user through
`PairingInteraction.confirm(YeelightProvider.lanControlGuidance)` to enable it and retry (up to
`Configuration.pairAttempts`). Manual hosts that refuse are still listed by `discover` with
`metadata["lanControl"] == "off"` so the wizard can show the hint before pairing.

## Limits and quirks

- **60 commands per minute per bulb** (spec). Every call (including `get_prop`) goes through a
  per-bulb `RateLimiter` (`Configuration.rateLimit`, default 60/min, burst 60). Exceeding the
  device quota returns `client quota exceeded`, surfaced as `LightCoreError.protocolError`.
  Music mode (bulb connects back to us, no quota) is not implemented (see open items).
- **At most 4 simultaneous TCP connections** per bulb. The provider keeps one persistent connection
  per bulb; discovery probes open short-lived ones.
- **First command after a dropped connection may be ignored** (HA docs). A request that times out
  on a freshly opened connection is retried once.
- Colour setters (`set_rgb`, `set_hsv`, `set_ct_abx`, `set_bright`) are only accepted while the
  light is on. `set_scene` works in both states and turns the light on.
- `smooth` transitions need at least 30 ms; `sudden` ignores the duration.
- The `name` property may be Base64 for non-ASCII names (spec suggestion); it is passed through.

## Identity, discovery

Lights are keyed by the SSDP `id` (`yeelight:0x000000000015243f`), never by IP (PLAN.md D10).
`discover(options:)` merges, deduplicating by id:

1. **Manual / cached hosts**: TCP probe (`get_prop`) plus **unicast** M-SEARCH to `<ip>:1982` for
   the id (unicast needs no multicast entitlement).
2. **Multicast** M-SEARCH (BSD `UDPSocket` bound to Wi-Fi) only when
   `options.broadcastAvailable` (multicast entitlement present).
3. **Bonjour** `_miio._udp`, instances named `yeelink-*`; each hit is probed like a manual host. If
   the device does not answer, the id is derived from the `_miio<did>` suffix (did in hex) [verify].
4. **/24 sweep** (`SubnetSweeper`, TCP probe on 55443) when broadcast is not available.

Devices that never answer SSDP get a provisional id `ip:<host>`; `pair` retries the unicast search
and upgrades to the real id when it can.

## Control

`send` normalises the command (`LightCommand.normalized(for:)`) and asks
`YeelightMapper.calls(for:capabilities:current:support:)` for the fewest calls:

| Command (state) | Calls |
|---|---|
| off / brightness 0 | `set_power off` |
| on + colour (light off) | `set_scene` (colour + brightness + power in one call) |
| colour + brightness (light on, no transition) | `set_scene` |
| brightness only (light off, colour known) | `set_scene` with the known colour |
| colour or brightness with transition (light on) | `set_ct_abx` / `set_hsv` / `set_rgb`, then `set_bright` (smooth, duration) |
| on only | `set_power on` |

Capabilities: colour models expose `[colorTemp, hs, rgb]`, tunable-white models `[colorTemp]`,
mono models `[brightness]`. Kelvin ranges per model come from python-yeelight's `_MODEL_SPECS`
(e.g. `color*`/`strip1`/`bslamp*` 1700-6500 K, `colorc`/`strip2..6`/ceilings 2700-6500 K,
`ceiling17` 3000-5700 K, `lamp1` 2700-5000 K). Light kind: `support` list first (`set_rgb` ->
colour, `set_ct_abx` -> tunable white, else mono), then model name, then a `get_prop` heuristic.

`props` notifications update the cached state and are published as
`ProviderEvent.stateChanged`; connection loss publishes `reachabilityChanged(false)`, and after the
backoff reconnect `reachabilityChanged(true)` followed by a `get_prop` refresh.

Extras on the actor: `toggle(_:)`, `setName(_:for:)`, `refresh(_:)`, `restore(_:)` /
`pairedDevices()` for `DeviceStore`, `remove(_:)`, `disconnectAll()`; `YeelightCommands` also
builds `start_cf` / `stop_cf` / `auto_delay_off` for later effect support.

## Usage

```swift
let provider = YeelightProvider.live()                  // Apple platforms
await provider.restore(try await store.pairedDevices().filter { $0.brand == .yeelight })
for await device in await provider.discover(options: DiscoveryOptions(manualHosts: ["192.168.1.50"])) {
    let paired = try await provider.pair(device, using: wizard)
    try await store.save(paired)
}
try await provider.send(LightCommand(on: true, brightness: 0.6, color: .kelvin(3000)), to: lightID)
```

## Tests

- `YeelightCodecTests`: SSDP request bytes, spec search-response fixture, NOTIFY, echo/foreign
  SSDP rejection, JSON-RPC request bytes for every method, result/error/notification parsing,
  framing, model table, state mapping, command planning.
- `YeelightProviderTests`: provider against an in-memory fake device (`FakeYeelightBulb`) and,
  over real loopback TCP, against `FakeYeelightTCPServer` (test target only; `Packages/Simulators`
  untouched). On Apple platforms the TCP suite also runs with `NWYeelightConnector`.

## Reuse evaluation: ahmetcanaltun/YeelightKit

MIT, Swift, single `YeelightKit` module (Network.framework transport mixed with protocol code,
Swift 5.9 tools, 0 stars, pushed 2026-10). Not adopted: it does not fit the mandatory codec /
transport split (D6) or `LightCore` types, and cannot be tested on Linux. Its music-mode session
is a useful reference if we add music mode later.
