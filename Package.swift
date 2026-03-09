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
        .library(name: "RockitLSPLib", targets: ["RockitLSPLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dark-matter-tech/rockit-booster.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "RockitLSPLib",
            dependencies: [
                .product(name: "RockitKit", package: "rockit-booster"),
            ],
            path: "Sources/RockitLSP"
        ),
        .executableTarget(
            name: "RockitLSPCLI",
            dependencies: ["RockitLSPLib"],
            path: "Sources/RockitLSPCLI"
        ),
    ]
)
