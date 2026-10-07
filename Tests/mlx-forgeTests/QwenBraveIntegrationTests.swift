import Foundation
import MLXLMCommon
import XCTest

@testable import mlx_forge

/// Opt-in model-driven search using Forge's loader, generation, tool-call parser,
/// history replay, and live Brave client. The test supplies the Brave tool binding;
/// the standalone Brave globe mode does not currently attach it to local models.
final class QwenBraveIntegrationTests: XCTestCase {
    @MainActor
    func testModelCallsBraveAndAnswersFromTheResult() async throws {
        guard let path = ProcessInfo.processInfo.environment["FORGE_QWEN_BRAVE_MODEL"] else {
            throw XCTSkip("Set FORGE_QWEN_BRAVE_MODEL to a local MLX checkpoint")
        }
        let key = try XCTUnwrap(SecretsStore.braveSearchAPIKey, "No configured Brave key")
        let directory = URL(fileURLWithPath: path)
        let model = LocalModel(
            name: directory.lastPathComponent, directory: directory,
            sizeBytes: 0, isManaged: false,
            chatTemplateCaps: ChatTemplateSniffer.sniff(modelDirectory: directory))
        let engine = InferenceEngine()
        let started = Date()
        let entry = try await engine.load(model, policy: .eager)
        defer { engine.unloadAll() }
        XCTAssertEqual(entry.model.directory.standardizedFileURL, directory.standardizedFileURL)
        let loadSeconds = Date().timeIntervalSince(started)
        print("[qwen-brave] model=\(path) loadSeconds=\(loadSeconds) nativeMTP=\(entry.qwenMTPEnabled)")

        let binding = MCPToolBinding(serverID: "brave-search", tool: MCPTool(
            name: "search",
            description: "Search the web with Brave Research. Returns a sourced research answer. Use this to verify current information, then answer the user from the result.",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"The web research question, requesting source links."}},"required":["query"]}"#))
        let originalPrompt = "Use Brave search to verify what Claude Code CLI and Codex CLI are used for. Explain in two short paragraphs with source links."
        let instructions = "Use the provided Brave search tool before answering a research request. After the tool returns, use its result to answer the original request in normal prose with source links."
        var runs: [[String: Any]] = []

