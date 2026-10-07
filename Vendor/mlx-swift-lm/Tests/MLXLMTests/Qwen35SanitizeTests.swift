// Copyright © 2026 Apple Inc.
//
// Qwen35 sanitize regression tests.
//
// 1. Issue #143: the VLM sanitize must remap bare `model.*` weight keys to
//    `language_model.model.*`. Pre-fix the keys fell through unchanged and
//    `language_model` lost its tensors at load time.
// 2. Upstream #598: the RMSNorm "+1" shift (raw HuggingFace checkpoints store
//    norm weights as offsets from one) must key on the conv1d layout only. A
//    converted checkpoint that keeps its inline MTP tensors is already shifted;
//    shifting it again doubles every layer's activation scale and the model
//    emits garbage. Pinned for both the text-only and the VLM sanitize.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import XCTest

final class Qwen35SanitizeTests: XCTestCase {

    private func makeMinimalConfig() throws -> MLXVLM.Qwen35Configuration {
        // Minimum-viable config with small dims so module init stays cheap.
        // Only the fields without defaults need values; everything else
        // falls back to the public defaults (which we never exercise in the
        // sanitize-only test).
        let json = """
            {
                "model_type": "qwen3_5_moe_vl",
                "text_config": {
                    "hidden_size": 8,
                    "num_hidden_layers": 1,
                    "intermediate_size": 16,
                    "num_attention_heads": 1,
                    "num_key_value_heads": 1,
                    "linear_num_value_heads": 1,
                    "linear_num_key_heads": 1,
                    "linear_key_head_dim": 8,
                    "linear_value_head_dim": 8,
                    "linear_conv_kernel_dim": 4,
                    "vocab_size": 32,
                    "full_attention_interval": 2,
                    "num_experts": 0,
                    "num_experts_per_tok": 0
                },
                "vision_config": {
                    "model_type": "qwen3_5_moe_vl",
                    "depth": 1,
                    "hidden_size": 8,
                    "intermediate_size": 16,
                    "out_hidden_size": 8,
                    "num_heads": 1,
                    "patch_size": 16,
                    "spatial_merge_size": 1,
                    "temporal_patch_size": 1,
                    "num_position_embeddings": 8
                }
            }
            """
        return try JSONDecoder().decode(
            MLXVLM.Qwen35Configuration.self, from: Data(json.utf8))
    }

    /// Text-only Qwen3.5 configuration with small dims; sanitize never runs the model.
    private func makeMinimalTextConfig() throws -> MLXLLM.Qwen35Configuration {
        let json = """
            {
                "model_type": "qwen3_5",
                "text_config": {
                    "model_type": "qwen3_5_text",
                    "hidden_size": 64,
                    "num_hidden_layers": 4,
                    "intermediate_size": 128,
                    "num_attention_heads": 2,
                    "num_key_value_heads": 1,
                    "head_dim": 32,
                    "linear_num_value_heads": 2,
                    "linear_num_key_heads": 1,
                    "linear_key_head_dim": 16,
                    "linear_value_head_dim": 16,
                    "linear_conv_kernel_dim": 4,
                    "vocab_size": 64,
                    "full_attention_interval": 4
                }
            }
            """
        return try JSONDecoder().decode(
            MLXLLM.Qwen35Configuration.self, from: Data(json.utf8))
    }

