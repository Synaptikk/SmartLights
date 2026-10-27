# HueKit

Philips Hue bridge support for SmartLights. Local only: CLIP v2 over HTTPS on the LAN, no Hue account and no cloud. Tasks T1.1 and T3.8 (Entertainment streaming). Background research: `research/research_hue.md` §1, §2, §5, §6, §9.

| Product | Builds on | Contains |
|---|---|---|
| `HueCodec` | Linux + Apple | Lenient Codable models for `light`, `grouped_light`, `room`, `zone`, `scene`, `device`, `bridge`, `zigbee_connectivity`, `entertainment_configuration`, `geofence_client`. Also the `{errors,data}` envelope, the SSE event model, `HueResourceStore` (raw + typed mirror, partial-update merge, mapping to `Light`/`LightScene`, resync diff), request bodies, the group planner, v1 pairing and `/api/config` parsing, `discovery.meethue.com` parsing and `HueError` mapping. HueStream v2 frame encoder/decoder (`HueStreamFrame`), `HueEntertainmentAction` and `HueClientKey` (PSK hex decoding) |
| `HueKit` | Linux + Apple | `HueProvider` actor (`LightProvider`) running on an injected `HueTransport`, plus `HueRootCertificates`. `URLSessionHueTransport` (URLSession, NetKit `TrustingSessionDelegate`/`SSEClient`/`BonjourBrowser`) is Apple-only. `HueEntertainmentSession` (send loop, idle stop) runs on an injected `HueDTLSConnector`; `NWDTLSConnector` (Network.framework DTLS-PSK) is Apple-only |

The provider logic is platform-neutral, so `swift test` in the `swift:6.1` container covers it with a mock transport. The `FakeHueBridge` integration tests (`Tests/HueKitTests/FakeHueBridgeIntegrationTests.swift`) exercise the real URLSession transport, so they run on macOS CI only.

> Product naming: the root `project.yml` comment suggests `product: HueProvider`. This package exposes **`HueKit`** (and `HueCodec`), so link `HueKit` when the package is registered.

## Setup in the app

```swift
import HueKit
let hue = HueProvider(secrets: KeychainSecretStore(accessGroup: group),
                      pinStore: keychainBackedTOFUPinStore)          // persistent TOFU pins
for device in pairedHueBridges { await hue.addBridge(device) }       // restore on launch
let lights = try await hue.loadLights()                              // also opens the event streams
```

Info.plist needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `_hue._tcp`. Call `disconnectEventStreams()` when the app goes to the background and `connectEventStreams()` when it returns to the foreground. Use `updateHost(bridgeID:host:)` when discovery finds a bridge at a new IP. Bridges are keyed by bridge id, never by IP.

Ids:
- light: `hue:<BRIDGEID>/<light uuid>`
- scene: `hue:<BRIDGEID>/<scene uuid>`
- `providerRef`: `<BRIDGEID>/<uuid>`

## Discovery

`discover(options:)` runs these sources in parallel until `options.timeout`, deduplicating by bridge id:
- Bonjour `_hue._tcp`. If the TXT record has `bridgeid`, the bridge is emitted right away; otherwise it is probed.
- `GET https://discovery.meethue.com/`, at most once per 60 s. The cached answer is reused in between because the broker rate-limits. Each entry is probed; entries that cannot be reached are still offered with `metadata["confirmed"] = "false"`.
- `manualHosts` and `cachedHosts`. Accepted forms are `ip`, `ip:port`, `[v6]:port` and `https://ip/`.

Probe: unauthenticated `GET /api/config`, HTTPS first with an HTTP fallback on transport failure. Over HTTPS the certificate's CN must equal the returned `bridgeid`. Metadata comes from the same response: `modelid` (`BSB002` = Bridge v2, `BSB003` = Bridge Pro), `swversion`, `apiversion` and `scheme`.

## Pairing flow

