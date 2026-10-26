// swift-tools-version: 6.0
import PackageDescription

// LightCore: SmartLights domain model, provider protocol, registry, stores, ColorMath.
// Foundation only; must build and test on Linux (swift:6.1 container). See LINUX_OK.
let package = Package(
    name: "LightCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "LightCore", targets: ["LightCore"]),
    ],
    targets: [
        .target(
            name: "LightCore",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "LightCoreTests",
            dependencies: ["LightCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
