// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LMChat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChatCore", targets: ["ChatCore"]),
        .library(name: "ChatUI", targets: ["ChatUI"]),
        .executable(name: "chatcli", targets: ["chatcli"]),
    ],
    targets: [
        .target(name: "ChatCore"),
        .target(name: "ChatUI", dependencies: ["ChatCore"]),
        .executableTarget(name: "chatcli", dependencies: ["ChatCore"]),
        .executableTarget(name: "uisnapshot", dependencies: ["ChatUI"]),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatUITests", dependencies: ["ChatUI", "ChatCore"]),
    ]
)
