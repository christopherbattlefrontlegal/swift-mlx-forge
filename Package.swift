// swift-tools-version: 6.0
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
        .macOS(.v14)
    ],
    products: [
        .executable(name: "mlx-runtime", targets: ["mlx-runtime"]),
        .executable(name: "mlx-studio", targets: ["mlx-studio"]),
        .executable(name: "mlx-forge", targets: ["mlx-forge"])
    ],
    dependencies: [
        // MLX runtime + LLM stack (public source).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),

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
        .package(
            url: "https://github.com/eastriverlee/LLM.swift",
            exact: "1.7.1"),
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
            path: "Sources/mlx-forge"
        )
    ]
)
