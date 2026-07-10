// Forge — in-process MLX inference engine with multi-model residency.
//
// Several models can be loaded into unified memory simultaneously; one is
// "active" for the chat UI, and the API server can address any loaded model
// by name (auto-loading installed ones on demand). Per-conversation
// ChatSessions keep KV caches alive across turns.

import AppKit
import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Observation
import Tokenizers
import os.log

private struct BudgetTurn: Sendable {
    var role: String
    var content: String
    var images: [Data] = []
}

@MainActor
@Observable
final class InferenceEngine {

    /// A model resident in unified memory — MLX backend (container) or
    /// llama.cpp backend (gguf). Exactly one of the two is non-nil.
    struct Loaded: Identifiable {
        let model: LocalModel
        let container: ModelContainer?
        /// Forge weight materialization policy when loaded via the policy path.
        let weightLoadPolicy: WeightLoadPolicy?
        /// llama.cpp context when this is a GGUF model.
        let gguf: GGUFRuntime?
        /// Sniffed at load: tokenizer ships a chat template.
        let chatTemplateHasTemplate: Bool
        /// Sniffed at load: template defines `enable_thinking`.
        let chatTemplateSupportsThinkingToggle: Bool
        /// Sniffed at load: template has no off-branch for `enable_thinking`.
        let chatTemplateThinkingOnly: Bool
        /// Sniffed at load: generation prompt always opens a `` block.
        let chatTemplateThinkingBuiltIn: Bool

