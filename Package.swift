// swift-tools-version: 6.2
// Swift-native Forge app with in-process MLX and GGUF inference.
//
// Architecture note: in mlx-swift-lm 3.x the LLM/VLM libraries and the
// tokenizer/downloader integration were decoupled. This manifest re-assembles
// the pieces Forge needs:
//   - MLXLLM / MLXVLM / MLXLMCommon / MLXHuggingFace : public mlx-swift-lm package
//   - HuggingFace (HubClient/HubCache/Repo)          : huggingface/swift-huggingface
//   - Tokenizers / Hub (AutoTokenizer)               : huggingface/swift-transformers

import PackageDescription

let package = Package(
    name: "forge_swift_open_source",
    platforms: [
        // Forge currently targets the macOS 26 SDK surface used by the native app.
        .macOS(.v26)
    ],
    // swift-tools-version 6.2 already selects Swift 6 language mode (data-race safety
    // by default); confirmed building with -swift-version 6 on the Swift 6.4 toolchain.
    products: [
        .executable(name: "mlx-forge", targets: ["mlx-forge"])
    ],
    dependencies: [
        // MLX runtime + LLM stack (public source).
        // 3.31.4 adds pure Mamba2 (SSM) models, Mixtral, and generation seeding.
        // Vendored from mlx-swift-lm 3.31.4 so Forge can carry its native
        // Qwen3.5/Qwen3.6 MTP implementation until it lands upstream.
        .package(path: "Vendor/mlx-swift-lm"),

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

        // llama.cpp (GGUF) backend for the Forge app — Metal-accelerated,
        // compiled in-process (sandbox-safe). Second engine next to MLX.
        // Vendored fork of eastriverlee/LLM.swift 2.1.0 with the bundled
        // llama.xcframework upgraded to llama.cpp b9870 — required for the
        // nemotron_h_moe architecture (Nemotron 3 Super/Nano MoE GGUFs).
        .package(path: "Vendor/LLM.swift"),
    ],
    targets: [
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
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/mlx-forge"
        )
    ]
)
