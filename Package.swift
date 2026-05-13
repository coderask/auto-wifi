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
            dependencies: ["Core"],
            path: "Sources/AutoWiFi"
        ),
        .target(
            name: "Algorithms",
            path: "Sources/Algorithms"
        ),
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        // NOTE: AlgorithmsTests target intentionally omitted until Xcode is installed.
        // Command Line Tools doesn't ship XCTest or swift-testing. Phase 3 will reinstate
        // a `.testTarget` using Swift Testing per ARCHITECTURE.md "Pattern 5".
    ],
    swiftLanguageModes: [.v6]
)
