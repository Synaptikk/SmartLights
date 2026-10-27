# DirigeraKit third-party notices

## Leggin/dirigera

- Source: https://github.com/Leggin/dirigera
- Commit: e7537e91011a68b231d36c33351b22fa3567ebf2 (2026-10-23)
- License: MIT
- Used in: `Sources/DirigeraCodec` (PKCE authorize/token flow from `hub/auth.py`, endpoint paths and PATCH body shape from `hub/hub.py` and `devices/light.py`, the mired-bound handling of `_bound_to_kelvin`), `Tests/DirigeraCodecTests/Fixtures/devices.json` (the "Bed" light from `tests/test_light.py`).
- Changes: re-implemented in Swift; no Python code copied verbatim except the fixture JSON.

```
MIT License

Copyright (c) 2023 Leggin

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
