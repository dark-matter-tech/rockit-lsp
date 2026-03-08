// swift-tools-version: 5.9
// Rockit Language Server Protocol
// Dark Matter Tech

import PackageDescription

let package = Package(
    name: "RockitLSP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "rockit-lsp", targets: ["RockitLSPCLI"]),
        .library(name: "RockitLSP", targets: ["RockitLSP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dark-matter-tech/rockit-booster.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "RockitLSP",
            dependencies: [
                .product(name: "RockitKit", package: "rockit-booster"),
            ],
            path: "Sources/RockitLSP"
        ),
        .executableTarget(
            name: "RockitLSPCLI",
            dependencies: ["RockitLSP"],
            path: "Sources/RockitLSPCLI"
        ),
    ]
)
