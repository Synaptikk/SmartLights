# TPLinkKit

TP-Link **Kasa** and **Tapo** lights over the LAN. Task T2.6.

| Product | Builds on | Contains |
|---|---|---|
| `TPLinkCodec` | Linux + Apple (Foundation + LightCore + swift-crypto) | XOR framing, KLAP v1/v2 hashes and AES-128-CBC session, IOT/SMART JSON, discovery datagrams, model table, state/command mapping |
| `TPLinkProvider` | Linux + Apple; UDP discovery Apple only | `actor TPLinkProvider: LightProvider`, per-device `TPLinkDeviceClient`, POSIX TCP, URLSession HTTP; NetKit UDP behind `#if canImport(Darwin)` |

`LINUX_OK`: the Linux job builds the whole package and runs every test, including the provider
tests against the in-package fake Kasa (TCP) and fake Tapo KLAP (HTTP) devices on loopback.

## Third-Party Compatibility (read this before adding a Tapo light)

Newer Kasa firmware and **every Tapo device** only accept local control from apps that prove they
know the **TP-Link account email and password** (KLAP handshake). Both are **case-sensitive**: the
email must be typed exactly as it was registered (`Jane.Doe@…` is not `jane.doe@…`).

Some firmware additionally refuses third-party apps until **Tapo app > Me > Tapo Lab >
Third-Party Compatibility** is turned on. TP-Link's own FAQ (https://www.tapo.com/us/faq/714/) says
the switch is off by default and that turning it on "can reintroduce security vulnerabilities" -
the guide must say so and let the user decide. If pairing keeps saying the email and password are
wrong although they are right, this switch is the usual cause; unplugging other TP-Link devices
during the first pairing also helps (onboarding §8 troubleshooting).

Legacy Kasa bulbs (KL/LB on old firmware) need no credentials and ignore the switch.

## Protocols

### Legacy Kasa: XOR JSON over TCP 9999

- Autokey XOR, initial key 171 (`0xAB`): `c[i] = p[i] ^ c[i-1]`.
- TCP: 4-byte big-endian length + XORed JSON, both ways (`TPLinkXOR.frame/unframe/deframe`).
  The provider opens one short connection per request (`PosixTPLinkStreamTransport`).
- IOT JSON (`TPLinkIOT`): `{"system":{"get_sysinfo":{}}}`; bulbs
  `smartlife.iot.smartbulb.lightingservice.transition_light_state`, strips (KL400/420/430)
  `smartlife.iot.lightStrip.set_light_state`, args `on_off`, `brightness` 1-100, `hue` 0-360,
  `saturation` 0-100, `color_temp` (K, 0 = colour), `transition_period` (ms), `ignore_default`
  (0 only for a bare "turn on", so the bulb restores its last state). `err_code` is checked at both
  levels. Bulbs answer a set with the resulting `light_state`, which becomes the cached state.
- When off, `light_state` carries the colour in `dft_on_state`.

### KLAP over HTTP :80 (Tapo, newer Kasa)

`TPLinkKLAP` / `TPLinkKLAPSession` / `TPLinkDeviceClient`:

1. `POST /app/handshake1`, body `local_seed` (16 random bytes) -> `remote_seed (16) + server_hash (32)`,
   `Set-Cookie: TP_SESSIONID=…;TIMEOUT=86400`.
2. `auth_hash` v2 = `SHA256(SHA1(email) + SHA1(password))` (v1, old Kasa KLAP: `MD5(MD5(email) + MD5(password))`).
   The client accepts handshake1 when `server_hash` equals v2 `SHA256(local + remote + auth_hash)`
   (v1 `SHA256(local + auth_hash)`) for one of: the account, TP-Link's two vendor default accounts,
   blank credentials (devices never bound to a cloud account). No match -> authentication error,
   nothing is sent to the device.
3. `POST /app/handshake2` with the cookie, body v2 `SHA256(remote + local + auth_hash)`
   (v1 `SHA256(remote + auth_hash)`) -> 200.
4. Session: `key = SHA256("lsk"+l+r+h)[:16]`, `iv = SHA256("iv"+l+r+h)`: first 12 bytes + 4-byte
   sequence (the last 4 bytes as signed big-endian Int32, incremented before each request,
   wrapping), `sig = SHA256("ldk"+l+r+h)[:28]`. Body = `SHA256(sig + seq + ct) + ct`,
   `ct = AES-128-CBC(PKCS7(json))`, `POST /app/request?seq=<seq>`; the answer uses the same layout
   and sequence. The signature of answers is verified.
