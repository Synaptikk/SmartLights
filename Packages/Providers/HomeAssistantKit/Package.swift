// swift-tools-version: 6.0
import PackageDescription

// HomeAssistantKit: Home Assistant WebSocket API (research/research_brands.md §5).
// - HomeAssistantCodec: pure Swift (Foundation + LightCore). WebSocket message models, registry
//   models, HA light attributes <-> LightCapabilities/LightState, LightCommand -> call_service.
//   Builds and tests on Linux (swift:6.1). See LINUX_OK.
// - HomeAssistantKit: the `HomeAssistantProvider` actor over an injected `HAWebSocketTransport`.
//   The URLSessionWebSocketTask transport is Apple-only (`#if canImport(Darwin)`); the provider
//   logic builds on Linux and its tests run against an in-package fake Home Assistant server.
let package = Package(
    name: "HomeAssistantKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "HomeAssistantCodec", targets: ["HomeAssistantCodec"]),
        .library(name: "HomeAssistantKit", targets: ["HomeAssistantKit"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
    ],
    targets: [
        .target(
            name: "HomeAssistantCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .target(
            name: "HomeAssistantKit",
            dependencies: [
                "HomeAssistantCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
        .testTarget(
            name: "HomeAssistantCodecTests",
            dependencies: [
                "HomeAssistantCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HomeAssistantKitTests",
            dependencies: [
                "HomeAssistantKit",
                "HomeAssistantCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