        init(
            model: LocalModel, container: ModelContainer?,
            weightLoadPolicy: WeightLoadPolicy? = nil,
            gguf: GGUFRuntime? = nil,
            templateCaps: ChatTemplateSniffer.Capabilities = ChatTemplateSniffer.Capabilities()
        ) {
            self.model = model
            self.container = container
            self.weightLoadPolicy = weightLoadPolicy
            self.gguf = gguf
            self.chatTemplateHasTemplate = templateCaps.hasChatTemplate
            self.chatTemplateSupportsThinkingToggle = templateCaps.supportsThinkingToggle
            self.chatTemplateThinkingOnly = templateCaps.thinkingOnly
            self.chatTemplateThinkingBuiltIn = templateCaps.thinkingBuiltIntoTemplate
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
    /// IDs of generations that are live. `stop()` empties this set; a cancelled
    /// generation that drains afterwards finds its ID gone and must not touch
    /// state owned by a newer generation.
    private var activeGenerationIDs: Set<UUID> = []

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
    /// Models that have passed admission and are queued/loading but are not yet
    /// resident. They reserve RAM and slots so concurrent loads cannot each
    /// admit themselves against the same stale snapshot.
    private var pendingLoadModels: [String: LocalModel] = [:]
    /// In-flight GGUF load per model ID — same dedup role as `loadTasks`.
    private var ggufLoadTasks: [String: Task<GGUFRuntime?, Never>] = [:]

    /// Models unloaded while their load was still in flight. Without this, the
    /// load completes AFTER the unload and re-appends the entry — resurrecting
    /// tens of GB the user just ejected.
    private var discardedLoads: Set<String> = []

    private static let log = Logger(subsystem: "com.forge.mlx", category: "memory")

    /// Resolves the MLX safetensors load policy for UI and API loads.
    var weightLoadPolicy: () -> WeightLoadPolicy = { .eager }
    /// Generation settings for GGUF context sizing and sampling.
    var generationSettings: () -> GenerationSettings = { GenerationSettings() }

    private func admissionDecision(for model: LocalModel) -> ModelMemoryBudget.LoadDecision {
        let reservations = pendingLoadModels.values.filter { $0.id != model.id }
        var knownModels = loadedModels.map(\.model) + reservations
        if !knownModels.contains(where: { $0.id == model.id }) {
            knownModels.append(model)
        }
        return ModelMemoryBudget.canLoad(
            model,
            slotAssignments: loadedModels.map(\.id) + reservations.map(\.id),
            allModels: knownModels)
    }

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

        let admission = admissionDecision(for: model)
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
            pendingLoadModels[model.id] = model
            let loadGeneration = generation
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
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.gate.withTurn {
                    try Task.checkCancellation()
                    return try await Self.loadMLXContainerOffMainThread(
                        directory: directory,
                        loadPolicy: loadPolicy,
                        useFactoryLoader: useFactoryLoader
                    ) { [weak self, modelID, loadGeneration] fraction in
                        Task { @MainActor [weak self, modelID, loadGeneration] in
                            guard let self,
                                self.loadGenerations[modelID] == loadGeneration,
                                self.loadingModels.keys.contains(modelID)
                            else { return }
                            self.loadingModels[modelID] = fraction
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
                pendingLoadModels.removeValue(forKey: model.id)
            }
        }

        do {
            let container = try await task.value
            if loadGenerations[model.id] != generation
                || discardedLoads.remove(model.id) != nil
            {
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
                model: model, container: container,
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
        let admission = admissionDecision(for: model)
        if !admission.allowed {
            let message = admission.message ?? "Not enough RAM to load \(model.shortName)."
            lastError = message
            throw ForgeError.loadFailed(message)
        }

        // Same dedup + generation discipline as the MLX `loadTasks` path:
        // concurrent callers (UI + API auto-load) await ONE runtime creation,
        // and a superseded load can neither clean up the newer load's state
        // nor resurrect a model the user just ejected.
        let task: Task<GGUFRuntime?, Never>
        let generation: UInt64
        if let inFlight = ggufLoadTasks[model.id] {
            task = inFlight
            generation = loadGenerations[model.id] ?? 0
        } else {
            discardedLoads.remove(model.id)
            lastError = nil
            loadingModels.updateValue(nil, forKey: model.id)
            generation = (loadGenerations[model.id] ?? 0) + 1
            loadGenerations[model.id] = generation
            pendingLoadModels[model.id] = model

            let settings = generationSettings()
            // 0 = auto. 8192 was far too small: a big system preset + long message
            // overflows llama.cpp's context and the wrapper fails the turn with NO
            // output at all. 32k covers real prompts; the wrapper still clamps to
            // the model's trained context.
            let ctxTokens = settings.maxKVSize > 0 ? settings.maxKVSize : 32_768
            let url = model.directory
            let modelID = model.id
            let loadGeneration = generation
            // llama.cpp reports load progress per tensor from its loader thread —
            // throttle to whole-percent steps before hopping to the main actor.
            let lastPercent = GGUFLoadProgressThrottle()
            task = Task { [weak self, url, ctxTokens, modelID, loadGeneration, lastPercent] in
                guard let self else { return nil }
                do {
                    return try await self.gate.withTurn {
                        await Task.detached(priority: .userInitiated) {
                            [url, ctxTokens, modelID, loadGeneration, lastPercent, weak self] in
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return GGUFRuntime(
                                fileURL: url, maxTokens: Int32(min(ctxTokens, 131_072)),
                                onLoadProgress: {
                                    [weak self, modelID, loadGeneration, lastPercent] fraction in
                                    guard lastPercent.advance(to: fraction) else { return }
                                    Task { @MainActor [weak self, modelID, loadGeneration] in
                                        guard let self,
                                            self.loadGenerations[modelID] == loadGeneration,
                                            self.loadingModels.keys.contains(modelID)
                                        else { return }
                                        self.loadingModels[modelID] = fraction
                                    }
                                })
                        }.value
                    }
                } catch {
                    return nil
                }
            }
            ggufLoadTasks[model.id] = task
        }
        defer {
            // Only the owner of the current generation cleans up — a superseded
            // load must not remove the newer load's task or progress entry.
            if loadGenerations[model.id] == generation {
                ggufLoadTasks.removeValue(forKey: model.id)
                loadingModels.removeValue(forKey: model.id)
                pendingLoadModels.removeValue(forKey: model.id)
            }
        }

        let runtime = await task.value
        if discardedLoads.remove(model.id) != nil || loadGenerations[model.id] != generation {
            // Unloaded mid-flight, or superseded by a newer load cycle — never
            // surface a stale runtime (it would resurrect ejected gigabytes).
            recordLoadCancelled(for: model)
            throw CancellationError()
        }
        if let existing = loadedModels.first(where: { $0.id == model.id }) {
            return existing
        }
        guard let runtime else {
            let readable = FileManager.default.isReadableFile(atPath: model.directory.path)
            let message =
                "llama.cpp could not load \(model.shortName) at \(model.directory.path) — "
                + (readable
                    ? "check RAM is available and the quantization is supported."
                    : "file is not readable (re-add the model folder in Settings if sandboxed).")
            lastError = message
            throw ForgeError.loadFailed(message)
        }
        let entry = Loaded(
            model: model, container: nil,
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
        Task { [weak self, model, policy] in
            guard let self else { return }
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
        cancelGenerations(for: modelID)
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
        generationModelIDs.removeAll()
        materializingModelID = nil
        activeGenerationIDs.removeAll()
        isGenerating = false

        tearDownLoadedModels(scheduleAsyncPurge: false)

        _ = try? await gate.withTurn {
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
        let inFlight = Set(loadTasks.keys)
            .union(ggufLoadTasks.keys)
            .union(loadingModels.keys)
            .union(pendingLoadModels.keys)
        discardedLoads.formUnion(inFlight)
        for modelID in inFlight {
            loadGenerations[modelID] = (loadGenerations[modelID] ?? 0) + 1
        }
        loadTasks.values.forEach { $0.cancel() }
        ggufLoadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        loadTaskPolicies.removeAll()
        ggufLoadTasks.removeAll()
        loadingModels.removeAll()
        pendingLoadModels.removeAll()
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
            || ggufLoadTasks[modelID] != nil
            || loadingModels[modelID] != nil
        else { return }
        discardedLoads.insert(modelID)
        loadGenerations[modelID] = (loadGenerations[modelID] ?? 0) + 1
        loadTasks[modelID]?.cancel()
        loadTasks.removeValue(forKey: modelID)
        loadTaskPolicies.removeValue(forKey: modelID)
        // llama.cpp loads aren't cancellable mid-read; dropping the task entry
        // plus the discard flag/generation check keeps the result from landing.
        ggufLoadTasks.removeValue(forKey: modelID)
        loadingModels.removeValue(forKey: modelID)
        pendingLoadModels.removeValue(forKey: modelID)
    }

    /// Purging the MLX buffer cache while a generation is mid-stream frees
    /// buffers a live Metal command buffer may still reference — the classic
    /// eviction-during-flight GPU fault. State above is dropped immediately
    /// (ARC keeps the container alive for any draining stream); the purge
    /// itself waits its turn until the GPU is quiet.
    private func scheduleCachePurge() {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await gate.withTurn {
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
        var localThinkingMaxTokens: Int
    }

    private var sessions: [UUID: SessionBox] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    private var generationModelIDs: [UUID: String] = [:]

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
        if let tid = targetModelID {
            guard let t = loadedModels.first(where: { $0.id == tid }) else {
                // A dispatched/fan-out target that was unloaded must fail loudly,
                // not silently answer from whatever model is active.
                onComplete(nil, "Model is no longer loaded.")
                return
            }
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
            guard images.isEmpty else {
                onComplete(
                    nil,
                    "GGUF models in Forge are text-only. Load an MLX vision model to send images.")
                return
            }
            generateGGUF(
                gguf, modelID: entry.id, conversation: conversation,
                prompt: prompt, settings: settings,
                systemInstructions: resolvedSystem,
                onChunk: onChunk, onComplete: onComplete)
            return
        }

        // A thinking cap or a prefill-closed think block requires the token-level
        // decode — ChatSession cannot express a mid-turn continuation or a prompt
        // suffix. No session/KV reuse on these runs; the next plain turn re-hydrates
        // from stored history.
        let budgetTarget =
            Self.thinkingBudgetApplies(to: entry, settings: settings)
            ? settings.localThinkingTokenLimit : nil
        let noThinkPrefill = Self.noThinkPrefillApplies(to: entry, settings: settings)
        if budgetTarget != nil || noThinkPrefill, entry.container != nil {
            sessions.removeValue(forKey: conversation.id)
            let userPrompt = Self.userPrompt(
                prompt: prompt,
                thinkingDirective: Self.thinkingBudgetFrontDirective(
                    for: entry, settings: settings))
            let generationID = beginGeneration(modelID: entry.id)
            if entry.weightLoadPolicy == .deferred {
                materializingModelID = entry.id
                loadAdvisory = nil
            }
            generationTasks[generationID] = Task { [generationID] in
                _ = try? await self.gate.withTurn {
                    defer {
                        self.generationTasks.removeValue(forKey: generationID)
                        self.generationModelIDs.removeValue(forKey: generationID)
                        if self.materializingModelID == entry.id {
                            self.materializingModelID = nil
                        }
                    }
                    let start = Date()
                    do {
                        let completionInfo = try await self.streamBudgetedMLXResponse(
                            entry: entry,
                            conversation: conversation,
                            userPrompt: userPrompt,
                            systemInstructions: resolvedSystem,
                            images: images,
                            settings: settings,
                            budgetTarget: budgetTarget,
                            noThinkPrefill: noThinkPrefill,
                            start: start,
                            onChunk: onChunk)
                        self.finishGeneration(generationID)
                        onComplete(completionInfo, nil)
                    } catch {
                        self.finishGeneration(generationID)
                        onComplete(nil, error.localizedDescription)
                    }
                }
            }
            return
        }

        let session: ChatSession
        let userPrompt: String
        do {
            (session, userPrompt) = try preparedSession(
                for: conversation, entry: entry, settings: settings,
                prompt: prompt,
                systemInstructions: resolvedSystem)
        } catch {
            onComplete(nil, error.localizedDescription)
            return
        }
        session.generateParameters = Self.parameters(from: settings)

        let generationID = beginGeneration(modelID: entry.id)
        let deferredMaterialize = entry.weightLoadPolicy == .deferred
        if deferredMaterialize {
            materializingModelID = entry.id
            loadAdvisory = nil
        }

        generationTasks[generationID] = Task { [generationID] in
            // One gate turn for the whole stream: no API-server request can
            // overlap this generation, and a stop-then-resend queues here
            // until the cancelled stream has fully drained.
            _ = try? await self.gate.withTurn {
                defer {
                    self.generationTasks.removeValue(forKey: generationID)
                    self.generationModelIDs.removeValue(forKey: generationID)
                    if self.materializingModelID == entry.id {
                        self.materializingModelID = nil
                    }
                }
                let start = Date()
                do {
                    let completionInfo = try await self.streamMLXResponse(
                        session: session,
                        userPrompt: userPrompt,
                        entry: entry,
                        images: images,
                        start: start,
                        onChunk: onChunk)
                    self.sessions[conversation.id]?.messageCount += 2
                    self.finishGeneration(generationID)
                    onComplete(completionInfo, nil)
                } catch {
                    // KV cache may be mid-turn; drop the session so the next
                    // generation re-hydrates cleanly from stored history.
                    self.sessions.removeValue(forKey: conversation.id)
                    // Chat-template failures (Jinja.TemplateException) come from
                    // ChatSession's templating; retry once through the token-level
                    // path, which falls back to a hand-built ChatML prompt.
                    if "\(error)".localizedCaseInsensitiveContains("template")
                        || "\(error)".contains("Jinja"), entry.container != nil
                    {
                        do {
                            let completionInfo = try await self.streamBudgetedMLXResponse(
                                entry: entry,
                                conversation: conversation,
                                userPrompt: userPrompt,
                                systemInstructions: resolvedSystem,
                                images: images,
                                settings: settings,
                                budgetTarget: nil,
                                noThinkPrefill: false,
                                start: start,
                                onChunk: onChunk)
                            self.finishGeneration(generationID)
                            onComplete(completionInfo, nil)
                            return
                        } catch {
                            self.finishGeneration(generationID)
                            onComplete(nil, error.localizedDescription)
                            return
                        }
                    }
                    self.finishGeneration(generationID)
                    onComplete(nil, error.localizedDescription)
                }
            }
        }
    }

    /// Streams a reply from a llama.cpp (GGUF) model. Same gate discipline as
    /// the MLX path — llama.cpp competes for the same GPU.
    private func generateGGUF(
        _ gguf: GGUFRuntime,
        modelID: String,
        conversation: Conversation,
        prompt: String,
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

        let generationID = beginGeneration(modelID: modelID)

        generationTasks[generationID] = Task { [generationID] in
            _ = try? await self.gate.withTurn {
                defer {
                    self.generationTasks.removeValue(forKey: generationID)
                    self.generationModelIDs.removeValue(forKey: generationID)
                }
                gguf.configure(
                    temperature: settings.temperature, topP: settings.topP,
                    topK: settings.topK, system: systemPrompt, history: history)
                let start = Date()
                // llama.cpp's wrapper has no mid-stream injection hook, so the thinking
                // budget is prompt-told only on GGUF models.
                let effectivePrompt: String
                if let limit = settings.localThinkingTokenLimit {
                    effectivePrompt =
                        Self.thinkingBudgetDirectiveText(limit: limit) + "\n\n" + prompt
                } else {
                    effectivePrompt = prompt
                }
                let fullText = await gguf.respond(
                    to: effectivePrompt, thinkingEnabled: settings.localThinkingEnabled
                ) { delta in
                    await MainActor.run {
                        self.liveTokenCount += 1
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 0.2 {
                            self.liveTokensPerSecond = Double(self.liveTokenCount) / elapsed
                        }
                        onChunk(delta)
                    }
                }
                self.finishGeneration(generationID)
                // llama.cpp's wrapper fails a turn SILENTLY (empty streams) when the
                // prompt doesn't fit the context — never leave the user a blank bubble.
                let producedNothing =
                    fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && self.liveTokenCount == 0
                if producedNothing, !Task.isCancelled {
                    onComplete(
                        nil,
                        "The model produced no output. The prompt (system prompt + history + message) "
                            + "most likely exceeds the llama.cpp context window "
                            + "(\(gguf.contextTokens) tokens). Raise Max KV cache in Tuning, "
                            + "shorten the system prompt, or start a new chat — then reload the model."
                    )
                } else {
                    onComplete(nil, nil)
                }
            }
        }
    }

    func stop() {
        loadedModels.compactMap(\.gguf).forEach { $0.stop() }
        generationTasks.values.forEach { $0.cancel() }
        generationTasks.removeAll()
        generationModelIDs.removeAll()
        materializingModelID = nil
        if isGenerating {
            // Cancelled mid-turn: KV caches of in-flight sessions no longer
            // match stored history; drop them all (cheap, they re-prefill).
            sessions.removeAll()
        }
        activeGenerationIDs.removeAll()
        isGenerating = false
        refreshMemory()
    }

    private func cancelGenerations(for modelID: String) {
        let matching = generationModelIDs.compactMap { generationID, candidate in
            candidate == modelID ? generationID : nil
        }
        guard !matching.isEmpty else { return }
        loadedModels.first(where: { $0.id == modelID })?.gguf?.stop()
        for generationID in matching {
            generationTasks[generationID]?.cancel()
            activeGenerationIDs.remove(generationID)
            generationModelIDs.removeValue(forKey: generationID)
        }
        isGenerating = !activeGenerationIDs.isEmpty
    }

    @discardableResult
    private func beginGeneration(modelID: String) -> UUID {
        let generationID = UUID()
        if activeGenerationIDs.isEmpty {
            liveTokenCount = 0
            liveTokensPerSecond = 0
        }
        activeGenerationIDs.insert(generationID)
        generationModelIDs[generationID] = modelID
        isGenerating = true
        return generationID
    }

    private func finishGeneration(_ generationID: UUID) {
        // Already cleared by stop() (or double-finished): don't decrement state
        // that now belongs to a newer generation.
        guard activeGenerationIDs.remove(generationID) != nil else { return }
        generationModelIDs.removeValue(forKey: generationID)
        isGenerating = !activeGenerationIDs.isEmpty
        refreshMemory()
    }

    func invalidateChatSessions() {
        sessions.removeAll()
    }

    private func preparedSession(
        for conversation: Conversation, entry: Loaded, settings: GenerationSettings,
        prompt: String,
        systemInstructions: String
    ) throws -> (ChatSession, String) {
        let systemPrompt = systemInstructions
        let thinkingDirective = Self.thinkingBudgetFrontDirective(
            for: entry, settings: settings)
        if let box = sessions[conversation.id],
            box.modelID == entry.id,
            box.systemPrompt == systemPrompt,
            box.messageCount == conversation.messages.count,
            box.localThinkingEnabled == settings.localThinkingEnabled,
            box.localThinkingMaxTokens == settings.localThinkingMaxTokens
        {
            box.session.additionalContext = Self.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled)
            sessions[conversation.id] = box
            let userPrompt = Self.userPrompt(
                prompt: prompt,
                thinkingDirective: thinkingDirective)
            return (box.session, userPrompt)
        }

        var history: [Chat.Message] = []
        for message in conversation.messages {
            switch message.role {
            case .user:
                history.append(
                    .user(
                        message.content,
                        images: try Self.mlxImages(from: message.attachedImageData)))
            // Don't feed our own "⚠️ …" notices back to the model as prior turns.
            case .assistant:
                if !message.isErrorMessage, !message.content.isEmpty {
                    history.append(.assistant(message.content))
                }
            case .system:
                history.append(.system(message.content))
            }
        }

        // GGUF entries never reach here — generate() branches to generateGGUF
        // first, so every entry in this path has an MLX container.
        let session = ChatSession(
            entry.container!,
            instructions: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : systemPrompt,
            history: history,
            generateParameters: Self.parameters(from: settings),
            additionalContext: Self.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled))
        sessions[conversation.id] = SessionBox(
            session: session, modelID: entry.id,
            messageCount: conversation.messages.count, systemPrompt: systemPrompt,
            localThinkingEnabled: settings.localThinkingEnabled,
            localThinkingMaxTokens: settings.localThinkingMaxTokens)
        let userPrompt = Self.userPrompt(
            prompt: prompt,
            thinkingDirective: thinkingDirective)
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
        prompt: String,
        thinkingDirective: String? = nil
    ) -> String {
        thinkingDirective.map { $0 + "\n\n" + prompt } ?? prompt
    }

    private nonisolated static func mlxImages(from data: [Data]) throws -> [UserInput.Image] {
        try data.enumerated().map { index, bytes in
            guard let image = CIImage(data: bytes) else {
                throw ForgeError.invalidImage(index + 1)
            }
            return .ciImage(image)
        }
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
            [directory, loadPolicy, useFactoryLoader, reportProgress] in
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
            weightLoadPolicy: loadedModels[index].weightLoadPolicy,
            gguf: loadedModels[index].gguf,
            templateCaps: caps)
    }

    /// Grace above the target thinking cap before Forge force-closes an open `</think>` block.
    static let thinkingBudgetGraceFraction = 0.10

    /// The canonical Qwen thinking-budget early-stop string (Qwen3 technical report /
    /// qwen.readthedocs.io "thinking budget" recipe). Appended to the truncated reasoning
    /// token-level, after which decoding CONTINUES into the final answer.
    nonisolated static let thinkingBudgetForceCloseSuffix =
        "\n\nConsidering the limited time by the user, I have to give the solution based on the thinking directly now.\n</think>\n\n"

    static func thinkingBudgetGraceTokens(for target: Int) -> Int {
        max(1, Int((Double(target) * thinkingBudgetGraceFraction).rounded()))
    }

    static func thinkingBudgetHardLimit(for target: Int) -> Int {
        target + thinkingBudgetGraceTokens(for: target)
    }

    /// First line of the active user turn when a thinking cap is set — models see this before the task.
    static func thinkingBudgetFrontDirective(
        for entry: Loaded, settings: GenerationSettings
    ) -> String? {
        guard thinkingBudgetApplies(to: entry, settings: settings),
              let limit = settings.localThinkingTokenLimit
        else { return nil }
        return thinkingBudgetDirectiveText(limit: limit)
    }

    static func thinkingBudgetDirectiveText(limit: Int) -> String {
        let hardStop = thinkingBudgetHardLimit(for: limit)
        return """
        [Thinking budget] You have \(limit) thinking tokens — do not exceed \(hardStop). Open <think>, finish all reasoning inside it, close </think>, then answer. Wrap up before you hit the limit.
        """
    }

    private func streamMLXResponse(
        session: ChatSession,
        userPrompt: String,
        entry: Loaded,
        images: [Data],
        start: Date,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> GenerateCompletionInfo? {
        var completionInfo: GenerateCompletionInfo?
        // Templates that pre-open <think> inside the generation prompt stream reasoning
        // with no opening tag — surface one so the UI can render a live reasoning block.
        var emittedSyntheticThinkOpen = false

        let mlxImages = try Self.mlxImages(from: images)
        for try await item in session.streamDetails(
            to: userPrompt, role: .user, images: mlxImages, videos: [])
        {
            if Task.isCancelled { break }
            switch item {
            case .chunk(let text):
                if materializingModelID == entry.id {
                    materializingModelID = nil
                }
                if !emittedSyntheticThinkOpen {
                    emittedSyntheticThinkOpen = true
                    if entry.chatTemplateThinkingBuiltIn, !text.hasPrefix("<think>") {
                        onChunk("<think>")
                    }
                }
                liveTokenCount += 1
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > 0.2 {
                    liveTokensPerSecond = Double(liveTokenCount) / elapsed
                }
                onChunk(text)
            case .info(let info):
                completionInfo = info
            case .toolCall:
                break
            }
        }
        return completionInfo
    }

    /// Thinking-budget generation: the official Qwen early-stop, done at the token level.
    ///
    /// Phase 1 decodes normally (the front directive already told the model its budget, so a
    /// compliant model closes `</think>` on its own). If reasoning is still open past the
    /// target + 10% grace, phase 2 appends the canonical wrap-up + `</think>` to the tokens
    /// generated so far and CONTINUES decoding the final answer — the run never dies at the cap.
    ///
    /// This bypasses `ChatSession` deliberately: re-templating the partial reasoning as a
    /// completed assistant turn (the old approach) let Qwen-family templates strip the think
    /// block from history, so the model saw a finished turn and emitted EOS immediately.
    private func streamBudgetedMLXResponse(
        entry: Loaded,
        conversation: Conversation,
        userPrompt: String,
        systemInstructions: String,
        images: [Data],
        settings: GenerationSettings,
        budgetTarget: Int?,
        noThinkPrefill: Bool,
        start: Date,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> GenerateCompletionInfo? {
        var turns: [BudgetTurn] = []
        let trimmedSystem = systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            turns.append(BudgetTurn(role: "system", content: systemInstructions))
        }
        turns.append(contentsOf: conversation.messages.compactMap { message in
            switch message.role {
            case .user:
                return BudgetTurn(
                    role: "user", content: message.content,
                    images: message.attachedImageData)
            case .assistant:
                return message.isErrorMessage || message.content.isEmpty
                    ? nil : BudgetTurn(role: "assistant", content: message.content)
            case .system:
                return BudgetTurn(role: "system", content: message.content)
            }
        })
        turns.append(BudgetTurn(role: "user", content: userPrompt, images: images))

        let thinkingFromStart =
            !noThinkPrefill
            && (entry.chatTemplateThinkingOnly || entry.chatTemplateThinkingBuiltIn)
        var completionInfo: GenerateCompletionInfo?
        var emittedSyntheticThinkOpen = false

        let stream = Self.budgetedGenerationStream(
            container: entry.container!,
            turns: turns,
            additionalContext: Self.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled),
            parameters: Self.parameters(from: settings),
            hardLimit: budgetTarget.map { Self.thinkingBudgetHardLimit(for: $0) },
            thinkingFromStart: thinkingFromStart,
            prefillText: noThinkPrefill ? Self.noThinkPrefillText : nil)

        for try await item in stream {
            if Task.isCancelled { break }
            switch item {
            case .chunk(let text):
                if materializingModelID == entry.id {
                    materializingModelID = nil
                }
                if !emittedSyntheticThinkOpen {
                    emittedSyntheticThinkOpen = true
                    // thinkingFromStart = the template pre-opened <think>, so the
                    // raw stream begins mid-reasoning with no opening tag — surface
                    // one so ThinkTagParser routes the tokens into the reasoning channel.
                    if thinkingFromStart, !text.hasPrefix("<think>") {
                        onChunk("<think>")
                    }
                }
                liveTokenCount += 1
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > 0.2 {
                    liveTokensPerSecond = Double(liveTokenCount) / elapsed
                }
                onChunk(text)
            case .info(let info):
                completionInfo = info
            case .toolCall:
                break
            }
        }
        return completionInfo
    }

    /// Off-main two-phase decode. Runs entirely inside the model container's isolation;
    /// chunks stream back in order through the returned stream.
    ///
    /// `prefillText` is appended to the prompt tokens before decoding (used to close a
    /// template's pre-opened `<think>` for thinking-off). `hardLimit` nil = no budget.
    nonisolated private static func budgetedGenerationStream(
        container: ModelContainer,
        turns: [BudgetTurn],
        additionalContext: [String: any Sendable]?,
        parameters: GenerateParameters,
        hardLimit: Int?,
        thinkingFromStart: Bool,
        prefillText: String? = nil
    ) -> AsyncThrowingStream<Generation, Error> {
        let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        let task = Task {
            [container, turns, additionalContext, parameters, hardLimit,
                thinkingFromStart, prefillText, continuation] in
            do {
                try await container.perform { context in
                    let messages: [Chat.Message] = try turns.map { turn in
                        switch turn.role {
                        case "system": return .system(turn.content)
                        case "assistant": return .assistant(turn.content)
                        default:
                            return .user(
                                turn.content,
                                images: try Self.mlxImages(from: turn.images))
                        }
                    }
                    let userInput = UserInput(
                        chat: messages, additionalContext: additionalContext)
                    let lmInput: LMInput
                    do {
                        lmInput = try await context.processor.prepare(input: userInput)
                    } catch {
                        // A text-only fallback would silently discard VLM media.
                        // Preserve the processor's image error instead so the
                        // caller gets an honest failure rather than an answer
                        // produced without seeing the attachment.
                        guard turns.allSatisfy({ $0.images.isEmpty }) else {
                            throw error
                        }
                        // Chat-template failure (e.g. Jinja.TemplateException on an
                        // exotic community template): fall back to a hand-built
                        // ChatML prompt so the turn still generates.
                        let fallback =
                            turns.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>" }
                            .joined(separator: "\n") + "\n<|im_start|>assistant\n"
                        let ids = context.tokenizer.encode(
                            text: fallback, addSpecialTokens: false)
                        lmInput = LMInput(
                            text: .init(tokens: MLXArray(ids.map { Int32($0) })))
                    }

                    var promptTokens = lmInput.text.tokens
                    if let prefillText {
                        let prefillIDs = context.tokenizer.encode(
                            text: prefillText, addSpecialTokens: false)
                        promptTokens = concatenated([
                            promptTokens, MLXArray(prefillIDs.map { Int32($0) }),
                        ])
                    }

                    // Phase 1 — decode until </think> closes naturally or the cap hits.
                    let iterator = try TokenIterator(
                        input: LMInput(text: .init(tokens: promptTokens)),
                        model: context.model, parameters: parameters)
                    let (phase1, phase1Task) = MLXLMCommon.generateTask(
                        promptTokenCount: promptTokens.size,
                        modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer,
                        iterator: iterator)

                    var generated = ""
                    var thinkingClosed = false
                    var thinkingTokens = 0
                    var hitBudget = false

                    for await item in phase1 {
                        if Task.isCancelled { break }
                        switch item {
                        case .chunk(let text):
                            generated += text
                            if !thinkingClosed, generated.contains("</think>") {
                                thinkingClosed = true
                            }
                            if let hardLimit, !thinkingClosed,
                                thinkingFromStart || generated.contains("<think>")
                            {
                                // Chunks from the naive detokenizer are one token each.
                                thinkingTokens += 1
                                if thinkingTokens >= hardLimit { hitBudget = true }
                            }
                            continuation.yield(item)
                        case .info(let info):
                            if !hitBudget { continuation.yield(.info(info)) }
                        case .toolCall:
                            continuation.yield(item)
                        }
                        if hitBudget { break }
                    }
                    // Stop the iterator before touching the GPU again — an abandoned
                    // stream would otherwise keep decoding into a buffered stream.
                    phase1Task.cancel()
                    await phase1Task.value

                    guard hitBudget, !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    // Phase 2 — canonical early-stop injection, then continue the answer.
                    let injection = thinkingBudgetForceCloseSuffix
                    continuation.yield(.chunk(injection))
                    let continuationIDs = context.tokenizer.encode(
                        text: generated + injection, addSpecialTokens: false)
                    var phase2Parameters = parameters
                    if let maxTokens = parameters.maxTokens {
                        phase2Parameters.maxTokens = max(64, maxTokens - continuationIDs.count)
                    }
                    let phase2Tokens = concatenated([
                        promptTokens,
                        MLXArray(continuationIDs.map { Int32($0) }),
                    ])
                    let iterator2 = try TokenIterator(
                        input: LMInput(text: .init(tokens: phase2Tokens)),
                        model: context.model,
                        parameters: phase2Parameters)
                    let (phase2, phase2Task) = MLXLMCommon.generateTask(
                        promptTokenCount: phase2Tokens.size,
                        modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer,
                        iterator: iterator2)
                    for await item in phase2 {
                        if Task.isCancelled { break }
                        continuation.yield(item)
                    }
                    phase2Task.cancel()
                    await phase2Task.value
                    continuation.finish()
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func thinkingBudgetApplies(to entry: Loaded, settings: GenerationSettings) -> Bool {
        guard settings.localThinkingTokenLimit != nil else { return false }
        // Thinking switched off on a pre-opened template → Forge prefills </think>,
        // so there is no reasoning left to cap.
        if noThinkPrefillApplies(to: entry, settings: settings) { return false }
        if entry.chatTemplateThinkingOnly || entry.chatTemplateThinkingBuiltIn { return true }
        return entry.chatTemplateSupportsThinkingToggle && settings.localThinkingEnabled
    }

    /// Templates that unconditionally open `<think>` in the generation prompt (stock
    /// Qwen3/3.6-Thinking and GLM conversions, which usually ship WITHOUT the
    /// `enable_thinking` variable) can still have thinking turned off: the tag is in
    /// the prompt, so prefilling `</think>` closes the block before the model reasons.
    /// Same trick as Qwen's own empty-think prefill, done at the token level.
    static func noThinkPrefillApplies(to entry: Loaded, settings: GenerationSettings) -> Bool {
        entry.chatTemplateThinkingBuiltIn
            && !entry.chatTemplateSupportsThinkingToggle
            && !settings.localThinkingEnabled
    }

    /// Closes the template's pre-opened think block before decoding starts.
    nonisolated static let noThinkPrefillText = "</think>\n\n"

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

/// Rate-limits llama.cpp's per-tensor load-progress callback to whole-percent
/// steps. Called from a single loader thread; the lock guards the cross-thread
/// read from the main actor's perspective.
final class GGUFLoadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    /// Returns true when `fraction` crosses into a new whole percent.
    func advance(to fraction: Double) -> Bool {
        let percent = Int((fraction * 100).rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard percent > lastPercent else { return false }
        lastPercent = percent
        return true
    }
}

enum ForgeError: LocalizedError {
    case loadFailed(String)
    case modelNotFound(String)
    case invalidImage(Int)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message): return message
        case .modelNotFound(let name):
            return "Model '\(name)' is not loaded and not found in the local library."
        case .invalidImage(let position):
            return "Attached image \(position) is not a readable JPEG, PNG, HEIC, or other Core Image format."
        }
    }
}
