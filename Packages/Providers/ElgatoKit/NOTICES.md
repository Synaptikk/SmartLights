# ElgatoKit third-party notices

No third-party code is copied. The codec is written from the public descriptions of the Elgato
local HTTP API; nothing here needs an entry in the repo-level `THIRD_PARTY_NOTICES.md`.

## References
- `frenck/python-elgato` (MIT, https://github.com/frenck/python-elgato): endpoint names
  (`/elgato/lights`, `/elgato/accessory-info`, `/elgato/lights/settings`, `/elgato/identify`),
  field names and ranges (brightness 0-100, temperature 143-344 mireds, Light Strip hue/saturation).
- Home Assistant `elgato` integration (Apache-2.0, https://www.home-assistant.io/integrations/elgato/):
  serial number as unique id, `powerOnHue` as the Light Strip colour signal, `_elg._tcp` zeroconf.
- `research/research_brands.md` § Elgato (connection-reset quirk, `Connection: close`).