5. **Re-handshake**: HTTP 401/403 on `/app/request`, or SMART `error_code` 9999
   (`SESSION_TIMEOUT`), -40401, 1002, 1112, -1001, -1012 drop the session and retry with a new
   handshake (twice at most). Sessions are also renewed 20 minutes before `TIMEOUT` runs out.
   Authentication codes (-1501, 1111, 1100, 1003, -1005, -40412) emit
   `.needsReauthentication(accountID: "tplink-account")` once and throw
   `LightCoreError.authenticationRequired(.tplink)`.
6. SMART JSON (`TPLinkSmart`): `{"method","params","request_time_milis","terminal_uuid"}` ->
   `{"error_code","result"}`; `get_device_info` (`device_on`, `brightness`, `hue`, `saturation`,
   `color_temp` (0 = colour), `color_temp_range`, base64 `nickname`, `mac`, `device_id`, `model`),
   `set_device_info` with the same fields. Tapo has no per-command transition (fades are the
   device's `on_off_gradually` setting), so Tapo lights report `supportsTransition = false`.
7. Kasa devices on KLAP firmware speak IOT JSON through the same session (v1 unless discovery
   reports `lv >= 2`). When the hash matches the other KLAP version than expected (Add by IP), the
   client switches version; a failing SMART read on a KLAP device is retried as IOT.

Not implemented: the AES "securePassthrough" transport of early Tapo firmware (discovery reports
`encrypt_type: AES`; pairing explains that a firmware update is needed), HTTPS-only KLAP
(`is_support_https`), the newer TPAP protocol, Tapo light-strip effects and segment control.

### Discovery

| Port | Datagram | Answer |
|---|---|---|
| UDP 9999 | XORed `{"system":{"get_sysinfo":{}}}` without length prefix | XORed sysinfo |
| UDP 20002 | 16-byte header `02 00 0001 <size u16> <flags> 00 <serial u32> <crc32>` + optional `{"params":{"rsa_key":"<PEM>"}}` | 16-byte header + `{"error_code":0,"result":{device_id, device_model, device_type, mac, ip, mgt_encrypt_schm{encrypt_type, http_port, lv, is_support_https}}}` |

The CRC32 (zlib) is computed with `0x5A6B7C8D` in the CRC field and then written there; the bare
header (serial 0, flags 0) is python-kasa's `DISCOVERY_QUERY_2` `020000010000000000000000463cb5d3`.
The provider sends the bare header and, by default, python-kasa's keyed probe (flags 17, random
serial, a throwaway 2048-bit RSA public key generated once).

`TPLinkProvider.discover(options:)` (ends at `options.timeout`):

1. broadcast of both datagrams (3 rounds) to the Wi-Fi directed broadcast and 255.255.255.255 when
   `options.broadcastAvailable` (multicast entitlement);
2. otherwise a unicast sweep of the Wi-Fi /24 with the same datagrams (`SubnetSweeper`, 32 in
   flight, 800 ms per host);
3. always: `cachedHosts`, known device IPs and `manualHosts` - UDP probe, then TCP 9999
   `get_sysinfo`, then a KLAP handshake1 probe (Add by IP works without UDP, e.g. on another subnet).

Plugs, switches, hubs and cameras are skipped. A 20002 answer wins over a 9999 answer from the same
host (it names the transport). `DiscoveredDevice.metadata`: `connection` (`xor:9999`,
`klap2-smart:80`, `klap1-iot:80`, `aes-smart:80`), `needsCredentials`, `deviceId`, `deviceType`,
`firmware`, `unsupported` (reason).

## Provider

- **Identity**: `LightID` = `tplink:<MAC as 12 lowercase hex>` (`tplink:5ce931123456`); the
  device id when no MAC is reported. IPs are hints; discovery updates a moved device.
- **Pairing**: legacy Kasa - no prompts. KLAP - stored credentials first (or blank/defaults for an
  unbound device); on rejection `PairingInteraction.text` (email, "case-sensitive") +
  `secureText` (password); when entered or stored credentials are rejected, a `confirm` explains case sensitivity and
  Third-Party Compatibility and offers another try. Accepted credentials are stored in
  `SecretStore` (`com.sinap.smartlights.tplink`, `account/username`, `account/password`; the plain
  values are needed to derive both hash versions) and `account` reports `tplink-account` with a
  masked email. `PairedDevice.metadata`: `connection`, `deviceId`, `mac`, `firmware`, `strip`.
