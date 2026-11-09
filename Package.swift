// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CableTapper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cabletapper", targets: ["CableTapper"]),
        .library(name: "CableTapperCore", targets: ["CableTapperCore"]),
    ],
    dependencies: [
        .package(path: "Vendor/BTHIDKit"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CableTapperCore",
            dependencies: [
                .product(name: "BTHIDKit", package: "BTHIDKit"),
            ]
        ),
        .executableTarget(
            name: "CableTapper",
            dependencies: [
                "CableTapperCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
