// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Poptalk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "PoptalkCore"),
        .executableTarget(
            name: "Poptalk",
            dependencies: ["PoptalkCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "PoptalkBench", dependencies: ["PoptalkCore"]),
        .testTarget(name: "PoptalkCoreTests", dependencies: ["PoptalkCore"]),
    ]
)
