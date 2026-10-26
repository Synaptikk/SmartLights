// swift-tools-version: 6.0
import PackageDescription

// NetKit: low-level local-network helpers shared by every brand provider.
// Linux-safe parts (SSE parser, subnet math, TOFU pin store, backoff, hex, HTTP status
// mapping, sweeper) build and test in a `swift:6.1` container. Apple-only parts are
// guarded with `#if canImport(Network)` / `canImport(Darwin)` / `canImport(Security)`.
let package = Package(
    name: "NetKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NetKit", targets: ["NetKit"]),
        .executable(name: "NetKitDemo", targets: ["NetKitDemo"]),
    ],
    targets: [
        .target(name: "NetKit"),
        .executableTarget(name: "NetKitDemo", dependencies: ["NetKit"]),
        .testTarget(name: "NetKitTests", dependencies: ["NetKit"]),
    ]
)
