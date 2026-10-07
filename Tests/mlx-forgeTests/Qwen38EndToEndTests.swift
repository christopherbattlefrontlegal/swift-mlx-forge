import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import XCTest

@testable import MLXLLM
@testable import mlx_forge

/// Runs only when `FORGE_E2E_MODEL_DIR` points at a local Qwen3.8 MLX checkpoint whose
/// config carries the legacy `rope_scaling` YaRN block (Solstice-AI oQ8e-1M). Exercises
/// Forge's own loader, template sniffer, and kwargs builder end to end, including the
/// strict Qwen3.8 template's `reasoning_effort` validation.
final class Qwen38EndToEndTests: XCTestCase {
    @MainActor
    func testSolsticeCheckpointLoadsWithYarnAndAnswersAtEveryEffortLevel() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FORGE_E2E_MODEL_DIR"] else {
            throw XCTSkip("FORGE_E2E_MODEL_DIR not set")
        }
        let directory = URL(fileURLWithPath: dir)

        let caps = ChatTemplateSniffer.sniff(modelDirectory: directory)
        XCTAssertEqual(caps.reasoningEffortLevels, ["xhigh", "medium", "low"])
        XCTAssertEqual(caps.reasoningEffortDefault, "xhigh")
        XCTAssertTrue(caps.supportsThinkingToggle)

        let started = Date()
        let (container, _) = try await loadLLMContainerWithPolicy(
            modelDirectory: directory, policy: .eager,
            tokenizerLoader: #huggingFaceTokenizerLoader())
        print("[e2e] loaded in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

        let rope: (yarn: Int, plain: Int) = await container.perform { context in
            guard let model = context.model as? Qwen35Model else { return (0, 0) }
            var yarn = 0
            var plain = 0
            for layer in model.loraLayers {
                guard let attention = (layer as? Qwen35DecoderLayer)?.selfAttn else { continue }
                if attention.rope is YarnRoPE { yarn += 1 } else { plain += 1 }
            }
            return (yarn, plain)
        }
        print("[e2e] full-attention layers with YaRN: \(rope.yarn), plain RoPE: \(rope.plain)")
        XCTAssertEqual(rope.yarn, 16)
        XCTAssertEqual(rope.plain, 0)

        let model = LocalModel(
            name: "e2e", directory: directory, sizeBytes: 0, isManaged: false,
            chatTemplateCaps: caps)
        let entry = InferenceEngine.Loaded(model: model, container: container, templateCaps: caps)

        for (effort, enabled) in [("xhigh", true), ("medium", true), ("low", true), ("low", false)] {
            let context = InferenceEngine.thinkingAdditionalContext(
                for: entry, enabled: enabled, effort: effort)
            let session = ChatSession(
                container,
                generateParameters: GenerateParameters(maxTokens: 48, temperature: 0),
                additionalContext: context)
            let turn = Date()
            let reply = try await session.respond(to: "Reply with one short sentence: what is 2 + 2?")
            let seconds = Date().timeIntervalSince(turn)
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            print(
                "[e2e] effort=\(effort) thinking=\(enabled) \(String(format: "%.1f", seconds)) s: "
                    + text.replacingOccurrences(of: "\n", with: " ").prefix(220))
            XCTAssertFalse(text.isEmpty, "effort=\(effort) thinking=\(enabled) produced no text")
        }
    }
}
