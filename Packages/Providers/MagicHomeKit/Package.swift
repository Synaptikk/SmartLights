// swift-tools-version: 6.0
import PackageDescription

// MagicHomeKit: Magic Home / Zengge / LEDENET Wi-Fi controllers and bulbs (binary TCP 5577,
// UDP 48899 discovery) for SmartLights.
//
//  - MagicHomeCodec: pure Swift (Foundation + LightCore). Message builders with checksums, the
//    14-byte state response, stream framing, UDP discovery text, the model-id table and the
//    raw state <-> LightState/LightCommand mapping. Builds and tests on Linux.
//  - MagicHomeProvider: the `MagicHomeProvider` actor over injectable TCP/UDP transports. The
//    actor is platform neutral (tests run it on Linux against an in-process fake device); the
//    real transports (NWConnection TCP, NetKit UDP) are guarded by `#if canImport(Network)`.
let package = Package(
    name: "MagicHomeKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MagicHomeCodec", targets: ["MagicHomeCodec"]),
        .library(name: "MagicHomeProvider", targets: ["MagicHomeProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "MagicHomeCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "MagicHomeProvider",
            dependencies: [
                "MagicHomeCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "MagicHomeCodecTests",
            dependencies: [
                "MagicHomeCodec",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .testTarget(
            name: "MagicHomeProviderTests",
            dependencies: [
                "MagicHomeProvider",
                "MagicHomeCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
