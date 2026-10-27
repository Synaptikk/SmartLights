# HueKit third-party notices

## aiohue test fixture (trimmed)

- Source: https://github.com/home-assistant-libs/aiohue/blob/master/tests/fixtures/v2_resources.json
- License: Apache-2.0 (Copyright Home Assistant contributors / home-assistant-libs)
- Used in: `Tests/HueCodecTests/Fixtures/v2_resources.json`
- Changes: reduced to the resource types HueKit models (lights, grouped lights, rooms, zones, scenes, bridge,
  zigbee_connectivity, geofence_client, the devices owning those, one entertainment_configuration, one motion).
  HueKit's keep-alive approach (geofence_client rename) follows aiohue's design; no aiohue code was copied.

## Signify "root-bridge" CA certificate

- Source: https://raw.githubusercontent.com/jdmg94/Hue-Sync/master/signify.pem (public CA certificate published by
  Signify on developers.meethue.com)
- Used in: `Sources/HueKit/Resources/hue-roots.pem`

## adeze/HueEntertainmentKit (approach, no code copied)

- Source: https://github.com/adeze/HueEntertainmentKit (`Sources/HueEntertainmentKit/EntertainmentTransport.swift`, `HueStreamPacketEncoder.swift`)
- License: Apache-2.0
- Used for: the Network.framework DTLS-PSK option set in `Sources/HueKit/Entertainment/NWDTLSConnector.swift` (DTLS 1.2, cipher 0x00A8, `sec_protocol_options_add_pre_shared_key` with identity = application key) and the "fail if the area is already active" default. HueKit uses `NWConnection` directly instead of swift-nio `NIOTransportServices`; the encoder was written from the layout in `research/research_hue.md` §2.2.
