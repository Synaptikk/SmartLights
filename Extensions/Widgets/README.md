# Widgets extension (placeholder)

Interactive widgets (light toggle, scene recall) and iOS 18 Control Center controls.

- No code yet. The owning task adds a `SmartLightsWidgets` target (type `app-extension`, WidgetKit) to `project.yml` and embeds it in the `SmartLights` app target.
- Bundle id: `com.sinap.smartlights.widgets`.
- Must share the App Group `group.com.sinap.smartlights` and the keychain access group `$(AppIdentifierPrefix)com.sinap.smartlights` with the app.
- HomeKit calls fail inside the extension process (HMError 80 since iOS 18.4). Route HomeKit actions to the app with a `ForegroundContinuableIntent`; direct LAN brands can run in-extension. See `research/research_ios_platform.md` A2/A5.
