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
    /// Context window this llama context was created with (for error reporting).
    let contextTokens: Int32

    /// `onLoadProgress` fires on llama.cpp's loader thread with 0…1 as tensors
    /// are read into memory (a 100GB+ file takes minutes — this is the only
    /// signal that anything is happening).
    init?(
        fileURL: URL, maxTokens: Int32 = 8192,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        guard fileURL.isFileURL else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        guard fm.isReadableFile(atPath: fileURL.path)
            || FileHandle(forReadingAtPath: fileURL.path) != nil
        else { return nil }
        let ctx = max(2048, min(maxTokens, 131_072))
        let progress: ((Float) -> Bool)? = onLoadProgress.map { report in
            { fraction in
                report(Double(fraction))
                return true
            }
        }
        guard let llm = LLM(from: fileURL, maxTokenCount: ctx, loadProgress: progress)
        else { return nil }
        self.fileURL = fileURL
        self.llm = llm
        self.contextTokens = ctx
    }

    /// LLM.swift doesn't expose the GGUF's embedded jinja template, so pick the
    /// family template from the filename. chatML covers Qwen and most modern
    /// finetunes; explicit families override.
    private func template(system: String?) -> Template {
        let name = fileURL.lastPathComponent.lowercased()
        let system = (system?.isEmpty == false) ? system : nil
        if name.contains("mistral") { return .mistral }
        if name.contains("gemma") { return .gemma }
        if name.contains("deepseek") || name.contains("r1") || name.contains("qwen")
            || name.contains("thinking")
        {
            return .chatML(system)
        }
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
    ///
    /// `thinkingEnabled: true` streams reasoning inline (raw `<think>` text the chat UI
    /// renders as a live reasoning block); `false` uses llama.cpp's suppressed mode,
    /// which injects an empty thinking block so the model skips reasoning entirely.
    func respond(
        to prompt: String, thinkingEnabled: Bool = true,
        maxOutputTokens: Int? = nil,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async -> String {
        let capture = GGUFResponseCapture()
        await llm.respond(to: prompt, thinking: thinkingEnabled ? .none : .suppressed) {
            stream in
            var text = ""
            var generatedChunks = 0
            if maxOutputTokens == 0 {
                self.llm.stop()
            }
            for await delta in stream {
                if Task.isCancelled || maxOutputTokens == 0 { break }
                text += delta
                generatedChunks += 1
                await onDelta(delta)
                if let maxOutputTokens, generatedChunks >= maxOutputTokens {
                    self.llm.stop()
                    break
                }
            }
            capture.set(text)
            return text
        }
        // LLM.swift's callback-based `respond` overload does not update its
        // published `output` property. Return the text collected by this exact
        // invocation instead of a stale/empty property value.
        return capture.get()
    }

    func stop() {
        llm.stop()
    }
}

private final class GGUFResponseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func set(_ value: String) {
        lock.lock()
        text = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
