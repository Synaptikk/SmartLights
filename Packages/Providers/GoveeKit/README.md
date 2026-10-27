# GoveeKit

`LightProvider` for **Govee** (`Brand.govee`): the local **LAN API** first, the official
**Developer API** (cloud, API key) as a per-device fallback and for models without LAN support.

| Product | Imports | Builds on | Contains |
|---|---|---|---|
| `GoveeCodec` | Foundation, LightCore | Linux, macOS, iOS | LAN messages (`scan`, `devStatus`, `turn`, `brightness`, `colorwc`), LAN SKU allow-list, Developer API request/response models, capability/state/command mapping, daily budget maths |
| `GoveeProvider` | + NetKit (`UDPSocket` only on Apple) | Linux, macOS, iOS | `actor GoveeProvider: LightProvider`, `GoveeLANTransport`/`GoveeHTTPTransport` protocols, `URLSessionGoveeHTTPTransport` (Apple + Linux), `NetKitGoveeLANTransport` (`#if canImport(Darwin)`) |

`LINUX_OK`: both products and all tests build and run in the `swift:6.1` container
(`docker run --rm -v "<repo>:/src" -w /src/Packages/Providers/GoveeKit swift:6.1 swift test`).

## For the user (wizard content, see `docs/ONBOARDING-WALKTHROUGHS.md` §6)

1. **Turn on LAN Control.** Govee Home app > the device > Settings (gear) > **LAN Control**.
   The toggle only exists on LAN-capable models and can take a few minutes to appear after a
   firmware update. Phone and light must be on the same Wi-Fi (2.4 GHz for the light).
   **[verify path]** – Govee's guide (https://app-h5.govee.com/user-manual/wlan-guide) is JS-only.
2. **Optional: API key** for cloud control (needed for models without LAN API, and as fallback
   when the light is not reachable locally): Govee Home > Profile > Settings > **Apply for API Key**,
   fill in the form, the key arrives by e-mail. Paste it when SmartLights asks
   "Paste your Govee API key". The key is stored only in the Keychain (`SecretStore`,
   `com.sinap.smartlights.govee` / `govee-developer-api/apiKey`) and never logged.
3. **SKU limits.** Only ~270 models implement the LAN API (strips, lamps, panels, outdoor lights);
   most plain A19 bulbs (e.g. the Bluetooth-only H6001) do not; a few Wi-Fi bulbs (H6006, H6008)
   are on the list. Those can only be controlled via the
   API key. Brand-new 2025-26 Govee bulbs are often Matter: add them through Apple Home instead.
4. **Limits of the cloud:** about 10,000 requests per day per key; SmartLights spends at most 70 %
   of that on status polling and keeps the rest for your commands.

## Protocol summary

**LAN** (no auth, plaintext JSON over UDP; govee-local-api `message.py`, homebridge-govee `lan.js`):

| Step | Datagram | To | Reply |
|---|---|---|---|
| Discover | `{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}` | `239.255.255.250:4001` (or unicast `<ip>:4001`) | `scan` with `ip`, `device`, `sku`, `bleVersionHard/Soft`, `wifiVersionHard/Soft` → client **:4002** |
| Power | `turn {value: 0/1}` | `<ip>:4003` | none |
| Brightness | `brightness {value: 1...100}` | `<ip>:4003` | none |
| Colour | `colorwc {color:{r,g,b}, colorTemInKelvin}` (kelvin 0 = RGB; RGB 0/0/0 + kelvin = white) | `<ip>:4003` | none |
| Status | `devStatus {}` | `<ip>:4003` | `devStatus {onOff, brightness, color, colorTemInKelvin}` → **:4002** (no device id: correlated by source IP) |

**Developer API** (`https://openapi.api.govee.com`, header `Govee-API-Key`):
`GET /router/api/v1/user/devices` (capabilities per device), `POST /router/api/v1/device/control`
(`{requestId, payload:{sku, device, capability:{type, instance, value}}}`),
`POST /router/api/v1/device/state`. Mapped capabilities: `on_off/powerSwitch`, `range/brightness`,
`color_setting/colorRgb` (`r<<16 | g<<8 | b`), `color_setting/colorTemperatureK`,
`dynamic_scene/*` options as effects (`"<instance>/<option name>"`). Documented limits: device list
30/min per account; control 2/s (burst 6) per device and 12/s (burst 80) per account; state 30/min
per device. Rate-limit headers are parsed in several spellings (`API-RateLimit-*`, `X-RateLimit-*`,
`Rate-Limit-*`) **[verify]** with a real key.

## Provider behaviour

