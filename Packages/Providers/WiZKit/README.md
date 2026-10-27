# WiZKit

Local control of WiZ (Signify) lights over the reverse-engineered JSON-over-UDP protocol.
Sources: `research/research_wiz.md` §1, §7, §8; tooling: `tools/probe/wiz.mjs`.

| Product | Contents | Builds on |
|---|---|---|
| `WiZCodec` | Ordered JSON codec, request builders, response/push parsing, error model, HMAC signing, signing-key import, `moduleName` decoding, capabilities, scene table, pilot <-> `LightState`, `LightCommand` -> `setPilot` params | Linux + Apple (Foundation, swift-crypto, LightCore) |
| `WiZKit` | `WiZProvider` actor (`LightProvider`), `WiZTransport` protocol, `NetKitWiZTransport` (BSD sockets, `#if canImport(Darwin)`) | Linux + Apple (transport Apple-only) |

```sh
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/WiZKit swift:6.1 swift test
```

The provider's transport is a protocol, so the integration tests (`Tests/WiZKitTests`) run the real
provider against `FakeWiZBulb` (Packages/Simulators) on Linux too, through `VirtualWiZNetwork`,
which maps virtual IPs such as `10.0.0.2:38899` to the fakes' loopback ports and supports
broadcast, packet loss, injected replies and IP changes.

## Protocol summary

- One JSON object per UDP datagram to the bulb on **38899**:
  `{"id":1,"method":"setPilot","params":{"state":true,"temp":3000,"dimming":75}}`.
  Replies echo `method`, add `"env":"pro"` and carry `result` or `error`.
- Methods: `getPilot`, `setPilot`, `setState`, `getSystemConfig` (MAC, `moduleName`, `fwVersion`),
  `getModelConfig` (`cctRange`, `nowc`, `wcr`; -32601 on fw <= 1.22), `getUserConfig`,
  `registration`, `pulse`. Bulb -> app pushes on **38900**: `syncPilot` (state change / heartbeat)
  and `firstBeat` (bulb rejoined the network).
- Errors: -32601 method not found, -32602 invalid params (with `sigTs`: signing required),
  -32605 security error (bad signature or stale `sigTs`), -32700 parse error.
- Bulbs are identified by **MAC** (`LightID` = `wiz:<12 hex>`); IPs are cached hints.
- `moduleName` (`ESPxx_<ID>_<rev>`): `RGB` -> colour + tunable white, `DDTW` -> fan + tunable white,
  `FANDIM` -> fan + dimmable, `TW` -> tunable white, `SOCKET` -> plug (on/off), anything else ->
  dimmable white; `DH` = dual head, `SH` = single head. Missing `moduleName` (fw 1.8.0): guessed
  from the `getPilot` fields.
- Kelvin range: min/max of `getModelConfig.cctRange`, else `extRange`/`whiteRange`, else 2200-6500 K
  (colour) / 2700-6500 K (tunable white).
- Scenes are exposed as `EffectDescriptor`s with the scene id as effect id (`"4"` = Party):
  1-36, 40, 256-265 (Custom Mode 1-10), 1000 (Rhythm) for colour bulbs; the 17-scene TW subset and
  the 8-scene DW subset otherwise. Party, Club, Halloween and Alarm are flagged `isFast`.

### Reliability

- Requests to one bulb are serialised; each is re-sent with pywizlight's gaps
  0.75 / 1.5 / 3 / 3 / 3 s and fails after 13 s. Writes use a shorter schedule (0.75 / 1.5 s,
  5 s) to avoid flicker. Replies whose `method` differs from the pending request are dropped
  (late replies to earlier requests).
- One `setPilot` combines state, colour/temperature/scene and dimming (no flash between steps).
- `sendGroup` sends every bulb's datagram back-to-back before waiting for any reply (no
  "popcorn" effect), then collects replies.
- Discovery: unicast to manual and cached hosts; broadcast `registration register:false` +
  `getPilot` every second for 5 s when the multicast entitlement works
  (`DiscoveryOptions.broadcastAvailable` or `BroadcastCapability.detect() == .entitled`);
  otherwise (or when broadcast finds nothing) a unicast `getPilot` sweep of the Wi-Fi /24
  (1 s per host, 32 in flight).
- Push: `start()` (foreground) binds UDP 38900, sends `registration register:true` with the
  current Wi-Fi IP to every bulb now and every 20 s, and polls `getPilot` every 30 s for bulbs that
  have not pushed for 33 s. `stop()` (background) closes the listener.
- A bulb that stops answering at its cached IP is marked unreachable and located again by a
  background sweep/broadcast; pushes from a new IP also update the cache.

## Signing (firmware 1.34+)

