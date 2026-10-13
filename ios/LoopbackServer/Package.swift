// swift-tools-version: 5.10
// In-app loopback HTTP server and YouTube proxy for the iOS build. Also builds on macOS, so the
// tests run on a Mac with `swift test`.
import PackageDescription

let package = Package(
    name: "LoopbackServer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LoopbackServer", targets: ["LoopbackServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.27.1"),
    ],
    targets: [
        .target(
            name: "LoopbackServer",
            dependencies: [.product(name: "FlyingFox", package: "FlyingFox")]
        ),
        .testTarget(
            name: "LoopbackServerTests",
            dependencies: ["LoopbackServer", .product(name: "FlyingFox", package: "FlyingFox")]
        ),
    ]
)
