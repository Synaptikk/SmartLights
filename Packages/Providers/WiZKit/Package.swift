// swift-tools-version: 6.0
import PackageDescription

// WiZKit: WiZ local UDP protocol (research/research_wiz.md).
// - WiZCodec: pure Swift (Foundation + swift-crypto + LightCore); JSON codec, HMAC signing,
//   moduleName/capability decoding, scenes, state mapping. Builds and tests on Linux.
// - WiZKit: the `WiZProvider` actor. Its transport is a protocol; the NetKit BSD-socket
//   implementation is guarded with `#if canImport(Darwin)`, so the provider logic also builds
//   on Linux and its integration tests run against `FakeWiZBulb` (Packages/Simulators).
let package = Package(
    name: "WiZKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "WiZCodec", targets: ["WiZCodec"]),
        .library(name: "WiZKit", targets: ["WiZKit"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Test-only:
        .package(path: "../../Simulators"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "WiZCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "WiZKit",
            dependencies: [
                "WiZCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
        .testTarget(
            name: "WiZCodecTests",
            dependencies: ["WiZCodec", .product(name: "LightCore", package: "LightCore")]
        ),
        .testTarget(
            name: "WiZKitTests",
            dependencies: [
                "WiZKit",
                "WiZCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
                .product(name: "Simulators", package: "Simulators"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
