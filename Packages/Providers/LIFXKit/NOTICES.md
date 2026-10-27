# LIFXKit third-party notices

No third-party code is copied. The codec is written from the published protocol description; please
also copy these entries into the repo-level `THIRD_PARTY_NOTICES.md`.

## LIFX LAN protocol documentation and `LIFX/public-protocol`
- Sources: https://lan.developer.lifx.com and https://github.com/LIFX/public-protocol (`protocol.yml`).
- License: none declared on the repository (checked 2026-10-26).
- Used: message ids, field layouts and sizes; the SetColor worked example used as a test vector.

## `LIFX/products`
- Source: https://github.com/LIFX/products (`products.json`).
- License: none declared on the repository (checked 2026-10-26).
- Used: `Sources/LIFXCodec/LIFXProductTable.swift` is generated from it (vendor/product ids, names,
  feature flags, Kelvin ranges, firmware upgrades) by `Scripts/gen_products.py`.
