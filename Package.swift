// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CouchRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CouchRemote", targets: ["CouchRemote"]),
        .executable(name: "tvctl", targets: ["tvctl"]),
        // Self-contained: depends on nothing in this repo, so it can move to its own package later.
        .library(name: "TVKit", targets: ["TVKit"]),
    ],
    targets: [
        .target(name: "TVKit", exclude: ["README.md"], resources: [.copy("Resources/AppIcons")]),
        .executableTarget(name: "CouchRemote", dependencies: ["TVKit"]),
        .executableTarget(name: "tvctl", dependencies: ["TVKit"]),
        .testTarget(name: "TVKitTests", dependencies: ["TVKit"]),
    ],
    swiftLanguageModes: [.v5]
)
