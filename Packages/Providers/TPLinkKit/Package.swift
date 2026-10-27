// swift-tools-version: 6.0
import PackageDescription

// TPLinkKit: TP-Link Kasa and Tapo lights (task T2.6, see README.md).
//
//  - TPLinkCodec: pure Swift (Foundation + LightCore + swift-crypto). Legacy Kasa XOR framing,
//    KLAP v1/v2 handshake hashes and AES-128-CBC session, IOT/SMART JSON requests, discovery
//    datagrams (UDP 9999 / 20002), model capability table, state/command mapping. Linux + Apple.
//  - TPLinkProvider: the `TPLinkProvider` actor. Platform neutral (POSIX TCP for legacy Kasa,
//    URLSession for KLAP); the NetKit UDP discovery environment is `#if canImport(Darwin)`.
//    Its tests run on Linux against an in-package fake Kasa (TCP) and fake Tapo KLAP (HTTP) device.
let package = Package(
    name: "TPLinkKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "TPLinkCodec", targets: ["TPLinkCodec"]),
        .library(name: "TPLinkProvider", targets: ["TPLinkProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "TPLinkCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "TPLinkProvider",
            dependencies: [
                "TPLinkCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "TPLinkCodecTests",
            dependencies: [
                "TPLinkCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "TPLinkProviderTests",
            dependencies: [
                "TPLinkProvider",
                "TPLinkCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
