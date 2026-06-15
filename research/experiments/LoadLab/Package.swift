// swift-tools-version: 5.10
// LoadLab — isolated measurement harness for the mmap/lazy-loading research.
// Lives entirely under research/experiments; does not touch Forge sources.
// Pins the SAME mlx-swift version as Forge (Package.resolved: 0.31.4) so the
// measured behavior is the behavior Forge ships.

import PackageDescription

let package = Package(
    name: "LoadLab",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4")
    ],
    targets: [
        .executableTarget(
            name: "loadlab",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift")
            ]
        )
    ]
)
