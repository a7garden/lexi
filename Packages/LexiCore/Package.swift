// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LexiCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LexiCore", targets: ["LexiCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(name: "LexiCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LexiCoreTests", dependencies: ["LexiCore"])
    ]
)
