// swift-tools-version: 6.0
import PackageDescription

// ShellyKit: Shelly lights (Gen1 REST, Gen2+ JSON-RPC over HTTP and WebSocket) for SmartLights.
//
//  - ShellyCodec: pure Swift (Foundation + LightCore + swift-crypto). Device info, JSON-RPC
//    frames and notifications, HTTP digest auth (RFC 7616, SHA-256/MD5) and the RPC `auth`
//    object, Gen1 query strings, component status <-> LightState/LightCommand mapping.
//    Builds and tests on Linux.
//  - ShellyProvider: the `ShellyProvider` actor over an injectable HTTP transport. The actor is
//    platform neutral (tests run it on Linux against in-process fake devices); URLSession HTTP
//    works on Apple and Linux, Bonjour and the WebSocket notification channel are guarded by
//    `#if canImport(Network)` / `#if canImport(Darwin)`.
let package = Package(
    name: "ShellyKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ShellyCodec", targets: ["ShellyCodec"]),
        .library(name: "ShellyProvider", targets: ["ShellyProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "ShellyCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ShellyProvider",
            dependencies: [
                "ShellyCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "ShellyCodecTests",
            dependencies: [
                "ShellyCodec",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .testTarget(
            name: "ShellyProviderTests",
            dependencies: [
                "ShellyProvider",
                "ShellyCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
