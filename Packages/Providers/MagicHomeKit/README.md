# MagicHomeKit

Magic Home / Zengge / LEDENET (also sold as Daybetter, Kuled, Surplife and many no-name strip
controllers and bulbs) over the **LAN protocol**: binary messages on TCP 5577, UDP 48899 discovery,
no authentication. Task T2.5 (T2.5b, together with ShellyKit).

| Product | Builds on | Contains |
|---|---|---|
| `MagicHomeCodec` | Linux + Apple (Foundation + LightCore) | Message builders with checksums, outer wrapper, 14-byte state, stream framing, UDP discovery text, model-id table, raw state <-> `LightState`/`LightCommand` mapping |
| `MagicHomeProvider` | Linux + Apple; real transports Apple only | `actor MagicHomeProvider: LightProvider` over `MagicHomeNetworkEnvironment`; `NWConnection` TCP + NetKit UDP behind `#if canImport(Network)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider tests
against the in-process fake device.

The wire format was re-implemented from the behaviour documented by
[flux_led](https://github.com/lightinglibs/flux_led) (LGPL-3.0). No flux_led code was copied or
translated: only protocol facts (byte layouts, model ids, firmware thresholds) and the byte vectors
its test suite asserts. See `NOTICES.md`.

## Codec

- **Checksum**: every message of the supported dialects ends with `sum(bytes) & 0xff`.
- **State query** `81 8a 8b 96` -> 14-byte state
  `81 <model> <23 on|24 off> <pattern> <mode> <speed> <r> <g> <b> <warm> <version> <cold> <colour mode> <cs>`.
- **Power** `71 23 0f a3` (on) / `71 24 0f a4` (off); reply/push `xx 71 23|24 cs` (checksum not checked,
  real devices get it wrong).
- **Levels**: 8-byte `31 r g b w <mode> 0f cs`, 9-byte `31 r g b ww cw <mode> 0f cs`; write mode `00` all,
  `f0` colours only, `0f` whites only; `0x41` instead of `0x31` = not persisted
  (`Configuration.persistLevels`).
- **CCT dialect** (0x09, 0x1C): `35 b1 <cold share %> <brightness %> 00 00 00 03 cs`; 0x1C wraps every
  message in `b0 b1 b2 b3 00 01 01 <counter> <len16> <inner> cs`.
- **Effects**: `61 <pattern> <delay> 0f` or, on dimmable-effect firmware, `38 <pattern> <delay> <brightness %>`.
  Patterns 0x25-0x38 (+0x24, 0x39, 0x3A on dimmable firmware) are exposed as `EffectDescriptor`s;
  strobes and "colour jump" are flagged `isFast` (photosensitivity warning).
- **Framing**: `MagicHomeFramer` splits the TCP stream by message type (state 14, power 4, clock 12,
  wrapper by its length field...) and unwraps outer messages.
- **Model table** (`MagicHomeModel.all`): model id -> name, dialect per firmware version, channel
  layout (switch, dim, CCT, RGB, RGBW, RGBWW, RGB-or-white, RGB-or-CCT), per-mode layouts of multi-mode
  controllers, channel maps (white in the red byte, CCT in red/green), "always writes all". Unknown ids
  are treated as 8-byte devices whose layout follows the mode byte.
- **Mapping**: brightness scales the channels (the protocol has no separate dimmer): colour and
  brightness go out in one levels message. Kelvin uses the vendor app's linear 2700-6500 K warm/cold mix.
  On RGB/W bulbs a Kelvin request selects the white LEDs (`ColorMode.white` in the state).
  `brightness 0` without `on` turns the light off; levels/effects on firmware that does not turn on by
  itself get a power-on message first.

Not supported (pairing throws `LightCoreError.unsupported`): addressable strips (0xA1-0xA7),
Christmas/string lights (0x10, 0x1A), the original no-checksum protocol (0x01-0x03), 25-byte bulbs
(0x35 firmware >= 10) and the extended-state 0xB6 controller. Timers, music mode, remote pairing and
custom effects are not implemented.

## Provider

- **Identity**: `LightID` = `magichome:<mac>` (from the UDP reply). IP is a hint, replaced when
  discovery finds the MAC elsewhere (the TCP session is then reopened).
- **Discovery** (`discover(options:)`, ends at `options.timeout`):
  1. broadcast `HF-A11ASSISTHREAD` to UDP 48899 when `options.broadcastAvailable` (multicast
     entitlement);
  2. otherwise a unicast sweep of the Wi-Fi /24 with the same datagram (`SubnetSweeper`, 32 in flight,
     600 ms per host); devices answer unicast too, no entitlement needed;
  3. always: `cachedHosts`, known devices and `manualHosts`. A manual host that ignores UDP is
     identified over TCP and reported with a provisional `ip:<host>` id; pairing needs the MAC and asks
     UDP again.
  Every hit gets one state query so the model and firmware are known.
- **Pairing**: no credentials. Asks for an IP when there is none (Add by IP), learns the MAC, reads the
  state, refuses unsupported dialects, returns a `PairedDevice` with metadata `hardware`, `modelNumber`,
  `version`, `protocol`, `layout`. Call `restore(_:)` on launch.
- **Connections**: one persistent TCP connection per device (the firmware accepts few clients),
  opened lazily and reopened after errors. State queries wait 2 s and are retried twice on fresh
  connections. Commands are fire-and-forget (the protocol has no acknowledgement): the predicted
  state is applied and emitted; a failed write reconnects once and resends.
- **Events**: push firmware (dimmable-effect, socket and CCT dialects) reports external changes on the
  open connection -> `.stateChanged`. `start()` also polls every 10 s (`pollInterval`) for older
  firmware and reachability; `stop()` pauses, `shutdown()` closes every connection.

## App wiring

```swift
let magicHome = MagicHomeProvider.live()
await magicHome.restore(storedMagicHomeDevices)
await registry.register(magicHome)
await magicHome.start()
```

`DiscoveryOptions.broadcastAvailable` should come from `BroadcastCapability.detect()`.

## Tests

- `MagicHomeCodecTests`: checksums; byte vectors asserted by flux_led's test suite (state query, power,
  `31 01 19 50 00 f0 0f 9a`, `31 00 00 00 19 0f 0f 68`, 9-byte whites, preset patterns
  `61 38 10 0f b8` / `38 28 10 32 a2`) and the wrapped CCT vectors from its protocol docstrings; state
  parsing and rejection; framing of split/coalesced/wrapped/unknown messages; discovery and `AT+LVER`
  text; model table; capability, state and command-plan mapping per layout.
- `MagicHomeProviderTests`: `FakeMagicHomeDevice` (in the test target) answers UDP discovery and
  speaks the TCP dialect of its model over in-memory connections. Covers broadcast and sweep
  discovery, pairing (incl. Add by IP and the no-UDP case), one persistent connection, one levels
  message per command, power-on ordering, push events, polling, dropped-query retries, offline and
  recovery, the wrapped CCT lamp, unsupported models, IP change, restore and group partial failure.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/MagicHomeKit swift:6.1 swift test
```

## Not verified yet

- No real-hardware run: the owner has not listed a Magic Home device. Probe and record results in
  `docs/HARDWARE-NOTES.md` before relying on the model table for a specific device.
- The Apple transport (`NWMagicHomeConnector`, NetKit broadcast) compiles only on macOS CI.
- Some legacy firmware only answers discovery when the request's source port is 48899; the live
  broadcast uses an ephemeral port (unicast sweep and manual IP still work for those).
