// swift-tools-version: 6.0
import PackageDescription

// GoveeKit: Govee LAN API (UDP multicast scan + JSON commands) and Govee Developer (cloud) API.
//
// Layout (PLAN.md D6):
//  - GoveeCodec: pure Swift (Foundation + LightCore). LAN messages, LAN SKU allow-list, cloud
//    request/response models, capability/state/command mapping, daily budget maths.
//  - GoveeProvider: the `actor GoveeProvider: LightProvider`, transport protocols, a URLSession
//    cloud transport (Apple + Linux) and the NetKit `UDPSocket` LAN transport (`#if canImport(Darwin)`).
// Both targets build and test on Linux (LINUX_OK); provider tests use in-package fake UDP/HTTP servers.
let package = Package(
    name: "GoveeKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GoveeCodec", targets: ["GoveeCodec"]),
        .library(name: "GoveeProvider", targets: ["GoveeProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "GoveeCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "GoveeProvider",
            dependencies: [
                "GoveeCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "GoveeCodecTests",
            dependencies: ["GoveeCodec", .product(name: "LightCore", package: "LightCore")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GoveeProviderTests",
            dependencies: [
                "GoveeProvider",
                "GoveeCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
