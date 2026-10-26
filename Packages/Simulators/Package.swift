// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Simulators",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "Simulators", targets: ["Simulators"]),
        .executable(name: "simctl", targets: ["simctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Simulators",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .executableTarget(
            name: "simctl",
            dependencies: ["Simulators"]
        ),
        .testTarget(
            name: "SimulatorsTests",
            dependencies: [
                "Simulators",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
    ]
)
