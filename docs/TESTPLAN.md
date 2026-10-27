# Phase-1 manual test plan (real hardware)

Covers T1.1-T1.7 on the user's own gear: Philips Hue bridge, WiZ bulbs (one on firmware 1.34+ if
available), AiDot/Linkind bulbs, and any light already in Apple Home. Run it on a TestFlight build
on an iPhone on the same Wi-Fi as the lights. Record results in the table at the end and attach
the diagnostics export (Settings > Diagnostics > Export) to the T1.9 issue.

Conventions:
- "Diagnostics log" = Settings > Diagnostics > log section / exported `log.txt`. Lines look like
  `2026-10-26T20:15:03Z [INFO] com.sinap.smartlights.app/wiring (app): Hue: restored 1 bridge(s)`.
- Never paste keys, tokens or passwords into issues. The export is redacted; spot-check it (step X.3).
- "External change" = change made in the vendor app or with a physical switch, not in SmartLights.

## 0. Preparation

| # | Step | Expected |
|---|------|----------|
| 0.1 | Delete any previous SmartLights install, install the TestFlight build, open it. | No Local Network or HomeKit prompt at launch (prompts appear only in the Add flow). |
| 0.2 | Settings > Diagnostics. | Local network: undetermined. Multicast entitlement: absent (until Apple grants it). Wi-Fi subnet shows your /24. |
| 0.3 | Diagnostics log. | `Hue: restored 0 bridge(s)` and `WiZ: restored 0 bulb(s)` under category `wiring`. No Apple Home / AiDot lines. |

## 1. Philips Hue

| # | Step | Expected |
|---|------|----------|
| 1.1 | Add > Philips Hue. Tick the checklist. Tap **Scan**. | iOS shows the Local Network prompt once; allow it. Within 10 s a "Choose devices" sheet lists the bridge (name, IP, `bonjour` or `cloud`), ticked. Log: `Broadcast capability: notEntitled` (or `entitled`), `Philips Hue: discovery found 1 device(s)`. |
| 1.2 | Tap **Add 1**. Step shows "Found 1 device". Skip "Add by IP". | |
| 1.3 | On "Press the link button" tap **Continue**. When the prompt says so, press the bridge button, then **Continue** within 30 s. | Status line counts down ("Waiting for the link button... n s") until pressed, then "Added <bridge name>". Log: `Philips Hue: added <name>`. OSLog (`com.sinap.smartlights.huekit`) shows the app key only as redacted. |
| 1.4 | Older bridge only (self-signed cert): note the result of 1.3. | Pairing succeeds; log `Pinned certificate for <bridgeid> on first use` (category `tofu`). Relaunch the app: no new "Pinned" line (pin read from Keychain). |
| 1.5 | **Check a light**: pick a light from the list. | The chosen light turns off/on twice and returns to its previous state; answer **Continue** to "Did ... blink?". |
| 1.6 | Close the guide, open Lights. | All Hue lights appear grouped by Hue room. |
| 1.7 | Toggle a light; drag brightness; pick a colour; set a colour temperature. | Each change visible on the bulb in < 0.5 s; slider drags do not lag (≤ 10 commands/s). Diagnostics shows latency per light (typically 50-200 ms). |
| 1.8 | Scenes tab: recall a Hue scene. | Lights change to the scene. |
| 1.9 | In the Hue app (or a Hue dimmer), toggle a light and change brightness. | SmartLights updates within 1 s without pulling to refresh (SSE). Diagnostics: Hue provider `connected`. |
| 1.10 | Background the app for 1 minute, change a light in the Hue app, return. | Log: `huekit` event stream disconnected after ~2 s in background and reconnected on return; state is correct within 2 s of returning. |
| 1.11 | Force-quit and relaunch. | Log: `Hue: restored 1 bridge(s)`; lights load without pairing again. |
| 1.12 | Manual IP path: Settings > Diagnostics shows the bridge IP. Re-run Add > Philips Hue, at the picker untick the bridge, type its IP in "Add by IP address", tap **Check address**. | The bridge appears ticked with method `manual` and "already added". Continuing re-pairs without duplicates. |

## 2. WiZ

