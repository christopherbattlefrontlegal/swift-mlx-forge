// Forge — in-process MLX inference engine with multi-model residency.
//
// Several models can be loaded into unified memory simultaneously; one is
// "active" for the chat UI, and the API server can address any loaded model
// by name (auto-loading installed ones on demand). Per-conversation
// ChatSessions keep KV caches alive across turns.

import AppKit
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Observation
import Tokenizers
import os.log

@MainActor
@Observable
final class InferenceEngine {

    /// A model resident in unified memory — MLX backend (container) or
    /// llama.cpp backend (gguf). Exactly one of the two is non-nil.
    struct Loaded: Identifiable {
        let model: LocalModel
        let container: ModelContainer?
        var loadedAt: Date
        /// Retains the memory-mapped readers when using the mmap loading path.
        let mmapReaders: [SafetensorsReader]?
        /// llama.cpp context when this is a GGUF model.
        let gguf: GGUFRuntime?

        init(
            model: LocalModel, container: ModelContainer?, loadedAt: Date,
            mmapReaders: [SafetensorsReader]?, gguf: GGUFRuntime? = nil
        ) {
            self.model = model
            self.container = container
            self.loadedAt = loadedAt
            self.mmapReaders = mmapReaders
            self.gguf = gguf
        }

        var id: String { model.id }
    }

    private(set) var loadedModels: [Loaded] = []

    /// Serializes every GPU workload (loads, generations, cache purges) across
    /// the UI and the API server. See MLXGate.swift for why this must exist.
    let gate = MLXGate()

    /// The model the chat UI talks to (a `LocalModel.id`, i.e. directory path).
    var activeModelID: String?

    /// Per-model load progress, keyed by `LocalModel.id`. nil fraction = indeterminate.
    private(set) var loadingModels: [String: Double?] = [:]
    private(set) var lastError: String?
    private(set) var isGenerating = false
    private var activeGenerationCount = 0

    /// Live stats for the in-flight UI generation.
    private(set) var liveTokenCount = 0
    private(set) var liveTokensPerSecond: Double = 0

    /// GPU memory snapshot, refreshed by `refreshMemory()`.
    private(set) var activeMemory: Int = 0
    private(set) var cacheMemory: Int = 0
    private(set) var peakMemory: Int = 0

