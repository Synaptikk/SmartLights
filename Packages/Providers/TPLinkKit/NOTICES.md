# TPLinkKit third-party notices

No third-party code is copied into this package. Please keep the summary in the repo-level
`THIRD_PARTY_NOTICES.md` in sync.

## python-kasa (`python-kasa/python-kasa`)
- Source: https://github.com/python-kasa/python-kasa, version 0.12.0 (PyPI, checked 2026-10-27).
- License: **GPL-3.0** (inherited from pyHS100). Because GPL code cannot be ported into this app
  under the repo's MIT/Apache rule, nothing was copied: the XOR, KLAP, SMART/IOT and discovery
  formats were re-implemented in Swift from the protocol's observable behaviour. Protocol facts
  (message layouts, hash constructions, error codes, the vendor default account names) are not
  copyrightable.
- Used: `Tests/TPLinkCodecTests/Fixtures/gen_vectors.py` *runs* python-kasa to produce
  `tplink_vectors.json`; the hex values in the Swift tests are outputs of that run. The script is a
  test tool, not shipped with the app. Device field names were checked against python-kasa's test
  fixtures; no fixture file is included.

## `mihai-dinculescu/tapo`
- Source: https://github.com/mihai-dinculescu/tapo
- License: MIT.
- Used: reference for the KLAP handshake and SMART request shapes (no code copied).

## softScheck "Reverse Engineering the TP-Link HS110"
- Source: https://www.softscheck.com/en/reverse-engineering-tp-link-hs110/ and
  https://github.com/softScheck/tplink-smartplug (Apache-2.0).
- Used: description of the XOR autokey (initial key 171) and the 4-byte length prefix (no code copied).