| # | Step | Expected |
|---|------|----------|
| 2.1 | Add > WiZ. In "Control mode" answer what the WiZ app shows. Tap **Scan**. | Takes up to 20 s without the multicast entitlement (subnet sweep). Picker lists every powered bulb (name "WiZ ... <last MAC digits>", module name, IP, `sweep`/`broadcast`). |
| 2.2 | Keep all ticked, tap **Add n**. | Each bulb is read and added; status line "Adding ...". Bulbs on firmware 1.34+ with "Only verified controls" ask how to provide the key (import file / paste / allow all controls). Log: `WiZ: added <name>` per bulb. |
| 2.3 | Signing path (1.34+ bulb with "Only verified controls"): on the **Signing key** step tap **Import**, choose "Import the key file", pick the JSON exported from WiZ app > Home settings > Integrations > Local integrations. | "WiZ: signing key stored" in the log; the key value never appears (export shows `<redacted>` if anything). Commands to that bulb succeed. |
| 2.4 | Paste path: repeat 2.3 with "Paste the key" and the 32-hex `udp_signing_key`. Then paste a wrong value. | Correct key stored; a malformed value shows an inline error (no crash, nothing stored). |
| 2.5 | **Check a bulb**. | The bulb pulses (WiZ pulse) and you confirm. |
| 2.6 | Toggle, brightness, RGB colour (colour bulbs), temperature (TW bulbs). | Applied in < 0.5 s; temperature limited to the bulb's `cctRange`. |
| 2.7 | Change a bulb with the WiZ app or wall switch off/on. | SmartLights reflects it within ~1-2 s while foregrounded (push registration on UDP 38900); if pushes are blocked, within 30 s (poll). Diagnostics: WiZ provider `Listening for WiZ pushes on UDP 38900`. |
| 2.8 | Background the app 1 minute, return. | Log: WiZ `Stopped` after ~2 s in background, `Listening ...` again on return; states refresh. |
| 2.9 | Give a bulb a new IP (router DHCP change or reboot) then relaunch. | Bulb is found again by MAC (id unchanged), no duplicate light. |
| 2.10 | Manual IP: re-run Add > WiZ, use "Add by IP address" with a bulb's IP (or the guide's "Add by IP" step followed by **Signing key** or **Check a bulb**). | Bulb added via `manual`; already-added bulbs start unticked. |
| 2.11 | Switch the WiZ app to "Only verified controls" after adding without a key, then toggle that bulb. | Toast "WiZ needs you to sign in again..." once; red badge on the Settings tab; Diagnostics shows WiZ "Needs sign-in again". Importing the key (2.3) clears the badge. |

## 3. AiDot / Linkind

| # | Step | Expected |
|---|------|----------|
| 3.1 | Add > AiDot. Tap **Sign in**. Pick the country used in the AiDot app, enter e-mail, password. | Status "Signing in to AiDot..." then "Loading your AiDot devices...". Step shows "Added AiDot account". Log never contains the password or tokens (check export). |
| 3.2 | Wrong password attempt first. | Inline error under the step; retry works. |
| 3.3 | **Scan**. | Picker lists the account's LAN bulbs found on the network (UDP 6666 if entitled, otherwise unicast/sweep). Unticked ones are already covered by the account. |
| 3.4 | **Check a light**. | Chosen bulb blinks; confirm. |
| 3.5 | Toggle, brightness, colour/temperature per capabilities. | Applied in < 1 s over local TCP 10000. |
| 3.6 | Change a bulb in the AiDot app. | SmartLights updates (status push) within ~2 s. |
| 3.7 | Background 1 minute, return. | Log: AiDot sessions closed in background and reopened on return. |
| 3.8 | Sign in to the AiDot app on another phone with the same account, then use SmartLights. | Token rejected: toast + Settings badge + Diagnostics "Needs sign-in again". Re-running Add > AiDot > Sign in clears it. |
| 3.9 | Manual IP: re-run Add > AiDot, enter a bulb's IP in "Add by IP address". | Bulb found via `manual` and added. |
| 3.10 | Relaunch. | Log: `AiDot: restored account`; lights load without signing in. |

## 4. Apple Home

| # | Step | Expected |
|---|------|----------|
| 4.1 | Add > Apple Home. Tap **Allow HomeKit access**; allow in the iOS prompt. | Step completes; lights from the Home app appear in Lights with brand "Apple Home" and the accessory maker. |
| 4.2 | Deny instead (fresh install). | Inline error with the Settings > Privacy & Security > HomeKit path; no Apple Home lights; relaunch shows no HomeKit prompt. |
| 4.3 | Toggle and dim an Apple Home light; change it in the Home app. | Both directions update within ~1 s. |
| 4.4 | Relaunch. | Log: `Apple Home: registered`; no permission prompt. |

## X. Cross-cutting

| # | Step | Expected |
|---|------|----------|
| X.1 | Airplane mode on, open the app. | Cached lights show (unreachable), no crash; errors listed in Diagnostics. |
| X.2 | Settings > Diagnostics > Export, open the bundle. | Contains provider health (connected, last error, needs re-auth), per-device last seen/latency/errors, and the log. |
| X.3 | Search the export for your Hue app key, WiZ key, AiDot password/e-mail. | Not present (keys/tokens redacted; e-mail masked). |
| X.4 | Settings > Privacy & Security > Local Network: turn SmartLights off, run any **Scan**. | Inline error "Local Network access is off..." with the path to fix it. |

## Results

| Section | Device / firmware | Pass/Fail | Notes |
|---------|-------------------|-----------|-------|
| 1 Hue | | | |
| 2 WiZ | | | |
| 3 AiDot | | | |
| 4 Apple Home | | | |
| X | | | |