1. Probe the host to confirm the bridge id. If the discovered id differs, pairing fails with a mismatch.
2. `PairingInteraction.confirm("Press the round button on the Hue Bridge, then tap Continue")`. Answering "no" throws `LightCoreError.userCancelled`.
3. `POST https://<ip>/api` with `{"devicetype":"SmartLights#iphone","generateclientkey":true}`. On `[{"error":{"type":101}}]` it retries every second for up to 30 s, posting `status("Waiting for the link button... N s")`. After 30 s it throws `LightCoreError.timeout`.
4. On `[{"success":{"username","clientkey"}}]`, both values are stored in `SecretStore`:
   - `SecretKey(brand: .hue, owner: <BRIDGEID>, item: "appkey")` holds `hue-application-key`.
   - `SecretKey(brand: .hue, owner: <BRIDGEID>, item: "clientkey")` holds the Entertainment DTLS PSK.

   Keys are never logged (`Log.redact`).

The returned `PairedDevice` has `id = BRIDGEID`, `hostHint`, `port`, and `metadata["scheme"/"modelid"/"swversion"/"apiversion"/"bridgePro"]`. Pass it back to `addBridge` on the next launch.

## TLS

- Every request that carries the app key uses a per-bridge URLSession with NetKit `TrustEvaluator`:
  - anchors come from `Sources/HueKit/Resources/hue-roots.pem`;
  - `SecPolicyCreateBasicX509` is used because we connect by IP;
  - **the leaf CN must equal the bridge id**.
- Older bridges serve a self-signed certificate (issuer = subject, CN = bridge id). Those are accepted with **trust on first use**: the SHA-256 of the certificate is pinned per bridge id in the `TOFUPinStore` at pairing time. A different certificate later is rejected.
- `hue-roots.pem` must hold **two Signify roots**:
  1. `CN=root-bridge, O=Philips Hue, C=NL` (2017 to 2038, ECDSA P-256), used by Bridge v2. It is included, taken from the Hue-Sync repository.
  2. The **Hue Bridge Pro** root. **TODO (user):** research could not fetch it because it sits behind the developer login. Paste it into the marked placeholder section of `hue-roots.pem`. Until then, a Bridge Pro with a CA-signed certificate fails TLS. A self-signed Pro still works through TOFU.
- The `/api/config` identity probe is the only request that accepts any certificate. It sends no secrets and checks CN == returned bridge id.

## Rate limits and request policy

