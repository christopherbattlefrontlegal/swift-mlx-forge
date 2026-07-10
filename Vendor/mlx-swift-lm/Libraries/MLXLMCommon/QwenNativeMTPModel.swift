import Foundation
import MLX

/// Opt-in gate used while constructing Qwen3.5/Qwen3.6. The target and the
/// standalone AEON drafter are loaded into one logical module namespace.
public enum QwenNativeMTPConfig {
    public static var retainWeights: Bool {
        ProcessInfo.processInfo.environment["FORGE_QWEN_MTP_ENABLE"] == "1"
    }
}

/// Native Qwen MTP execution surface. This is intentionally separate from
/// `MTPDrafterModel`, whose state contract is Gemma-oriented in 3.31.4.
public protocol QwenNativeMTPModel: LanguageModel {
    /// Main logits followed by MTP prediction-depth logits.
    func callQwenMTP(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        mtpCaches: [[KVCache]]?
    ) -> [MLXArray]

    func makeQwenMTPCaches(parameters: GenerateParameters?) -> [[KVCache]]
}
