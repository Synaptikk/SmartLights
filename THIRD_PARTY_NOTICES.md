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

## TuyaKit: tinytuya

- Source: https://github.com/jasonacox/tinytuya
- Commit / version: 1.20.0 (PyPI)
- License: MIT
- Used in: `Packages/Providers/TuyaKit` (`TuyaCodec`, `TuyaKit`); `Tests/TuyaCodecTests/Fixtures/tuya_fixtures.json` is generated with it
- Changes: Swift port of the local protocol (framing, payloads, AES-ECB/GCM, HMAC, 3.4/3.5 session-key negotiation, UDP decoding, `BulbDevice` dp sets and colour strings); device-side codec added for tests

```
MIT License

Copyright (c) 2024 Jason Cox

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
