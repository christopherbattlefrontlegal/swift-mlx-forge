// swift-tools-version: 6.2
// Swift-native, headless MLX runtime.
//
// This package builds the existing mlx-swift-examples `llm-tool` sources as a
// standalone command-line executable. It performs direct, in-process MLX
// inference on Apple Silicon: no Python, no server, no daemon, no REST API.
//
// Architecture note: in mlx-swift-lm 3.x the LLM/VLM libraries and the
// tokenizer/downloader integration were decoupled. This manifest re-assembles
// the pieces the CLI needs:
//   - MLXLLM / MLXVLM / MLXLMCommon / MLXHuggingFace : public mlx-swift-lm package
//   - HuggingFace (HubClient/HubCache/Repo)          : huggingface/swift-huggingface
//   - Tokenizers / Hub (AutoTokenizer)               : huggingface/swift-transformers
//   - ArgumentParser                                 : apple/swift-argument-parser

import PackageDescription

let package = Package(
    name: "forge_swift_open_source",
    platforms: [
        // Deploy to macOS 26 so the app still runs on the prior OS; the Foundation Models
        // LLM-provider API is macOS 27.0+, so that code is gated with `if #available`.
        .macOS(.v26)
    ],
    // swift-tools-version 6.2 already selects Swift 6 language mode (data-race safety
    // by default); confirmed building with -swift-version 6 on the Swift 6.4 toolchain.
    products: [
        .executable(name: "mlx-runtime", targets: ["mlx-runtime"]),
        .executable(name: "mlx-studio", targets: ["mlx-studio"]),
        .executable(name: "mlx-forge", targets: ["mlx-forge"])
    ],
    dependencies: [
        // MLX runtime + LLM stack (public source).
        // 3.31.4 adds pure Mamba2 (SSM) models, Mixtral, and generation seeding.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),

        // PrismML fork of mlx-swift: upstream main (>= 0.31.4) plus 1-bit affine
        // quantization Metal kernels (Bonsai models). Root-package declaration
        // overrides mlx-swift-lm's transitive ml-explore/mlx-swift dependency.
        .package(
            url: "https://github.com/PrismML-Eng/mlx-swift.git",
            revision: "e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230"),

        // Tokenizer + downloader integration packages required by the
        // MLXHuggingFace macros used in the tool sources.
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.9.0"),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.0"),

        // CLI argument parsing.
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.6.2"),

        // llama.cpp (GGUF) backend for the Forge app — Metal-accelerated,
        // compiled in-process (sandbox-safe). Second engine next to MLX.
        // 2.1.0: newer llama.cpp runtime, multi-turn fix, and ThinkingMode
        // (separate reasoning stream + suppressed-thinking toggle).
        .package(
            url: "https://github.com/eastriverlee/LLM.swift",
            exact: "2.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "mlx-runtime",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/mlx-runtime"
        ),
        .executableTarget(
            name: "mlx-studio",
            dependencies: [],
            path: "Sources/mlx-studio"
        ),
        .executableTarget(
            name: "mlx-forge",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "LLM", package: "LLM.swift"),
            ],
            path: "Sources/mlx-forge",
            linkerSettings: [
                .linkedFramework("FoundationModels"),
            ]
        )
    ]
)
