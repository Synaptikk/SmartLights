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
