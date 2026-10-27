# ShellyKit third-party notices

No third-party code is copied. Please keep the repo-level `THIRD_PARTY_NOTICES.md` entry in sync.

## aioshelly (reference)
- Source: https://github.com/home-assistant-libs/aioshelly (`rpc_device/wsrpc.py`, `common.py`), main as of 2026-10-27.
- License: Apache-2.0.
- Used: the RPC frame layout, the 401 challenge JSON and the WebSocket `auth` object formula
  (`HA2 = sha256("dummy_method:dummy_uri")`, decimal `nc`), `/shelly` field names. Re-implemented in Swift.

## Home Assistant `shelly` integration (reference)
- Source: https://github.com/home-assistant/core/tree/dev/homeassistant/components/shelly (`light.py`, `const.py`).
- License: Apache-2.0.
- Used: component names and `*.Set` parameters (`brightness`, `rgb`, `white`, `ct`, `mode`,
  `transition_duration`, minimum 0.5 s), `ct_range`, Gen1 light fields (`ison`, `gain`, `temp`, `mode`,
  `transition`, max 5000 ms) and Kelvin ranges. Re-implemented in Swift.

## RFC 7616 (HTTP Digest Access Authentication)
- Source: https://www.rfc-editor.org/rfc/rfc7616 section 3.9.1.
- Used: the MD5 and SHA-256 example as test vectors.
