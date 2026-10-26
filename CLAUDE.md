# SmartLights – agent instructions

One iPhone app that controls smart lights from every brand the owner has (Hue bridge, WiZ, AiDot/Linkind, plus LIFX, Govee, Nanoleaf, TP-Link, Yeelight, Tuya and more), local-first, with a guided "Add brand" walkthrough per brand.

## Read in this order
1. `PLAN.md` – goals, decisions (D1-D10), architecture, phases, user prerequisites.
2. `agents/TASKS.md` – your task list with acceptance criteria. Claim one task; stay inside its package/folder.
3. `docs/BRAND-RUNDOWN.md` and `docs/ONBOARDING-WALKTHROUGHS.md` – per-brand facts and wizard content.
4. `research/*.md` – sourced protocol detail. Trust these over memory; where they say [uncertain]/[verify], confirm with a probe script or flag it in `docs/HARDWARE-NOTES.md`.

## Hard constraints
- Native Swift 6 / SwiftUI, iOS 18 minimum, Xcode 27. No cross-platform frameworks.
- Every brand package is split into `XxxCodec` (pure Swift, Foundation + swift-crypto only, must `swift build`/`swift test` in a Linux `swift:6.1` container) and `XxxProvider` (Apple frameworks allowed). Guard Apple-only code with `#if canImport(...)`.
- The dev machine is Windows with git, gh, Node 24 and Docker, but no Swift or Xcode. Test codecs in Docker; everything Apple-specific is built and tested by GitHub Actions macOS runners (`.github/workflows/ios.yml`). Read CI logs with `gh run view --log`. Never claim an Apple-side build passes without a green CI run.
- Devices are keyed by stable ids (Hue uuid, WiZ MAC, AiDot devId), never by IP. IPs are cached hints.
- Secrets only in Keychain (`SecretStore`); never log credentials, keys, tokens.
- UDP broadcast/multicast requires the multicast entitlement, which may not be granted; every discovery path must have a unicast/manual fallback.
- Do not modify or root the Hue bridge. Do not implement GE Cync DNS hijacking.
- Hardware probes (`tools/probe/*.mjs`) only read state by default; writes go to the device named in `TEST_DEVICE`.
- Hue developer terms: show "not a Signify app" disclosure in About; no Hue logos; photosensitivity warning before fast effects.

## Code conventions
- `actor` providers conforming to `LightProvider`; `AsyncStream` for events; structured concurrency, no `DispatchQueue`.
- Swift Testing (`import Testing`) for unit tests; simulators in `Packages/Simulators` for integration tests.
- `OSLog` subsystem `com.sinap.smartlights.<package>`.
- Third-party code ported from MIT/Apache projects keeps attribution in `THIRD_PARTY_NOTICES.md`.
- Commit messages: `<package>: <imperative summary>`; one task per PR; PR description lists which acceptance criteria were met and how (CI run link, simulator test names, hardware confirmation if any).

## When blocked
- Missing user input (dev account secrets, WiZ key, AiDot credentials, device models): write the question into `docs/OPEN-QUESTIONS.md` and continue with simulator-backed work.
- Research contradiction: record it in `docs/HARDWARE-NOTES.md` with what you observed and pick the behaviour that matches real hardware.
