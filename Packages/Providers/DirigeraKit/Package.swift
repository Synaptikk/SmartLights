// swift-tools-version: 6.0
import PackageDescription

// DirigeraKit: IKEA DIRIGERA hub over its unofficial local REST API (HTTPS :8443, bearer token
// from a PKCE authorize/token flow confirmed by the hub's action button; WebSocket events on
// wss://<hub>:8443/v1). Protocol ported from Leggin/dirigera (MIT). Task T3.5.
//
//  - DirigeraCodec: pure Swift (Foundation + LightCore + swift-crypto for the PKCE SHA-256).
//    PKCE helpers, device/scene/hub/event models with partial-update merge, capability and state
//    mapping, PATCH body planning. Builds and tests on Linux.
//  - DirigeraProvider: the `DirigeraProvider` actor over a `DirigeraTransport`. The actor is
//    platform neutral (tests run it on Linux against an in-package fake hub over loopback
//    HTTP + WebSocket); the URLSession transport with NetKit `TrustEvaluator` TOFU pinning is
//    guarded by `#if canImport(Darwin)`.
let package = Package(
    name: "DirigeraKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "DirigeraCodec", targets: ["DirigeraCodec"]),
        .library(name: "DirigeraProvider", targets: ["DirigeraProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "DirigeraCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "DirigeraProvider",
            dependencies: [
                "DirigeraCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "DirigeraCodecTests",
            dependencies: [
                "DirigeraCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DirigeraProviderTests",
            dependencies: [
                "DirigeraProvider",
                "DirigeraCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
