import Foundation
import Testing
@testable import MLXLLM

@Test func testQwen35DecodesNativeMTPHiddenLayerCount() throws {
    let json = """
        {
            "model_type": "qwen3_5_text",
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
            "mtp_num_hidden_layers": 1
        }
        """

    let configuration = try JSONDecoder().decode(
        Qwen35TextConfiguration.self, from: Data(json.utf8))

    #expect(configuration.mtpNumHiddenLayers == 1)
    #expect(configuration.numNextnPredictLayers == 1)
}

@Test func testQwen35ExplicitNextNPredictCountTakesPrecedence() throws {
    let json = """
        {
            "model_type": "qwen3_5_text",
            "mtp_num_hidden_layers": 1,
            "num_nextn_predict_layers": 2
        }
        """

    let configuration = try JSONDecoder().decode(
        Qwen35TextConfiguration.self, from: Data(json.utf8))

    #expect(configuration.mtpNumHiddenLayers == 1)
    #expect(configuration.numNextnPredictLayers == 2)
}
