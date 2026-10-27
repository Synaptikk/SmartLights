// swift-tools-version: 6.0
import PackageDescription

// SwitchBotKit: SwitchBot lights through the official cloud API v1.1
// (https://github.com/OpenWonderLabs/SwitchBotAPI), see README.md.
//
//  - SwitchBotCodec: pure Swift (Foundation + LightCore + swift-crypto). HMAC-SHA256 request
//    signing, request builders, response/status decoding, light type table, LightCommand ->
//    commands and status -> LightState mapping. Builds and tests on Linux.
//  - SwitchBotProvider: the `SwitchBotProvider` actor over a `SwitchBotHTTPTransport`
//    (URLSession on Apple platforms and Linux), daily request budget via LightCore `RateLimiter`.
//    Tests run it on Linux against an in-package fake SwitchBot cloud.
let package = Package(
    name: "SwitchBotKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SwitchBotCodec", targets: ["SwitchBotCodec"]),
        .library(name: "SwitchBotProvider", targets: ["SwitchBotProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "SwitchBotCodec",
            dependencies: [
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "SwitchBotProvider",
            dependencies: [
                "SwitchBotCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "SwitchBotCodecTests",
            dependencies: [
                "SwitchBotCodec",
                .product(name: "LightCore", package: "LightCore"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SwitchBotProviderTests",
            dependencies: [
                "SwitchBotProvider",
                "SwitchBotCodec",
                .product(name: "LightCore", package: "LightCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
