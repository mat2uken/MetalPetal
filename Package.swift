// swift-tools-version:5.1

// requires SE-0271

import PackageDescription

let package = Package(
    name: "MetalPetal",
    platforms: [.macOS(.v10_13), .iOS(.v11), .tvOS(.v13)],
    products: [
        .library(
            name: "MetalPetal",
            targets: ["MetalPetal"]
        ),
        .executable(
            name: "MetalPetalBenchmarks",
            targets: ["MetalPetalBenchmarks"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MetalPetal",
            dependencies: ["MetalPetalObjectiveC"]),
        .target(
            name: "MetalPetalObjectiveC",
            dependencies: []),
        .target(
            name: "MetalPetalTestHelpers",
            dependencies: ["MetalPetal"],
            path: "Tests/MetalPetalTestHelpers"),
        .target(
            name: "MetalPetalBenchmarks",
            dependencies: ["MetalPetal", "MetalPetalTestHelpers"],
            path: "Benchmarks/MetalPetalBenchmarks"),
        .testTarget(
            name: "MetalPetalTests",
            dependencies: ["MetalPetal", "MetalPetalTestHelpers"]),
    ],
    cxxLanguageStandard: .cxx14
)