Bulbs on fw 1.34+ in the WiZ app's **"Only verified controls"** mode reject unsigned writes with
`{"code":-32602,"message":"Invalid params","sigTs":...}`. Reads and `registration` stay unsigned.

A signed request (byte-identical to `tools/probe/wiz.mjs`):

```json
{"id":1,"method":"setPilot","params":{"state":true,"sigTs":1790000000},"env":"pro","hmac":"oVfeexiMeoOHVfY6lr7GA4t1kPID+9ioR/s8JDyLv6k="}
```

1. Key: the per-home `udp_signing_key`, 32 hex characters, hex-decoded to 16 bytes.
2. `sigTs` (unix seconds) is appended to `params` (replaced in place if already present), keeping
   the existing key order, as JavaScript `{...params, sigTs}` does.
3. `hmac` = base64(HMAC-SHA256(key, compact JSON of the whole `params` object)) with
   `JSON.stringify` formatting (no spaces, insertion order).
4. `env:"pro"` and `hmac` are appended at the top level.

Test vectors (key `00112233445566778899aabbccddeeff`): `{"state":true,"sigTs":1790000000}` ->
`oVfeexiMeoOHVfY6lr7GA4t1kPID+9ioR/s8JDyLv6k=` (wiz.mjs / Python `hmac`),
`{"state":true,"sigTs":1790441723}` -> `vARMv4JpVsxYabcBovABd25ISBzYT8+71v0CUtpU1sg=` (pywizlight PR #216).
A `sigTs` 30 s old was accepted and 60 s old rejected on real hardware; the provider learns each
bulb's clock offset from the `sigTs` in its replies and signs with the bulb's time.

### The two user paths during pairing

`pair` reads `getSystemConfig`, `getModelConfig`, `getUserConfig` and `getPilot`, then sends a
probe `setState` to the light's current state (no visible change):

- Success: no signing needed.
- -32602 with `sigTs`: if a key is already stored it is tried first; otherwise the user chooses:
  1. **Import the key file** (`PairingInteraction.importFile`): WiZ app > Home settings >
     Integrations > Local integrations > export. Any JSON containing `udp_signing_key` (at any
     depth) is accepted.
  2. **Paste the key** (`PairingInteraction.secureText`): the raw 32-hex key or the whole JSON.
  3. **"Allow all controls"** (`PairingInteraction.confirm`): WiZ app > Settings > Security; the
     probe is repeated afterwards.

  A key is validated (format, then a signed probe) before it is stored in the Keychain under
  `SecretKey(brand: .wiz, owner: "home", item: "udp_signing_key")`; the provider then exposes
  `ProviderAccount(id: "wiz:home")`. Three failed attempts throw `authenticationRequired(.wiz)`.

If a bulb starts demanding signatures later (firmware update, setting changed) the stored key is
used automatically. A rejected key (-32605, e.g. rotated in the WiZ app) emits
`needsReauthentication(accountID: "wiz:home")`; replace it with `setSigningKey(_:)`.
Pushes with a signature that does not verify against the stored key are dropped.

## iOS notes

- **Local Network:** every path needs `NSLocalNetworkUsageDescription`; a denied permission shows
  up as send failures.
- **Broadcast needs the managed `com.apple.developer.networking.multicast` entitlement** and BSD
  sockets (Network.framework cannot broadcast). Without it `BroadcastCapability` reports
  `.notEntitled` and discovery falls back to the unicast /24 sweep, plus cached and manually typed
  IPs. Manual hosts must be IPv4 addresses.
- The 38900 listener does not survive suspension: call `stop()` when the app goes to the
  background and `start()` when it returns, which re-registers with the current Wi-Fi IP.

## Known quirks

- **Mode exclusivity:** a bulb is in colour (`r,g,b`) or white (`temp`) mode or running a scene;
  each command switches modes. If a pilot reports both `temp` and RGB, `temp` wins. A command with
  both a scene and a colour sends the scene.
- **Dimming floor:** `dimming` is 10-100 %; brightness `0...1` maps through
  `ColorMath.deviceValue(forBrightness:in: 10...100)`, so any positive brightness is at least 10 %.
  Brightness 0 (or `on: false`) sends only `{"state":false}`, because changing other parameters
  turns the light on.
- **IP changes:** bulbs often get new DHCP addresses after power cuts. Everything is keyed by MAC;
  a silent bulb is located again by sweep/broadcast, and a push from a new IP updates the cache.
- While a scene runs, `{"state":true}` may succeed without a visible change.
- `getModelConfig`/`getUserConfig` return -32601 on old firmware; both are optional.
- Fan control (`fanState`, `fanSpeed`, ...) of `FANDIM`/`DDTW` modules is not exposed: LightCore
  has no fan model yet. Only the light part is controlled.
