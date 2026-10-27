# Widgets extension (T2.7)

`SmartLightsWidgets` (`com.sinap.smartlights.widgets`, WidgetKit, iOS 18), embedded in the app.

| Item | Kind | Configuration | Action |
| --- | --- | --- | --- |
| Light widget (small) | `WidgetKind.light` | `SelectLightIntent` (`LightEntity`) | `Toggle` → `LightPowerControlIntent` |
| Room widget (medium/large) | `WidgetKind.room` | `SelectRoomIntent` (`RoomEntity`) | one `Toggle` per light |
| Scene widget (small) | `WidgetKind.scene` | `SelectSceneIntent` (`SceneEntity`) | `Button` → `SceneControlIntent` |
| Light control (Control Center / Lock Screen / Action button) | `WidgetKind.lightControl` | `SelectLightControlIntent` | `ControlWidgetToggle` |
| Scene control | `WidgetKind.sceneControl` | `SelectSceneControlIntent` | `ControlWidgetButton` |

## How it works

- **Data**: the app writes `widget-snapshot.json` (`Shared/WidgetSnapshot.swift`) to the App Group
  `group.com.sinap.smartlights` whenever lights, rooms or scenes change
  (`App/Model/AppModel+WidgetSnapshot.swift`, debounced, observation-tracked) and reloads all
  timelines and controls. The extension only reads it: no providers, no network, no discovery.
  Timelines use `.never`; the app is the only reload trigger.
- **Entities**: `Shared/IntentEntityTypes.swift` holds `LightEntity` / `RoomEntity` / `SceneEntity`
  for both targets. The app's queries read `AppModel`; the extension's (`WidgetEntityQueries.swift`)
  read the snapshot. Ids are stable ids (`LightID` raw value, room UUID, scene id), never IPs.
- **Actions**: `Shared/WidgetIntents.swift` is compiled into both targets. In the app the intents
  conform to `ForegroundContinuableIntent` (unavailable in extensions), so they are performed in
  the app process with the registered providers and their cached IPs (`AppModel.performIntent`,
  `recallForIntent`; no discovery). Apple Home lights bring the app to the foreground first,
  because HomeKit fails from extensions and background (HMError 80, see
  `Packages/Providers/HomeKitProvider/README.md`); other brands run without opening the app.
  The extension copy (`WIDGET_EXTENSION`) only throws "Open SmartLights".
- **Entitlements**: `SmartLightsWidgets.entitlements` shares the App Group and the keychain access
  group `$(AppIdentifierPrefix)com.sinap.smartlights` with the app. No HomeKit entitlement.
- Controls cannot show errors (research A5); failures land in Diagnostics via the app.