    /// Pre-fix, weights with `model.*` paths (no `language_model` prefix and
    /// no `visual` prefix) fell through `sanitize` unchanged, so the
    /// `language_model` submodule received no weights and load failed with
    /// `keyNotFound`.
    func testBareModelKeysAreRemapped() throws {
        let config = try makeMinimalConfig()
        let model = Qwen35(config)

        // 2D dummy avoids tripping vision-side sanitize transposes for any
        // weights that flow through the Qwen3VL vision model's sanitize at
        // the end of Qwen35.sanitize — only language-side keys are tested.
        let dummy = MLXArray.zeros([1, 1])
        let weights: [String: MLXArray] = [
            // Path that issue #143 calls out: bare `model.layers.*`.
            "model.layers.0.mlp.up_proj.weight": dummy,
            "model.layers.0.self_attn.q_proj.weight": dummy,
            "model.embed_tokens.weight": dummy,
            "model.norm.weight": dummy,
            // Already-namespaced path — verify the existing rename branch
            // still fires.
            "model.language_model.layers.0.mlp.up_proj.weight": dummy,
            // Top-level path the existing logic remaps.
            "lm_head.weight": dummy,
        ]

        let sanitized = model.sanitize(weights: weights)

        // Bare `model.*` keys are now under `language_model.model.*`.
        XCTAssertNotNil(
            sanitized["language_model.model.layers.0.mlp.up_proj.weight"],
            "bare `model.layers.0.mlp.up_proj.weight` must be remapped")
        XCTAssertNotNil(
            sanitized["language_model.model.layers.0.self_attn.q_proj.weight"])
        XCTAssertNotNil(sanitized["language_model.model.embed_tokens.weight"])
        XCTAssertNotNil(sanitized["language_model.model.norm.weight"])

        // The `lm_head` rename branch is preserved.
        XCTAssertNotNil(sanitized["language_model.lm_head.weight"])

        // None of the bare `model.*` keys remain in the sanitized dict.
        for key in sanitized.keys {
            XCTAssertFalse(
                key.hasPrefix("model.layers.")
                    || key == "model.embed_tokens.weight"
                    || key == "model.norm.weight",
                "bare model.* key leaked through sanitize: \(key)")
        }
    }

    // MARK: - Norm shift keyed on conv1d layout (upstream #598)

    private static let conv1dKey = "language_model.model.layers.0.linear_attn.conv1d.weight"
    private static let inputNormKey = "language_model.model.layers.0.input_layernorm.weight"
    private static let postNormKey =
        "language_model.model.layers.0.post_attention_layernorm.weight"
    private static let finalNormKey = "language_model.model.norm.weight"

    /// Language-side tensors in the namespace the loaders hand to `sanitize`,
    /// with every norm at exactly 1 and an inline MTP head alongside, as
    /// converted Qwen3.8 checkpoints ship it.
    private func languageWeights(conv1d: MLXArray, hidden: Int) -> [String: MLXArray] {
        [
            Self.conv1dKey: conv1d,
            Self.inputNormKey: MLXArray.ones([hidden]),
            Self.postNormKey: MLXArray.ones([hidden]),
            Self.finalNormKey: MLXArray.ones([hidden]),
            "language_model.mtp.fc.weight": MLXArray.zeros([hidden, hidden * 2]),
            "language_model.mtp.norm.weight": MLXArray.ones([hidden]),
        ]
    }

    private func assertNorm(
        _ weights: [String: MLXArray], _ key: String, equals expected: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let array = weights[key] else {
            XCTFail("missing \(key)", file: file, line: line)
            return
        }
        let values = array.asArray(Float.self)
        XCTAssertFalse(values.isEmpty, "\(key) is empty", file: file, line: line)
        XCTAssertTrue(
            values.allSatisfy { $0 == expected },
            "\(key): expected every element \(expected), got \(Array(values.prefix(4)))",
            file: file, line: line)
    }

    /// Converted layout ([C, K, 1]) plus MTP tensors: the norms are already in
    /// MLX convention and must stay at 1.
    func testTextModelKeepsConvertedNormsDespiteMTPTensors() throws {
        let model = Qwen35Model(try makeMinimalTextConfig())
        let sanitized = model.sanitize(
            weights: languageWeights(conv1d: MLXArray.zeros([64, 4, 1]), hidden: 64))

        assertNorm(sanitized, Self.inputNormKey, equals: 1)
        assertNorm(sanitized, Self.postNormKey, equals: 1)
        assertNorm(sanitized, Self.finalNormKey, equals: 1)
        XCTAssertEqual(sanitized[Self.conv1dKey]?.shape, [64, 4, 1])
        if !QwenNativeMTPConfig.retainWeights {
            XCTAssertFalse(
                sanitized.keys.contains { $0.contains("mtp.") },
                "inline MTP tensors must be dropped without the sidecar flag")
        }
    }

