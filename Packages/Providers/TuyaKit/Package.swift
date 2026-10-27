// swift-tools-version: 6.0
import PackageDescription

// TuyaKit: Tuya / Smart Life white-label Wi-Fi lights over the local protocol (tinytuya port, see README.md).
// - TuyaCodec: pure Swift (Foundation + LightCore + swift-crypto); 55AA/6699 framing, AES-ECB/GCM,
//              CRC32/HMAC trailers, 3.4/3.5 session keys, UDP discovery, DPS <-> LightState mapping.
//              Builds and tests on Linux.
// - TuyaKit:   TuyaProvider actor. TCP via NWConnection and UDP via NetKit on Apple platforms; a small
//              POSIX fallback keeps it buildable/testable on Linux against the in-package fake device.
let package = Package(
    name: "TuyaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TuyaCodec", targets: ["TuyaCodec"]),
        .library(name: "TuyaKit", targets: ["TuyaKit"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "TuyaCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TuyaKit",
            dependencies: [
                "TuyaCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
        .testTarget(
            name: "TuyaCodecTests",
            dependencies: [
                "TuyaCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "TuyaKitTests",
            dependencies: [
                "TuyaKit",
                "TuyaCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
