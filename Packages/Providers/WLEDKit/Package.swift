// swift-tools-version: 6.0
import PackageDescription

// WLEDKit: WLED (DIY ESP8266/ESP32 LED controllers) over the JSON HTTP API (port 80,
// `/json/state`, `/json/info`, `/json/effects`, no authentication) for SmartLights.
//
//  - WLEDCodec: pure Swift (Foundation + LightCore). JSON models, mDNS-name identity, effect list
//    -> `EffectDescriptor`s, state/command mapping (bri 0-255, seg[0].col RGB/RGBW, `tt` transition
//    in 100 ms units). Builds and tests on Linux.
//  - WLEDProvider: the `WLEDProvider` actor over a `WLEDHTTPTransport`. The actor and the
//    URLSession transport are platform neutral (tests run them on Linux against an in-process
//    fake HTTP controller); Bonjour `_wled._tcp` discovery is guarded by `#if canImport(Network)`.
let package = Package(
    name: "WLEDKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "WLEDCodec", targets: ["WLEDCodec"]),
        .library(name: "WLEDProvider", targets: ["WLEDProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "WLEDCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "WLEDProvider",
            dependencies: [
                "WLEDCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "WLEDCodecTests",
            dependencies: [
                "WLEDCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WLEDProviderTests",
            dependencies: [
                "WLEDProvider",
                "WLEDCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