- **Sessions**: one `TPLinkDeviceClient` actor per device serialises requests (KLAP sequence
  numbers must not interleave), keeps cookie + AES state and re-handshakes as above.
- **State**: `loadLights()` reads every paired device concurrently; failures mark the light
  unreachable instead of throwing.
- **Commands**: `TPLinkMapping.plan` normalises the command, merges power, brightness and colour into
  one request (`brightness 0` = off; brightness or colour on an off light turns it on; Kelvin
  clamped to the model range) and sends `transition_light_state` / `set_light_state` /
  `set_device_info`. `sendGroup` fans out concurrently (`.partialFailure` lists failed lights).
- **Events**: no push protocol. `start()` polls every 10 s and emits `.stateChanged`,
  `.lightUpdated` (name/capabilities) and `.reachabilityChanged`; `stop()` pauses.
- **Capabilities**: from the device (`is_color`/`is_variable_color_temp`/`is_dimmable`, Tapo
  `hue`/`color_temp_range`/`brightness`), Kelvin ranges and pre-read defaults from
  `TPLinkModelTable` (KL110/120/125/130/135, KB130, LB100/110/120/130/230, KL400/420/430,
  L430/L510/L530/L535/L630/L900/L920/L930). A fixed `color_temp_range` such as L920's `[9000, 9000]`
  means no white-temperature control.

## App wiring

```swift
let tplink = TPLinkProvider.live()          // POSIX TCP + URLSession + NetKit UDP + Keychain
await tplink.loadAccount()
await tplink.restore(storedTPLinkDevices)   // PairedDevice values from DeviceStore
await registry.register(tplink)
await tplink.start()                        // polling while foregrounded
// Re-authentication (`.needsReauthentication`): try await tplink.configureAccount(using: ui)
```

`DiscoveryOptions.broadcastAvailable` should come from `BroadcastCapability.detect()`. KLAP is plain
`http://<LAN IP>`; App Transport Security exempts numeric IP addresses, so no ATS exception should
be needed - confirm on device (see "Not verified yet").

## Tests

- `TPLinkCodecTests`: vectors from `Tests/TPLinkCodecTests/Fixtures/tplink_vectors.json`, generated
  by running python-kasa 0.12.0 (`Fixtures/gen_vectors.py`): XOR frames, discovery datagrams
  (legacy, bare 20002 header, keyed 20002 query with CRC), KLAP v1/v2 auth and handshake hashes,
  case sensitivity, session key/IV/sequence/signature, two encrypted requests and device answers,
  signed sequence packing. Plus NIST AES-CBC, CRC32, JSON, IOT/SMART envelopes and error codes,
  device-info parsing, model table, command planning.
- `TPLinkProviderTests`: `FakeKasaBulb` (XOR over a loopback TCP port, bulb or strip) and
  `FakeTapoBulb` (KLAP v2 over a loopback HTTP port, SMART JSON, injectable 403s and error codes),
  `FakeDatagramNetwork` for UDP. Covers manual/broadcast/sweep discovery, Add by IP without UDP,
  pairing without credentials, credential prompts and storage, wrong-case email retry, giving up,
  stored credentials, set requests, re-handshake after 403 and after `error_code` 9999,
  re-authentication event, polling, unreachable, group partial failure, restore, AES refusal.

```sh
docker run --rm -v "$PWD:/repo" -w /repo/Packages/Providers/TPLinkKit swift:6.1 swift test
# regenerate vectors
python3 -m venv /tmp/kasa && /tmp/kasa/bin/pip install python-kasa==0.12.0
(cd Tests/TPLinkCodecTests/Fixtures && /tmp/kasa/bin/python -I gen_vectors.py > tplink_vectors.json)
```

## Not verified yet

- No real-hardware run (the owner has not listed TP-Link lights). Hardware facts to confirm are in
  `docs/HARDWARE-NOTES.md` (TP-Link section).
- The NetKit UDP transport (`NetKitTPLinkDatagramTransport`) compiles on macOS CI only and is not
  exercised by tests (tests inject `FakeDatagramNetwork`).
- Whether every firmware answers the bare 20002 header; the keyed probe is sent too.
- Plain-HTTP KLAP from the iOS app under ATS (numeric IPs should be exempt).
