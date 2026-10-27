# Third-party notices (GoveeKit)

## govee-local-api

`Sources/GoveeCodec/GoveeSKUCatalog.swift` contains a table of LAN-capable Govee models (SKU,
RGB / colour-temperature / brightness support, segment counts, Kelvin ranges) derived from
`src/govee_local_api/light_capabilities.py` (`GOVEE_LIGHT_CAPABILITIES`) of
https://github.com/Galorhallen/govee-local-api (fetched 2026-10-26). No code was copied; the LAN
message formats follow the same project's `message.py` and Govee's WLAN guide.

Copyright the govee-local-api contributors. Licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0). Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
OR CONDITIONS OF ANY KIND, either express or implied.
