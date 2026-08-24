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
    /// Reasoning and answer text leave LLM.swift on distinct native channels.
    /// Suppressed mode injects an empty reasoning block before generation.
    func respond(
        to prompt: String, thinkingEnabled: Bool = true,
        maxOutputTokens: Int? = nil,
        onDelta: @escaping @Sendable (InferenceStreamDelta) async -> Void
    ) async -> String {
        let capture = GGUFResponseCapture(maxChunks: maxOutputTokens)
        let (stream, continuation) = AsyncStream<InferenceStreamDelta>.makeStream()
        let delivery = Task {
            for await delta in stream {
                await onDelta(delta)
            }
        }

        @Sendable func receive(_ value: String?, as kind: GGUFResponseCapture.Kind) {
            guard let value, !value.isEmpty else { return }
            let decision = capture.record(value, as: kind)
            if decision.shouldDeliver {
                continuation.yield(
                    kind == .reasoning ? .reasoning(value) : .content(value))
            }
            if decision.shouldStop || Task.isCancelled {
                self.llm.stop()
            }
        }

        llm.updateThinking = { receive($0, as: .reasoning) }
        llm.update = { receive($0, as: .content) }

        await llm.respond(
            to: prompt,
            thinking: thinkingEnabled ? .enabled : .suppressed)

        llm.updateThinking = { _ in }
        llm.update = { _ in }
        continuation.finish()
        await delivery.value
        return capture.content()
    }

    func stop() {
        llm.stop()
    }
}

private final class GGUFResponseCapture: @unchecked Sendable {
    enum Kind: Sendable {
        case reasoning, content
    }

    struct Decision: Sendable {
        let shouldDeliver: Bool
        let shouldStop: Bool
    }

    private let lock = NSLock()
    private let maxChunks: Int?
    private var text = ""
    private var chunkCount = 0
    private var stopped = false

    init(maxChunks: Int?) {
        self.maxChunks = maxChunks
    }

    func record(_ value: String, as kind: Kind) -> Decision {
        lock.lock()
        defer { lock.unlock() }

        guard !stopped else {
            return Decision(shouldDeliver: false, shouldStop: false)
        }
        guard maxChunks != 0 else {
            stopped = true
            return Decision(shouldDeliver: false, shouldStop: true)
        }

        chunkCount += 1
        if kind == .content {
            text += value
        }
        let reachedLimit = maxChunks.map { chunkCount >= $0 } ?? false
        if reachedLimit {
            stopped = true
        }
        return Decision(shouldDeliver: true, shouldStop: reachedLimit)
    }

    func content() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
