// swift-tools-version: 6.0
import PackageDescription

// HueKit: Philips Hue bridge (CLIP v2) support.
// - HueCodec: pure Swift (Foundation + LightCore). Builds and tests on Linux (swift:6.1). See LINUX_OK.
// - HueKit:   the `HueProvider` actor. Its logic is portable and runs against an injected
//             `HueTransport`; the URLSession/Network.framework transport is Apple-only and
//             guarded with `#if canImport(...)`.
// Integration tests against `FakeHueBridge` (Packages/Simulators) run on macOS only.
let package = Package(
    name: "HueKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "HueCodec", targets: ["HueCodec"]),
        .library(name: "HueKit", targets: ["HueKit"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(path: "../../Simulators"),
    ],
    targets: [
        .target(
            name: "HueCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
        .target(
            name: "HueKit",
            dependencies: [
                "HueCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            resources: [.copy("Resources/hue-roots.pem")]
        ),
        .testTarget(
            name: "HueCodecTests",
            dependencies: [
                "HueCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HueKitTests",
            dependencies: [
                "HueKit",
                "HueCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
                // Linux builds skip the simulator (and its swift-nio graph); the integration
                // tests are compiled only where `canImport(Simulators)` holds.
                .product(name: "Simulators", package: "Simulators", condition: .when(platforms: [.macOS])),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
