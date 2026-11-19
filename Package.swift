// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Poptalk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.33.0"),
        // mlx-swift-lm 3.x ships no tokenizer or downloader; these are its documented integration (MLXHuggingFace macros).
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.4.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "1.0.1"),
    ],
    targets: [
        .target(name: "PoptalkCore"),
        // Speech recognition (FluidAudio), shared by the app and the benchmark; keeps PoptalkCore dependency-free.
        .target(name: "PoptalkSpeech", dependencies: ["PoptalkCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        // In-process MLX inference (the `mlx` provider), shared by the app and the benchmark.
        .target(name: "PoptalkMLX", dependencies: [
            "PoptalkCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .executableTarget(
            name: "Poptalk",
            dependencies: ["PoptalkCore", "PoptalkSpeech", "PoptalkMLX", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "PoptalkBench", dependencies: ["PoptalkCore", "PoptalkSpeech", "PoptalkMLX"]),
        .testTarget(name: "PoptalkCoreTests", dependencies: ["PoptalkCore"]),
    ]
)
