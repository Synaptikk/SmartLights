# App Intents extension (placeholder)

App Intents for Siri, Shortcuts and Spotlight ("turn on the living room", "recall Relax").

- No code yet. Intents that can run in the app process may live in the app target; an extension target (bundle id `com.sinap.smartlights.intents`) is added to `project.yml` only if needed.
- Must share the App Group `group.com.sinap.smartlights` and the keychain access group with the app.
- HomeKit-backed intents must be `ForegroundContinuableIntent` (run in the app process). See `PLAN.md` §7b and `research/research_ios_platform.md`.
