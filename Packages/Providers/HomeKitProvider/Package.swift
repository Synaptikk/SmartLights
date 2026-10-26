// swift-tools-version: 6.0
import PackageDescription

// HomeKitProvider: Apple Home (HomeKit, incl. Matter accessories added to Apple Home) as a
// SmartLights `LightProvider`.
//
// Layout:
//  - HomeKitSession.swift / HomeKitMapper.swift / HomeKitProvider.swift: platform-neutral logic
//    over value snapshots; builds and tests on Linux (LINUX_OK) and Apple.
//  - HMHomeKitSession.swift: the only file that imports HomeKit, guarded with
//    `#if canImport(HomeKit) && !os(macOS)` (no AppKit HomeKit). IOS_ONLY makes the macOS CI
//    job build and test this package on the iOS simulator so the adapter is compiled.
let package = Package(
    name: "HomeKitProvider",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "HomeKitProvider", targets: ["HomeKitProvider"]),
    ],
    dependencies: [
        .package(path: "../../LightCore"),
    ],
    targets: [
        .target(
            name: "HomeKitProvider",
            dependencies: [.product(name: "LightCore", package: "LightCore")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HomeKitProviderTests",
            dependencies: [
                "HomeKitProvider",
                .product(name: "LightCore", package: "LightCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
