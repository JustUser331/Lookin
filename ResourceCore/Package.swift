// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LookinResourceCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LookinResourceCore", targets: ["LookinResourceCore"]),
        .library(name: "LookinPreviewSupport", targets: ["LookinPreviewSupport"])
    ],
    targets: [
        .target(name: "LookinResourceCore"),
        .testTarget(name: "LookinResourceCoreTests", dependencies: ["LookinResourceCore"]),
        .target(name: "LookinPreviewSupport"),
        .testTarget(name: "LookinPreviewSupportTests", dependencies: ["LookinPreviewSupport"])
    ]
)