        for thinking in [false, true] {
            var settings = GenerationSettings()
            settings.temperature = 0
            settings.topP = 0
            settings.maxTokens = 4096
            settings.localThinkingEnabled = thinking
            settings.reasoningEnabled = thinking
            var conversation = Conversation()
            var prompt = originalPrompt
            var turns: [[String: Any]] = []
            var searches = 0
            var finalAnswer = ""

            for iteration in 0..<4 {
                let turn = try await generate(
                    engine: engine, modelID: entry.id, conversation: conversation,
                    prompt: prompt, instructions: instructions, settings: settings, tools: [binding])
                var record: [String: Any] = [
                    "iteration": iteration, "content": turn.content, "reasoning": turn.reasoning,
                    "firstDeltaSeconds": turn.firstDeltaSeconds,
                    "elapsedSeconds": turn.elapsedSeconds,
                ]
                if let info = turn.info {
                    record["promptTokens"] = info.promptTokenCount
                    record["promptSeconds"] = info.promptTime
                    record["generationTokens"] = info.generationTokenCount
                    record["tokensPerSecond"] = info.tokensPerSecond
                }
                print("[qwen-brave] thinking=\(thinking) iteration=\(iteration) firstDelta=\(turn.firstDeltaSeconds) promptTokens=\(turn.info?.promptTokenCount ?? 0) promptSeconds=\(turn.info?.promptTime ?? 0) tps=\(turn.info?.tokensPerSecond ?? 0) contentChars=\(turn.content.count) reasoningChars=\(turn.reasoning.count)")
                guard let call = AppState.parseMCPCallRequest(from: turn.content) else {
                    turns.append(record)
                    finalAnswer = turn.content
                    break
                }
                XCTAssertTrue(call.serverID.isEmpty || call.serverID == binding.serverID)
                XCTAssertEqual(call.toolName, binding.tool.name)
                let query = try XCTUnwrap(call.arguments["query"] as? String)
                XCTAssertFalse(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                print("[qwen-brave] Brave query: \(query)")
                let searchStarted = Date()
                var result = ""
                try await BraveAnswersClient(apiKey: key, config: BraveSearchConfig(enableResearch: true)).stream(
                    query: query, onChunk: { if case .content(let text) = $0 { result += text } })
                XCTAssertGreaterThan(result.count, 100)
                XCTAssertFalse(result.contains("<answer>"))
                searches += 1
                record["braveQuery"] = query
                record["braveSeconds"] = Date().timeIntervalSince(searchStarted)
                record["braveResult"] = result
                turns.append(record)
                print("[qwen-brave] Brave returned \(result.count) characters in \(Date().timeIntervalSince(searchStarted)) seconds")

                // Match AppState's executed-tool transcript and continuation.
                if iteration == 0 { conversation.messages.append(ChatMessage(role: .user, content: originalPrompt)) }
                let arguments = String(decoding: try JSONSerialization.data(
                    withJSONObject: call.arguments, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
                conversation.messages.append(ChatMessage(role: .assistant,
                    content: "MCP request: `brave-search.search`\n\n```json\n\(arguments)\n```"))
                conversation.messages.append(ChatMessage(role: .system,
                    content: "MCP result: brave-search.search\n\n\(result)"))
                prompt = "The MCP tool brave-search.search returned its result above in this conversation. Use it to continue the task. If another MCP tool call is needed, call it now; otherwise answer the user's original request. Original request:\n\(originalPrompt)"
            }

            runs.append(["thinking": thinking, "searches": searches, "turns": turns, "finalAnswer": finalAnswer])
            if let reportPath = ProcessInfo.processInfo.environment["FORGE_QWEN_BRAVE_REPORT"] {
                let report: [String: Any] = ["model": path, "loadSeconds": loadSeconds, "runs": runs]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            }
            XCTAssertGreaterThan(searches, 0, "The model must actually call Brave before answering")
            XCTAssertGreaterThan(finalAnswer.count, 100, "The model stopped without a final answer")
            XCTAssertTrue(finalAnswer.lowercased().contains("claude"), finalAnswer)
            XCTAssertTrue(finalAnswer.lowercased().contains("codex"), finalAnswer)
            XCTAssertTrue(finalAnswer.contains("https://"), "No source links: \(finalAnswer)")
            XCTAssertFalse(finalAnswer.contains("FORGE_MCP_CALL"))
            XCTAssertFalse(finalAnswer.contains("<tool_call>"))
        }
    }

    private struct TurnResult {
        var content = ""
        var reasoning = ""
        var firstDeltaSeconds = -1.0
        var elapsedSeconds = 0.0
        var info: GenerateCompletionInfo?
    }

    @MainActor
    private func generate(
        engine: InferenceEngine, modelID: String, conversation: Conversation,
        prompt: String, instructions: String, settings: GenerationSettings, tools: [MCPToolBinding]
    ) async throws -> TurnResult {
        let started = Date()
        var result = TurnResult()
        result.info = try await withCheckedThrowingContinuation { continuation in
            engine.generate(
                conversation: conversation, prompt: prompt, settings: settings,
                systemInstructions: instructions, targetModelID: modelID, mcpTools: tools,
                onChunk: { delta in
                    if result.firstDeltaSeconds < 0 { result.firstDeltaSeconds = Date().timeIntervalSince(started) }
                    switch delta {
                    case .content(let text): result.content += text
                    case .reasoning(let text): result.reasoning += text
                    case .invalidReasoningStructure: XCTFail("Invalid reasoning structure")
                    }
                }, onComplete: { info, error in
                    if let error { continuation.resume(throwing: NSError(domain: "QwenBraveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
                    else { continuation.resume(returning: info) }
                })
        }
        result.elapsedSeconds = Date().timeIntervalSince(started)
        return result
    }
}
