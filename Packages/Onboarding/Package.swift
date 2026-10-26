// swift-tools-version: 6.0
import PackageDescription

// Onboarding: data-driven "Add a brand" wizard (PLAN.md D8, §7).
// Model, catalog, runner and text renderer are pure Swift and build/test on Linux (see LINUX_OK);
// SwiftUI views live under `#if canImport(SwiftUI)` and are built by the macOS/iOS CI.
let package = Package(
    name: "Onboarding",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "Onboarding", targets: ["Onboarding"]),
    ],
    dependencies: [
        .package(path: "../LightCore"),
    ],
    targets: [
        .target(
            name: "Onboarding",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "OnboardingTests",
            dependencies: [
                "Onboarding",
                .product(name: "LightCore", package: "LightCore"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
