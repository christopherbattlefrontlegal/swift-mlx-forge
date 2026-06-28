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
        /// Forge weight materialization policy when loaded via the policy path.
        let weightLoadPolicy: WeightLoadPolicy?
        /// llama.cpp context when this is a GGUF model.
        let gguf: GGUFRuntime?
        /// Whether the tokenizer chat template accepts a `system` role.
        let supportsChatSystemRole: Bool
        /// Sniffed at load: tokenizer ships a chat template.
        let chatTemplateHasTemplate: Bool
        /// Sniffed at load: template defines `enable_thinking`.
        let chatTemplateSupportsThinkingToggle: Bool
        /// Sniffed at load: template has no off-branch for `enable_thinking`.
        let chatTemplateThinkingOnly: Bool
        /// Sniffed at load: generation prompt always opens a `` block.
        let chatTemplateThinkingBuiltIn: Bool

        init(
            model: LocalModel, container: ModelContainer?, loadedAt: Date,
            weightLoadPolicy: WeightLoadPolicy? = nil,
            gguf: GGUFRuntime? = nil,
            supportsChatSystemRole: Bool = true,
            templateCaps: ChatTemplateSniffer.Capabilities = ChatTemplateSniffer.Capabilities()
        ) {
            self.model = model
            self.container = container
            self.loadedAt = loadedAt
            self.weightLoadPolicy = weightLoadPolicy
            self.gguf = gguf
            self.supportsChatSystemRole = supportsChatSystemRole
            self.chatTemplateHasTemplate = templateCaps.hasChatTemplate
            self.chatTemplateSupportsThinkingToggle = templateCaps.supportsThinkingToggle
            self.chatTemplateThinkingOnly = templateCaps.thinkingOnly
            self.chatTemplateThinkingBuiltIn = templateCaps.thinkingBuiltIntoTemplate
        }

        var expectsReasoningOutput: Bool {
            ChatTemplateSniffer.expectsReasoningOutput(
                ChatTemplateSniffer.Capabilities(
                    hasChatTemplate: chatTemplateHasTemplate,
                    supportsThinkingToggle: chatTemplateSupportsThinkingToggle,
                    thinkingOnly: chatTemplateThinkingOnly,
                    thinkingBuiltIntoTemplate: chatTemplateThinkingBuiltIn))
        }

        var id: String { model.id }
    }

    private(set) var loadedModels: [Loaded] = []

    /// Serializes every GPU workload (loads, generations, cache purges) across
    /// the UI and the API server. See MLXGate.swift for why this must exist.
    let gate = MLXGate()

    /// The model the chat UI talks to (a `LocalModel.id`, i.e. directory path).
    var activeModelID: String? {
        didSet {
            guard let activeModelID, activeModelID != oldValue else { return }
            refreshTemplateCaps(for: activeModelID)
        }
    }

    /// Per-model load progress, keyed by `LocalModel.id`. nil fraction = indeterminate.
    private(set) var loadingModels: [String: Double?] = [:]
    /// Deferred model paying the first-forward materialization cost (UI spinner label).
    private(set) var materializingModelID: String?
    /// Non-fatal note shown after a deferred load on a very large checkpoint.
    private(set) var loadAdvisory: String?
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
    private var loadGenerations: [String: UInt64] = [:]
    private var loadTaskPolicies: [String: WeightLoadPolicy] = [:]

    /// Models unloaded while their load was still in flight. Without this, the
    /// load completes AFTER the unload and re-appends the entry — resurrecting
    /// tens of GB the user just ejected.
    private var discardedLoads: Set<String> = []

    private static let log = Logger(subsystem: "com.forge.mlx", category: "memory")

    /// Resolves the MLX safetensors load policy for UI and API loads.
    var weightLoadPolicy: () -> WeightLoadPolicy = { .eager }
    /// Generation settings for GGUF context sizing and sampling.
    var generationSettings: () -> GenerationSettings = { GenerationSettings() }

    /// Loads a model into memory (idempotent) without changing the active model.
    @discardableResult
    func load(_ model: LocalModel) async throws -> Loaded {
        try await load(model, policy: weightLoadPolicy())
    }

    @discardableResult
    func load(_ model: LocalModel, policy: WeightLoadPolicy) async throws -> Loaded {
        if let existing = loadedModels.first(where: { $0.id == model.id }) {
            return existing
        }
        if model.isGGUF {
            return try await loadGGUF(model)
        }

        var knownModels = loadedModels.map(\.model)
        if !knownModels.contains(where: { $0.id == model.id }) {
            knownModels.append(model)
        }
        let admission = ModelMemoryBudget.canLoad(
            model,
            slotAssignments: loadedModels.map(\.id),
            allModels: knownModels)
        if !admission.allowed {
            let message = admission.message ?? "Not enough RAM to load \(model.shortName)."
            lastError = message
            throw ForgeError.loadFailed(message)
        }

        let useFactoryLoader = policy == .eager || model.prefersStandardMLXLoad
        let task: Task<ModelContainer, Error>
        let generation: UInt64
        if let inFlight = loadTasks[model.id],
            loadTaskPolicies[model.id] == policy
        {
            task = inFlight
            generation = loadGenerations[model.id] ?? 0
        } else {
            if loadTasks[model.id] != nil {
                loadTasks[model.id]?.cancel()
                loadTasks.removeValue(forKey: model.id)
                loadTaskPolicies.removeValue(forKey: model.id)
            }
            discardedLoads.remove(model.id)
            lastError = nil
            loadingModels.updateValue(nil, forKey: model.id)
            let modelID = model.id
            let directory = model.directory
            let loadPolicy = policy
            generation = (loadGenerations[model.id] ?? 0) + 1
            loadGenerations[model.id] = generation
            loadTaskPolicies[model.id] = policy
            if loadPolicy != .eager, model.prefersStandardMLXLoad {
                Self.log.info(
                    "load(\(modelID, privacy: .public)): MoE/dense-mix — using standard MLX loader for full speed"
                )
            }
            if loadPolicy == .deferred, model.isVeryLargeForDeferredLoad {
                loadAdvisory =
                    "Deferred \(model.shortName): first send materializes the full checkpoint (often several minutes on 100B+). The status bar shows progress — use Stop if needed, or Reload Standard for eager weights."
                Self.log.info(
                    "load(\(modelID, privacy: .public)): deferred on very large model — first send will materialize all weights (may take several minutes)"
                )
            } else {
                loadAdvisory = nil
            }
            task = Task {
                try await self.gate.withTurn {
                    try Task.checkCancellation()
                    return try await Self.loadMLXContainerOffMainThread(
                        directory: directory,
                        loadPolicy: loadPolicy,
                        useFactoryLoader: useFactoryLoader
                    ) { fraction in
                        Task { @MainActor [weak self] in
                            if self?.loadingModels.keys.contains(modelID) == true {
                                self?.loadingModels[modelID] = fraction
                            }
                        }
                    }
                }
            }
            loadTasks[model.id] = task
        }
        defer {
            if loadGenerations[model.id] == generation {
                loadTasks.removeValue(forKey: model.id)
                loadTaskPolicies.removeValue(forKey: model.id)
                loadingModels.removeValue(forKey: model.id)
            }
        }

        do {
            let container = try await task.value
            if discardedLoads.remove(model.id) != nil {
                Self.log.info("load(\(model.id, privacy: .public)) discarded — unloaded mid-flight")
                recordLoadCancelled(for: model)
                scheduleCachePurge()
                throw CancellationError()
            }
            if let existing = loadedModels.first(where: { $0.id == model.id }) {
                return existing
            }
            let recordedPolicy: WeightLoadPolicy? =
                useFactoryLoader && policy != .eager ? .eager : policy
            let templateCaps = Self.templateCaps(for: model)
            let entry = Loaded(
                model: model, container: container, loadedAt: Date(),
                weightLoadPolicy: recordedPolicy,
                templateCaps: templateCaps)
            loadedModels.append(entry)
            if activeModelID == nil { activeModelID = entry.id }
            refreshMemory()
            if let policy = entry.weightLoadPolicy {
                Self.log.info(
                    "load(\(model.id, privacy: .public)) complete — policy \(policy.shortLabel, privacy: .public)")
            }
            return entry
        } catch is CancellationError {
            if lastError == nil { recordLoadCancelled(for: model) }
            refreshMemory()
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            refreshMemory()
            throw error
        }
    }

    /// Loads a GGUF model on the llama.cpp backend.
    private func loadGGUF(_ model: LocalModel) async throws -> Loaded {
        var knownModels = loadedModels.map(\.model)
        if !knownModels.contains(where: { $0.id == model.id }) {
            knownModels.append(model)
        }
        let admission = ModelMemoryBudget.canLoad(
            model,
            slotAssignments: loadedModels.map(\.id),
            allModels: knownModels)
        if !admission.allowed {
            let message = admission.message ?? "Not enough RAM to load \(model.shortName)."
            lastError = message
            throw ForgeError.loadFailed(message)
        }

        lastError = nil
        loadingModels.updateValue(nil, forKey: model.id)
        defer { loadingModels.removeValue(forKey: model.id) }

        let settings = generationSettings()
        let ctxTokens = settings.maxKVSize > 0 ? settings.maxKVSize : 8192
        let url = model.directory
        let runtime = await gate.withTurn {
            await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return GGUFRuntime(
                    fileURL: url, maxTokens: Int32(min(ctxTokens, 131_072)))
            }.value
        }
        guard let runtime else {
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            let message =
                "llama.cpp could not load \(model.shortName) at \(url.path) — "
                + (readable
                    ? "check RAM is available and the quantization is supported."
                    : "file is not readable (re-add the model folder in Settings if sandboxed).")
            lastError = message
            throw ForgeError.loadFailed(message)
        }
        if discardedLoads.remove(model.id) != nil {
            recordLoadCancelled(for: model)
            throw CancellationError()
        }
        let entry = Loaded(
            model: model, container: nil, loadedAt: Date(),
            weightLoadPolicy: nil, gguf: runtime,
            templateCaps: Self.templateCaps(for: model))
        loadedModels.append(entry)
        if activeModelID == nil { activeModelID = entry.id }
        refreshMemory()
        return entry
    }

    /// User-initiated or superseded load — don't surface as a load failure.
    private func recordLoadCancelled(for model: LocalModel) {
        Self.log.info("load(\(model.id, privacy: .public)) cancelled")
        lastError = nil
    }

    /// UI path: load in the background and make active when ready.
    func loadAndActivate(_ model: LocalModel, policy: WeightLoadPolicy = .eager) {
        Task {
            do {
                let entry = try await load(model, policy: policy)
                activeModelID = entry.id
            } catch is CancellationError {
                // Unload mid-flight or superseded — not an error surface.
            } catch {
                // lastError already set by load()
            }
        }
    }

    func unload(_ modelID: String) {
        if activeModelID == modelID, isGenerating { stop() }
        cancelInFlightLoad(for: modelID)
        sessions = sessions.filter { $0.value.modelID != modelID }
        loadedModels.removeAll { $0.id == modelID }
        if activeModelID == modelID {
            activeModelID = loadedModels.first?.id
        }
        lastError = nil
        Self.log.info(
            "unload(\(modelID, privacy: .public)): remaining=\(self.loadedModels.count) sessions=\(self.sessions.count)"
        )
        scheduleCachePurge()
    }

    func unloadAll() {
        stop()
        tearDownLoadedModels(scheduleAsyncPurge: true)
    }

    /// Quit-safe teardown: wait for in-flight MLX/GGUF work to drain before
    /// dropping containers (avoids scheduler/Metal faults on app exit).
    func shutdown() async {
        let generationSnapshot = Array(generationTasks.values)
        loadedModels.compactMap(\.gguf).forEach { $0.stop() }
        generationSnapshot.forEach { $0.cancel() }

        let loadSnapshot = Array(loadTasks.values)
        let inFlight = Set(loadTasks.keys).union(loadingModels.keys)
        discardedLoads.formUnion(inFlight)
        loadSnapshot.forEach { $0.cancel() }

        for task in generationSnapshot { await task.value }
        for task in loadSnapshot { _ = try? await task.value }

        generationTasks.removeAll()
        materializingModelID = nil
        activeGenerationCount = 0
        isGenerating = false

        tearDownLoadedModels(scheduleAsyncPurge: false)

        await gate.withTurn {
            await Task.detached(priority: .utility) {
                Memory.clearCache()
            }.value
            self.refreshMemory()
            Self.log.info(
                "shutdown purge: active=\(self.activeMemory) cache=\(self.cacheMemory) peak=\(self.peakMemory)"
            )
        }
    }

    private func tearDownLoadedModels(scheduleAsyncPurge: Bool) {
        loadTasks.removeAll()
        loadTaskPolicies.removeAll()
        loadingModels.removeAll()
        sessions.removeAll()
        loadedModels.removeAll()
        activeModelID = nil
        lastError = nil
        if scheduleAsyncPurge {
            scheduleCachePurge()
        }
    }

    /// Abort a background load and drop its progress indicator immediately.
    private func cancelInFlightLoad(for modelID: String) {
        guard loadTasks[modelID] != nil
            || loadingModels[modelID] != nil
        else { return }
        discardedLoads.insert(modelID)
        loadTasks[modelID]?.cancel()
        loadTasks.removeValue(forKey: modelID)
        loadTaskPolicies.removeValue(forKey: modelID)
        loadingModels.removeValue(forKey: modelID)
    }

    /// Purging the MLX buffer cache while a generation is mid-stream frees
    /// buffers a live Metal command buffer may still reference — the classic
    /// eviction-during-flight GPU fault. State above is dropped immediately
    /// (ARC keeps the container alive for any draining stream); the purge
    /// itself waits its turn until the GPU is quiet.
    private func scheduleCachePurge() {
        Task {
            await gate.withTurn {
                await Task.detached(priority: .utility) {
                    Memory.clearCache()
                }.value
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
        var localThinkingEnabled: Bool
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
        systemInstructions: String = "",
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

        let resolvedSystem = Self.resolvedSystemInstructions(
            explicit: systemInstructions, conversation: conversation, settings: settings)

        if let gguf = entry.gguf {
            generateGGUF(
                gguf, conversation: conversation, prompt: prompt, settings: settings,
                systemInstructions: resolvedSystem,
                onChunk: onChunk, onComplete: onComplete)
            return
        }

        let (session, userPrompt) = preparedSession(
            for: conversation, entry: entry, settings: settings,
            systemInstructions: resolvedSystem)
        session.generateParameters = Self.parameters(from: settings)

        let generationID = beginGeneration()
        let deferredMaterialize = entry.weightLoadPolicy == .deferred
        if deferredMaterialize {
            materializingModelID = entry.id
            loadAdvisory = nil
        }

        generationTasks[generationID] = Task { [generationID] in
            // One gate turn for the whole stream: no API-server request can
            // overlap this generation, and a stop-then-resend queues here
            // until the cancelled stream has fully drained.
            await self.gate.withTurn {
                defer {
                    self.generationTasks.removeValue(forKey: generationID)
                    if self.materializingModelID == entry.id {
                        self.materializingModelID = nil
                    }
                }
                let start = Date()
                var completionInfo: GenerateCompletionInfo?
                do {
                    // TODO: Convert [Data] -> [UserInput.Image] once the exact public initializer
                    // in this version of MLXLMCommon is confirmed (currently no accessible inits
                    // in this context). For now we pass empty so text path works.
                    // The attachedImageData on the ChatMessage is still captured and available
                    // for manual MCP tool calls (base64 in arguments) and future VLM wiring.
                    for try await item in session.streamDetails(
                        to: userPrompt, role: .user, images: [], videos: [])
                    {
                        if Task.isCancelled { break }
                        switch item {
                        case .chunk(let text):
                            if self.materializingModelID == entry.id {
                                self.materializingModelID = nil
                            }
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
        systemInstructions: String,
        onChunk: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (GenerateCompletionInfo?, String?) -> Void
    ) {
        let systemPrompt = systemInstructions
        let history: [(role: GGUFRuntime.HistoryRole, content: String)] =
            conversation.messages.compactMap { message in
                switch message.role {
                case .user: return (.user, message.content)
                case .assistant:
                    if message.content.isEmpty || message.isErrorMessage { return nil }
                    return (.assistant, message.content)
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
        materializingModelID = nil
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

    func invalidateChatSessions() {
        sessions.removeAll()
    }

    private func preparedSession(
        for conversation: Conversation, entry: Loaded, settings: GenerationSettings,
        systemInstructions: String
    ) -> (ChatSession, String) {
        let systemPrompt = systemInstructions
        if var box = sessions[conversation.id],
            box.modelID == entry.id,
            box.systemPrompt == systemPrompt,
            box.messageCount == conversation.messages.count,
            box.localThinkingEnabled == settings.localThinkingEnabled
        {
            box.session.additionalContext = Self.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled)
            sessions[conversation.id] = box
            let userPrompt = Self.userPrompt(
                prompt: conversation.messages.last?.content ?? "",
                system: systemPrompt,
                supportsSystemRole: entry.supportsChatSystemRole)
            return (box.session, userPrompt)
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
        let instructionsForSession =
            (!systemPrompt.isEmpty && entry.supportsChatSystemRole) ? systemPrompt : nil
        let session = ChatSession(
            entry.container!,
            instructions: instructionsForSession,
            history: history,
            generateParameters: Self.parameters(from: settings),
            additionalContext: Self.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled))
        sessions[conversation.id] = SessionBox(
            session: session, modelID: entry.id,
            messageCount: conversation.messages.count, systemPrompt: systemPrompt,
            localThinkingEnabled: settings.localThinkingEnabled)
        let userPrompt = Self.userPrompt(
            prompt: conversation.messages.last?.content ?? "",
            system: systemPrompt,
            supportsSystemRole: entry.supportsChatSystemRole)
        return (session, userPrompt)
    }

    private static func resolvedSystemInstructions(
        explicit: String,
        conversation: Conversation,
        settings: GenerationSettings
    ) -> String {
        let trimmedExplicit = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExplicit.isEmpty { return explicit }
        let global = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { return settings.systemPrompt }
        let perConversation = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !perConversation.isEmpty { return conversation.systemPrompt }
        return ""
    }

    private static func userPrompt(
        prompt: String, system: String, supportsSystemRole: Bool
    ) -> String {
        guard !supportsSystemRole else { return prompt }
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else { return prompt }
        return """
            System instructions:
            \(trimmedSystem)

            User:
            \(prompt)
            """
    }

    /// Heavy MLX container load — always off the main thread so huge checkpoints
    /// don't beach-ball the UI during shard I/O or eval.
    private nonisolated static func loadMLXContainerOffMainThread(
        directory: URL,
        loadPolicy: WeightLoadPolicy,
        useFactoryLoader: Bool,
        reportProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let configuration = ModelConfiguration(directory: directory)
            let downloader = ModelStore.makeDownloader()
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            if useFactoryLoader {
                do {
                    return try await LLMModelFactory.shared.loadContainer(
                        from: downloader, using: tokenizerLoader,
                        configuration: configuration
                    ) { progress in
                        reportProgress(progress.fractionCompleted)
                    }
                } catch let error as ModelFactoryError {
                    guard case .unsupportedModelType = error else { throw error }
                    return try await VLMModelFactory.shared.loadContainer(
                        from: downloader, using: tokenizerLoader,
                        configuration: configuration)
                }
            }

            do {
                let (container, _) = try await loadLLMContainerWithPolicy(
                    modelDirectory: directory,
                    policy: loadPolicy,
                    tokenizerLoader: tokenizerLoader,
                    progress: reportProgress
                )
                return container
            } catch let error as ModelFactoryError {
                guard case .unsupportedModelType = error else { throw error }
                return try await VLMModelFactory.shared.loadContainer(
                    from: downloader, using: tokenizerLoader,
                    configuration: configuration)
            }
        }.value
    }

    /// Prefer catalog sniff at scan time; re-sniff on disk when loading.
    static func templateCaps(for model: LocalModel) -> ChatTemplateSniffer.Capabilities {
        if let cached = model.chatTemplateCaps { return cached }
        return ChatTemplateSniffer.sniff(modelDirectory: model.directory)
    }

    /// Re-sniff template files for a loaded entry (e.g. after an app update).
    func refreshTemplateCaps(for modelID: String) {
        guard let index = loadedModels.firstIndex(where: { $0.id == modelID }) else { return }
        let model = loadedModels[index].model
        let caps = Self.templateCaps(for: model)
        loadedModels[index] = Loaded(
            model: model,
            container: loadedModels[index].container,
            loadedAt: loadedModels[index].loadedAt,
            weightLoadPolicy: loadedModels[index].weightLoadPolicy,
            gguf: loadedModels[index].gguf,
            supportsChatSystemRole: loadedModels[index].supportsChatSystemRole,
            templateCaps: caps)
    }

    /// Qwen/QwQ chat templates read `enable_thinking` from template kwargs.
    /// Models without that variable in their Jinja template ignore it harmlessly.
    static func thinkingAdditionalContext(
        for entry: Loaded, enabled: Bool
    ) -> [String: any Sendable]? {
        guard entry.chatTemplateSupportsThinkingToggle else { return nil }
        return ["enable_thinking": enabled]
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