- **Ids:** `govee:<device>` where `device` is the MAC-like id (`1F:80:C5:32:32:36:72:4E`), identical on
  LAN and cloud, so a light found both ways is one light. IPs are hints (`PairedDevice.hostHint`,
  `Light.providerRef = "lan:<ip>"` or `"cloud:<sku>"`).
- **Discovery** (`discover(options:)`): opens the single UDP socket on 4002, then
  - multicast `scan` (3×) when `options.broadcastAvailable` and `.broadcast` is allowed;
  - unicast `scan` to `manualHosts` (`.manual`) and `cachedHosts` + known IPs (`.cached`), always;
  - `/24` unicast sweep (`SubnetSweeper`, current Wi-Fi) when broadcast is **not** available;
  - the cloud device list (`.cloud`) when an API key is stored.
  Results are merged by id; metadata flags `lan` = `seen`/`capable`/`unsupported` (LAN allow-list)
  and `cloud` = `true`/`false` (LAN-only devices that are not on the account).
- **Pairing:** LAN devices pair without prompts. `GoveeProvider.cloudAccountDevice` (or any device
  that is not reachable on the LAN) asks `secureText("Paste your Govee API key")`, validates it with
  `GET /user/devices`, stores it and sets `account`; all lights of the account become lights.
  `setAPIKey(_:)` / `removeAPIKey()` for Settings.
- **Commands:** `LightCommand.normalized(for:)` first. LAN is used when the device answered on the
  LAN within the last 35 s (or when there is no cloud fallback); otherwise the Developer API. Order:
  power on, brightness, colour; "off" sends only `turn 0`. The LAN API has one attribute per
  datagram (no combined brightness+colour command). Effects (cloud `dynamic_scene`) always go via
  the cloud. Commands are serialised per device; `sendGroup` fans out concurrently and reports
  `partialFailure`.
- **Rate limits:** per-device LAN limiter (10/s, burst 5); cloud limiters per the documented limits;
  a daily quota (`GoveeDailyQuota`, UTC day **[verify]**) shared by polling and commands, polling stops
  when only the 30 % command reserve is left.
- **Polling** (`start()`/`stop()`): `devStatus` every 10 s for LAN lights (re-scan every 6th round
  to catch IP changes); a LAN light silent for 35 s becomes unreachable unless it has a cloud
  fallback. Cloud `device/state` polling for lights not reachable on the LAN, interval
  `max(60 s, 86400 s × devices / 7000)` (`GoveeCloudBudget.pollInterval`).
- **Events:** `stateChanged` (polls and optimistic updates), `reachabilityChanged`, `lightAdded`/
  `lightUpdated`/`lightRemoved` (cloud list changes, IP changes), `needsReauthentication` (401/403),
  `error` (multicast failures, socket errors).

## Multicast entitlement (iOS)

Sending the multicast `scan` needs `com.apple.developer.networking.multicast` (PLAN.md §4.3).
Without it `UDPSocket.send` fails with `EACCES`; the provider reports an `.error` event and relies
on unicast scans to cached/manual hosts and the /24 sweep (pass `broadcastAvailable: false`).
Unicast commands and receiving replies on 4002 only need Local Network permission. If another app
on the phone holds UDP 4002 (another Govee controller), `SO_REUSEPORT` lets both bind but replies
may go to either **[verify]**.

## Tests

- `GoveeCodecTests` (fixtures in `Tests/GoveeCodecTests/Fixtures`: LAN scan/devStatus from the
  Govee WLAN guide format, cloud device list/state/control shaped like the developer-docs examples).
- `GoveeProviderTests`: a fake LAN device on real UDP sockets (`FakeGoveeUDPDevice`, POSIX sockets,
  Linux + macOS), an in-memory multi-device LAN (`FakeLANNetwork`: multicast, sweep, entitlement
  denied), and a fake Developer API on a loopback HTTP server (`FakeGoveeCloud`) driven through
  `URLSessionGoveeHTTPTransport`. On Apple platforms one test also runs `NetKitGoveeLANTransport`
  against the UDP fake.

## Open items / [verify]

- LAN Control menu path, unicast `scan` to `<ip>:4001` on all firmware, `devStatus` reply port.
- Real rate-limit header names and the daily reset time of the Developer API.
- Segment colours, music mode and the LAN `ptReal` scene frames are not implemented.
- Light scenes (`/router/api/v1/device/scenes`) are not fetched; only scene options already listed
  in the device list (snapshots, DIY) are exposed as effects.

Attribution: the LAN SKU table is derived from `govee-local-api` (Apache-2.0), see `NOTICES.md`.
