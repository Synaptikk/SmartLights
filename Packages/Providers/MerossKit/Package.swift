// swift-tools-version: 6.0
import PackageDescription

// MerossKit: Meross Wi-Fi lights (msl120/msl320/msl430/msl450, mss560-570 dimmers) for SmartLights.
// Ported from albertogeniola/MerossIot and krahabb/meross_lan (both MIT), see README.md.
//
//  - MerossCodec: pure Swift (Foundation + LightCore + swift-crypto). Cloud sign-in request
//    signing, device list decoding, local `/config` message building/signing/parsing,
//    `Appliance.Encrypt.ECDHE` AES-CBC, HTTP/1.1 framing, light capacity bits and state/command
//    mapping. Builds and tests on Linux.
//  - MerossProvider: the `MerossProvider` actor over `MerossCloudTransport`/`MerossLocalTransport`.
//    URLSession for the cloud everywhere; raw HTTP/1.1 over NWConnection for the LAN on Apple
//    platforms (no ATS exception needed), URLSession on Linux. Tests run it on Linux against
//    in-package fake cloud + device servers.
let package = Package(
    name: "MerossKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MerossCodec", targets: ["MerossCodec"]),
        .library(name: "MerossProvider", targets: ["MerossProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(path: "../../NetKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "MerossCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "MerossProvider",
            dependencies: [
                "MerossCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "NetKit", package: "NetKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "MerossCodecTests",
            dependencies: [
                "MerossCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MerossProviderTests",
            dependencies: [
                "MerossProvider",
                "MerossCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
