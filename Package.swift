// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RepoCommons",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RepoCommonsCore"),
        .executableTarget(name: "RepoCommons", dependencies: ["RepoCommonsCore"]),
        .testTarget(name: "RepoCommonsCoreTests", dependencies: ["RepoCommonsCore"]),
    ]
)
