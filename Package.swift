// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "auto-wifi",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AutoWiFi", targets: ["AutoWiFi"]),
        .library(name: "Algorithms", targets: ["Algorithms"]),
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .executableTarget(
            name: "AutoWiFi",
            dependencies: ["Core", "Algorithms"],
            path: "Sources/AutoWiFi"
        ),
        .target(
            name: "Algorithms",
            dependencies: ["Core"],
            path: "Sources/Algorithms"
        ),
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        // CLT doesn't ship XCTest or swift-testing, so the Algorithms tests run as a plain
        // executable target instead. `swift run AlgorithmsRunner` produces pass/fail output
        // and exits non-zero on failure (so it slots cleanly into `make test`). Phase 3
        // will reinstate a real `.testTarget` once Xcode is installed.
        .executableTarget(
            name: "AlgorithmsRunner",
            dependencies: ["Algorithms", "Core"],
            path: "Tests/AlgorithmsRunner"
        ),
    ],
    swiftLanguageModes: [.v6]
)
