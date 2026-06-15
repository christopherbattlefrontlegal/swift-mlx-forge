// Forge — GGUF backend: llama.cpp embedded via LLM.swift.
//
// Second engine beside MLX. A GGUFRuntime owns one llama.cpp context for one
// .gguf file: Metal-accelerated, loaded in-process (sandbox-safe), freed by
// ARC when its Loaded entry is dropped. This file is the ONLY one that may
// import LLM — its `Chat` typealias collides with MLXLMCommon's `Chat`.

import Foundation
import LLM

final class GGUFRuntime: @unchecked Sendable {

    /// Plain-Swift mirror of the chat roles so callers never import LLM.
    enum HistoryRole {
        case user, assistant
    }

    private let llm: LLM
    private let fileURL: URL

    init?(fileURL: URL, maxTokens: Int32 = 4096) {
        guard let llm = LLM(from: fileURL, maxTokenCount: maxTokens) else { return nil }
        self.fileURL = fileURL
        self.llm = llm
    }

    /// LLM.swift doesn't expose the GGUF's embedded jinja template, so pick the
    /// family template from the filename. chatML covers Qwen and most modern
    /// finetunes; explicit families override.
    private func template(system: String?) -> Template {
        let name = fileURL.lastPathComponent.lowercased()
        let system = (system?.isEmpty == false) ? system : nil
        if name.contains("mistral") { return .mistral }
        if name.contains("gemma") { return .gemma }
        if name.contains("llama") || name.contains("bonsai") { return .llama(system) }
        if name.contains("alpaca") { return .alpaca(system) }
        return .chatML(system)
    }

    func configure(
        temperature: Double, topP: Double, topK: Int,
        system: String?, history: [(role: HistoryRole, content: String)]
    ) {
        llm.template = template(system: system)
        llm.temp = Float(temperature)
        llm.topP = Float(topP)
        llm.topK = Int32(topK == 0 ? 40 : min(topK, 1000))
        llm.historyLimit = 1000
        llm.history = history.map { item in
            (role: item.role == .user ? Role.user : Role.bot, content: item.content)
        }
    }

    /// Streams a reply, calling `onDelta` per chunk; returns the full text.
    /// Cancel by calling `stop()` (or cancelling the surrounding Task).
    func respond(
        to prompt: String, onDelta: @escaping @Sendable (String) async -> Void
    ) async -> String {
        await llm.respond(to: prompt) { stream in
            var text = ""
            for await delta in stream {
                if Task.isCancelled { break }
                text += delta
                await onDelta(delta)
            }
            return text
        }
        return llm.output
    }

    func stop() {
        llm.stop()
    }
}
