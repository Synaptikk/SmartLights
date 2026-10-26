# Packages

All app logic lives in local Swift packages. The app target (`App/`) is a thin SwiftUI shell that wires them together; extensions link the same packages.

```
Packages/
├─ LightCore/        Domain model (Light, LightState, LightCommand, ColorMode, ...), LightProvider
│                    protocol, ProviderRegistry, DeviceStore, SecretStore, ColorMath, RateLimiter, Log
├─ NetKit/           UDP (BSD sockets + broadcast capability detection), /24 sweep, Bonjour browser,
│                    SSE client, TLS trust evaluator, HTTP helpers, local-network permission probe
├─ Onboarding/       BrandGuide model + per-brand guide content (no UI)
├─ Providers/
│  ├─ HueKit/        HueCodec + HueProvider
│  ├─ WiZKit/        WiZCodec + WiZProvider
│  ├─ AiDotKit/      AiDotCodec + AiDotProvider
│  ├─ HomeKitProvider/  (no codec)
│  └─ ...Kit/        one package per further brand
└─ Simulators/       Fake devices (UDP/TCP/HTTP servers) for tests and previews
```

## The codec / transport split (mandatory, PLAN.md D6)

Every brand package declares (at least) two library products:

| Product | May import | Must build on | Contains |
|---|---|---|---|
| `XxxCodec` | Foundation, swift-crypto only | **Linux** (`swift:6.1` container) and Apple | Wire models (Codable), request/response encoding, parsing, signing/encryption, capability decoding, pure state merging |
| `XxxProvider` | anything (Network, HomeKit, CoreBluetooth, Security, ...) | Apple (macOS CI) | Transport (sockets, URLSession, NWBrowser), Keychain, `LightProvider` actor conformance |

Rules:
- `XxxCodec` never imports `Network`, `Security`, `HomeKit`, `os`, `SwiftUI`, `UIKit` or any Apple-only framework. If a shared package (e.g. LightCore) needs an Apple-only implementation, guard it with `#if canImport(...)` and provide a Linux fallback.
- `XxxProvider` depends on `XxxCodec`, `LightCore` and `NetKit`; never the other way round.
- All protocol logic that can be tested without a socket belongs in the codec, so it is covered by `swift test` in Docker on the Windows dev machine.
- Providers are `actor`s, publish events via `AsyncStream`, use structured concurrency (no `DispatchQueue`), and log with `OSLog` subsystem `com.sinap.smartlights.<package>`.
- Tests use Swift Testing (`import Testing`). Integration tests run against `Packages/Simulators`.
- Swift tools version 6.0+, Swift 6 language mode, platforms `.iOS(.v18)` plus a macOS version (e.g. `.macOS(.v15)`) so `swift test` can also run on the macOS runner.

## Adding a package to the app

1. Create it under `Packages/` (or `Packages/Providers/`).
2. Register it in the root `project.yml` under `packages:` and add the product to the `SmartLights` target's `dependencies:` (see the comment there).
3. If it builds on Linux (codec-only or fully `#if`-guarded), add an empty `LINUX_OK` file in the package folder; the Linux codec job discovers it automatically (`tools/ci/find-linux-packages.sh`). Add `LINUX_SKIP` to exclude, `IOS_ONLY` if it cannot build for macOS.
