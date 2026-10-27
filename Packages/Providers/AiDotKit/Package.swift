// swift-tools-version: 6.0
import PackageDescription

// AiDotKit: AiDot / Linkind Wi-Fi lights (python-aidot protocol port, see README.md).
// - AiDotCodec: pure Swift (Foundation + LightCore + swift-crypto); builds and tests on Linux.
// - AiDotKit:   AiDotProvider actor. TCP via NWConnection and UDP via NetKit on Apple platforms;
//               a small POSIX fallback transport keeps it buildable/testable on Linux.
let package = Package(
    name: "AiDotKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AiDotCodec", targets: ["AiDotCodec"]),
        .library(name: "AiDotKit", targets: ["AiDotKit"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
        // Test-only: fake AiDot cloud + device for integration tests.
        .package(path: "../../Simulators"),
    ],
    targets: [
        .target(
            name: "AiDotCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "AiDotKit",
            dependencies: [
                "AiDotCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
        .testTarget(
            name: "AiDotCodecTests",
            dependencies: [
                "AiDotCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AiDotKitTests",
            dependencies: [
                "AiDotKit",
                "AiDotCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Simulators", package: "Simulators"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
