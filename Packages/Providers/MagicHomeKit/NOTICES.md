# MagicHomeKit third-party notices

No third-party code is copied. Please keep the repo-level `THIRD_PARTY_NOTICES.md` entry in sync.

## flux_led (protocol reference only)
- Source: https://github.com/lightinglibs/flux_led (`flux_led/protocol.py`, `models_db.py`,
  `pattern.py`, `scanner.py`, `tests.py`), master as of 2026-10-27.
- License: **LGPL-3.0**. Because LGPL code cannot simply be linked into an iOS app, nothing was
  translated from it. The Swift implementation is written from the observable wire format.
- Used as facts only: message byte layouts and checksums, the outer-wrapper layout, model ids with
  their names, firmware-version thresholds, colour-mode sets and channel maps, preset pattern ids and
  names, the speed/delay formula, and the byte vectors its tests assert (reused as test expectations in
  `Tests/MagicHomeCodecTests`).
