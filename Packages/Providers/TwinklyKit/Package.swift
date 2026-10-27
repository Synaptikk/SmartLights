// swift-tools-version: 6.0
import PackageDescription

// TwinklyKit: Twinkly LED strings/strips over the unofficial local "xled" REST API
// (HTTP :80, challenge login + X-Auth-Token) and UDP 5555 discovery. Task T3.4.
//
//  - TwinklyCodec: pure Swift (Foundation + LightCore). Discovery datagrams, login/verify models,
//    gestalt/mode/color/brightness/effects models, state + capability mapping and the command
//    planner. Builds and tests on Linux.
//  - TwinklyProvider: the `TwinklyProvider` actor over a `TwinklyTransport`. The actor is platform
//    neutral (tests run it on Linux against an in-package fake device over loopback HTTP/UDP);
//    the URLSession + NetKit `UDPSocket` transport is guarded by `#if canImport(Darwin)`.
let package = Package(
    name: "TwinklyKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "TwinklyCodec", targets: ["TwinklyCodec"]),
        .library(name: "TwinklyProvider", targets: ["TwinklyProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "TwinklyCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "TwinklyProvider",
            dependencies: [
                "TwinklyCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "TwinklyCodecTests",
            dependencies: [
                "TwinklyCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TwinklyProviderTests",
            dependencies: [
                "TwinklyProvider",
                "TwinklyCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
