// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LookinAgentBridge",
    platforms: [.macOS(.v13)],
    products: [.library(name: "LookinAgentBridge", targets: ["LookinAgentBridge"])],
    dependencies: [
        // Ревизия upstream содержит исправление NetworkTransport для Swift 6.3.3.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "68300d7130f95a031284177c89e1e32fe32e7d82"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.94.0")
    ],
    targets: [
        .target(name: "LookinAgentBridge", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio")
        ]),
        .testTarget(name: "LookinAgentBridgeTests", dependencies: ["LookinAgentBridge", .product(name: "MCP", package: "swift-sdk")])
    ]
)
