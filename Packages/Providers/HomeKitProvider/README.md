# HomeKitProvider

`LightProvider` for **Apple Home** (`Brand.appleHome`). Every `HMServiceTypeLightbulb` service of
every home the user has in Apple Home becomes a `Light`; the accessory maker goes into
`Light.manufacturer`, the model into `Light.model`.

**Matter accessories in Apple Home appear here too.** Apple exposes Matter accessories added to
Apple Home through the same `HMAccessory`/`HMService`/`HMCharacteristic` API as HAP accessories;
the HomeKit entitlement is enough, no re-pairing (research_ios_platform.md A2, research_brands.md §4).

## Layout

| File | Imports HomeKit | Builds on |
|---|---|---|
| `HomeKitSession.swift`: `HomeKitSession` protocol (`@MainActor`), value snapshots `HomeKitLightbulb`, `HomeKitCharacteristicSnapshot`, `HomeKitWrite`, `HomeKitSessionEvent`, `HomeKitAuthorizationState` | no | Linux, macOS, iOS |
| `HomeKitMapper.swift`: snapshot → `Light`/capabilities/state, `LightCommand` → characteristic writes, Kelvin ↔ mireds | no | Linux, macOS, iOS |
| `HomeKitProvider.swift`: the `actor HomeKitProvider: LightProvider` | no | Linux, macOS, iOS |
| `HMHomeKitSession.swift`: the real adapter over `HMHomeManager` + delegates, `HomeKitProvider.live()` | yes, `#if canImport(HomeKit) && !os(macOS)` | iOS (compiles to nothing on macOS AppKit and Linux) |

Markers: `LINUX_OK` (the Linux job runs the logic tests), `IOS_ONLY` (the macOS job builds and
tests the package with `xcodebuild` on an iOS simulator so the HomeKit adapter is compiled).
HomeKit does not work in the Simulator, so the tests use `FakeHomeKitSession` and never create an
`HMHomeManager`.

## Mapping

- Id: `applehome:<HMAccessory.uniqueIdentifier>/<HMService.uniqueIdentifier>` (also `providerRef`
  and `DiscoveredDevice.id`). These UUIDs are stable per device and per app install.
- Capabilities: power → `.onOff`; brightness → `.brightness`; hue + saturation → `.hs`;
  colour temperature (mireds) → `.colorTemp`, Kelvin range = `1e6 / max mireds ... 1e6 / min mireds`
  from characteristic metadata (HAP default 140...500 when missing). No transitions, no effects.
- Room: `HMAccessory.room.name`, nil for the "entire home" default room. Reachability:
  `HMAccessory.isReachable`.
- Commands: `LightCommand.normalized(for:)` first, then brightness `0...1` → `0...100` int,
  Kelvin → mireds (clamped to metadata), HS → degrees / percent. Order: power on, brightness,
  colour; turning off writes only power. Brightness 0 without `on` turns off; brightness > 0 on an
  off light also turns it on. Values equal to the cached value are skipped.
- Writes are serialised per accessory (one write chain per `HMAccessory`), concurrent across
  accessories (`sendGroup`). HomeKit does not notify an app of its own writes, so the provider
  updates its cache and emits `.stateChanged` after each successful write.
- Colour mode: HomeKit does not say whether an hs+CT light is showing a colour or a white. The
  provider remembers the last mode it wrote or saw change (`colorModeHints`); without one,
  saturation > 0 means `.hs`. **[verify]** with a Hue bulb in Apple Home: some bridges also
  update hue/saturation when CT is set, which may flip the reported mode.

## Events

`enableNotification(true)` is called once per lightbulb service (retried after failures/when the
accessory becomes reachable). `HMAccessoryDelegate` value updates → `.stateChanged` (or
`.lightUpdated` when name/room changed); `accessoryDidUpdateReachability` →
`.reachabilityChanged` for every lightbulb service of the accessory; `homeManagerDidUpdateHomes`,
home/accessory add/remove, room changes → the provider re-reads and diffs → `.lightAdded` /
`.lightRemoved` / `.lightUpdated`. Authorization: `authorizationState` property; denied/restricted
→ `.error(accessDeniedMessage)` + `.connectionChanged(connected: false, ...)`; granted →
`.connectionChanged(connected: true, nil)`. `loadLights` throws `LightCoreError.unsupported` when
access is denied.

## What the app must do

1. **Entitlement**: enable the HomeKit capability → `com.apple.developer.homekit = true` in the
   app's `.entitlements` (any team; not a managed entitlement).
2. **Usage string**: `NSHomeKitUsageDescription` in Info.plist (e.g. "SmartLights controls the
   lights you added to Apple Home."). Without it the app crashes when `HMHomeManager` is created.
3. **Register**: on the main actor, `let homeKit = HomeKitProvider.live()` then
   `await registry.register(homeKit)`. Creating the provider does not touch HomeKit; the
   permission prompt appears on the first `start()` / `requestAccess()` / `loadLights()` /
   `discover`. The onboarding step can call `await homeKit.requestAccess()` and read the result.
4. **Main actor**: `HMHomeKitSession` is `@MainActor` (HomeKit delegate callbacks arrive on the
   main queue); the provider actor hops to it. Keep a single session/provider for the app
   lifetime (`HMHomeManager` must stay alive to receive updates).
5. **Not from extensions**: since iOS 18.4, HomeKit calls from widget / control / App Intent
   extension processes fail with `HMErrorDomain Code=80 "Missing entitlement for API"`
   ("Handler does not support background access"). The adapter maps it to
   `LightCoreError.unsupported("... foreground (HMError 80)")`. Workaround for T1.10 / T2.7: make
   intents that touch Apple Home lights `ForegroundContinuableIntent` so they continue in the main
   app process (unavailable to extensions). https://developer.apple.com/forums/thread/779354
6. **No vendor effects or scenes**: HomeKit only exposes power, brightness, hue/saturation and
   colour temperature. Effects (Nanoleaf, Twinkly, Govee) need the brand's own provider.
7. Apple Home needs a home hub (HomePod / Apple TV) for remote access; on the LAN the phone talks
   to accessories through `homed` directly.
