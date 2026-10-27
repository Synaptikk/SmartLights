# HomeAssistantKit

Home Assistant support for SmartLights over the [WebSocket API](https://developers.home-assistant.io/docs/api/websocket) (`/api/websocket`). Every `light.*` entity of a Home Assistant server shows up as a SmartLights light, and `scene.*` entities show up as vendor scenes. This is the route for brands with no direct path (Zigbee via ZHA/Zigbee2MQTT, Sengled, Cync, Wyze) and for automations that keep running when the phone is off. Task T3.6; background in `research/research_brands.md` §5.

| Product | Builds on | Contains |
|---|---|---|
| `HomeAssistantCodec` | Linux + Apple (Foundation, LightCore) | `HAJSONValue`; WebSocket messages (`auth_required`/`auth`/`auth_ok`/`auth_invalid`, `result`, `event`, `pong`, coalesced frames); commands (`subscribe_events`, `unsubscribe_events`, `get_states`, `get_config`, `call_service`, `config/entity_registry/list`, `config/device_registry/list`, `config/area_registry/list`, `ping`); entity state and registry models; HA light attributes → `LightCapabilities`/`LightState`; `LightCommand` → `light.turn_on`/`turn_off`; ids; URL normalisation |
| `HomeAssistantKit` | Linux + Apple | `HomeAssistantProvider` actor (`LightProvider`) over an injected `HAWebSocketTransport`; `HAClient` (one authenticated socket: id correlation, subscriptions, ping). `URLSessionHATransport` (`URLSessionWebSocketTask` + NetKit Bonjour) is Apple-only (`#if canImport(Darwin)`) |

```sh
docker run --rm -v "<repo>/Packages:/pk" -w /pk/Providers/HomeAssistantKit swift:6.1 swift test
```

The provider tests (`Tests/HomeAssistantKitTests`) run the real provider against `FakeHomeAssistant`, an in-package server that speaks the HA protocol: the auth phase, ids, results, `state_changed` broadcasts after `call_service`, registry lists, ping/pong, and server-side drops. They run on Linux and macOS. The codec tests use HA JSON fixtures; see "Fixtures" below.

> We do not use `home-assistant/HAKit`. It is Apple-only, so the codec could not be tested on Linux (PLAN.md D6). The protocol subset needed here is small.

## Setup in the app

```swift
import HomeAssistantKit
let ha = HomeAssistantProvider(secrets: KeychainSecretStore(accessGroup: group),
                               transport: URLSessionHATransport())
for device in pairedHAInstances { await ha.addInstance(device) }    // restore on launch
let lights = try await ha.loadLights()                              // also opens the live connections
```

- Info.plist: add `_home-assistant._tcp` to `NSBonjourServices` for discovery. Without it, Bonjour reports policy-denied and only manual URLs work. `NSLocalNetworkUsageDescription` is needed for LAN URLs. A Nabu Casa URL is plain HTTPS and needs neither.
- Call `disconnectEventStreams()` when the app goes to the background and `connectEventStreams()` when it comes back. The sockets do not survive suspension.
- After the user creates a new token (on a `needsReauthentication` event), call `setAccessToken(_:instanceID:)`.

## Creating a long-lived access token

1. Open Home Assistant in a browser or in the companion app and sign in as the user whose lights the app should control. An administrator is not required: state reads, `call_service` and the registry lists all work for normal users.
2. Click your **user name** (bottom left) to open your profile, then open the **Security** tab.
3. Scroll to **Long-lived access tokens** and click **Create token**. Name it, for example `SmartLights iPhone`, and click **OK**.
4. Copy the token right away. Home Assistant shows it **only once**. It is a long JWT (`eyJ…`), so copy all of it.
5. In SmartLights, choose Add brand → Home Assistant, enter the URL and paste the token.

Tokens are valid for 10 years and can be revoked from the same page. If a token is revoked or mistyped, HA answers `auth_invalid`. The provider then stops reconnecting, emits `needsReauthentication(accountID: <instanceID>)`, and waits for `setAccessToken`. The token is stored only in the Keychain, under `SecretKey(brand: .homeAssistant, owner: <instanceID>, item: "accessToken")`, and is never logged.

## URLs: local and Nabu Casa remote

Pairing asks for two URLs:

- **Home Assistant URL** (required). Examples: `http://homeassistant.local:8123`, `http://192.168.1.10:8123`, `https://ha.example.com`. A bare host such as `homeassistant.local` or `192.168.1.10` becomes `http://<host>:8123`. Paths are stripped. `ws(s)://` is accepted. The socket URL is `ws(s)://<host>[:port]/api/websocket`.
- **Remote URL** (optional), for when the phone is away from home:
  - **Nabu Casa (Home Assistant Cloud)**: in HA go to Settings → Home Assistant Cloud → Remote control. Turn remote access on and copy the `https://<random>.ui.nabu.casa` address. Remote control needs an active Home Assistant Cloud subscription.
  - Your own reverse proxy, DuckDNS + Let's Encrypt, or a VPN (Tailscale/WireGuard) address also works. Anything that serves HA's WebSocket over `wss://` with a publicly trusted certificate is fine. Self-signed certificates are rejected by URLSession.

The provider tries the local URL first and the remote URL second, on every (re)connect. If the base URL already is a Nabu Casa URL, the remote prompt is skipped. A URL discovered via Bonjour with `external_url` in its TXT record fills in the remote URL automatically.

## Ids

- Instance: the HA installation `uuid` from the Bonjour TXT record when discovered that way, otherwise a UUID generated at pairing. It is never the host or IP.
- Light: `homeassistant:<instanceID>/<key>`, where `key` is the **entity registry id**, which survives `entity_id` renames. Entities without a registry entry, such as YAML lights without `unique_id`, use the `entity_id`.
- `providerRef`: `<instanceID>/<entity_id>`. Scene: `homeassistant:<instanceID>/scene.<name>`.
- Room hint: the entity's area, else its device's area (`config/device_registry/list`). Name: `friendly_name`. Hidden or disabled registry entries are skipped.
- If the registry lists fail (old core, error), lights are still loaded, keyed by `entity_id` and without rooms. On later failures the previous registry snapshot is kept so ids stay stable.

## Mapping

HA's colour modes match LightCore's 1:1 (PLAN.md D7): `onoff`, `brightness`, `color_temp`, `hs`, `xy`, `rgb`, `rgbw`, `rgbww`, `white`.

| HA attribute | LightCore |
|---|---|
| `supported_color_modes` | `supportedColorModes`. If missing (legacy cores): `supported_features` bits 1/2/16 → brightness/colour temp/hs, else `.brightness` if `brightness` is reported, else `.onOff` |
| `min_color_temp_kelvin` / `max_color_temp_kelvin` | `minKelvin`/`maxKelvin`. Legacy `max_mireds`/`min_mireds` are converted |
| `supported_features` & 4 / & 32 | `supportsEffects` / `supportsTransition` |
| `effect_list` (minus `"off"`) | `effects`. Names containing strobe/flash/party/disco/… are flagged `isFast` for the photosensitivity warning |
| `state` `on`/`off`/`unavailable` | `isOn`, `reachable` (`unavailable` → unreachable) |
| `brightness` 0-255 | `brightness` 0-1 |
| `color_mode` | `colorMode` (inferred from the present attributes when missing) |
| `color_temp_kelvin` (legacy `color_temp` mireds) | `kelvin` |
| `hs_color` [h, s%] | `hs` (s / 100) |
| `rgb_color`, `rgbw_color`, `rgbww_color`, `xy_color` | `rgb`, `rgbw`, `rgbww`, `xy` |
| `effect` (`"off"` = none) | `effect` |
| `last_updated` | `updatedAt` |

HA clears colour attributes while a light is off, so an off light has no colour state.

Commands are first normalised with `LightCommand.normalized(for:)`, so exactly one colour attribute that the light supports is sent:

- `on: false` or brightness 0 → `light.turn_off` (+ `transition`).
- Otherwise → `light.turn_on` with:
  - `brightness_pct`, 0-100 with two decimals. A positive brightness never goes below 1, because `brightness_pct: 0` turns the light off.
  - One of `color_temp_kelvin`, `hs_color` `[h, s×100]`, `rgb_color`, `rgbw_color`, `rgbww_color`, `xy_color`.
  - `effect`, and `transition` in seconds.
- `sendGroup` sends one `call_service` per distinct payload, with `target.entity_id` set to the list of entities. HA fans that out, and Hue/ZHA groups use their native group commands.
- Scenes: `scene.turn_on`. `callService(_:instanceID:)` can call any other service, for example `script.turn_on`.

## Connection lifecycle

- Connect: open the socket, receive `auth_required`, send `auth`, receive `auth_ok`. Then `subscribe_events` for `state_changed`, plus `entity_registry_updated`, `device_registry_updated` and `area_registry_updated`. Then a full resync: `get_states` and the three registry lists, diffed against the previous snapshot.
- `state_changed` for a known light becomes `stateChanged` (and `reachabilityChanged` when its availability flips). If the name, room or capabilities changed, it becomes `lightUpdated` instead. Unknown, removed or renamed entities and registry events trigger a debounced resync (500 ms), which emits `lightAdded`/`lightRemoved`/`lightUpdated`/`scenesChanged`.
- Heartbeat: `ping` every 30 s. If no `pong` arrives within 10 s, the socket is closed.
- Reconnect: exponential backoff from 1 s, doubling, capped at 60 s, with 20% jitter. Every reconnect resubscribes and resyncs, so changes made while disconnected are picked up. On disconnect, `connectionChanged(false)` and `reachabilityChanged(false)` are emitted for every light.
- `auth_invalid` stops the loop with `needsReauthentication` and does not retry a bad token.
- Commands time out after 10 s. HA `result` errors map to `LightCoreError.protocolError("<context>: <code> <message>")`, and `unauthorized` maps to `authenticationRequired`.
- URLSession's 1 MiB default `maximumMessageSize` is raised to 64 MiB, because `get_states` on large installs is several MB.

## Discovery

- Bonjour `_home-assistant._tcp`, through the transport. HA's zeroconf TXT carries `uuid`, `location_name`, `version`, `internal_url`, `external_url` and `base_url`.
- Manual and cached hosts are normalised and probed: open the socket and read `auth_required`. That confirms it is HA and gives the version. Unreachable hosts are still offered, with `metadata["confirmed"] = "false"`.

## Fixtures

`Tests/HomeAssistantCodecTests/Fixtures`:

- `auth_*.json`, `result_call_service.json`, `result_subscribe.json`, `pong.json` and `event_state_changed.json` are verbatim examples from the WebSocket API docs (developers.home-assistant.io, `docs/api/websocket.md`). `event_state_changed.json` keeps its pre-colour-mode attributes on purpose; it exercises the legacy path.
- `get_states.json` follows the `light` entity `state_attributes` and `capability_attributes` of HA core (`homeassistant/components/light/entity.py`), filled with the entities of HA's demo light platform. The derived hs/rgb/xy hints were computed with HA's published colour formulas; the rgbw/rgbww hints are approximate.
- `entity_registry_list.json`, `device_registry_list.json` and `area_registry_list.json` have the key set asserted in HA core's `tests/components/config/test_{entity,device,area}_registry.py`.
- `result_error.json` and `coalesced.json` follow the documented `result` error shape and the coalesced-messages array.

## Known limitations

- Only `light.*` entities (and `scene.*` as scenes). `switch.*` plugs are not exposed yet.
- `white` mode (lights that support `ColorMode.WHITE`) is mapped, but LightCore has no "white at brightness" command, so only colour and brightness are sent.
- No OAuth/IndieAuth login: long-lived tokens only. This is enough for a personal app and avoids an auth web view.
- `URLSessionHATransport` is compiled and tested only on macOS CI. Its Bonjour TXT parsing has a unit test there. The socket path is covered by the fake transport on Linux.
