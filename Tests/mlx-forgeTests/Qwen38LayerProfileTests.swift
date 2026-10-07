import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import Tokenizers
import XCTest

@testable import MLXLLM
@testable import mlx_forge

/// Attributes a decode pass to layer types and sub-operations at widths 1 and 4,
/// to locate per-row cost in the Swift Qwen3.5 implementation. Runs only when
/// `FORGE_BENCH_MODEL_DIR` points at a Qwen3.8 MLX checkpoint.
final class Qwen38LayerProfileTests: XCTestCase {

    @MainActor
    func testLayerCostsByWidth() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FORGE_BENCH_MODEL_DIR"] else {
            throw XCTSkip("FORGE_BENCH_MODEL_DIR not set")
        }
        let (container, _) = try await loadLLMContainerWithPolicy(
            modelDirectory: URL(fileURLWithPath: dir), policy: .eager,
            tokenizerLoader: #huggingFaceTokenizerLoader())
        try await container.perform { context in
            guard let model = context.model as? Qwen35Model else {
                XCTFail("not a Qwen35Model")
                return
            }
            let text = model.languageModel
            let layers = text.loraLayers.compactMap { $0 as? Qwen35DecoderLayer }
            guard let linear = layers.first(where: { $0.isLinear }),
                let attention = layers.first(where: { !$0.isLinear })
            else {
                XCTFail("layer types not found")
                return
            }
            let counts = (
                linear: layers.filter { $0.isLinear }.count,
                attention: layers.filter { !$0.isLinear }.count)
            let hidden = 5120

            func time(_ label: String, reps: Int = 15, _ body: () -> [MLXArray]) -> Double {
                for _ in 0 ..< 3 { eval(body()) }
                let start = Date.timeIntervalSinceReferenceDate
                for _ in 0 ..< reps { eval(body()) }
                return (Date.timeIntervalSinceReferenceDate - start) / Double(reps) * 1000
            }
            func row(_ label: String, _ l1: Double, _ l4: Double, multiplier: Int) {
                let total1 = l1 * Double(multiplier)
                let total4 = l4 * Double(multiplier)
                print(
                    "[layers] \(label): L=1 \(String(format: "%.3f", l1)) ms, L=4 \(String(format: "%.3f", l4)) ms"
                        + "  x\(multiplier) -> \(String(format: "%.1f", total1)) / \(String(format: "%.1f", total4)) ms per pass")
            }

            for (name, L) in [("L=1", 1), ("L=4", 4)] {
                _ = name
                _ = L
            }
            let x1 = MLXRandom.normal([1, 1, hidden]).asType(.bfloat16)
            let x4 = MLXRandom.normal([1, 4, hidden]).asType(.bfloat16)

            // Whole decoder layers.
            let gdnCache1 = MambaCache()
            let gdnCache4 = MambaCache()
            let kv1 = KVCacheSimple()
            let kv4 = KVCacheSimple()
            // Prime with a short history so masks and offsets look like decode.
            eval(linear(x4, attentionMask: .none, ssmMask: nil, cache: gdnCache1))
            eval(linear(x4, attentionMask: .none, ssmMask: nil, cache: gdnCache4))
            eval(attention(x4, attentionMask: .causal, ssmMask: nil, cache: kv1))
            eval(attention(x4, attentionMask: .causal, ssmMask: nil, cache: kv4))

            let lin1 = time("linear layer L=1") { [linear(x1, attentionMask: .none, ssmMask: nil, cache: gdnCache1)] }
            let lin4 = time("linear layer L=4") { [linear(x4, attentionMask: .none, ssmMask: nil, cache: gdnCache4)] }
            row("linear-attention decoder layer", lin1, lin4, multiplier: counts.linear)

            let mask1 = createAttentionMask(h: x1, cache: kv1)
            let mask4 = createAttentionMask(h: x4, cache: kv4)
            let att1 = time("attention layer L=1") { [attention(x1, attentionMask: mask1, ssmMask: nil, cache: kv1)] }
            let att4 = time("attention layer L=4") { [attention(x4, attentionMask: mask4, ssmMask: nil, cache: kv4)] }
            row("full-attention decoder layer", att1, att4, multiplier: counts.attention)

            // Sub-operations of the linear-attention layer.
            let gdn = linear.linearAttn!
            let qkv1 = time("in_proj_qkv L=1") { [gdn.inProjQKV(x1)] }
            let qkv4 = time("in_proj_qkv L=4") { [gdn.inProjQKV(x4)] }
            row("  in_proj_qkv", qkv1, qkv4, multiplier: counts.linear)

            let convDim = gdn.convDim
            let k = gdn.convKernelSize
            let conv1In = MLXRandom.normal([1, k - 1 + 1, convDim]).asType(.bfloat16)
            let conv4In = MLXRandom.normal([1, k - 1 + 4, convDim]).asType(.bfloat16)
            let c1 = time("conv1d L=1") { [gdn.conv1d(conv1In)] }
            let c4 = time("conv1d L=4") { [gdn.conv1d(conv4In)] }
            row("  depthwise conv1d", c1, c4, multiplier: counts.linear)

            func gdnInputs(_ L: Int) -> (MLXArray, MLXArray, MLXArray, MLXArray, MLXArray) {
                let q = MLXRandom.normal([1, L, gdn.numKHeads, gdn.headKDim]).asType(.bfloat16)
                let kk = MLXRandom.normal([1, L, gdn.numKHeads, gdn.headKDim]).asType(.bfloat16)
                let v = MLXRandom.normal([1, L, gdn.numVHeads, gdn.headVDim]).asType(.bfloat16)
                let a = MLXRandom.normal([1, L, gdn.numVHeads]).asType(.bfloat16)
                let b = MLXRandom.normal([1, L, gdn.numVHeads]).asType(.bfloat16)
                return (q, kk, v, a, b)
            }
            let (q1, k1, v1, a1, b1) = gdnInputs(1)
            let (q4, k4, v4, a4, b4) = gdnInputs(4)
            let state = MLXArray.zeros([1, gdn.numVHeads, gdn.headVDim, gdn.headKDim], dtype: .float32)
            let g1 = time("gatedDeltaUpdate L=1") {
                let (y, s) = gatedDeltaUpdate(q: q1, k: k1, v: v1, a: a1, b: b1, aLog: gdn.aLog, dtBias: gdn.dtBias, state: state)
                return [y, s]
            }
            let g4 = time("gatedDeltaUpdate L=4") {
                let (y, s) = gatedDeltaUpdate(q: q4, k: k4, v: v4, a: a4, b: b4, aLog: gdn.aLog, dtBias: gdn.dtBias, state: state)
                return [y, s]
            }
            row("  gatedDeltaUpdate (recurrence kernel)", g1, g4, multiplier: counts.linear)

            let out1 = MLXRandom.normal([1, 1, gdn.numVHeads, gdn.headVDim]).asType(.bfloat16)
            let out4 = MLXRandom.normal([1, 4, gdn.numVHeads, gdn.headVDim]).asType(.bfloat16)
            let z1 = MLXRandom.normal([1, 1, gdn.numVHeads, gdn.headVDim]).asType(.bfloat16)
            let z4 = MLXRandom.normal([1, 4, gdn.numVHeads, gdn.headVDim]).asType(.bfloat16)
            let n1 = time("gated norm L=1") { [gdn.norm(out1, gate: z1)] }
            let n4 = time("gated norm L=4") { [gdn.norm(out4, gate: z4)] }
            row("  gated RMSNorm", n1, n4, multiplier: counts.linear)

            let o1 = time("out_proj L=1") { [gdn.outProj(out1.reshaped(1, 1, -1))] }
            let o4 = time("out_proj L=4") { [gdn.outProj(out4.reshaped(1, 4, -1))] }
            row("  out_proj", o1, o4, multiplier: counts.linear)

            let mlp = linear.mlp as! UnaryLayer
            let m1 = time("mlp L=1") { [mlp(x1)] }
            let m4 = time("mlp L=4") { [mlp(x4)] }
            row("  mlp (gate/up/down)", m1, m4, multiplier: layers.count)

            let rms1 = time("rmsnorm L=1") { [linear.inputLayerNorm(x1)] }
            let rms4 = time("rmsnorm L=4") { [linear.inputLayerNorm(x4)] }
            row("  input RMSNorm", rms1, rms4, multiplier: layers.count * 2)

            let sa = attention.selfAttn!
            let s1 = time("self_attn L=1") { [sa(x1, mask: mask1, cache: kv1)] }
            let s4 = time("self_attn L=4") { [sa(x4, mask: mask4, cache: kv4)] }
            row("  self_attn (proj + rope + sdpa)", s1, s4, multiplier: counts.attention)

            // Whole-model: CPU graph construction alone versus construction + evaluation,
            // across graph-submission intervals.
            let previousInterval = QwenDecodePipeline.layerInterval
            defer { QwenDecodePipeline.layerInterval = previousInterval }
            for interval in [0, 8, 16, 32] {
            QwenDecodePipeline.layerInterval = interval
            for L in [1, 4] {
                let x = MLXArray((0 ..< L).map { Int32(1000 + $0) })[.newAxis]
                let cache = text.newCache(parameters: nil)
                eval(text.qwenMTPBackbone(x, cache: cache, logitsForLastPositionOnly: L == 1).logits)
                var build = 0.0
                var total = 0.0
                for _ in 0 ..< 8 {
                    let t0 = Date.timeIntervalSinceReferenceDate
                    let out = text.qwenMTPBackbone(x, cache: cache, logitsForLastPositionOnly: L == 1)
                    let t1 = Date.timeIntervalSinceReferenceDate
                    eval(out.logits, out.hidden)
                    let t2 = Date.timeIntervalSinceReferenceDate
                    build += (t1 - t0) * 1000
                    total += (t2 - t0) * 1000
                }
                print("[layers] whole model L=\(L) pipeline=\(interval): graph build \(String(format: "%.1f", build / 8)) ms, build+eval \(String(format: "%.1f", total / 8)) ms")
            }
            }
            print("[layers] attention mask modes: L=1 \(mask1), L=4 \(mask4); rope type \(type(of: sa.rope))")
        }
    }
}
