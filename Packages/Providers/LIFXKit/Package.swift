// swift-tools-version: 6.0
import PackageDescription

// LIFXKit: LIFX LAN protocol (binary UDP 56700) for SmartLights.
//
//  - LIFXCodec: pure Swift (Foundation + LightCore). Header/message encoding, HSBK, product
//    registry, HSBK <-> LightState/LightCommand mapping. Builds and tests on Linux.
//  - LIFXProvider: the `LIFXProvider` actor over a `LIFXTransport`. The actor is platform
//    neutral (tests run it on Linux against a fake UDP bulb); the real transport (NetKit
//    `UDPSocket`) and Bonjour discovery are guarded by `#if canImport(Darwin)` /
//    `#if canImport(Network)`.
let package = Package(
    name: "LIFXKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "LIFXCodec", targets: ["LIFXCodec"]),
        .library(name: "LIFXProvider", targets: ["LIFXProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "LIFXCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "LIFXProvider",
            dependencies: [
                "LIFXCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "LIFXCodecTests",
            dependencies: [
                "LIFXCodec",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .testTarget(
            name: "LIFXProviderTests",
            dependencies: [
                "LIFXProvider",
                "LIFXCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
