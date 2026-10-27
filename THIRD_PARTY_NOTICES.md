# Third-party notices

SmartLights includes or is derived from the third-party software listed below. Each entry keeps the original copyright notice and license text as required by that license.

When you port code from an MIT/Apache/BSD project, add an entry here in the same PR (see `CLAUDE.md`).

<!--
Template (copy for each project):

## <Project name>

- Source: <URL>
- Commit / version: <sha or tag>
- License: <MIT | Apache-2.0 | BSD-3-Clause | ...>
- Used in: <package/file paths>
- Changes: <brief description of modifications>

```
<full copyright notice and license text>
```
-->

_No third-party code has been included yet._

## LightCore

See `Packages/LightCore/NOTICES.md` for attributions (Home Assistant Apache-2.0 colour utilities, house-control MIT, benknight/rgbxy MIT).

## HueKit

See `Packages/Providers/HueKit/NOTICES.md` (aiohue test fixture, Apache-2.0; Signify root CA PEM via Hue-Sync).

## AiDotKit

Protocol ported from python-aidot 0.3.59 (AiDot-Development-Team, MIT); test fixtures generated with it.

## ShellyKit

No code copied. Protocol details from aioshelly and Home Assistant's `shelly` integration (both Apache-2.0) and RFC 7616 test vectors; see `Packages/Providers/ShellyKit/NOTICES.md`.

## MagicHomeKit

No code copied. flux_led (LGPL-3.0) was used only as a protocol reference (byte layouts, model-id table data, test byte vectors); the Swift code is an independent implementation. See `Packages/Providers/MagicHomeKit/NOTICES.md`.
