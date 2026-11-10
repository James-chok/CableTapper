// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CableTapper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CableTapperCore", targets: ["CableTapperCore"]),
        .library(name: "CableTapperMCP", targets: ["CableTapperMCP"]),
    ],
    dependencies: [
        .package(path: "Vendor/BTHIDKit"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "CableTapperCore",
            dependencies: [
                .product(name: "BTHIDKit", package: "BTHIDKit"),
            ]
        ),
        .target(
            name: "CableTapperMCP",
            dependencies: [
                "CableTapperCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
