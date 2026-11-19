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
        // Speech recognition (FluidAudio), shared by the app and the benchmark; keeps PoptalkCore dependency-free.
        .target(name: "PoptalkSpeech", dependencies: ["PoptalkCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(
            name: "Poptalk",
            dependencies: ["PoptalkCore", "PoptalkSpeech", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "PoptalkBench", dependencies: ["PoptalkCore", "PoptalkSpeech"]),
        .testTarget(name: "PoptalkCoreTests", dependencies: ["PoptalkCore"]),
    ]
)
