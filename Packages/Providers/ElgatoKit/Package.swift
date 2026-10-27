// swift-tools-version: 6.0
import PackageDescription

// ElgatoKit: Elgato Key Light / Key Light Air / Mini / Ring Light / Light Strip over the local
// HTTP API (port 9123, `/elgato/lights`, no authentication) for SmartLights.
//
//  - ElgatoCodec: pure Swift (Foundation + LightCore). JSON models for `/elgato/lights`,
//    `/elgato/accessory-info` and `/elgato/lights/settings`, mired <-> Kelvin, state/command
//    mapping. Builds and tests on Linux.
//  - ElgatoProvider: the `ElgatoProvider` actor over an `ElgatoHTTPTransport`. The actor and the
//    URLSession transport are platform neutral (tests run them on Linux against an in-process
//    fake HTTP light); Bonjour `_elg._tcp` discovery is guarded by `#if canImport(Network)`.
let package = Package(
    name: "ElgatoKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ElgatoCodec", targets: ["ElgatoCodec"]),
        .library(name: "ElgatoProvider", targets: ["ElgatoProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "ElgatoCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ElgatoProvider",
            dependencies: [
                "ElgatoCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "ElgatoCodecTests",
            dependencies: [
                "ElgatoCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ElgatoProviderTests",
            dependencies: [
                "ElgatoProvider",
                "ElgatoCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
