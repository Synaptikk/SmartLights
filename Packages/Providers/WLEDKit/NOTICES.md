# WLEDKit third-party notices

No third-party code is copied. The codec is written from the WLED JSON API documentation;
nothing here needs an entry in the repo-level `THIRD_PARTY_NOTICES.md`.

## References
- WLED JSON API (https://kno.wled.ge/interfaces/json-api/): `/json/state`, `/json/info`,
  `/json/effects`, `/json/cfg`, `bri` 0-255, `seg[].col`, `fx`, `tt`/`transition` in 100 ms units,
  `v: true`, `leds.lc` capability bits.
- WLED firmware (EUPL-1.2, https://github.com/Aircoookie/WLED): `_wled._tcp` service with TXT `mac`,
  default mDNS name `wled-` + last 6 hex digits of the MAC. Consulted only, not copied.
- Home Assistant `wled` integration (Apache-2.0): zeroconf discovery, one light per segment.
