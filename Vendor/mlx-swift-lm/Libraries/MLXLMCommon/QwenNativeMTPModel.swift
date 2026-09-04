import Foundation
import MLX

/// Gate consulted while Qwen3.5-family models are constructed and sanitized:
/// when true the native multi-token-prediction head is built and its weights
/// retained. Forge's loader sets it for the duration of a load, whether the
/// head is packaged inside the checkpoint (Qwen3.8) or as a sidecar drafter
/// (AEON Qwen3.6). `FORGE_QWEN_MTP_ENABLE=1` in the environment remains an
/// override for command-line experiments.
public enum QwenNativeMTPConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var retainOverride: Bool?
    nonisolated(unsafe) private static var preNormOverride: Bool?

    public static var retainWeights: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let retainOverride { return retainOverride }
            return ProcessInfo.processInfo.environment["FORGE_QWEN_MTP_ENABLE"] == "1"
        }
        set {
            lock.lock()
            retainOverride = newValue
            lock.unlock()
        }
    }

    /// Drop the loader's setting so the environment override applies again.
    public static func resetRetainWeights() {
        lock.lock()
        retainOverride = nil
        lock.unlock()
    }

    /// Which backbone state the head fuses with the next token's embedding.
    /// The mlx-lm reference (ml-explore/mlx-lm#990) feeds the state before the
    /// final norm; vLLM's `qwen3_next_mtp` feeds the normed state. Both are
    /// exposed so they can be compared by acceptance rate on a checkpoint.
    /// `FORGE_QWEN_MTP_PRENORM=0` selects the normed state.
    public static var usePreNormHidden: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let preNormOverride { return preNormOverride }
            return ProcessInfo.processInfo.environment["FORGE_QWEN_MTP_PRENORM"] != "0"
        }
        set {
            lock.lock()
            preNormOverride = newValue
            lock.unlock()
        }
    }
}

/// Decode-time graph pipelining for Qwen3.5-family backbones: every
/// `layerInterval` layers the partial graph is submitted with `asyncEval`, so
/// the GPU starts on early layers while the CPU is still building later ones.
/// 0 disables it. `FORGE_QWEN_PIPELINE_INTERVAL` overrides the default.
public enum QwenDecodePipeline {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: Int?

    public static var layerInterval: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let override { return override }
            if let raw = ProcessInfo.processInfo.environment["FORGE_QWEN_PIPELINE_INTERVAL"],
                let value = Int(raw)
            {
                return max(0, value)
            }
            return 16
        }
        set {
            lock.lock()
            override = max(0, newValue)
            lock.unlock()
        }
    }
}

/// One forward through the backbone or the MTP head.
public struct QwenNativeMTPStep {
    /// Next-token logits. For the head, and for a backbone call that asked for
    /// the last position only, shape `[B, 1, V]`; otherwise `[B, N, V]`.
    public let logits: MLXArray
    /// State for every input position, `[B, N, H]`: the backbone state the head
    /// consumes, or the head's own output state for chaining a deeper draft.
    public let hidden: MLXArray

    public init(logits: MLXArray, hidden: MLXArray) {
        self.logits = logits
        self.hidden = hidden
    }
}

/// Native Qwen MTP execution surface. The head predicts token t+2 from the
/// backbone state at t and the embedding of token t+1, so callers pair each
/// state with the token that followed it. This is intentionally separate from
/// `MTPDrafterModel`, whose state contract is Gemma-oriented.
public protocol QwenNativeMTPModel: LanguageModel {
    /// Heads loaded; zero when the checkpoint has none or they were dropped.
    var qwenMTPHeadCount: Int { get }

    /// Backbone forward that also returns the state the head consumes.
    func qwenMTPBackbone(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        logitsForLastPositionOnly: Bool
    ) -> QwenNativeMTPStep

    /// Apply the head over N positions: `hidden` `[B, N, H]` paired with
    /// `nextTokens` `[B, N]`. Logits are returned for the last position only.
    func qwenMTPHead(
        hidden: MLXArray,
        nextTokens: MLXArray,
        cache: [KVCache]?
    ) -> QwenNativeMTPStep

    /// Fresh caches for the head's own layers.
    func makeQwenMTPCache(parameters: GenerateParameters?) -> [KVCache]
}
