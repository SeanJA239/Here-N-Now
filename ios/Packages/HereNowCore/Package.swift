// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HereNowCore",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HereNowCore", targets: ["HereNowCore"])],
    targets: [
        .target(name: "HereNowCore"),
        .testTarget(name: "HereNowCoreTests", dependencies: ["HereNowCore"]),
    ]
)
