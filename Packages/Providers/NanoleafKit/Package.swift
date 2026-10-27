// swift-tools-version: 6.0
import PackageDescription

// NanoleafKit: Nanoleaf Open API (Light Panels, Canvas, Shapes, Elements, Lines) as a SmartLights
// `LightProvider`.
//
// Layout (PLAN.md D6):
//  - NanoleafCodec: pure Swift (Foundation + LightCore + NetKit's Linux-safe core). Open API models,
//    request builders, SSE event decoding, mapping to LightCore types. Builds and tests on Linux.
//  - NanoleafProvider: the `actor NanoleafProvider`. Its HTTP/SSE transport is URLSession based and
//    portable (FoundationNetworking on Linux), so the provider is tested on Linux against an
//    in-package fake device. Only Bonjour browsing (`NanoleafBonjour.swift`) is Apple-only and is
//    guarded with `#if canImport(Network)`.
let package = Package(
    name: "NanoleafKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "NanoleafCodec", targets: ["NanoleafCodec"]),
        .library(name: "NanoleafProvider", targets: ["NanoleafProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "NanoleafCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "NanoleafProvider",
            dependencies: [
                "NanoleafCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "NanoleafCodecTests",
            dependencies: [
                "NanoleafCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NanoleafProviderTests",
            dependencies: [
                "NanoleafProvider",
                "NanoleafCodec",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
