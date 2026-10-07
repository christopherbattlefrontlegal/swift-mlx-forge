// Qwen3.8 checkpoints converted across the transformers v5 schema change ship
// `rope_parameters` (type default) *and* a legacy `rope_scaling` block carrying the
// YaRN factors. These tests pin the merge in both decoders and the explicit
// `attention_factor` handling in `YarnRoPE`.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import MLXLLM
@testable import MLXVLM

private let defaultRopeParameters = """
    {"mrope_interleaved": true, "mrope_section": [11, 11, 10], "partial_rotary_factor": 0.25,
     "rope_theta": 10000000, "type": "default"}
    """

private let legacyYarnScaling = """
    {"type": "yarn", "rope_type": "yarn", "factor": 4.0, "original_max_position_embeddings": 262144,
     "attention_factor": 1.0, "beta_fast": 32.0, "beta_slow": 1.0}
    """

private func qwen35TextJSON(ropeParameters: String, ropeScaling: String?) -> Data {
    var fields = [
        "\"model_type\": \"qwen3_5_text\"",
        "\"hidden_size\": 64",
        "\"num_hidden_layers\": 4",
        "\"intermediate_size\": 128",
        "\"num_attention_heads\": 2",
        "\"num_key_value_heads\": 1",
        "\"head_dim\": 32",
        "\"linear_num_value_heads\": 2",
        "\"linear_num_key_heads\": 1",
        "\"linear_key_head_dim\": 16",
        "\"linear_value_head_dim\": 16",
        "\"linear_conv_kernel_dim\": 4",
        "\"vocab_size\": 64",
        "\"full_attention_interval\": 4",
        "\"max_position_embeddings\": 1048576",
        "\"rope_parameters\": \(ropeParameters)",
    ]
    if let ropeScaling {
        fields.append("\"rope_scaling\": \(ropeScaling)")
    }
    return Data(("{" + fields.joined(separator: ",\n") + "}").utf8)
}

private func typeName(_ config: [String: StringOrNumber]?) -> String? {
    if case .string(let name)? = config?["type"] { return name }
    return nil
}

@Test func qwen35TextConfigurationMergesLegacyYarnScaling() throws {
    let config = try JSONDecoder().decode(
        MLXLLM.Qwen35TextConfiguration.self,
        from: qwen35TextJSON(ropeParameters: defaultRopeParameters, ropeScaling: legacyYarnScaling))

    let scaling = try #require(config.ropeScaling)
    #expect(typeName(scaling) == "yarn")
    #expect(scaling["factor"]?.asFloat() == 4.0)
    #expect(scaling["original_max_position_embeddings"]?.asInt() == 262_144)
    #expect(scaling["attention_factor"]?.asFloat() == 1.0)
    #expect(scaling["beta_fast"]?.asFloat() == 32.0)
    // Base geometry stays with `rope_parameters`.
    #expect(scaling["mrope_section"]?.asInts() == [11, 11, 10])
    #expect(config.ropeTheta == 10_000_000)
    #expect(config.partialRotaryFactor == 0.25)
    #expect(config.maxPositionEmbeddings == 1_048_576)
}

@Test func qwen35TextConfigurationKeepsExplicitRopeParametersType() throws {
    let explicitYarn = """
        {"mrope_section": [11, 11, 10], "partial_rotary_factor": 0.25, "rope_theta": 10000000,
         "rope_type": "yarn", "factor": 2.0, "original_max_position_embeddings": 262144}
        """
    let config = try JSONDecoder().decode(
        MLXLLM.Qwen35TextConfiguration.self,
        from: qwen35TextJSON(ropeParameters: explicitYarn, ropeScaling: legacyYarnScaling))

    #expect(typeName(config.ropeScaling) == "yarn")
    #expect(config.ropeScaling?["factor"]?.asFloat() == 2.0)
    #expect(config.ropeScaling?["attention_factor"] == nil)
}

@Test func qwen35TextConfigurationWithoutLegacyScalingStaysDefault() throws {
    let config = try JSONDecoder().decode(
        MLXLLM.Qwen35TextConfiguration.self,
        from: qwen35TextJSON(ropeParameters: defaultRopeParameters, ropeScaling: nil))

    #expect(typeName(config.ropeScaling) == "default")
    #expect(config.ropeScaling?["factor"] == nil)
}

@Test func qwen35VLTextConfigurationMergesLegacyYarnScaling() throws {
    let config = try JSONDecoder().decode(
        MLXVLM.Qwen35Configuration.TextConfiguration.self,
        from: qwen35TextJSON(ropeParameters: defaultRopeParameters, ropeScaling: legacyYarnScaling))

    #expect(typeName(config.ropeParameters) == "yarn")
    #expect(config.ropeParameters?["factor"]?.asFloat() == 4.0)
    #expect(config.ropeParameters?["attention_factor"]?.asFloat() == 1.0)
    #expect(config.ropeParameters?["mrope_section"]?.asInts() == [11, 11, 10])
    #expect(config.ropeTheta == 10_000_000)
}

@Test func qwen35AttentionBuildsYarnRoPEFromMergedConfiguration() throws {
    let config = try JSONDecoder().decode(
        MLXLLM.Qwen35TextConfiguration.self,
        from: qwen35TextJSON(ropeParameters: defaultRopeParameters, ropeScaling: legacyYarnScaling))

    let attention = Qwen35Attention(config)

    #expect(attention.rope is YarnRoPE)
}

@Test func yarnParametersHonorExplicitAttentionFactor() {
    let config: [String: StringOrNumber] = [
        "type": .string("yarn"), "factor": .float(4),
        "original_max_position_embeddings": .int(262_144), "attention_factor": .float(1),
    ]
    let explicit = YarnRoPEParameters(scalingConfig: config)
    #expect(explicit?.attentionScale == 1.0)

    var inferred = explicit
    inferred?.attentionFactor = nil
    let expected: Float = 0.1 * log(Float(4)) + 1
    #expect(abs((inferred?.attentionScale ?? 0) - expected) < 1e-6)

    #expect(YarnRoPEParameters(scalingConfig: ["type": .string("default")]) == nil)
}

@Test func yarnRoPEScalesRotatedDimensionsByAttentionScale() {
    let x = (MLXArray(0 ..< 64).asType(.float32) / 16).reshaped(1, 1, 4, 16)
    func norm(_ y: MLXArray) -> Float { sqrt(sum(y * y)).item(Float.self) }
    let reference = norm(x)

    let explicit = YarnRoPE(
        dimensions: 16, base: 10_000, scalingFactor: 4, originalMaxPositionEmbeddings: 4096,
        attentionFactor: 1.0)
    // A pure rotation preserves the norm.
    #expect(abs(norm(explicit(x)) / reference - 1) < 1e-4)

    let inferred = YarnRoPE(
        dimensions: 16, base: 10_000, scalingFactor: 4, originalMaxPositionEmbeddings: 4096)
    let expected: Float = 0.1 * log(Float(4)) + 1
    #expect(abs(norm(inferred(x)) / reference - expected) < 1e-4)
}
