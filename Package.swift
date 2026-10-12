// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tinytowngen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tinytowngen", targets: ["tinytowngen"]),
    ],
    targets: [
        .target(name: "TinyTownCore"),
        .executableTarget(name: "tinytowngen", dependencies: ["TinyTownCore"]),
        .testTarget(name: "TinyTownCoreTests", dependencies: ["TinyTownCore"]),
    ]
)