- At most **3 concurrent requests per bridge**. aiohue says "the bridge denies more than 3".
- HTTP **429/503** are retried with a backoff of `0.25 s * attempt`, up to 10 attempts. After that the provider throws "bridge busy".
- Token buckets (LightCore `RateLimiter`): **10/s per light** and **1/s per grouped_light**. Scene recalls count against their room's group bucket.
- `send` builds **one PUT** containing `on` + `dimming.brightness` + colour + `dynamics.duration` (from `transition`):
  - colour is `color.xy` (clamped to gamut A/B/C) or `color_temperature.mirek` (clamped to the light's `mirek_schema`);
  - brightness > 0 without an explicit `on` also switches the light on;
  - brightness 0 switches it off.
- `sendGroup` uses a room/zone/bridge_home `grouped_light` for every room or zone whose lights (2 or more) are **all** targeted, largest group first. The remaining lights get parallel per-light PUTs. Commands with an effect always fan out, because groups have no effects.
- Coalescing slider drags is up to the UI. Signify: "the REST API ... should not be used for continuous fast light updates". Fast effects are for the Entertainment API (phase 3).

## Event stream

- One `GET /eventstream/clip/v2` per bridge through NetKit `SSEClient`, with headers `hue-application-key` and `Accept: text/event-stream`.
- Settings: 90 s read timeout, `Last-Event-ID` resume, and reconnect with `ExponentialBackoff.hueEventStream`.
- Keep-alive (the same approach as aiohue): on first connect, find or create a `geofence_client` named `smartlights_<random>`, then rename it every 60 s. This provokes traffic, so a dead socket hits the read timeout.
- After a gap of more than 60 s (or on the first connect when the cached state is older than that), the provider refetches everything and emits the diff.
- Events emitted:
  - `stateChanged`, `lightAdded`, `lightRemoved`, `lightUpdated` (name, room or capabilities changed);
  - `reachabilityChanged`, from `zigbee_connectivity`;
  - `scenesChanged` (adds, deletes, renames; status-only changes do not count);
  - `connectionChanged`;
  - `needsReauthentication` (on 401/403);
  - `error`.
- A 404 on the stream means the firmware has no CLIP v2. The provider reports it and stops retrying.

## Error mapping

| Bridge says | `HueError` | Thrown to callers (`LightCoreError`) |
|---|---|---|
| v1 error 101 while pairing (after 30 s) | `.linkButtonNotPressed` | `.timeout` |
| HTTP 401/403, v1 error 1, no stored key | `.unauthorized` / `.notPaired` | `.authenticationRequired(.hue)` + `needsReauthentication` event |
| HTTP 404 on `/clip/v2/resource` or the event stream | `.v2Unsupported` | `.unsupported` |
| HTTP 404 on a resource | `.resourceNotFound` | `.protocolError` |
| HTTP 429/503 after retries | `.bridgeBusy` | `.transport` |
| TLS rejected / connection failed / timeout | `HueTransportError` | `.transport` / `.unreachable` / `.timeout` |

## Tests

- `swift test` on Linux (Docker):

  ```
  docker run --rm -v "<repo>\Packages:/pk" -w /pk/Providers/HueKit swift:6.1 swift test
  ```

  It runs the `HueCodecTests` and the mock-transport `HueKitTests`. Codec fixtures are a trimmed copy of aiohue's `tests/fixtures/v2_resources.json` (Apache-2.0, see `NOTICES.md`) plus a hand-written `mini_resources.json`.
- On macOS CI, `FakeHueBridgeIntegrationTests` also runs against `Packages/Simulators`. It covers TLS with TOFU, pairing with the link button, list / toggle / colour / scene, grouped_light, and an external change arriving over SSE within 1 s.

## To verify once logged into developers.meethue.com

- [ ] The Bridge Pro root CA PEM (paste it into `hue-roots.pem`). Also confirm that the `root-bridge` PEM matches the "Using HTTPS" page.
- [ ] Exact rate-limit wording: 10 commands/s per light, 1/s per grouped_light, and the concurrent-connection limit.
- [ ] Event-stream keep-alive semantics: does the bridge ever send keep-alive comments? Is renaming a geofence_client still the recommended approach?
- [ ] Allowed `devicetype` length and characters, and whether `generateclientkey` is still required for Entertainment.
- [ ] `scene` `recall.action` values (`active`, `dynamic_palette`, `static`) and `dynamics.duration` limits.
- [ ] Whether `discovery.meethue.com` documents a rate limit (we poll at most once per minute).
- [ ] Bridge Pro: certificate CN format and whether any CLIP v2 differences affect lights, scenes or the event stream.

## Entertainment streaming (T3.8)

Fast colour streaming to an Entertainment area (`entertainment_configuration`), as used for sync and music effects. `research/research_hue.md` §2.

```swift
let areas = try await hue.entertainmentConfigurations(bridgeID: id)          // pick one, show its name
var config = HueEntertainmentSession.Configuration()
config.photosensitivityWarningAcknowledged = userAcceptedWarning               // required, see below
let session = HueEntertainmentSession(provider: hue, bridgeID: id, configurationID: area.id, configuration: config)
await session.setChannels(area.channelIDs.map { .rgb($0, red: 1, green: 0.2, blue: 0) })
try await session.start()
// every animation frame (any rate; the session sends at 25...50 Hz):
await session.setChannels(next)
await session.stop()                                                          // lights return to their previous state
```

What `start()` does:
1. Throws `photosensitivityWarningNotAcknowledged` unless the app set the flag.
2. Reads the app key (PSK identity) and `clientkey` (PSK, 32 hex digits → 16 bytes) from `SecretStore`. A bridge paired without `generateclientkey` gives `missingClientKey`: pair again.
3. `GET entertainment_configuration/{id}`. If `status == "active"` another app is streaming, and it throws `areaInUse` unless `takeOverActiveStream` is set (same default as HueEntertainmentKit's `.failIfActive`).
4. `PUT entertainment_configuration/{id}` `{"action":"start"}`.
5. DTLS 1.2 to `<bridge host>:2100` with `NWDTLSConnector`: `NWProtocolTLS.Options` with min/max `DTLSv12`, `sec_protocol_options_append_tls_ciphersuite(TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8)`, `sec_protocol_options_add_pre_shared_key(psk, identity)`, `NWParameters(dtls:udp:)`. The handshake must finish within `handshakeTimeout` (5 s); otherwise it sends `{"action":"stop"}` and throws.
6. A send loop at `frameRate` (default 50, clamped to 25...50 Hz) sends one HueStream v2 datagram per tick (more than 20 channels: several datagrams with the same sequence id). It re-sends the last colours on every tick, which is also what keeps the bridge streaming (it drops the area after a few seconds without traffic). Ticks are not made up when the loop falls behind.

The session stops (closes DTLS and sends `{"action":"stop"}`) on `stop()`, when `setChannels` has not been called for `idleTimeout` (default 10 s, `StopReason.idle`), or when a send fails (`.failed`). `stateUpdates` reports `.starting`, `.streaming` and `.stopped(reason)`.

HueStream v2 datagram (`HueStreamFrame`, big-endian): `"HueStream"`, `0x02 0x00`, sequence, `0x00 0x00`, colour space (`0x00` RGB, `0x01` xy + brightness), `0x00`, 36-byte lower-case configuration id, then up to 20 × (channel id, three UInt16). `HueStreamChannel.rgb(...)` / `.xy(...)` scale 0...1 to 0...65535.

### Photosensitivity warning (app layer, required)

Signify's developer terms require a health warning before fast or strobing effects. The session enforces that the app asked: `start()` throws until `photosensitivityWarningAcknowledged` is true. The app must:
- show the warning (the text already used in `App/Features/Lights/LightDetailView.swift`) before the first Entertainment session and before any effect that flashes, and set the flag only after the user accepts;
- not set the flag silently or from a stored default the user never saw;
- offer a visible Stop control while streaming; stopping restores the previous light state.

### Tests

- `HueCodecTests/HueStreamTests.swift` (Linux): byte-exact RGB and xy frames against bytes produced independently with Python `struct.pack`, header offsets, id validation, 20-channel limit and splitting, quantisation, decode round trip, PSK hex decoding, `entertainment_configuration` decoding.
- `HueKitTests/HueEntertainmentSessionTests.swift` (Linux + macOS, fake `HueDTLSConnector`): start/stop PUT bodies, credentials, photosensitivity gate, frame rate and sequence ids, idle auto-stop, `areaInUse` and take-over, stop after a handshake or send failure.
- `HueKitTests/DTLSLoopbackTests.swift` (macOS CI only): a DTLS 1.2 PSK echo server on loopback built with Network.framework `NWListener` and the same parameters. It checks the handshake, an echoed frame, that a wrong PSK fails, and a full session streaming to it. swift-nio-ssl has no DTLS support, so the echo server cannot be built with NIO (and so cannot run on Linux).
- Not covered without hardware: that a real bridge accepts the cipher suite negotiated by Apple's DTLS stack. HueEntertainmentKit uses the same options against real bridges. To verify on hardware, see `docs/HARDWARE-NOTES.md` (T3.8).

## Signify developer terms (must ship with the app)

- The app must tell users that **it is not a Signify app, product or service**. Show this in About / Settings → Acknowledgements, e.g. *"SmartLights is not a Signify app, product or service. Philips Hue is a trademark of Signify."*
- Descriptive use such as "works with Philips Hue" is fine. Do not use Hue or Signify logos or trade dress, and do not use "Hue" in the app name.
- Show a photosensitivity warning before any fast or strobing effect.
- No multi-user cloud aggregation of Hue control, and no security or surveillance features.
