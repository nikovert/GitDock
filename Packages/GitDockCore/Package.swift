// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitDockCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitDockCore", targets: ["GitDockCore"]),
        .executable(name: "GitDockCoreChecks", targets: ["GitDockCoreChecks"]),
        .executable(name: "GitDockWorkspaceCLI", targets: ["GitDockWorkspaceCLI"]),
    ],
    targets: [
        .target(name: "GitDockCore"),
        .executableTarget(
            name: "GitDockCoreChecks",
            dependencies: ["GitDockCore"],
            path: "Checks/GitDockCoreChecks"
        ),
        .executableTarget(
            name: "GitDockWorkspaceCLI",
            dependencies: ["GitDockCore"],
            path: "CLI/GitDockWorkspaceCLI"
        ),
        .testTarget(
            name: "GitDockCoreTests",
            dependencies: ["GitDockCore"]
        ),
    ]
)
