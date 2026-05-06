// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProjectHooks",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "GitHooksCore", targets: ["GitHooksCore"]),
        .executable(name: "project-hooks", targets: ["GitHooksCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "GitHooksCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
        ),
        .executableTarget(
            name: "GitHooksCLI",
            dependencies: [
                "GitHooksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
        ),
        .testTarget(
            name: "GitHooksCoreTests",
            dependencies: ["GitHooksCore"],
        ),
    ],
)