    /// Raw HuggingFace layout ([C, 1, K]): the conv1d is moved into MLX layout
    /// and every norm gains one.
    func testTextModelShiftsNormsForRawCheckpointLayout() throws {
        let model = Qwen35Model(try makeMinimalTextConfig())
        let sanitized = model.sanitize(
            weights: languageWeights(conv1d: MLXArray.zeros([64, 1, 4]), hidden: 64))

        assertNorm(sanitized, Self.inputNormKey, equals: 2)
        assertNorm(sanitized, Self.postNormKey, equals: 2)
        assertNorm(sanitized, Self.finalNormKey, equals: 2)
        XCTAssertEqual(sanitized[Self.conv1dKey]?.shape, [64, 4, 1])
    }

    func testVLMKeepsConvertedNormsDespiteMTPTensors() throws {
        let model = Qwen35(try makeMinimalConfig())
        let sanitized = model.sanitize(
            weights: languageWeights(conv1d: MLXArray.zeros([8, 4, 1]), hidden: 8))

        assertNorm(sanitized, Self.inputNormKey, equals: 1)
        assertNorm(sanitized, Self.postNormKey, equals: 1)
        assertNorm(sanitized, Self.finalNormKey, equals: 1)
        XCTAssertEqual(sanitized[Self.conv1dKey]?.shape, [8, 4, 1])
        XCTAssertFalse(sanitized.keys.contains { $0.contains("mtp.") })
    }

    func testVLMShiftsNormsForRawCheckpointLayout() throws {
        let model = Qwen35(try makeMinimalConfig())
        let sanitized = model.sanitize(
            weights: languageWeights(conv1d: MLXArray.zeros([8, 1, 4]), hidden: 8))

        assertNorm(sanitized, Self.inputNormKey, equals: 2)
        assertNorm(sanitized, Self.postNormKey, equals: 2)
        assertNorm(sanitized, Self.finalNormKey, equals: 2)
        XCTAssertEqual(sanitized[Self.conv1dKey]?.shape, [8, 4, 1])
    }

    /// With retention on, an inline head's bare `mtp.<name>` keys move into the
    /// module's array namespace `mtp.0.<name>`, and its norms stay untouched.
    func testInlineMTPKeysAreRemappedWhenRetained() throws {
        QwenNativeMTPConfig.retainWeights = true
        defer { QwenNativeMTPConfig.resetRetainWeights() }
        let model = Qwen35Model(try makeMinimalTextConfig())
        let sanitized = model.sanitize(
            weights: languageWeights(conv1d: MLXArray.zeros([64, 4, 1]), hidden: 64))

        XCTAssertNil(sanitized["language_model.mtp.fc.weight"])
        XCTAssertEqual(sanitized["language_model.mtp.0.fc.weight"]?.shape, [64, 128])
        assertNorm(sanitized, "language_model.mtp.0.norm.weight", equals: 1)
        assertNorm(sanitized, Self.inputNormKey, equals: 1)
    }

    /// Sidecar keys already carry the head index and pass through unchanged.
    func testIndexedMTPKeysPassThroughWhenRetained() throws {
        QwenNativeMTPConfig.retainWeights = true
        defer { QwenNativeMTPConfig.resetRetainWeights() }
        let model = Qwen35Model(try makeMinimalTextConfig())
        var weights = languageWeights(conv1d: MLXArray.zeros([64, 4, 1]), hidden: 64)
        weights["language_model.mtp.fc.weight"] = nil
        weights["language_model.mtp.norm.weight"] = nil
        weights["language_model.mtp.0.fc.weight"] = MLXArray.zeros([64, 128])
        let sanitized = model.sanitize(weights: weights)

        XCTAssertEqual(sanitized["language_model.mtp.0.fc.weight"]?.shape, [64, 128])
        XCTAssertFalse(sanitized.keys.contains("language_model.mtp.0.0.fc.weight"))
    }
}
