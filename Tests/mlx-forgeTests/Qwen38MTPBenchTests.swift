import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import XCTest

@testable import MLXLLM
@testable import mlx_forge

/// Decode-throughput and acceptance benchmark for the native MTP path. Runs
/// only when `FORGE_BENCH_MODEL_DIR` points at a Qwen3.8 MLX checkpoint that
/// carries its MTP head. The protocol matches the published oMLX recipes:
/// thinking off, temperature 0, 320 generated tokens, one prose and one code
/// prompt. `FORGE_BENCH_DEPTHS` (default `1,2,3,4`) and
/// `FORGE_BENCH_MAX_TOKENS` (default 320) adjust the sweep.
final class Qwen38MTPBenchTests: XCTestCase {

    private struct Run {
        let label: String
        let tokens: [Int]
        let decodeTokensPerSecond: Double
        let prefillSeconds: Double
        let proposed: Int
        let accepted: Int
        let passes: Int
    }

    private static let prompts: [(label: String, text: String)] = [
        (
            "prose",
            "Write about 400 words, in plain prose with no lists or headings, explaining "
                + "how unified memory bandwidth bounds single-stream decode speed for a large "
                + "language model on Apple Silicon and what speculative decoding changes."
        ),
        (
            "code",
            "Write a complete Swift implementation of a generic LRU cache keyed by a Hashable "
                + "type, with get, set, and eviction, doc comments on every public member, and "
                + "a short usage example at the end. Output only code."
        ),
    ]

