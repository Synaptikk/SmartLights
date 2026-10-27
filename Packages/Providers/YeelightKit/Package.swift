// swift-tools-version: 6.0
import PackageDescription

// YeelightKit: Yeelight Wi-Fi lights over the documented LAN protocol
// (SSDP-style discovery on 239.255.255.250:1982, JSON-RPC lines on TCP 55443).
//
// Layout (PLAN.md D6):
//  - YeelightCodec: pure Swift (Foundation + LightCore). SSDP request/response, JSON-RPC request
//    encoding, response/notification parsing, line framing, model table, LightState/LightCommand
//    mapping. Builds and tests on Linux (LINUX_OK).
//  - YeelightProvider: the `LightProvider` actor and the per-bulb session (id matching,
//    notifications, reconnect, rate limiting) over an abstract `YeelightConnector`. The provider
//    logic is platform-neutral; the Network.framework transport (`NWYeelightConnector`) and the
//    live discovery backend (BSD-socket multicast, Bonjour, unicast SSDP, /24 sweep hosts) are
//    guarded with `#if canImport(Network)` / `canImport(Darwin)`.
let package = Package(
    name: "YeelightKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "YeelightCodec", targets: ["YeelightCodec"]),
        .library(name: "YeelightProvider", targets: ["YeelightProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "YeelightCodec",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "YeelightProvider",
            dependencies: [
                "YeelightCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "YeelightCodecTests",
            dependencies: [
                "YeelightCodec",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .testTarget(
            name: "YeelightProviderTests",
            dependencies: [
                "YeelightProvider",
                "YeelightCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
