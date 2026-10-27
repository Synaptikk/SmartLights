# Open questions for the user

Agents add questions here when they need input only the user can give. Answer inline (or tell an agent) and move answered items to the bottom.

---

## From T3.2 / T3.3 (Meross, SwitchBot), 2026-10-27

1. Do you own any **Meross** lights or dimmers? If yes: model (e.g. MSL120, MSL320, MSS560), whether it has the "HK"
   (HomeKit) or "MA" (Matter) suffix (then Apple Home is the better path), and whether the Meross account uses two-factor
   authentication.
2. Do you own any **SwitchBot** lights (Color Bulb, Strip Light, Ceiling Light)? If yes: is Cloud Services on for them, and is
   there a SwitchBot Hub? A token + secret from the app's Developer Options would let a probe confirm the signing case
   (see `docs/HARDWARE-NOTES.md`, 2026-10-27).

---
## From T3.6 HomeAssistantKit (2026-10-27)

1. **Do you run Home Assistant?** If yes, which URL do you use at home (for example `http://homeassistant.local:8123`), and do you have Nabu Casa remote access (`https://….ui.nabu.casa`)? The provider needs a long-lived access token. See `Packages/Providers/HomeAssistantKit/README.md` for how to create one. Paste it only into the app, never into the repo.
2. **Info.plist (app task, not done in T3.6):** Bonjour discovery of Home Assistant needs `_home-assistant._tcp` in `NSBonjourServices` (`App/Resources/Info.plist` / `project.yml`). T3.6 was scoped to stay out of `App/` and `project.yml`, so whoever wires the provider into the app (T1.6-style registry task) should add it and link the `HomeAssistantKit` product. Manual URL entry works without it.

## From T0.8 hardware probes (2026-10-26)

The first probe run from the dev PC (`192.168.254.40`, wired to the Sagemcom/Kinetic gateway) found **no** WiZ bulbs, Hue bridge or AiDot bulbs. Details are in `docs/HARDWARE-NOTES.md`.

1. **Where are the lights?** Are the Hue bridge, WiZ bulbs and AiDot bulbs on this same network (`KINETIC_FD5DE0`, `192.168.254.x`)? Or are they at another location, on a separate router or mesh with its own subnet, or on a guest/IoT SSID? If there's a separate subnet, what is its IP range, and can the PC reach it?
2. **Are they powered?** Are the bulbs switched on at the wall right now? Bulbs that are off at the switch can't be seen on the network.
3. **Hue bridge:** `discovery.meethue.com` lists no bridge for this internet connection. Is the bridge plugged in by Ethernet to this gateway (or to the extenders at `.9`/`.10`)? If you know its IP (Hue app → Settings → My Hue System → Bridge → Network settings), run `node hue.mjs discover <ip>` and `node hue.mjs cert <ip>`. Which bridge is it (square v2 `BSB002`, or Bridge Pro `BSB003`)?
4. **Hue pairing (when reachable):** press the round link button on the bridge, then within 30 s run `cd tools/probe && node hue.mjs pair <ip>`. The key is stored in `tools/probe/out/hue.json` (gitignored). Then run `node hue.mjs list <ip>` and `node hue.mjs events <ip>` (toggle a light in the Hue app while it runs).
5. **WiZ:** in the WiZ app → Settings → Security, is "Allow local communication" on? Is the control mode "Allow all controls" or "Only verified controls"? If it is the verified mode, please export the **local integration key** (Home settings → Integrations → Local integrations; it's a 32-hex `udp_signing_key`). Put it in an env var, `WIZ_SIGNING_KEY`, and don't paste it into the repo or chat logs.
6. **AiDot credentials:** run `cd tools/probe && node aidot.mjs login` yourself. It asks for country, e-mail and a hidden password, or reads `AIDOT_COUNTRY`/`AIDOT_USER`/`AIDOT_PASS`. Then run `node aidot.mjs devices`. Two things to note:
   - Logging in with the same account may sign the AiDot phone app out (python-aidot/cbrightly report). Is that acceptable, or do you want to create a second account? A second account won't work for local TCP control unless it *owns* the home; shared members are rejected.
   - Which country is the account registered in? This picks the `us`/`eu`/`jp` API region.
7. **Test device for writes:** which single bulb per brand may agents toggle? Give a WiZ IP or MAC, a Hue light uuid (from `hue.mjs list`) and an AiDot devId (from `aidot.mjs devices`). Writes run only with `TEST_DEVICE=<that id>` set in the shell.
8. **Tuya-looking device at `192.168.254.38`** (TCP 6668 open, MAC `fc:3c:d7:ef:a5:ca`): what is it? If it's a light or plug you want in the app, it belongs to the Phase 2 Tuya provider.
