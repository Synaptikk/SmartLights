# MatterSetup extension (placeholder, phase 3)

MatterSupport extension (`com.apple.matter.support.extension.device-setup`) that commissions Matter devices into the app's own fabric via `MatterAddDeviceExtensionRequestHandler`.

- No code yet. Bundle id: `com.sinap.smartlights.mattersetup`.
- Requires the App Group `group.com.sinap.smartlights` + keychain sharing with the app, and the Matter Bonjour types already listed in `App/Resources/Info.plist` (`_matter._tcp`, `_matterc._udp`, `_matterd._udp`).
- Matter devices already in Apple Home are reachable through HomeKit without this extension. See `research/research_ios_platform.md` A3.