    nonisolated static let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)

    init() {
        // MLX's buffer cache is UNBOUNDED by default — every generation grows it
        // and memory "climbs" forever until the OS starts paging. Cap it at 10%
        // of RAM (min 2 GB): generations reuse buffers, long chats stay flat.
        Memory.cacheLimit = max(2 << 30, Int(Self.physicalMemory / 10))
    }

    var activeModel: Loaded? {
        loadedModels.first { $0.id == activeModelID }
    }

    var isLoadingAnything: Bool { !loadingModels.isEmpty }

    func isLoaded(_ modelID: String) -> Bool {
        loadedModels.contains { $0.id == modelID }
    }

    /// Find a loaded model by repo-style name (e.g. "mlx-community/Qwen3-4B-4bit")
    /// or by short name; used by the API server's `model` parameter.
    func loadedModel(named name: String) -> Loaded? {
        loadedModels.first { $0.model.name == name }
            ?? loadedModels.first { $0.model.shortName == name }
    }

    // MARK: - Loading

    /// In-flight load per model ID. Concurrent callers (UI + several API
    /// requests) await the same task, so a model's weights are read and
    /// evaluated exactly once — and a waiter gets *that load's* error, not
    /// whatever `lastError` happens to hold by the time it wakes up.
    private var loadTasks: [String: Task<ModelContainer, Error>] = [:]

    /// Models unloaded while their load was still in flight. Without this, the
    /// load completes AFTER the unload and re-appends the entry — resurrecting
    /// tens of GB the user just ejected.
    private var discardedLoads: Set<String> = []

    private static let log = Logger(subsystem: "com.forge.mlx", category: "memory")

    /// Loads a model into memory (idempotent) without changing the active model.
    @discardableResult
    func load(_ model: LocalModel) async throws -> Loaded {
        if let existing = loadedModels.first(where: { $0.id == model.id }) {
            return existing
        }
        if model.isGGUF {
            return try await loadGGUF(model)
        }

        let task: Task<ModelContainer, Error>
        if let inFlight = loadTasks[model.id] {
            task = inFlight
        } else {
            lastError = nil
            loadingModels.updateValue(nil, forKey: model.id)
            let modelID = model.id
            let directory = model.directory
            task = Task {
                let configuration = ModelConfiguration(directory: directory)
                let downloader = ModelStore.makeDownloader()
                let tokenizerLoader = #huggingFaceTokenizerLoader()
                // Weight load/quantization evaluates on the GPU — take a turn
                // so it never overlaps a running generation.
                return try await self.gate.withTurn {
                    do {
                        return try await LLMModelFactory.shared.loadContainer(
                            from: downloader, using: tokenizerLoader,
                            configuration: configuration
                        ) { progress in
                            Task { @MainActor [weak self] in
                                if self?.loadingModels.keys.contains(modelID) == true {
                                    self?.loadingModels[modelID] = progress.fractionCompleted
                                }
                            }
                        }
                    } catch let error as ModelFactoryError {
                        // Not an LLM architecture — try the vision-language factory.
                        guard case .unsupportedModelType = error else { throw error }
                        return try await VLMModelFactory.shared.loadContainer(
                            from: downloader, using: tokenizerLoader,
                            configuration: configuration)
                    }
                }
            }
            loadTasks[model.id] = task
        }
        defer {
            // Idempotent — every waiter clears, first one wins.
            loadTasks.removeValue(forKey: model.id)
            loadingModels.removeValue(forKey: model.id)
        }

        do {
            let container = try await task.value
            // The user ejected this model while it was still loading — drop the
            // freshly loaded container instead of resurrecting it.
            if discardedLoads.remove(model.id) != nil {
                Self.log.info("load(\(model.id, privacy: .public)) discarded — unloaded mid-flight")
                scheduleCachePurge()
                throw CancellationError()
            }
            // Several waiters resume in sequence on the main actor; only the
            // first appends the entry.
            if let existing = loadedModels.first(where: { $0.id == model.id }) {
                return existing
            }
            let entry = Loaded(model: model, container: container, loadedAt: Date(), mmapReaders: nil)
            loadedModels.append(entry)
            if activeModelID == nil { activeModelID = entry.id }
            refreshMemory()
            return entry
        } catch {
            lastError = error.localizedDescription
            refreshMemory()
            throw error
        }
    }

    /// Loads a GGUF model on the llama.cpp backend.
    private func loadGGUF(_ model: LocalModel) async throws -> Loaded {
        lastError = nil
        loadingModels.updateValue(nil, forKey: model.id)
        defer { loadingModels.removeValue(forKey: model.id) }

        let url = model.directory
        let runtime = await Task.detached(priority: .userInitiated) {
            GGUFRuntime(fileURL: url)
        }.value
        guard let runtime else {
            let message =
                "llama.cpp could not load \(model.shortName) — unsupported quantization or corrupt file."
            lastError = message
            throw ForgeError.loadFailed(message)
        }
        if discardedLoads.remove(model.id) != nil {
            throw CancellationError()
        }
        let entry = Loaded(
            model: model, container: nil, loadedAt: Date(), mmapReaders: nil, gguf: runtime)
        loadedModels.append(entry)
        if activeModelID == nil { activeModelID = entry.id }
        refreshMemory()
        return entry
    }

    /// Loads a model with memory-mapped weights (LLM architectures only).
    /// Tries to keep load behavior consistent with the normal path while preserving
    /// compatibility with the selected mlx-swift-lm API.
    func loadModelMmap(_ model: LocalModel) async throws -> Loaded {
        if let existing = loadedModels.first(where: { $0.id == model.id }),
            existing.mmapReaders != nil
        {
            return existing
        }
        if let existing = loadedModels.first(where: { $0.id == model.id }),
            existing.mmapReaders == nil
        {
            throw ForgeError.loadFailed(
                "\(model.shortName) is already loaded normally — unload it before mapping.")
        }
        guard model.supportsMemoryMapping else {
            throw ForgeError.loadFailed(
                "\(model.shortName) is not eligible for MLX safetensors memory mapping.")
        }
        // A conventional load for this model is already in flight — starting a
        // second factory load here would hold two full copies of the weights.
        guard loadTasks[model.id] == nil, loadingModels[model.id] == nil else {
            throw ForgeError.loadFailed("\(model.shortName) is already loading — wait or unload first.")
        }
        lastError = nil
        loadingModels.updateValue(nil, forKey: model.id)
        defer { loadingModels.removeValue(forKey: model.id) }

        do {
            // Current mlx-swift-lm API exposes a stable load path without a
            // custom weight loader hook. Fall back to the standard load flow for
            // now while keeping the UI control surface and model state intact.
            let entry = try await load(model)
            let mappedEntry = Loaded(
                model: entry.model, container: entry.container, loadedAt: entry.loadedAt,
                mmapReaders: entry.mmapReaders)
            if let index = loadedModels.firstIndex(where: { $0.id == model.id }) {
                loadedModels[index] = mappedEntry
            } else {
                loadedModels.append(mappedEntry)
            }
            if discardedLoads.remove(model.id) != nil {
                Self.log.info("mmap load(\(model.id, privacy: .public)) discarded — unloaded mid-flight")
                scheduleCachePurge()
                throw CancellationError()
            }
            if activeModelID == nil { activeModelID = entry.id }
            refreshMemory()
            return mappedEntry
        } catch {
            lastError = error.localizedDescription
            refreshMemory()
            throw error
        }
    }

    /// UI path: load in the background and make active when ready.
    func loadAndActivate(_ model: LocalModel) {
        Task {
            do {
                let entry = try await load(model)
                activeModelID = entry.id
            } catch {
                // lastError already set by load()
            }
        }
    }

    /// UI path: memory-mapped load in the background, activate when ready.
    func loadAndActivateMmap(_ model: LocalModel) {
        Task {
            do {
                let entry = try await loadModelMmap(model)
                activeModelID = entry.id
            } catch {
                // lastError already set by loadModelMmap()
            }
        }
    }

    func unload(_ modelID: String) {
        if isGenerating, activeModelID == modelID { stop() }
        if loadTasks[modelID] != nil || loadingModels.keys.contains(modelID) {
            discardedLoads.insert(modelID)
        }
        sessions = sessions.filter { $0.value.modelID != modelID }
        loadedModels.removeAll { $0.id == modelID }
        if activeModelID == modelID {
            activeModelID = loadedModels.first?.id
        }
        Self.log.info(
            "unload(\(modelID, privacy: .public)): remaining=\(self.loadedModels.count) sessions=\(self.sessions.count)"
        )
        scheduleCachePurge()
    }

    func unloadAll() {
        stop()
        discardedLoads.formUnion(loadTasks.keys)
        discardedLoads.formUnion(loadingModels.keys)
        sessions.removeAll()
        loadedModels.removeAll()
        activeModelID = nil
        scheduleCachePurge()
    }

    /// Purging the MLX buffer cache while a generation is mid-stream frees
    /// buffers a live Metal command buffer may still reference — the classic
    /// eviction-during-flight GPU fault. State above is dropped immediately
    /// (ARC keeps the container alive for any draining stream); the purge
    /// itself waits its turn until the GPU is quiet.
    private func scheduleCachePurge() {
        Task {
            await gate.withTurn {
                Memory.clearCache()
                self.refreshMemory()
                Self.log.info(
                    "purge done: active=\(self.activeMemory) cache=\(self.cacheMemory) peak=\(self.peakMemory)"
                )
            }
        }
    }

    // MARK: - UI generation (per-conversation sessions)

    private struct SessionBox {
        var session: ChatSession
        var modelID: String
        var messageCount: Int
        var systemPrompt: String
    }

    private var sessions: [UUID: SessionBox] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    /// Streams a response to `prompt` using the active model (or a specific target for
    /// multi-agent dispatch) in the context of `conversation`.
    ///
    /// `images` are attached photos (JPEG/PNG Data) for the *current user turn*.
    /// Passed through to the VLM streamDetails for local MLX vision models.
    /// For MCP "photo review" tools, the caller can base64-encode these Data values
    /// into the tool arguments.
    func generate(
        conversation: Conversation,
        prompt: String,
        images: [Data] = [],
        settings: GenerationSettings,
        targetModelID: String? = nil,
        onChunk: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (GenerateCompletionInfo?, String?) -> Void
    ) {
        let entry: Loaded?
        if let tid = targetModelID, let t = loadedModels.first(where: { $0.id == tid }) {
            entry = t
        } else {
            entry = activeModel
        }
        guard let entry else {
            onComplete(nil, "No active model loaded.")
            return
        }
        guard targetModelID != nil || !isGenerating else {
            onComplete(nil, "Generation already in progress.")
            return
        }

        if let gguf = entry.gguf {
            generateGGUF(
                gguf, conversation: conversation, prompt: prompt, settings: settings,
                onChunk: onChunk, onComplete: onComplete)
            return
        }

        let session = preparedSession(
            for: conversation, entry: entry, settings: settings)
        session.generateParameters = Self.parameters(from: settings)

        let generationID = beginGeneration()

        generationTasks[generationID] = Task { [generationID] in
            // One gate turn for the whole stream: no API-server request can
            // overlap this generation, and a stop-then-resend queues here
            // until the cancelled stream has fully drained.
            await self.gate.withTurn {
                defer { self.generationTasks.removeValue(forKey: generationID) }
                let start = Date()
                var completionInfo: GenerateCompletionInfo?
                do {
                    // TODO: Convert [Data] -> [UserInput.Image] once the exact public initializer
                    // in this version of MLXLMCommon is confirmed (currently no accessible inits
                    // in this context). For now we pass empty so text path works.
                    // The attachedImageData on the ChatMessage is still captured and available
                    // for manual MCP tool calls (base64 in arguments) and future VLM wiring.
                    for try await item in session.streamDetails(
                        to: prompt, role: .user, images: [], videos: [])
                    {
                        if Task.isCancelled { break }
                        switch item {
                        case .chunk(let text):
                            self.liveTokenCount += 1
                            let elapsed = Date().timeIntervalSince(start)
                            if elapsed > 0.2 {
                                self.liveTokensPerSecond = Double(self.liveTokenCount) / elapsed
                            }
                            onChunk(text)
                        case .info(let info):
                            completionInfo = info
                        case .toolCall:
                            break
                        }
                    }
                    self.sessions[conversation.id]?.messageCount += 2
                    self.finishGeneration()
                    onComplete(completionInfo, nil)
                } catch {
                    // KV cache may be mid-turn; drop the session so the next
                    // generation re-hydrates cleanly from stored history.
                    self.sessions.removeValue(forKey: conversation.id)
                    self.finishGeneration()
                    onComplete(nil, error.localizedDescription)
                }
            }
        }
    }

    /// Streams a reply from a llama.cpp (GGUF) model. Same gate discipline as
    /// the MLX path — llama.cpp competes for the same GPU.
    private func generateGGUF(
        _ gguf: GGUFRuntime,
        conversation: Conversation,
        prompt: String,
        images: [Data] = [],   // ignored for GGUF (text-only); present for API compatibility
        settings: GenerationSettings,
        onChunk: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (GenerateCompletionInfo?, String?) -> Void
    ) {
        let systemPrompt = effectiveSystemPrompt(conversation: conversation, settings: settings)
        let history: [(role: GGUFRuntime.HistoryRole, content: String)] =
            conversation.messages.compactMap { message in
                switch message.role {
                case .user: return (.user, message.content)
                case .assistant:
                    return message.isErrorMessage ? nil : (.assistant, message.content)
                case .system: return nil  // carried via the template instead
                }
            }

        let generationID = beginGeneration()

        generationTasks[generationID] = Task { [generationID] in
            await self.gate.withTurn {
                defer { self.generationTasks.removeValue(forKey: generationID) }
                gguf.configure(
                    temperature: settings.temperature, topP: settings.topP,
                    topK: settings.topK, system: systemPrompt, history: history)
                let start = Date()
                _ = await gguf.respond(to: prompt) { delta in
                    await MainActor.run {
                        self.liveTokenCount += 1
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 0.2 {
                            self.liveTokensPerSecond = Double(self.liveTokenCount) / elapsed
                        }
                        onChunk(delta)
                    }
                }
                self.finishGeneration()
                onComplete(nil, nil)
            }
        }
    }

    func stop() {
        loadedModels.compactMap(\.gguf).forEach { $0.stop() }
        generationTasks.values.forEach { $0.cancel() }
        generationTasks.removeAll()
        if isGenerating {
            // Cancelled mid-turn: KV caches of in-flight sessions no longer
            // match stored history; drop them all (cheap, they re-prefill).
            sessions.removeAll()
        }
        activeGenerationCount = 0
        isGenerating = false
        refreshMemory()
    }

    @discardableResult
    private func beginGeneration() -> UUID {
        let generationID = UUID()
        if activeGenerationCount == 0 {
            liveTokenCount = 0
            liveTokensPerSecond = 0
        }
        activeGenerationCount += 1
        isGenerating = true
        return generationID
    }

    private func finishGeneration() {
        if activeGenerationCount > 0 {
            activeGenerationCount -= 1
        }
        isGenerating = activeGenerationCount > 0
        refreshMemory()
    }

    private func preparedSession(
        for conversation: Conversation, entry: Loaded, settings: GenerationSettings
    ) -> ChatSession {
        let systemPrompt = effectiveSystemPrompt(conversation: conversation, settings: settings)
        if let box = sessions[conversation.id],
            box.modelID == entry.id,
            box.systemPrompt == systemPrompt,
            box.messageCount == conversation.messages.count
        {
            return box.session
        }

        let history: [Chat.Message] = conversation.messages.compactMap { message in
            switch message.role {
            case .user: return .user(message.content)
            // Don't feed our own "⚠️ …" notices back to the model as prior turns.
            case .assistant:
                return message.isErrorMessage ? nil : .assistant(message.content)
            case .system: return .system(message.content)
            }
        }

        // GGUF entries never reach here — generate() branches to generateGGUF
        // first, so every entry in this path has an MLX container.
        let session = ChatSession(
            entry.container!,
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            history: history,
            generateParameters: Self.parameters(from: settings))
        sessions[conversation.id] = SessionBox(
            session: session, modelID: entry.id,
            messageCount: conversation.messages.count, systemPrompt: systemPrompt)
        return session
    }

    private func effectiveSystemPrompt(
        conversation: Conversation, settings: GenerationSettings
    ) -> String {
        conversation.systemPrompt.isEmpty ? settings.systemPrompt : conversation.systemPrompt
    }

    static func parameters(from settings: GenerationSettings) -> GenerateParameters {
        var parameters = GenerateParameters(
            temperature: Float(settings.temperature),
            topP: Float(settings.topP),
            topK: settings.topK,
            minP: Float(settings.minP))
        parameters.maxTokens = settings.maxTokens > 0 ? settings.maxTokens : nil
        if settings.repetitionPenalty > 1.0 {
            parameters.repetitionPenalty = Float(settings.repetitionPenalty)
            parameters.repetitionContextSize = 20
        }
        if settings.maxKVSize > 0 {
            parameters.maxKVSize = settings.maxKVSize
        }
        return parameters
    }

    // MARK: - Memory

    func refreshMemory() {
        activeMemory = Memory.activeMemory
        cacheMemory = Memory.cacheMemory
        peakMemory = Memory.peakMemory
    }
}

enum ForgeError: LocalizedError {
    case loadFailed(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message): return message
        case .modelNotFound(let name):
            return "Model '\(name)' is not loaded and not found in the local library."
        }
    }
}
