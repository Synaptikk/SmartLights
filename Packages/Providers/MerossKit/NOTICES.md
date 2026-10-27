# MerossKit third-party notices

## albertogeniola/MerossIot
- Source: https://github.com/albertogeniola/MerossIot @ 4fc819384086b2eae31e11c11871c5aef319654f
- License: MIT, Copyright (c) 2018 Alberto Geniola
- Used: cloud endpoints (`/v1/Auth/signIn`, `/v1/Device/devList`, `/v1/Profile/Logout`), request envelope and signing salt,
  headers, `apiStatus` error codes, devList fields, light capacity bits, ToggleX/Toggle payloads. Reimplemented in Swift.

## krahabb/meross_lan
- Source: https://github.com/krahabb/meross_lan @ bafedb4f8563153f9e3494292073551bb28f5f9a
- License: MIT, Copyright (c) 2020 Joakim Sørensen @ludeeus (template), krahabb
- Used: local `/config` message format and signature, `Appliance.Encrypt.ECDHE` key derivation and AES-CBC body handling,
  luminance/temperature scales, capacity handling and the ToggleX-after-light behaviour, DHCP OUIs, emulator trace payloads
  (msl320, msl450) as test fixtures. `Tests/MerossCodecTests/Fixtures/gen_fixtures.py` contains short verbatim excerpts
  (`compute_message_signature`, `compute_encryption_key`, cloud sign, CBC encryption).