    @MainActor
    func testNativeMTPThroughputAndAcceptance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FORGE_BENCH_MODEL_DIR"] else {
            throw XCTSkip("FORGE_BENCH_MODEL_DIR not set")
        }
        let directory = URL(fileURLWithPath: dir)
        XCTAssertTrue(
            qwenCheckpointHasNativeMTPHead(at: directory),
            "checkpoint at \(dir) carries no native MTP head")
        let maxTokens = Int(env["FORGE_BENCH_MAX_TOKENS"] ?? "") ?? 320
        let depths = (env["FORGE_BENCH_DEPTHS"] ?? "1,2,3,4")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let started = Date()
        let (container, _) = try await loadLLMContainerWithPolicy(
            modelDirectory: directory, policy: .eager,
            tokenizerLoader: #huggingFaceTokenizerLoader())
        print("[bench] loaded in \(Self.fmt(Date().timeIntervalSince(started))) s")

        let prompts = Self.prompts
        try await container.perform { context in
            guard let model = context.model as? any QwenNativeMTPModel else {
                XCTFail("loaded model does not expose native MTP")
                return
            }
            XCTAssertGreaterThan(model.qwenMTPHeadCount, 0, "MTP head was not retained at load")
            let eos = context.configuration.eosTokenIds
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)

            for prompt in prompts {
                let prepared = try await context.processor.prepare(
                    input: UserInput(
                        chat: [.user(prompt.text)],
                        additionalContext: ["enable_thinking": false]))
                let tokens = prepared.text.tokens
                print("[bench] ---- \(prompt.label): prompt \(tokens.dim(0)) tokens ----")

                let baseline = try Self.drive(
                    "\(prompt.label) baseline", eos: eos
                ) {
                    try TokenIterator(
                        input: LMInput(text: .init(tokens: tokens)),
                        model: context.model, parameters: parameters)
                }
                Self.report(baseline)

                var runs = [Int: Run]()
                for k in depths {
                    let run = try Self.drive("\(prompt.label) mtp k=\(k)", eos: eos) {
                        try QwenNativeMTPTokenIterator(
                            input: LMInput(text: .init(tokens: tokens)),
                            model: model, parameters: parameters, numMTPTokens: k)
                    }
                    Self.report(run)
                    let agree = Self.commonPrefix(baseline.tokens, run.tokens)
                    let comparable = min(baseline.tokens.count, run.tokens.count)
                    print("[bench]   greedy agreement with baseline: \(agree)/\(comparable) tokens")
                    // The baseline decodes one row per pass and the verify pass k+1 rows;
                    // a core whose small-M matmul rounds differently can flip a near-tie
                    // token, so only an early divergence counts as a defect.
                    XCTAssertGreaterThanOrEqual(
                        agree, min(16, comparable),
                        "k=\(k) \(prompt.label): diverged from the greedy baseline within 16 tokens")
                    runs[k] = run
                }
                // Depths verify with different row counts but share the same head and
                // rollback machinery; report how far they agree with each other.
                let keys = runs.keys.sorted()
                for (i, a) in keys.enumerated() {
                    for b in keys[(i + 1)...] {
                        let agree = Self.commonPrefix(runs[a]!.tokens, runs[b]!.tokens)
                        print("[bench]   k=\(a) vs k=\(b) agreement: \(agree)/\(min(runs[a]!.tokens.count, runs[b]!.tokens.count)) tokens")
                    }
                }

                // Head input A/B: pre-final-norm state (mlx-lm#990) versus normed
                // state (vLLM), at the recipe depth.
                let previous = QwenNativeMTPConfig.usePreNormHidden
                defer { QwenNativeMTPConfig.usePreNormHidden = previous }
                for preNorm in [true, false] {
                    QwenNativeMTPConfig.usePreNormHidden = preNorm
                    let run = try Self.drive(
                        "\(prompt.label) mtp k=3 \(preNorm ? "pre-norm" : "post-norm") hidden",
                        eos: eos
                    ) {
                        try QwenNativeMTPTokenIterator(
                            input: LMInput(text: .init(tokens: tokens)),
                            model: model, parameters: parameters, numMTPTokens: 3)
                    }
                    Self.report(run)
                }
            }
        }
    }

    /// Drive an iterator to completion. Decode throughput is measured from the
    /// first emitted token, so prefill and the standard iterator's prompt tail
    /// are excluded for both paths.
    private static func drive<T: TokenIteratorProtocol>(
        _ label: String, eos: Set<Int>, make: () throws -> T
    ) throws -> Run {
        var iterator = try make()
        var tokens = [Int]()
        var decodeStart: TimeInterval? = nil
        while let token = iterator.next() {
            tokens.append(token)
            if tokens.count == 1 { decodeStart = Date.timeIntervalSinceReferenceDate }
            if eos.contains(token) { break }
        }
        let end = Date.timeIntervalSinceReferenceDate
        let decoded = max(0, tokens.count - 1)
        let seconds = decodeStart.map { end - $0 } ?? 0
        let stats = iterator as? MTPStatsCollecting
        let passes = (iterator as? QwenNativeMTPTokenIterator)?.backbonePasses ?? decoded
        return Run(
            label: label, tokens: tokens,
            decodeTokensPerSecond: seconds > 0 ? Double(decoded) / seconds : 0,
            prefillSeconds: iterator.promptPrefillTime,
            proposed: stats?.proposedDraftTokens ?? 0,
            accepted: stats?.acceptedDraftTokens ?? 0,
            passes: passes)
    }

    private static func report(_ run: Run) {
        var line =
            "[bench] \(run.label): \(fmt(run.decodeTokensPerSecond)) tok/s decode, "
            + "\(run.tokens.count) tokens, prefill \(fmt(run.prefillSeconds)) s"
        if run.proposed > 0 {
            let acceptance = 100 * Double(run.accepted) / Double(run.proposed)
            let perPass = Double(max(0, run.tokens.count - 1)) / Double(max(1, run.passes))
            line +=
                ", acceptance \(fmt(acceptance))% (\(run.accepted)/\(run.proposed)), "
                + "\(fmt(perPass)) tokens per backbone pass"
        }
        print(line)
    }

    private static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Per-phase cost of one MTP round in isolation: plain pass, k=3 verify pass,
    /// head call, and a rollback with replay. Same env gate as the throughput test.
    @MainActor
    func testNativeMTPPhaseProfile() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FORGE_BENCH_MODEL_DIR"] else {
            throw XCTSkip("FORGE_BENCH_MODEL_DIR not set")
        }
        let directory = URL(fileURLWithPath: dir)
        let (container, _) = try await loadLLMContainerWithPolicy(
            modelDirectory: directory, policy: .eager,
            tokenizerLoader: #huggingFaceTokenizerLoader())
        try await container.perform { context in
            guard let model = context.model as? any QwenNativeMTPModel else {
                XCTFail("loaded model does not expose native MTP")
                return
            }
            let parameters = GenerateParameters(maxTokens: 8, temperature: 0)
            let prepared = try await context.processor.prepare(
                input: UserInput(
                    chat: [.user(Self.prompts[0].text)],
                    additionalContext: ["enable_thinking": false]))
            let cache = model.newCache(parameters: parameters)
            let headCache = model.makeQwenMTPCache(parameters: parameters)
            let prompt = prepared.text.tokens
            let primed = model.qwenMTPBackbone(prompt[.newAxis], cache: cache, logitsForLastPositionOnly: true)
            eval(primed.logits, primed.hidden)
            let hiddenSize = primed.hidden.dim(2)
            _ = model.qwenMTPHead(
                hidden: primed.hidden[0..., (prompt.dim(0) - 1)..., 0...],
                nextTokens: MLXArray([Int32(1000)])[.newAxis], cache: headCache)
            eval(headCache.flatMap { $0.innerState() })

            func time(_ label: String, reps: Int = 12, _ body: () -> [MLXArray]) {
                for _ in 0 ..< 2 { eval(body()) }
                let start = Date.timeIntervalSinceReferenceDate
                for _ in 0 ..< reps { eval(body()) }
                let ms = (Date.timeIntervalSinceReferenceDate - start) / Double(reps) * 1000
                print("[profile] \(label): \(String(format: "%.1f", ms)) ms")
            }

            let one = MLXArray([Int32(1001)])[.newAxis]
            let four = MLXArray([Int32(1001), 1002, 1003, 1004])[.newAxis]
            time("backbone L=1 (plain step), logits last only") {
                let out = model.qwenMTPBackbone(one, cache: cache, logitsForLastPositionOnly: true)
                return [out.logits, out.hidden]
            }
            time("backbone L=4 (verify pass), logits all positions") {
                let out = model.qwenMTPBackbone(four, cache: cache, logitsForLastPositionOnly: false)
                return [out.logits, out.hidden]
            }
            time("backbone L=4 + argmax + host readback") {
                let out = model.qwenMTPBackbone(four, cache: cache, logitsForLastPositionOnly: false)
                let sampled = argMax(out.logits[0], axis: -1)
                _ = sampled.asArray(Int.self)
                return [out.hidden]
            }
            time("backbone L=4 with speculative windows recorded") {
                for c in cache { (c as? MambaCache)?.speculativeWindowArmed = true }
                let out = model.qwenMTPBackbone(four, cache: cache, logitsForLastPositionOnly: false)
                eval(out.logits, out.hidden)
                for c in cache { (c as? MambaCache)?.clearSpeculativeWindow() }
                return [out.hidden]
            }
            time("rollback: L=4 recorded, trim 2, replay") {
                for c in cache { (c as? MambaCache)?.speculativeWindowArmed = true }
                let out = model.qwenMTPBackbone(four, cache: cache, logitsForLastPositionOnly: false)
                eval(out.logits, out.hidden)
                trimPromptCache(cache, numTokens: 2)
                return cache.flatMap { $0.innerState() }
            }
            let state1 = MLXArray.zeros([1, 1, hiddenSize], dtype: primed.hidden.dtype)
            let state4 = MLXArray.zeros([1, 4, hiddenSize], dtype: primed.hidden.dtype)
            time("head call, 1 position") {
                let out = model.qwenMTPHead(hidden: state1, nextTokens: one, cache: headCache)
                return [out.logits, out.hidden]
            }
            time("head call, 4 positions (commit + first draft)") {
                let out = model.qwenMTPHead(hidden: state4, nextTokens: four, cache: headCache)
                return [out.logits, out.hidden]
            }
            time("head chain of 3 (one round of drafting)") {
                var step = model.qwenMTPHead(hidden: state1, nextTokens: one, cache: headCache)
                for _ in 0 ..< 2 {
                    let token = argMax(step.logits[0..., -1, 0...], axis: -1)
                    step = model.qwenMTPHead(hidden: step.hidden, nextTokens: token[.newAxis], cache: headCache)
                }
                return [step.logits, step.hidden]
            }
            let standard = try TokenIterator(
                input: LMInput(text: .init(tokens: prompt)), model: context.model, parameters: parameters)
            var iterator = standard
            _ = iterator.next()
            let start = Date.timeIntervalSinceReferenceDate
            var n = 0
            while iterator.next() != nil { n += 1 }
            print("[profile] standard TokenIterator: \(String(format: "%.1f", (Date.timeIntervalSinceReferenceDate - start) / Double(max(1, n)) * 1000)) ms per token over \(n) tokens")
        }
    }
}
