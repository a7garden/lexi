// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LexiCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LexiCore", targets: ["LexiCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.29.1")),
    ],
    targets: [
        .target(
            name: "LexiCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLXEmbedders", package: "mlx-swift-examples"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "LexiCoreTests",
            dependencies: ["LexiCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
