// Forge — top-level observable app state: conversations, selection, settings,
// the multi-model engine, the local API server, and the send/stream loop.

import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    /// SwiftUI may construct the `App` struct (and its `@State` initial values)
    /// more than once; everything observable hangs off this single instance so
    /// servers, engines, and restore tasks exist exactly once per process.
    static let shared = AppState()

    let engine = InferenceEngine()
    let store = ModelStore()
    let server = ForgeServer()
    let launcher = HeadlessLauncher()
    let runtimeUpdates = RuntimeUpdateChecker()

    var conversations: [Conversation] = []
    var selectedConversationID: UUID? {
        didSet { autoActivateModel() }
    }
    var settings = GenerationSettings() {
        didSet {
            if oldValue.systemPrompt != settings.systemPrompt {
                reconcileActivePromptLabel()
            }
            if oldValue.systemPrompt != settings.systemPrompt
                || oldValue.localThinkingEnabled != settings.localThinkingEnabled
                || oldValue.localThinkingMaxTokens != settings.localThinkingMaxTokens
            {
                engine.invalidateChatSessions()
            }
            scheduleSave()
        }
    }

    /// Which saved preset (if any) is driving the inspector system prompt.
    var activePromptPresetID: UUID? {
        didSet { scheduleSave() }
    }
    /// Human label when the prompt came from a file/library pick instead of a saved preset.
    var activePromptExternalLabel: String? {
        didSet { scheduleSave() }
    }

    /// Named system-prompt presets shown in the inspector's dropdown.
    var promptPresets: [PromptPreset] = [] {
        didSet { scheduleSave() }
    }

    /// User-managed prompt directories (e.g. awesome-prompts style collections).
    /// Allows browsing and selecting prompts directly in the chat UI.
    /// Stored with security-scoped bookmarks for sandbox persistence (like extra models).
    var promptDirectories: [URL] = []
    private var promptDirectoryBookmarks: [URL: Data] = [:]
    /// Cached prompt index — refreshed off the hot path so SwiftUI body eval doesn't walk disks.
    private var cachedPrompts: [(category: String, items: [(name: String, url: URL)])] = []

    /// User-granted folders exposed to the built-in Forge commander tools.
    var commanderDirectories: [URL] = [] {
        didSet { mcp.commanderRoots = commanderDirectories }
    }
    private var commanderDirectoryBookmarks: [URL: Data] = [:]

    /// Last selected prompt content from library – auto-applied as systemPrompt for new conversations.
    var lastPromptContent: String = "" {
        didSet { scheduleSave() }
    }

    /// MCP servers declared in the local mcp.json (see MCP.swift).
    let mcp = MCPManager()

    // MARK: - Claude API provider (additive — parallel to the local engine)

    /// When non-nil, chat is routed to the Anthropic API instead of a local model.
    /// nil = use the local MLX engine. Persisted so the choice survives relaunch.
    var claudeModelID: String? = UserDefaults.standard.string(forKey: "claude.model") {
        didSet {
            if let claudeModelID {
                UserDefaults.standard.set(claudeModelID, forKey: "claude.model")
            } else {
                UserDefaults.standard.removeObject(forKey: "claude.model")
            }
        }
    }
    private(set) var isClaudeGenerating = false
    private var claudeTask: Task<Void, Never>?

    /// When non-empty, chat fans out to the selected OpenRouter models.
    var openRouterModelIDs: [String] = {
        let selected = UserDefaults.standard.stringArray(forKey: "openrouter.models") ?? []
        if !selected.isEmpty { return selected }
        if let legacy = UserDefaults.standard.string(forKey: "openrouter.model"), !legacy.isEmpty {
            return [legacy]
        }
        return []
    }() {
        didSet { persistOpenRouterModelSelection() }
    }
    var openRouterModelID: String? {
        get { openRouterModelIDs.first }
        set {
            if let newValue, !newValue.isEmpty {
                assignOpenRouterModelIDs([newValue])
            } else {
                assignOpenRouterModelIDs([])
            }
        }
    }
    /// User-added OpenRouter model slugs. Kept separate from the live selection so
    /// picking a primary model, clearing the selection, or saving the API key never
    /// deletes a model the user added — this list only changes on explicit add/remove.
    var openRouterCustomModels: [String] =
        UserDefaults.standard.stringArray(forKey: "openrouter.customModels") ?? []
    {
        didSet {
            guard oldValue != openRouterCustomModels else { return }
            UserDefaults.standard.set(openRouterCustomModels, forKey: "openrouter.customModels")
        }
    }

    private(set) var isOpenRouterGenerating = false
    private var openRouterTasks: [UUID: Task<Void, Never>] = [:]

    /// When non-nil, chat is routed to the OpenAI Responses API.
    var openAIModelID: String? = UserDefaults.standard.string(forKey: "openai.model") {
        didSet {
            if let openAIModelID {
                UserDefaults.standard.set(openAIModelID, forKey: "openai.model")
            } else {
                UserDefaults.standard.removeObject(forKey: "openai.model")
            }
        }
    }
    private(set) var isOpenAIGenerating = false
    private var openAITask: Task<Void, Never>?

    /// Z.AI Coding Plan lane backed by the account already signed into ZCode.
    /// Forge persists only the on/off model selection — never the account credential.
    var zaiModelID: String? = UserDefaults.standard.string(forKey: "zai.model") {
        didSet {
            if let zaiModelID {
                UserDefaults.standard.set(zaiModelID, forKey: "zai.model")
            } else {
                UserDefaults.standard.removeObject(forKey: "zai.model")
            }
        }
    }
    private(set) var zaiConfiguration = ZAICodingPlanClient.configurationStatus()
    private(set) var isZAIGenerating = false
    private var zaiTask: Task<Void, Never>?
    private var zaiRunControl: ZAIRunControl?

    var hasAnthropicKey: Bool { SecretsStore.hasAnthropicKey }
    func setAnthropicKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretsStore.anthropicAPIKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var hasOpenRouterKey: Bool { SecretsStore.hasOpenRouterKey }
    func setOpenRouterKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretsStore.openRouterAPIKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var hasOpenAIKey: Bool { SecretsStore.hasOpenAIKey }
    func setOpenAIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretsStore.openAIAPIKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var isZAISelected: Bool { zaiModelID?.isEmpty == false }

    func refreshZAIConfiguration() {
        zaiConfiguration = ZAICodingPlanClient.configurationStatus()
    }

    func setZAISelected(_ selected: Bool) {
        if selected {
            refreshZAIConfiguration()
            guard zaiConfiguration.isConfigured else { return }
            zaiModelID = ZAICodingPlanClient.modelID
        } else {
            zaiModelID = nil
        }
    }

    private var claudeSelected: Bool { (claudeModelID?.isEmpty == false) }
    private var openRouterSelected: Bool { !openRouterModelIDs.isEmpty }
    private var openAISelected: Bool { (openAIModelID?.isEmpty == false) }
    private var zaiSelected: Bool { isZAISelected }
    private var braveSearchSelected: Bool { braveSearchEnabled }
    /// Anything currently producing tokens (local OR Claude).
    var isBusy: Bool {
        engine.isGenerating || engine.isLoadingAnything || engine.materializingModelID != nil
            || isClaudeGenerating || isOpenRouterGenerating || isOpenAIGenerating
            || isZAIGenerating || isMCPRunning || isBraveSearchGenerating
    }
    /// Whether a chat target is selected.
    var canChat: Bool {
        engine.activeModel != nil || claudeSelected || openRouterSelected || openAISelected
            || zaiSelected || braveSearchSelected
    }

    var openRouterSelectionSummary: String {
        switch openRouterModelIDs.count {
        case 0:
            return "No models"
        case 1:
            return OpenRouterClient.label(for: openRouterModelIDs[0])
        default:
            return "\(openRouterModelIDs.count) models"
        }
    }

    func isOpenRouterModelSelected(_ id: String) -> Bool {
        openRouterModelIDs.contains(id)
    }

    func setOpenRouterModel(_ id: String, selected: Bool) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if selected {
            assignOpenRouterModelIDs(openRouterModelIDs + [trimmed])
        } else {
            assignOpenRouterModelIDs(openRouterModelIDs.filter { $0 != trimmed })
        }
    }

    /// Adds a model slug to the custom list and selects it. Idempotent.
    func addOpenRouterCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !openRouterCustomModels.contains(trimmed),
            !OpenRouterClient.models.contains(where: { $0.id == trimmed })
        {
            openRouterCustomModels.append(trimmed)
        }
        setOpenRouterModel(trimmed, selected: true)
    }

    /// Removes a model from the custom list and deselects it.
    func removeOpenRouterCustomModel(_ id: String) {
        openRouterCustomModels.removeAll { $0 == id }
        setOpenRouterModel(id, selected: false)
    }

    private func assignOpenRouterModelIDs(_ ids: [String]) {
        let normalized = Self.uniqueModelIDs(ids)
        // Any selected model that isn't a preset joins the custom list, so a
        // selection made anywhere (catalog menu, custom slug, older builds)
        // survives restarts and primary-model switches as a removable entry.
        let newCustom = normalized.filter { id in
            !OpenRouterClient.models.contains(where: { $0.id == id })
                && !openRouterCustomModels.contains(id)
        }
        if !newCustom.isEmpty { openRouterCustomModels.append(contentsOf: newCustom) }
        guard normalized != openRouterModelIDs else { return }
        openRouterModelIDs = normalized
    }

    private func persistOpenRouterModelSelection() {
        if let first = openRouterModelIDs.first {
            UserDefaults.standard.set(openRouterModelIDs, forKey: "openrouter.models")
            UserDefaults.standard.set(first, forKey: "openrouter.model")
        } else {
            UserDefaults.standard.removeObject(forKey: "openrouter.models")
            UserDefaults.standard.removeObject(forKey: "openrouter.model")
        }
    }

    func selectAllOpenRouterModels() {
        assignOpenRouterModelIDs(OpenRouterClient.models.map(\.id))
    }

    func clearOpenRouterModels() {
        assignOpenRouterModelIDs([])
    }

    /// When 2+ loaded local models are selected here, a normal send fans out to
    /// all of them — each answers in its own labeled bubble, and the MLX gate
    /// queues the actual GPU runs back-to-back. Mirrors the OpenRouter multi-select.
    var localFanoutModelIDs: [String] =
        UserDefaults.standard.stringArray(forKey: "chat.localFanout") ?? []
    {
        didSet {
            UserDefaults.standard.set(localFanoutModelIDs, forKey: "chat.localFanout")
        }
    }

    func isLocalFanoutSelected(_ id: String) -> Bool {
        localFanoutModelIDs.contains(id)
    }

    func toggleLocalFanout(_ id: String) {
        if localFanoutModelIDs.contains(id) {
            localFanoutModelIDs.removeAll { $0 == id }
        } else {
            localFanoutModelIDs.append(id)
        }
    }

    func selectAllLocalFanout() {
        localFanoutModelIDs = engine.loadedModels.map(\.id)
    }

    func clearLocalFanout() {
        localFanoutModelIDs = []
    }

    // MARK: - Model Room (split-view multi-model chat)

    /// Nine independent agent slots. Multiple slots may intentionally point at
    /// the same resident model: weights are shared, while each slot keeps its
    /// own identity and receives its own reconstructed conversation context.
    var modelSlotAssignments: [String] = {
        let saved = UserDefaults.standard.stringArray(forKey: "room.modelSlots") ?? []
        return Array((saved + Array(repeating: "", count: ModelMemoryBudget.slotCount))
            .prefix(ModelMemoryBudget.slotCount))
    }() {
        didSet {
            UserDefaults.standard.set(modelSlotAssignments, forKey: "room.modelSlots")
        }
    }

    /// Saved assignments that still exist in memory, followed by any newly
    /// loaded models in the first free slots. This keeps legacy loading paths
    /// useful without collapsing deliberate duplicate slot assignments.
    var effectiveModelSlotAssignments: [String?] {
        let loadedIDs = Set(engine.loadedModels.map(\.id))
        var result = modelSlotAssignments.map { id in
            id.isEmpty || !loadedIDs.contains(id) ? nil : id
        }
        var represented = Set(result.compactMap { $0 })
        for entry in engine.loadedModels where !represented.contains(entry.id) {
            guard let empty = result.firstIndex(where: { $0 == nil }) else { break }
            result[empty] = entry.id
            represented.insert(entry.id)
        }
        return result
    }

    func assignModel(_ model: LocalModel, toSlot index: Int) {
        guard modelSlotAssignments.indices.contains(index) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.engine.load(model)
                self.modelSlotAssignments[index] = entry.id
                self.engine.activeModelID = entry.id
                self.scheduleSave()
            } catch is CancellationError {
                // User cancelled or unloaded while the model was loading.
            } catch {
                // InferenceEngine exposes the actionable load error.
            }
        }
    }

    func clearModelSlot(_ index: Int) {
        guard modelSlotAssignments.indices.contains(index) else { return }
        var current = effectiveModelSlotAssignments
        guard let modelID = current[index] else { return }
        modelSlotAssignments[index] = ""
        current[index] = nil
        if !current.contains(where: { $0 == modelID }) {
            engine.unload(modelID)
        }
        scheduleSave()
    }

    // MARK: - Rivet workbench

    /// True when the detail pane hosts the bundled Rivet graph IDE. The old
    /// graph visibility key is read once as a migration for existing installs.
    var showRivet: Bool = {
        if UserDefaults.standard.object(forKey: "rivet.visible") != nil {
            return UserDefaults.standard.bool(forKey: "rivet.visible")
        }
        return UserDefaults.standard.bool(forKey: "graph.visible")
    }() {
        didSet {
            UserDefaults.standard.set(showRivet, forKey: "rivet.visible")
            reconcileServerLifecycle()
        }
    }


    /// Use a single OpenRouter model for chat (clears multi-select).
    func setPrimaryOpenRouterModel(_ id: String) {
        claudeModelID = nil
        openAIModelID = nil
        engine.activeModelID = nil
        assignOpenRouterModelIDs([id])
    }

    /// Use a single OpenAI model for chat (clears other cloud/local selection).
    func setPrimaryOpenAIModel(_ id: String) {
        claudeModelID = nil
        openRouterModelIDs = []
        engine.activeModelID = nil
        openAIModelID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var openRouterCatalog: [OpenRouterClient.ModelInfo] = []
    private(set) var isOpenRouterCatalogLoading = false
    var openRouterCatalogError: String?

    func refreshOpenRouterCatalog() {
        guard hasOpenRouterKey, let key = SecretsStore.openRouterAPIKey else {
            openRouterCatalogError = "Add an OpenRouter API key in Settings first."
            return
        }
        isOpenRouterCatalogLoading = true
        openRouterCatalogError = nil
        Task { @MainActor in
            do {
                let models = try await OpenRouterClient(apiKey: key).fetchModels()
                openRouterCatalog = models
                isOpenRouterCatalogLoading = false
            } catch {
                openRouterCatalogError = error.localizedDescription
                isOpenRouterCatalogLoading = false
            }
        }
    }

    var hasBraveSearchKey: Bool { SecretsStore.hasBraveSearchKey }
    func setBraveSearchKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretsStore.braveSearchAPIKey = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// When true, the next send routes to Brave Search Answers (web-grounded research).
    var braveSearchEnabled: Bool = UserDefaults.standard.bool(forKey: "braveSearch.enabled") {
        didSet { UserDefaults.standard.set(braveSearchEnabled, forKey: "braveSearch.enabled") }
    }

    var braveSearchModeLabel: String {
        braveSearchConfig.enableResearch ? "Brave Search · Research" : "Brave Search · Answers"
    }

    var braveSearchConfig: BraveSearchConfig = {
        if let data = UserDefaults.standard.data(forKey: "braveSearch.config"),
            let decoded = try? JSONDecoder().decode(BraveSearchConfig.self, from: data)
        {
            return decoded
        }
        return BraveSearchConfig()
    }() {
        didSet {
            if braveSearchConfig.enableResearch && braveSearchConfig.enableCitations {
                var config = braveSearchConfig
                config.enableCitations = false
                braveSearchConfig = config
                return
            }
            if let data = try? JSONEncoder().encode(braveSearchConfig) {
                UserDefaults.standard.set(data, forKey: "braveSearch.config")
            }
        }
    }

    private(set) var isBraveSearchGenerating = false
    private var braveSearchTask: Task<Void, Never>?

    var memoryBudgetSnapshot: ModelMemoryBudget.Snapshot {
        ModelMemoryBudget.snapshot(
            loadedModelIDs: engine.loadedModels.map(\.id),
            models: store.localModels,
            mlxActiveBytes: engine.activeMemory,
            loadedSlotCount: engine.loadedModels.count)
    }

    func admissionDecision(for model: LocalModel) -> ModelMemoryBudget.LoadDecision {
        let slots = (0..<ModelMemoryBudget.slotCount).map { index -> String? in
            guard index < engine.loadedModels.count else { return nil }
            return engine.loadedModels[index].id
        }
        return ModelMemoryBudget.canLoad(
            model,
            slotAssignments: slots,
            allModels: store.localModels)
    }

    private static func uniqueModelIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    var serverEnabled = false {
        didSet {
            guard oldValue != serverEnabled else { return }
            reconcileServerLifecycle()
            scheduleSave()
        }
    }
    /// Stable bearer token used when the local API is exposed beyond loopback.
    var serverAPIKey: String { SecretsStore.localServerAPIKey ?? "" }
    var serverPort = 3737 {
        didSet {
            guard oldValue != serverPort else { return }
            reconcileServerLifecycle()
            scheduleSave()
        }
    }
    /// LM Studio-style "serve on local network": bind all interfaces instead of loopback.
    var serverExposeToNetwork = false {
        didSet {
            guard oldValue != serverExposeToNetwork else { return }
            reconcileServerLifecycle()
            scheduleSave()
        }
    }

    var showModelBrowser = false
    var showInspector = true
    var showHeadlessHelper = false
    var showDesignPrompt = false
    var showSystemPromptEditor = false

    /// Rivet uses Forge's existing OpenAI-compatible server as a normal client.
    /// Keep it alive while either the public API toggle or the Rivet workbench
    /// needs it; Forge remains the sole owner of model loading and inference.
    private func reconcileServerLifecycle() {
        if serverEnabled || showRivet {
            server.start(
                port: UInt16(clamping: serverPort),
                exposeToNetwork: serverExposeToNetwork)
        } else {
            server.stop()
        }
    }

    func ensureRivetServer() {
        guard showRivet else { return }
        if case .running = server.state { return }
        reconcileServerLifecycle()
    }

    var composerText = ""

    /// Last-started stream (live bar / legacy). Parallel dispatches may stream several at once.
    private(set) var streamingMessageID: UUID?
    private(set) var streamingMessageIDs: Set<UUID> = []
    /// Live token buffer shown in the transcript without rewriting `conversations` each flush.
    private(set) var streamingTextByMessageID: [UUID: String] = [:]
    /// Live reasoning delivered on the typed inference channel.
    private(set) var streamingReasoningByMessageID: [UUID: String] = [:]

    func isMessageStreaming(_ messageID: UUID) -> Bool {
        streamingMessageIDs.contains(messageID)
    }

    private var saveTask: Task<Void, Never>?
    private var streamBuffers: [UUID: String] = [:]
    private var streamReasoningBuffers: [UUID: String] = [:]
    private var invalidReasoningStreamMessageIDs: Set<UUID> = []
    private var streamBufferConversationIDs: [UUID: UUID] = [:]
    private var streamFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var activeMCPCallCount = 0
    /// Monotonic cancellation token shared by generation and MCP follow-up work.
    /// Stopping invalidates every callback/task that captured the previous value.
    private var cancellationGeneration: UInt64 = 0

    private var isMCPRunning: Bool { activeMCPCallCount > 0 }

    private enum ResponseBackend {
        case local(modelID: String, label: String)
        case claude(modelID: String)
        case openRouter(modelID: String)
        case openAI(modelID: String)
        case zai(modelID: String)

        var modelName: String {
            switch self {
            case .local(_, let label):
                return label
            case .claude(let modelID):
                return AnthropicClient.label(for: modelID)
            case .openRouter(let modelID):
                return OpenRouterClient.label(for: modelID)
            case .openAI(let modelID):
                return OpenAIClient.label(for: modelID)
            case .zai:
                return ZAICodingPlanClient.label
            }
        }
    }

    private struct MCPCallRequest {
        var serverID: String
        var toolName: String
        var arguments: [String: Any]
    }

    var selectedConversation: Conversation? {
        get {
            guard let selectedConversationID else { return nil }
            return conversations.first { $0.id == selectedConversationID }
        }
        set {
            guard let newValue,
                let index = conversations.firstIndex(where: { $0.id == newValue.id })
            else { return }
            conversations[index] = newValue
        }
    }

    private init() {
        SecretsStore.warmCache()

        let state = Persistence.loadState()
        let persistedSettings = Persistence.loadSettings()
        conversations = state.conversations
        settings = persistedSettings.generation
        promptPresets = persistedSettings.promptPresets
        promptDirectories = resolvePromptDirectories(from: persistedSettings)
        commanderDirectories = resolveCommanderDirectories(from: persistedSettings)
        mcp.commanderRoots = commanderDirectories
        lastPromptContent = persistedSettings.lastPromptContent
        activePromptPresetID = persistedSettings.activePromptPresetID
        activePromptExternalLabel = persistedSettings.activePromptExternalLabel
        reconcileActivePromptLabel()

        server.engine = engine
        server.store = store
        server.mcp = mcp
        server.rivetRoot = RivetLocator.siteRoot()
        server.defaultSettings = { [weak self] in self?.settings ?? GenerationSettings() }
        server.apiKey = { SecretsStore.localServerAPIKey ?? "" }
        engine.weightLoadPolicy = { [weak self] in self?.settings.weightLoadPolicy ?? .eager }
        engine.generationSettings = { [weak self] in self?.settings ?? GenerationSettings() }

        // Models are NOT restored across launches: quitting Forge means the
        // models are gone, and a fresh launch starts at zero memory. Loading
        // 17–60 GB is an explicit user action, never a launch side effect.
        // (Older builds auto-reloaded everything resident last session, which
        // read as "the model never unloaded" in Activity Monitor.)

        store.extraDirectories = resolveExtraDirectories(from: persistedSettings)
        if let id = state.selectedConversationID, conversations.contains(where: { $0.id == id }) {
            selectedConversationID = id
        } else {
            selectedConversationID = conversations.first?.id
        }
        if conversations.isEmpty {
            newConversation()
        }

        serverPort = persistedSettings.serverPort
        serverExposeToNetwork = persistedSettings.serverExposeToNetwork
        serverEnabled = persistedSettings.serverEnabled
        reconcileServerLifecycle()

        assignOpenRouterModelIDs(openRouterModelIDs)
        refreshPrompts()
    }

    private var didBeginMCP = false

    /// Deferred past first frame so AppState init never blocks the window or Dock flame.
    func beginMCP() {
        guard !didBeginMCP else { return }
        didBeginMCP = true
        refreshZAIConfiguration()
        mcp.start()
        runtimeUpdates.checkDailyIfNeeded()
    }

    // MARK: - User model directories (sandbox-safe)

    /// Security-scoped bookmarks for each user-added model directory, keyed by the
    /// resolved URL so `saveNow` can re-persist them.
    private var directoryBookmarks: [URL: Data] = [:]

    /// Resolves persisted bookmarks into accessible URLs, starting security-scoped
    /// access for each. Falls back to plain paths (covers unsandboxed `swift run`
    /// and settings written before bookmarks existed).
    private func resolveExtraDirectories(from settings: PersistedSettings) -> [URL] {
        var dirs: [URL] = []
        for data in settings.extraModelDirectoryBookmarks {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            _ = url.startAccessingSecurityScopedResource()
            // Re-mint a stale bookmark so it doesn't silently rot.
            directoryBookmarks[url] =
                (stale ? try? url.bookmarkData(options: .withSecurityScope) : nil) ?? data
            dirs.append(url)
        }
        for path in settings.extraModelDirectories {
            let url = URL(filePath: path)
            if !dirs.contains(url) { dirs.append(url) }
        }
        return dirs
    }

    /// Resolves persisted prompt directory bookmarks (for user prompt libraries/folders).
    private func resolvePromptDirectories(from settings: PersistedSettings) -> [URL] {
        var dirs: [URL] = []
        for data in settings.promptDirectoryBookmarks {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            _ = url.startAccessingSecurityScopedResource()
            promptDirectoryBookmarks[url] =
                (stale ? try? url.bookmarkData(options: .withSecurityScope) : nil) ?? data
            dirs.append(url)
        }
        for path in settings.promptDirectories {
            let url = URL(filePath: path)
            if !dirs.contains(url) { dirs.append(url) }
        }
        return dirs
    }

    /// Resolves persisted Forge commander workspace bookmarks.
    private func resolveCommanderDirectories(from settings: PersistedSettings) -> [URL] {
        var dirs: [URL] = []
        for data in settings.commanderDirectoryBookmarks {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            _ = url.startAccessingSecurityScopedResource()
            commanderDirectoryBookmarks[url] =
                (stale ? try? url.bookmarkData(options: .withSecurityScope) : nil) ?? data
            dirs.append(url)
        }
        for path in settings.commanderDirectories {
            let url = URL(filePath: path)
            if !dirs.contains(url) { dirs.append(url) }
        }
        return dirs
    }

    /// Registers a user-selected model directory: mints a security-scoped bookmark
    /// while the `NSOpenPanel` grant is live so the folder survives relaunch.
    func addModelDirectory(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            directoryBookmarks[url] = bookmark
        }
        _ = url.startAccessingSecurityScopedResource()
        if !store.extraDirectories.contains(url) {
            store.extraDirectories.append(url)
        }
        scheduleSave()
    }

    /// Registers a user-selected prompt folder (e.g. awesome-prompts or personal collection).
    /// Mints bookmark for sandbox persistence. The folder (and subfolders) can then be
    /// browsed in the chat prompt library UI.
    func addPromptDirectory(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            promptDirectoryBookmarks[url] = bookmark
        }
        _ = url.startAccessingSecurityScopedResource()
        if !promptDirectories.contains(url) {
            promptDirectories.append(url)
        }
        refreshPrompts()
        scheduleSave()
    }

    func removePromptDirectory(_ url: URL) {
        promptDirectories.removeAll { $0 == url }
        promptDirectoryBookmarks[url] = nil
        refreshPrompts()
        scheduleSave()
    }

    /// Registers a user-selected workspace for the built-in Forge commander tools.
    func addCommanderDirectory(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            commanderDirectoryBookmarks[url] = bookmark
        }
        _ = url.startAccessingSecurityScopedResource()
        if !commanderDirectories.contains(url) {
            commanderDirectories.append(url)
        }
        scheduleSave()
    }

    func removeCommanderDirectory(_ url: URL) {
        commanderDirectories.removeAll { $0 == url }
        commanderDirectoryBookmarks[url] = nil
        scheduleSave()
    }

    /// Loads prompt content from a bookmarked prompt file (starts scoped access).
    func loadPromptContent(from url: URL) -> String? {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Scans all registered prompt directories and returns categorized list of prompt files.
    /// Categories are derived from immediate parent folder names (user organizes subfolders).
    /// Returns [(category, [(name, url)]) ] sorted.
    func availablePrompts() -> [(category: String, items: [(name: String, url: URL)])] {
        cachedPrompts
    }

    func refreshPrompts() {
        let directories = promptDirectories
        Task.detached(priority: .utility) { [weak self] in
            let indexed = Self.scanPromptDirectories(directories)
            await MainActor.run { self?.cachedPrompts = indexed }
        }
    }

    private nonisolated static func scanPromptDirectories(
        _ directories: [URL]
    ) -> [(category: String, items: [(name: String, url: URL)])] {
        var grouped: [String: [(String, URL)]] = [:]
        for dir in directories {
            _ = dir.startAccessingSecurityScopedResource()
            defer { dir.stopAccessingSecurityScopedResource() }
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                    !isDir.boolValue
                {
                    let category = fileURL.deletingLastPathComponent().lastPathComponent
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    grouped[category, default: []].append((name, fileURL))
                }
            }
        }
        return grouped.keys.sorted().map { cat in
            (cat, grouped[cat]!.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending })
        }
    }

    // MARK: - Conversations

    func newConversation() {
        var conversation = Conversation()
        if !lastPromptContent.isEmpty {
            conversation.systemPrompt = lastPromptContent
        }
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        scheduleSave()
    }

    func deleteConversation(_ id: UUID) {
        // Cancel BOTH providers — `engine.stop()` alone leaked an in-flight Claude
        // request (billed tokens, composer stuck "responding…").
        if streamingMessageID != nil, selectedConversationID == id {
            stopGenerating()
        }
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id {
            selectedConversationID = conversations.first?.id
        }
        if conversations.isEmpty {
            newConversation()
        }
        scheduleSave()
    }

    func clearAllConversations() {
        if streamingMessageID != nil {
            stopGenerating()
        }
        conversations.removeAll()
        selectedConversationID = nil
        newConversation()
        scheduleSave()
    }

    /// When switching to a conversation that last used a model which is
    /// currently resident, make that model active automatically.
    private func autoActivateModel() {
        guard let conversation = selectedConversation,
            let lastModel = conversation.lastModelID,
            let loaded = engine.loadedModels.first(where: { $0.model.name == lastModel })
        else { return }
        engine.activeModelID = loaded.id
    }

    private func localModelLabel(_ model: LocalModel) -> String {
        "\(model.shortName) · \(model.runtimeDetails)"
    }

    /// Short label for the tuning panel — preset name, library file, custom, or empty.
    var systemPromptSourceLabel: String {
        let prompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return "empty" }
        if let id = activePromptPresetID,
            let preset = promptPresets.first(where: { $0.id == id }),
            preset.text == settings.systemPrompt
        {
            return preset.name
        }
        if let external = activePromptExternalLabel,
            !external.isEmpty,
            lastPromptContent == settings.systemPrompt
        {
            return external
        }
        if let match = promptPresets.first(where: { $0.text == settings.systemPrompt }) {
            return match.name
        }
        return "Custom"
    }

    /// Apply the inspector's active system prompt (source of truth for new turns).
    func applySystemPrompt(
        _ text: String,
        preset: PromptPreset? = nil,
        externalLabel: String? = nil
    ) {
        if let preset {
            activePromptPresetID = preset.id
            activePromptExternalLabel = nil
        } else if let externalLabel, !externalLabel.isEmpty {
            activePromptPresetID = nil
            activePromptExternalLabel = externalLabel
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activePromptPresetID = nil
            activePromptExternalLabel = nil
        }
        var next = settings
        next.systemPrompt = text
        settings = next
    }

    func removePromptPreset(_ preset: PromptPreset) {
        promptPresets.removeAll { $0.id == preset.id }
        if activePromptPresetID == preset.id {
            activePromptPresetID = nil
            reconcileActivePromptLabel()
        }
    }

    private func reconcileActivePromptLabel() {
        let prompt = settings.systemPrompt
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activePromptPresetID = nil
            activePromptExternalLabel = nil
            return
        }
        if let id = activePromptPresetID,
            let preset = promptPresets.first(where: { $0.id == id }),
            preset.text == prompt
        {
            activePromptExternalLabel = nil
            return
        }
        if let match = promptPresets.first(where: { $0.text == prompt }) {
            activePromptPresetID = match.id
            activePromptExternalLabel = nil
            return
        }
        activePromptPresetID = nil
        if activePromptExternalLabel != nil, lastPromptContent != prompt {
            activePromptExternalLabel = nil
        }
    }

    private func historyWithMCPInstructions(
        _ conversation: Conversation, mcpSystemPrompt: String
    ) -> Conversation {
        var copy = conversation
        copy.systemPrompt = mcpSystemPrompt
        return copy
    }

    private func mcpEnrichedSystemPrompt(for conversation: Conversation) async -> String {
        let base = baseSystemPrompt(for: conversation)
        let tools = await mcp.prepareToolCatalogForPrompt()
        return systemPromptWithMCPInstructions(base: base, tools: tools)
    }

    /// System prompt plus the live tool bindings, for backends with native tool
    /// calling (Anthropic/OpenRouter) that pass tools in the request body.
    /// These models get NO sentinel-JSON instructions — teaching the wire syntax
    /// made them narrate JSON in prose answers; native tool_use needs no coaching.
    private func mcpPromptContext(
        for conversation: Conversation
    ) async -> (system: String, tools: [MCPToolBinding]) {
        let base = baseSystemPrompt(for: conversation)
        let tools = await mcp.prepareToolCatalogForPrompt()
        guard !tools.isEmpty else { return (base, tools) }
        let note = """
            You have tools available (MCP servers, e.g. legal research via CourtListener). \
            Use them when they help answer the user; after a tool result arrives, answer \
            the user's question in normal prose — do not echo raw JSON unless asked.
            """
        let system = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? note : base + "\n\n" + note
        return (system, tools)
    }

    /// Active system instructions for UI delineation and new turns.
    func effectiveSystemPrompt(for conversation: Conversation) -> String {
        baseSystemPrompt(for: conversation)
    }

    private var cloudReasoningEffort: CloudReasoningEffort {
        CloudReasoningEffort(rawValue: settings.anthropicEffort) ?? .high
    }

    private var anthropicStreamConfig: AnthropicStreamConfig {
        // With adaptive thinking on, a small shared maxTokens (tuned for local
        // models) gets consumed by reasoning before any answer streams — the
        // turn "stops mid-thinking". Floor it so thinking + answer both fit.
        let configured = settings.maxTokens > 0 ? settings.maxTokens : 8192
        let floored = settings.reasoningEnabled ? max(configured, 16_384) : configured
        return AnthropicStreamConfig(
            reasoningEnabled: settings.reasoningEnabled,
            effort: Self.anthropicEffort(from: cloudReasoningEffort),
            thinkingSummarized: settings.anthropicThinkingSummarized,
            maxTokens: floored)
    }

    private var openRouterStreamConfig: OpenRouterStreamConfig {
        OpenRouterStreamConfig(
            reasoningEnabled: settings.reasoningEnabled,
            effort: Self.openRouterEffort(from: cloudReasoningEffort),
            maxTokens: settings.maxTokens > 0 ? settings.maxTokens : 8192)
    }

    private var openAIStreamConfig: OpenAIStreamConfig {
        OpenAIStreamConfig(
            reasoningEnabled: settings.reasoningEnabled,
            effort: Self.openAIEffort(from: cloudReasoningEffort),
            reasoningSummary: settings.anthropicThinkingSummarized,
            maxOutputTokens: settings.maxTokens > 0 ? settings.maxTokens : 16_384)
    }

    private static func anthropicEffort(from cloud: CloudReasoningEffort) -> AnthropicEffort {
        switch cloud {
        case .none, .minimal: return .low
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh: return .xhigh
        case .max: return .max
        }
    }

    private static func openRouterEffort(from cloud: CloudReasoningEffort) -> OpenRouterReasoningEffort {
        OpenRouterReasoningEffort(rawValue: cloud.rawValue) ?? .high
    }

    private static func openAIEffort(from cloud: CloudReasoningEffort) -> OpenAIReasoningEffort {
        switch cloud {
        case .max: return .xhigh
        default: return OpenAIReasoningEffort(rawValue: cloud.rawValue) ?? .medium
        }
    }

    /// Inspector `settings.systemPrompt` wins over per-conversation copies saved at creation.
    private func baseSystemPrompt(for conversation: Conversation) -> String {
        let global = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { return settings.systemPrompt }
        return conversation.systemPrompt
    }

    private func systemPrompt(for conversation: Conversation, includeMCP: Bool) -> String {
        let base = baseSystemPrompt(for: conversation)
        guard includeMCP else { return base }
        return systemPromptWithMCPInstructions(base: base, tools: mcp.selectedPromptTools())
    }

    private func systemPromptWithMCPInstructions(
        base: String, tools: [MCPToolBinding]
    ) -> String {
        guard !tools.isEmpty else { return base }
        let toolLines = tools.prefix(80).map { binding in
            let description = Self.clippedForPrompt(binding.tool.description, max: 160)
            if description.isEmpty {
                return "- server: \"\(binding.serverID)\", tool: \"\(binding.tool.name)\""
            }
            return "- server: \"\(binding.serverID)\", tool: \"\(binding.tool.name)\": \(description)"
        }.joined(separator: "\n")
        let overflow =
            tools.count > 80 ? "\n- ... \(tools.count - 80) more enabled MCP tools hidden." : ""
        let configPath = MCPManager.projectConfigFile.path
        let instruction = """

        Forge MCP tools (from \(configPath)). To call one, output ONLY this line (no Markdown):
        FORGE_MCP_CALL {"server":"<server-id>","tool":"<tool-name>","arguments":{...}}

        Enabled tools:
        \(toolLines)\(overflow)

        Rules:
        - Use the exact server id and tool name from the list (e.g. server "sequential-thinking", tool "sequentialthinking").
        - Put tool arguments inside "arguments" as a JSON object matching the tool schema.
        - Example: FORGE_MCP_CALL {"server":"desktop-commander","tool":"read_file","arguments":{"path":"/path/to/file"}}
        - Never write FORGE_MCP_CALL inside <think>...</think> — Forge ignores everything inside \
        <think> and the call will silently fail. Close </think> first, then write FORGE_MCP_CALL \
        as the first line of your visible answer.
        - After Forge returns the MCP result in the chat, answer the user using that result.
        """
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return trimmedInstruction
        }
        // Large custom prompts bury appended MCP instructions; put tools first.
        if base.count > 3_000 {
            return trimmedInstruction + "\n\n" + base
        }
        return base + "\n\n" + trimmedInstruction
    }

    // MARK: - Sending

    var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if claudeSelected || openRouterSelected || openAISelected || zaiSelected
            || braveSearchSelected
        {
            guard !isBusy && hasText else { return false }
            if claudeSelected && !hasAnthropicKey { return false }
            if openRouterSelected && !hasOpenRouterKey { return false }
            if openAISelected && !hasOpenAIKey { return false }
            if zaiSelected && !zaiConfiguration.isConfigured { return false }
            if braveSearchSelected && !hasBraveSearchKey { return false }
            return true
        }
        return engine.activeModel != nil && !isBusy && hasText
    }

    func send(images: [Data] = []) {
        guard canSend, var conversation = selectedConversation else { return }
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = cancellationGeneration
        composerText = ""

        // Snapshot history BEFORE appending the new user message — the provider
        // re-hydrates from this and sends `prompt` as the new turn.
        let historySnapshot = conversation

        var userMessage = ChatMessage(role: .user, content: prompt)
        userMessage.attachedImageData = images
        conversation.messages.append(userMessage)

        if claudeSelected || openRouterSelected || openAISelected || zaiSelected
            || braveSearchSelected
        {
            let selectedModels = openRouterModelIDs
            var openRouterTargets: [(modelID: String, messageID: UUID)] = []
            var claudeTarget: (modelID: String, messageID: UUID)?
            var openAITarget: (modelID: String, messageID: UUID)?
            var zaiTarget: (modelID: String, messageID: UUID)?
            var braveTarget: UUID?
            if let claudeID = claudeModelID, !claudeID.isEmpty {
                var assistant = ChatMessage(role: .assistant, content: "")
                assistant.modelName = AnthropicClient.label(for: claudeID)
                conversation.messages.append(assistant)
                claudeTarget = (claudeID, assistant.id)
            }
            for modelID in selectedModels {
                var assistant = ChatMessage(role: .assistant, content: "")
                assistant.modelName = OpenRouterClient.label(for: modelID)
                conversation.messages.append(assistant)
                openRouterTargets.append((modelID, assistant.id))
            }
            if let openAIID = openAIModelID, !openAIID.isEmpty {
                var assistant = ChatMessage(role: .assistant, content: "")
                assistant.modelName = OpenAIClient.label(for: openAIID)
                conversation.messages.append(assistant)
                openAITarget = (openAIID, assistant.id)
            }
            if let zaiID = zaiModelID, !zaiID.isEmpty {
                var assistant = ChatMessage(role: .assistant, content: "")
                assistant.modelName = ZAICodingPlanClient.label
                conversation.messages.append(assistant)
                zaiTarget = (zaiID, assistant.id)
            }
            if braveSearchSelected {
                var assistant = ChatMessage(role: .assistant, content: "")
                assistant.modelName = braveSearchModeLabel
                conversation.messages.append(assistant)
                braveTarget = assistant.id
            }
            conversation.refreshTitle()
            conversation.updatedAt = Date()
            conversation.lastModelID =
                claudeTarget?.modelID ?? selectedModels.first ?? openAITarget?.modelID
                ?? zaiTarget?.modelID ?? (braveSearchSelected ? "brave" : nil)
            selectedConversation = conversation

            let conversationID = conversation.id
            if let braveTarget { beginStreaming(messageID: braveTarget) }
            if let zaiTarget { beginStreaming(messageID: zaiTarget.messageID) }
            if let openAITarget { beginStreaming(messageID: openAITarget.messageID) }
            for target in openRouterTargets { beginStreaming(messageID: target.messageID) }
            if let claudeTarget { beginStreaming(messageID: claudeTarget.messageID) }
            if let claudeTarget {
                streamClaude(
                    model: claudeTarget.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: claudeTarget.messageID,
                    images: images, cancellationGeneration: generation)
            }
            for target in openRouterTargets {
                streamOpenRouter(
                    model: target.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: target.messageID,
                    images: images, cancellationGeneration: generation)
            }
            if let openAITarget {
                streamOpenAI(
                    model: openAITarget.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: openAITarget.messageID,
                    images: images, cancellationGeneration: generation)
            }
            if let zaiTarget {
                streamZAI(
                    model: zaiTarget.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: zaiTarget.messageID,
                    images: images, cancellationGeneration: generation)
            }
            if let braveTarget {
                streamBraveSearch(
                    history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: braveTarget)
            }
            scheduleSave()
            return
        }

        // Fan out one send to every parallel-selected loaded local model. Each gets
        // its own labeled bubble; the MLX gate runs them back-to-back on the GPU.
        let fanoutTargets = engine.loadedModels.filter { localFanoutModelIDs.contains($0.id) }
        if claudeModelID?.isEmpty != false, fanoutTargets.count >= 2 {
            var targets: [(modelID: String, label: String, messageID: UUID)] = []
            for entry in fanoutTargets {
                var bubble = ChatMessage(role: .assistant, content: "")
                bubble.modelName = localModelLabel(entry.model)
                conversation.messages.append(bubble)
                targets.append((entry.id, localModelLabel(entry.model), bubble.id))
            }
            conversation.refreshTitle()
            conversation.updatedAt = Date()
            conversation.lastModelID = fanoutTargets.first?.model.name
            selectedConversation = conversation
            let conversationID = conversation.id
            for target in targets { beginStreaming(messageID: target.messageID) }
            Task { @MainActor [weak self] in
                guard let self, self.cancellationGeneration == generation else { return }
                let systemInstructions = await self.mcpEnrichedSystemPrompt(for: historySnapshot)
                guard self.cancellationGeneration == generation else { return }
                let generationHistory = self.historyWithMCPInstructions(
                    historySnapshot, mcpSystemPrompt: systemInstructions)
                for target in targets {
                    self.engine.generate(
                        conversation: generationHistory,
                        prompt: prompt,
                        images: images,
                        settings: self.settings,
                        systemInstructions: systemInstructions,
                        targetModelID: target.modelID,
                        onChunk: { [weak self] delta in
                            guard self?.cancellationGeneration == generation else { return }
                            self?.enqueueStreamDelta(
                                delta, conversationID: conversationID,
                                messageID: target.messageID)
                        },
                        onComplete: { [weak self] info, errorMessage in
                            guard let self, self.cancellationGeneration == generation else { return }
                            self.finishStreamBuffer(target.messageID)
                            self.appendToMessage(
                                conversationID: conversationID, messageID: target.messageID
                            ) {
                                if let info {
                                    $0.tokensPerSecond = info.tokensPerSecond
                                    $0.generationTokenCount = info.generationTokenCount
                                    $0.promptTokenCount = info.promptTokenCount
                                    $0.promptTime = info.promptTime
                                }
                                if let errorMessage {
                                    if $0.content.isEmpty {
                                        $0.content = "⚠️ \(errorMessage)"
                                        $0.isError = true
                                    } else {
                                        $0.content += "\n\n⚠️ stream interrupted: \(errorMessage)"
                                    }
                                }
                            }
                            self.endStreaming(messageID: target.messageID)
                            self.scheduleSave()
                            Task { @MainActor in
                                await self.handleMCPToolRequestIfNeeded(
                                    backend: .local(modelID: target.modelID, label: target.label),
                                    originalPrompt: prompt,
                                    images: images,
                                    conversationID: conversationID,
                                    messageID: target.messageID,
                                    cancellationGeneration: generation)
                            }
                        })
                }
            }
            scheduleSave()
            return
        }

        var assistant = ChatMessage(role: .assistant, content: "")
        if let claudeID = claudeModelID, !claudeID.isEmpty {
            assistant.modelName = AnthropicClient.label(for: claudeID)
        } else if let active = engine.activeModel {
            assistant.modelName = localModelLabel(active.model)
        } else {
            return
        }
        conversation.messages.append(assistant)
        conversation.refreshTitle()
        conversation.updatedAt = Date()
        conversation.lastModelID = claudeModelID ?? engine.activeModel?.model.name
        selectedConversation = conversation

        let conversationID = conversation.id
        let messageID = assistant.id
        beginStreaming(messageID: messageID)

        if let claudeID = claudeModelID, !claudeID.isEmpty {
            streamClaude(
                model: claudeID, history: historySnapshot, prompt: prompt,
                conversationID: conversationID, messageID: messageID,
                images: images, cancellationGeneration: generation)
            scheduleSave()
            return
        }

        let activeModelID = engine.activeModel?.id
        let activeModelLabel = engine.activeModel.map { localModelLabel($0.model) } ?? "Local"
        Task { @MainActor [weak self] in
            guard let self, self.cancellationGeneration == generation else { return }
            let systemInstructions = await self.mcpEnrichedSystemPrompt(for: historySnapshot)
            guard self.cancellationGeneration == generation else { return }
            let generationHistory = self.historyWithMCPInstructions(
                historySnapshot, mcpSystemPrompt: systemInstructions)
            self.engine.generate(
                conversation: generationHistory,
                prompt: prompt,
                images: images,
                settings: self.settings,
                systemInstructions: systemInstructions,
                onChunk: { [weak self] delta in
                    guard self?.cancellationGeneration == generation else { return }
                    self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
                },
                onComplete: { [weak self] info, errorMessage in
                    guard let self, self.cancellationGeneration == generation else { return }
                    self.finishStreamBuffer(messageID)
                    self.appendToMessage(conversationID: conversationID, messageID: messageID) {
                        if let info {
                            $0.tokensPerSecond = info.tokensPerSecond
                            $0.generationTokenCount = info.generationTokenCount
                            $0.promptTokenCount = info.promptTokenCount
                            $0.promptTime = info.promptTime
                        }
                        if let errorMessage {
                            if $0.content.isEmpty {
                                $0.content = "⚠️ \(errorMessage)"
                                $0.isError = true
                            } else {
                                // Partial answer already streamed — keep it, but make the
                                // interruption visible instead of silently truncating.
                                $0.content += "\n\n⚠️ stream interrupted: \(errorMessage)"
                            }
                        }
                    }
                    self.endStreaming(messageID: messageID)
                    self.scheduleSave()
                    if let activeModelID {
                        Task { @MainActor in
                            await self.handleMCPToolRequestIfNeeded(
                                backend: .local(modelID: activeModelID, label: activeModelLabel),
                                originalPrompt: prompt,
                                images: images,
                                conversationID: conversationID,
                                messageID: messageID,
                                cancellationGeneration: generation)
                        }
                    }
                })
        }
        scheduleSave()
    }

    /// Routes a chat turn to the Anthropic API and streams deltas into the message.
    private func streamClaude(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        images: [Data] = [],
        cancellationGeneration generation: UInt64,
        mcpDepth: Int = 0,
        mcpOriginalPrompt: String? = nil
    ) {
        guard generation == cancellationGeneration else { return }
        guard let key = SecretsStore.anthropicAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No Anthropic API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isClaudeGenerating = false
            endStreaming(messageID: messageID)
            return
        }

        var messages: [AnthropicClient.Message] = history.messages.compactMap { m in
            switch m.role {
            case .user: return .init(role: "user", text: m.content)
            case .assistant:
                // Skip empty placeholders and our own error notices — replaying a
                // "⚠️ …" bubble as an assistant turn poisons later context.
                let visible = m.modelVisibleContent
                return (visible.isEmpty || m.isErrorMessage)
                    ? nil : .init(role: "assistant", text: visible)
            case .system: return nil
            }
        }
        messages.append(.init(role: "user", text: prompt, images: images))
        let client = AnthropicClient(apiKey: key)

        isClaudeGenerating = true
        claudeTask = Task { [weak self] in
            // Tools stay available on every turn (including MCP follow-ups) so the model can
            // chain calls. The depth cap in handleMCPToolRequestIfNeeded ends the loop.
            let context = await self?.mcpPromptContext(for: history)
            guard self?.cancellationGeneration == generation else { return }
            let system =
                context?.system
                ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            do {
                try await client.stream(
                    model: model, system: system, messages: messages,
                    config: self?.anthropicStreamConfig ?? AnthropicStreamConfig(),
                    tools: context?.tools ?? []
                ) { delta in
                    guard self?.cancellationGeneration == generation else { return }
                    self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
                }
            } catch is CancellationError {
                // User pressed stop — leave whatever streamed in place.
            } catch {
                self?.finishStreamBuffer(messageID)
                self?.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if $0.content.isEmpty {
                        $0.content = "⚠️ \(error.localizedDescription)"
                        $0.isError = true
                    } else {
                        $0.content += "\n\n⚠️ stream interrupted: \(error.localizedDescription)"
                    }
                }
            }
            guard self?.cancellationGeneration == generation else { return }
            self?.finishStreamBuffer(messageID)
            self?.isClaudeGenerating = false
            self?.endStreaming(messageID: messageID)
            _ = await self?.handleMCPToolRequestIfNeeded(
                backend: .claude(modelID: model),
                originalPrompt: mcpOriginalPrompt ?? prompt,
                images: [],
                conversationID: conversationID,
                messageID: messageID,
                mcpDepth: mcpDepth,
                cancellationGeneration: generation)
            self?.scheduleSave()
        }
    }

    /// Routes a chat turn to OpenRouter and streams deltas into the message.
    private func streamOpenRouter(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        images: [Data] = [],
        cancellationGeneration generation: UInt64,
        mcpDepth: Int = 0,
        mcpOriginalPrompt: String? = nil
    ) {
        guard generation == cancellationGeneration else { return }
        guard let key = SecretsStore.openRouterAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No OpenRouter API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isOpenRouterGenerating = false
            endStreaming(messageID: messageID)
            return
        }

        var messages: [OpenRouterClient.Message] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                let visible = message.modelVisibleContent
                return (visible.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: visible)
            case .system:
                return nil
            }
        }
        messages.append(.init(role: "user", text: prompt, images: images))
        let client = OpenRouterClient(apiKey: key)

        isOpenRouterGenerating = true
        openRouterTasks[messageID] = Task { [weak self] in
            let context = await self?.mcpPromptContext(for: history)
            guard self?.cancellationGeneration == generation else { return }
            let system =
                context?.system
                ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            do {
                try await client.stream(
                    model: model,
                    system: system,
                    messages: messages,
                    config: self?.openRouterStreamConfig ?? OpenRouterStreamConfig(),
                    sessionID: conversationID.uuidString,
                    tools: context?.tools ?? []
                ) { delta in
                    guard self?.cancellationGeneration == generation else { return }
                    self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
                }
            } catch is CancellationError {
                // User pressed stop — leave whatever streamed in place.
            } catch {
                self?.finishStreamBuffer(messageID)
                self?.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if $0.content.isEmpty {
                        $0.content = "⚠️ \(error.localizedDescription)"
                        $0.isError = true
                    } else {
                        $0.content += "\n\n⚠️ OpenRouter stream interrupted: \(error.localizedDescription)"
                    }
                }
            }
            guard self?.cancellationGeneration == generation else { return }
            self?.finishStreamBuffer(messageID)
            self?.openRouterTasks.removeValue(forKey: messageID)
            self?.isOpenRouterGenerating = self?.openRouterTasks.isEmpty == false
            self?.endStreaming(messageID: messageID)
            _ = await self?.handleMCPToolRequestIfNeeded(
                backend: .openRouter(modelID: model),
                originalPrompt: mcpOriginalPrompt ?? prompt,
                images: [],
                conversationID: conversationID,
                messageID: messageID,
                mcpDepth: mcpDepth,
                cancellationGeneration: generation)
            self?.scheduleSave()
        }
    }

    /// Routes a chat turn to the OpenAI Responses API and streams deltas into the message.
    private func streamOpenAI(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        images: [Data] = [],
        cancellationGeneration generation: UInt64,
        mcpDepth: Int = 0,
        mcpOriginalPrompt: String? = nil
    ) {
        guard generation == cancellationGeneration else { return }
        guard let key = SecretsStore.openAIAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No OpenAI API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isOpenAIGenerating = false
            endStreaming(messageID: messageID)
            return
        }

        var turns: [OpenAIClient.Turn] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                let visible = message.modelVisibleContent
                return (visible.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: visible)
            case .system:
                return nil
            }
        }
        turns.append(.init(role: "user", text: prompt, images: images))
        let client = OpenAIClient(apiKey: key)

        isOpenAIGenerating = true
        openAITask = Task { [weak self] in
            let system =
                await self?.mcpEnrichedSystemPrompt(for: history)
                ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            guard self?.cancellationGeneration == generation else { return }
            do {
                try await client.stream(
                    model: model,
                    system: system,
                    turns: turns,
                    config: self?.openAIStreamConfig ?? OpenAIStreamConfig()
                ) { delta in
                    guard self?.cancellationGeneration == generation else { return }
                    self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
                }
            } catch is CancellationError {
                // User pressed stop — leave whatever streamed in place.
            } catch {
                self?.finishStreamBuffer(messageID)
                self?.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if $0.content.isEmpty {
                        $0.content = "⚠️ \(error.localizedDescription)"
                        $0.isError = true
                    } else {
                        $0.content += "\n\n⚠️ OpenAI stream interrupted: \(error.localizedDescription)"
                    }
                }
            }
            guard self?.cancellationGeneration == generation else { return }
            self?.finishStreamBuffer(messageID)
            self?.isOpenAIGenerating = false
            self?.endStreaming(messageID: messageID)
            _ = await self?.handleMCPToolRequestIfNeeded(
                backend: .openAI(modelID: model),
                originalPrompt: mcpOriginalPrompt ?? prompt,
                images: [],
                conversationID: conversationID,
                messageID: messageID,
                mcpDepth: mcpDepth,
                cancellationGeneration: generation)
            self?.scheduleSave()
        }
    }

    /// Routes a chat turn through the signed-in ZCode Z.AI Coding Plan account.
    /// ZCode tools remain disabled; approved Forge MCP actions return through the
    /// same host-controlled FORGE_MCP_CALL loop as every other backend.
    private func streamZAI(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        images: [Data] = [],
        cancellationGeneration generation: UInt64,
        mcpDepth: Int = 0,
        mcpOriginalPrompt: String? = nil
    ) {
        guard generation == cancellationGeneration else { return }
        refreshZAIConfiguration()
        guard zaiConfiguration.isConfigured else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ \(zaiConfiguration.detail)"
                $0.isError = true
            }
            isZAIGenerating = false
            endStreaming(messageID: messageID)
            return
        }
        guard images.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ The Z.AI Coding Plan lane currently accepts text and code; send image attachments to a vision-capable model."
                $0.isError = true
            }
            isZAIGenerating = false
            endStreaming(messageID: messageID)
            return
        }

        var messages: [ZAICodingPlanClient.Message] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                let visible = message.modelVisibleContent
                return (visible.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: visible)
            case .system:
                return nil
            }
        }
        messages.append(.init(role: "user", text: prompt))

        let runControl = ZAIRunControl()
        zaiRunControl = runControl
        isZAIGenerating = true
        zaiTask = Task { [weak self] in
            guard let self else { return }
            let context = await self.mcpPromptContext(for: history)
            guard self.cancellationGeneration == generation else { return }
            let tools = context.tools.map { binding in
                ZAICodingPlanClient.Tool(
                    name: binding.nativeToolName,
                    serverID: binding.serverID,
                    toolName: binding.tool.name,
                    description: binding.tool.description,
                    inputSchemaJSON: binding.tool.inputSchemaJSON)
            }
            do {
                let output = try await ZAICodingPlanClient.complete(
                    system: context.system,
                    messages: messages,
                    tools: tools,
                    runControl: runControl)
                guard self.cancellationGeneration == generation else { return }
                self.enqueueStreamDelta(
                    .content(output), conversationID: conversationID, messageID: messageID)
            } catch is CancellationError {
                // User pressed stop — the child process has already been terminated.
            } catch {
                self.finishStreamBuffer(messageID)
                self.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if $0.content.isEmpty {
                        $0.content = "⚠️ \(error.localizedDescription)"
                        $0.isError = true
                    } else {
                        $0.content += "\n\n⚠️ Z.AI GLM-5.3 interrupted: \(error.localizedDescription)"
                    }
                }
            }
            guard self.cancellationGeneration == generation else { return }
            self.finishStreamBuffer(messageID)
            self.isZAIGenerating = false
            self.zaiRunControl = nil
            self.zaiTask = nil
            self.endStreaming(messageID: messageID)
            _ = await self.handleMCPToolRequestIfNeeded(
                backend: .zai(modelID: model),
                originalPrompt: mcpOriginalPrompt ?? prompt,
                images: [],
                conversationID: conversationID,
                messageID: messageID,
                mcpDepth: mcpDepth,
                cancellationGeneration: generation)
            self.scheduleSave()
        }
    }

    /// Routes a chat turn to Brave Search Answers and streams deltas into the message.
    private func streamBraveSearch(
        history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID
    ) {
        guard let key = SecretsStore.braveSearchAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No Brave Search API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isBraveSearchGenerating = false
            endStreaming(messageID: messageID)
            return
        }

        let client = BraveAnswersClient(apiKey: key, config: braveSearchConfig)
        var citations: [BraveCitation] = []
        let buffersResearchDrafts = braveSearchConfig.enableResearch
        var researchText = ""

        isBraveSearchGenerating = true
        braveSearchTask?.cancel()
        braveSearchTask = Task { [weak self] in
            do {
                try await client.stream(
                    query: prompt,
                    onChunk: { delta in
                        if buffersResearchDrafts {
                            if case .content(let text) = delta { researchText += text }
                        } else {
                            self?.enqueueStreamDelta(
                                delta, conversationID: conversationID, messageID: messageID)
                        }
                    },
                    onCitation: { citation in
                        citations.append(citation)
                    },
                    onUsage: { _ in }
                )
                if buffersResearchDrafts {
                    let answer = BraveAnswersClient.cleanedResearchAnswer(researchText)
                    guard !answer.isEmpty else { throw BraveAnswersError.emptyAnswer }
                    self?.enqueueStreamDelta(
                        .content(answer), conversationID: conversationID, messageID: messageID)
                }
            } catch is CancellationError {
                // User pressed stop — leave whatever streamed in place.
            } catch {
                self?.finishStreamBuffer(messageID)
                self?.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if $0.content.isEmpty {
                        $0.content = "⚠️ \(error.localizedDescription)"
                        $0.isError = true
                    } else {
                        $0.content +=
                            "\n\n⚠️ Brave Search stream interrupted: \(error.localizedDescription)"
                    }
                }
            }
            self?.finishStreamBuffer(messageID)
            if let footer = self?.formatBraveCitationsFooter(citations), !footer.isEmpty {
                self?.appendToMessage(conversationID: conversationID, messageID: messageID) {
                    if !$0.content.hasSuffix(footer) {
                        $0.content += footer
                    }
                }
            }
            self?.isBraveSearchGenerating = false
            self?.braveSearchTask = nil
            self?.endStreaming(messageID: messageID)
            self?.scheduleSave()
        }
    }

    private func formatBraveCitationsFooter(_ citations: [BraveCitation]) -> String {
        guard braveSearchConfig.enableCitations, !citations.isEmpty else { return "" }
        let sorted = citations.sorted { $0.number < $1.number }
        var lines = ["\n\n---\n**Sources**"]
        for citation in sorted {
            let title = citation.snippet?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                lines.append("\(citation.number). [\(title)](\(citation.url))")
            } else {
                lines.append("\(citation.number). \(citation.url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Consecutive tool calls that arrived unparseable (truncated stream, call
    /// inside <think>, malformed JSON). Bounds the silent re-ask loop so a model
    /// that never manages a clean call can't spin forever.
    private var mcpParseRetryCount = 0

    @discardableResult
    private func handleMCPToolRequestIfNeeded(
        backend: ResponseBackend,
        originalPrompt: String,
        images: [Data],
        conversationID: UUID,
        messageID: UUID,
        mcpDepth: Int = 0,
        cancellationGeneration generation: UInt64
    ) async -> Bool {
        guard generation == cancellationGeneration else { return false }
        // Agent-loop bound. Tools stay available on every follow-up turn (so the model can
        // chain calls — e.g. sequential-thinking's repeated nextThoughtNeeded), so this cap
        // is the only backstop against a model that never stops calling tools. Reached only
        // after `settings.mcpMaxIterations` tool calls in a single user turn. A cap of 0
        // (or below) means Unlimited.
        let maxIterations = settings.mcpMaxIterations <= 0 ? Int.max : settings.mcpMaxIterations
        guard mcpDepth < maxIterations else {
            appendSystemMessage(
                conversationID: conversationID,
                content: "MCP tool loop reached the \(maxIterations)-call limit — stopping. Raise the tool-call limit in the Tuning panel (0 = Unlimited) for longer chains (e.g. sequential-thinking)."
            )
            return false
        }
        guard let content = messageContent(conversationID: conversationID, messageID: messageID)
        else { return false }
        if mcpDepth == 0 { mcpParseRetryCount = 0 }
        guard var request = Self.parseMCPCallRequest(from: content) else {
            // The model tried to call a tool but in a shape no parser understands —
            // usually a stream cut off mid-JSON or a call emitted inside <think>.
            // Don't kill the run: quietly hand the problem back to the model so it
            // can re-send the call. mcpParseRetryCount bounds the loop.
            if content.contains("FORGE_MCP_CALL") || content.contains("MCP request:") {
                if mcpParseRetryCount < 3 {
                    mcpParseRetryCount += 1
                    continueAfterMCPToolResult(
                        backend: backend,
                        originalPrompt: originalPrompt,
                        images: images,
                        requestLabel: "tool-call-check",
                        resultText: """
                            Your tool call was NOT executed — it arrived malformed, cut off \
                            mid-stream, or inside <think> (calls inside <think> are ignored). \
                            Re-send the complete call as one single line in your visible \
                            answer, exactly in this shape:
                            FORGE_MCP_CALL {"server":"<server-id>","tool":"<tool-name>","arguments":{...}}
                            """,
                        conversationID: conversationID,
                        mcpDepth: mcpDepth + 1,
                        cancellationGeneration: generation)
                    return true
                }
                appendSystemMessage(
                    conversationID: conversationID,
                    content: """
                        The model's MCP tool call stayed unparseable after 3 automatic \
                        retries, so the run stopped here. Tool calls must be a single line: \
                        `FORGE_MCP_CALL {"server":"<server-id>","tool":"<tool-name>","arguments":{...}}` \
                        — reply "continue" to let the model retry.
                        """
                )
            }
            return false
        }
        mcpParseRetryCount = 0

        request.serverID = mcp.resolveEntryID(request.serverID)
        let requestLabel = "\(request.serverID).\(request.toolName)"

        do {
            try await mcp.ensureConnected(entryID: request.serverID)
        } catch {
            appendSystemMessage(
                conversationID: conversationID,
                content: "MCP failed: \(requestLabel)\n\n\(error.localizedDescription)"
            )
            return true
        }
        guard generation == cancellationGeneration else { return false }

        guard isMCPToolEnabled(request) else {
            let enabled = mcp.effectiveSelectedTools(for: request.serverID)
                .joined(separator: ", ")
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = """
                    MCP request blocked: `\(requestLabel)` is not enabled.
                    Enabled tools for `\(request.serverID)`: \(enabled.isEmpty ? "none" : enabled).
                    """
                $0.isError = true
            }
            scheduleSave()
            return true
        }

        activeMCPCallCount += 1
        defer {
            activeMCPCallCount = max(0, activeMCPCallCount - 1)
            scheduleSave()
        }

        appendToMessage(conversationID: conversationID, messageID: messageID) {
            $0.content = """
                MCP request: `\(requestLabel)`

                ```json
                \(Self.prettyJSONString(request.arguments))
                ```
                """
        }
        appendSystemMessage(
            conversationID: conversationID,
            content: "MCP running: \(requestLabel)"
        )

        do {
            guard generation == cancellationGeneration else { return false }
            let data = try await mcp.callTool(
                entryID: request.serverID,
                name: request.toolName,
                arguments: request.arguments)
            guard generation == cancellationGeneration else { return false }
            let resultText = Self.readableMCPResult(from: data)
            appendSystemMessage(
                conversationID: conversationID,
                content: """
                    MCP result: \(requestLabel)

                    \(resultText)
                    """
            )
            continueAfterMCPToolResult(
                backend: backend,
                originalPrompt: originalPrompt,
                images: images,
                requestLabel: requestLabel,
                resultText: resultText,
                conversationID: conversationID,
                mcpDepth: mcpDepth + 1,
                cancellationGeneration: generation)
            return true
        } catch {
            appendSystemMessage(
                conversationID: conversationID,
                content: "MCP failed: \(requestLabel)\n\n\(error.localizedDescription)"
            )
            return true
        }
    }

    private func continueAfterMCPToolResult(
        backend: ResponseBackend,
        originalPrompt: String,
        images: [Data],
        requestLabel: String,
        resultText: String,
        conversationID: UUID,
        mcpDepth: Int,
        cancellationGeneration generation: UInt64
    ) {
        guard generation == cancellationGeneration else { return }
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        // Snapshot the live transcript BEFORE appending the new (empty) assistant bubble.
        // This carries the full chain — prior tool calls, results, and follow-ups — so a
        // multi-step tool like sequential-thinking sees its earlier thoughts on the next call.
        let liveHistory = conversations[ci]
        var assistant = ChatMessage(role: .assistant, content: "")
        assistant.modelName = "\(backend.modelName) • MCP"
        var conversation = conversations[ci]
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        conversations[ci] = conversation
        let messageID = assistant.id
        beginStreaming(messageID: messageID)

        let prompt = """
            The MCP tool \(requestLabel) returned this result:

            \(resultText)

            Use this result to continue. If another MCP tool call is needed to fully answer, \
            call it now; otherwise answer the user's original request. Original request:
            \(originalPrompt)
            """

        switch backend {
        case .local(let modelID, _):
            Task { @MainActor [weak self] in
                guard let self, self.cancellationGeneration == generation else { return }
                let systemInstructions = await self.mcpEnrichedSystemPrompt(for: liveHistory)
                guard self.cancellationGeneration == generation else { return }
                self.engine.generate(
                    conversation: self.historyWithMCPInstructions(
                        liveHistory, mcpSystemPrompt: systemInstructions),
                    prompt: prompt,
                    images: images,
                    settings: self.settings,
                    systemInstructions: systemInstructions,
                    targetModelID: modelID,
                onChunk: { [weak self] delta in
                    guard self?.cancellationGeneration == generation else { return }
                    self?.enqueueStreamDelta(
                        delta, conversationID: conversationID, messageID: messageID)
                },
                onComplete: { [weak self] info, errorMessage in
                    guard let self, self.cancellationGeneration == generation else { return }
                    self.finishStreamBuffer(messageID)
                    self.appendToMessage(conversationID: conversationID, messageID: messageID) {
                        if let info {
                            $0.tokensPerSecond = info.tokensPerSecond
                            $0.generationTokenCount = info.generationTokenCount
                            $0.promptTokenCount = info.promptTokenCount
                            $0.promptTime = info.promptTime
                        }
                        if let errorMessage {
                            if $0.content.isEmpty {
                                $0.content = "⚠️ \(errorMessage)"
                                $0.isError = true
                            } else {
                                $0.content += "\n\n⚠️ MCP follow-up interrupted: \(errorMessage)"
                            }
                        }
                    }
                    self.endStreaming(messageID: messageID)
                    self.scheduleSave()
                    // Close the loop: re-scan the follow-up for another tool call. The depth
                    // cap in handleMCPToolRequestIfNeeded is the only thing that ends the chain.
                    Task { @MainActor in
                        await self.handleMCPToolRequestIfNeeded(
                            backend: backend,
                            originalPrompt: originalPrompt,
                            images: images,
                            conversationID: conversationID,
                            messageID: messageID,
                            mcpDepth: mcpDepth,
                            cancellationGeneration: generation)
                    }
                })
            }
        case .claude(let modelID):
            streamClaude(
                model: modelID,
                history: liveHistory,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                images: images,
                cancellationGeneration: generation,
                mcpDepth: mcpDepth,
                mcpOriginalPrompt: originalPrompt)
        case .openRouter(let modelID):
            streamOpenRouter(
                model: modelID,
                history: liveHistory,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                images: images,
                cancellationGeneration: generation,
                mcpDepth: mcpDepth,
                mcpOriginalPrompt: originalPrompt)
        case .openAI(let modelID):
            streamOpenAI(
                model: modelID,
                history: liveHistory,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                images: images,
                cancellationGeneration: generation,
                mcpDepth: mcpDepth,
                mcpOriginalPrompt: originalPrompt)
        case .zai(let modelID):
            streamZAI(
                model: modelID,
                history: liveHistory,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                images: [],
                cancellationGeneration: generation,
                mcpDepth: mcpDepth,
                mcpOriginalPrompt: originalPrompt)
        }
    }

    private func isMCPToolEnabled(_ request: MCPCallRequest) -> Bool {
        let serverID = mcp.resolveEntryID(request.serverID)
        let canonicalTool = Self.canonicalizeMCPToolName(request.toolName, serverID: serverID)
        return mcp.selectedPromptTools().contains(where: {
            $0.serverID == serverID && $0.tool.name == canonicalTool
        })
    }

    private func messageContent(conversationID: UUID, messageID: UUID) -> String? {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID })
        else { return nil }
        if let live = streamingTextByMessageID[messageID], !live.isEmpty {
            return live
        }
        return conversations[ci].messages[mi].content
    }

    private func beginStreaming(messageID: UUID) {
        streamingMessageIDs.insert(messageID)
        streamingMessageID = messageID
        streamingTextByMessageID[messageID] = ""
        streamingReasoningByMessageID[messageID] = ""
        invalidReasoningStreamMessageIDs.remove(messageID)
    }

    private func endStreaming(messageID: UUID) {
        streamingMessageIDs.remove(messageID)
        if streamingMessageID == messageID {
            streamingMessageID = streamingMessageIDs.first
        }
        streamingTextByMessageID.removeValue(forKey: messageID)
        streamingReasoningByMessageID.removeValue(forKey: messageID)
        invalidReasoningStreamMessageIDs.remove(messageID)
        if smartPromptSelectionActive {
            applySmartSelectedPromptIfPresent(messageID: messageID)
        }
    }

    // MARK: - Prompt enhancement (wand button)

    private(set) var isEnhancingPrompt = false

    /// Rewrites the current composer draft into a clearer, more effective prompt
    /// using an available cloud model, replacing the composer text in place.
    func enhanceComposerPrompt() {
        let draft = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !isEnhancingPrompt else { return }
        let system = """
            You are a prompt engineer. Rewrite the user's draft into a clearer, more \
            specific, more effective prompt for an AI assistant. Preserve the intent, \
            facts, and any file paths or names exactly. Return ONLY the rewritten \
            prompt — no preamble, no commentary, no markdown fences.
            """
        isEnhancingPrompt = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isEnhancingPrompt = false }
            do {
                var enhanced = ""
                if let key = SecretsStore.anthropicAPIKey, !key.isEmpty {
                    try await AnthropicClient(apiKey: key).stream(
                        model: claudeModelID ?? AnthropicClient.models[0].id,
                        system: system,
                        messages: [.init(role: "user", text: draft)],
                        config: AnthropicStreamConfig(reasoningEnabled: false, maxTokens: 4096)
                    ) { delta in
                        if case .content(let text) = delta { enhanced += text }
                    }
                } else if let key = SecretsStore.openRouterAPIKey, !key.isEmpty {
                    enhanced = try await OpenRouterClient(apiKey: key).complete(
                        model: openRouterModelIDs.first ?? OpenRouterClient.defaultModelID,
                        system: system,
                        messages: [.init(role: "user", text: draft)],
                        config: OpenRouterStreamConfig(reasoningEnabled: false, maxTokens: 4096))
                } else {
                    if let id = selectedConversation?.id {
                        appendSystemMessage(
                            conversationID: id,
                            content: "Prompt enhancer needs an Anthropic or OpenRouter API key (Settings ⌘,)."
                        )
                    }
                    return
                }
                let cleaned = enhanced
                    .replacingOccurrences(of: "``", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    self.composerText = cleaned
                }
            } catch {
                if let id = selectedConversation?.id {
                    appendSystemMessage(
                        conversationID: id,
                        content: "Prompt enhancer failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Smart prompt selection

    /// True while a Smart Select turn is in flight — completed replies are
    /// scanned for a FORGE_PROMPT_BEGIN/END block to install.
    private(set) var smartPromptSelectionActive = false

    /// Searches the prompt_database index and sends the candidates to the
    /// active model, which picks or combines/redrafts and returns the final
    /// system prompt between FORGE_PROMPT_BEGIN/END markers.
    func startSmartPromptSelection(task: String, goals: String, notes: String) {
        guard let database = SmartPromptDB.databaseDirectory(promptDirectories: promptDirectories)
        else {
            if let id = selectedConversation?.id {
                appendSystemMessage(
                    conversationID: id,
                    content:
                        "Smart Select: no prompt_database folder found next to a registered prompt directory (expected <root>/prompt_database/search.py)."
                )
            }
            return
        }
        let query = [task, goals, notes]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = await SmartPromptDB.search(query: query, database: database)
            let instruction = Self.smartPromptInstruction(
                task: task, goals: goals, notes: notes, candidates: candidates)
            self.smartPromptSelectionActive = true
            self.composerText = instruction
            if self.canSend {
                self.send()
            }
        }
    }

    private static func smartPromptInstruction(
        task: String, goals: String, notes: String, candidates: [SmartPromptCandidate]
    ) -> String {
        let brief = """
            Choose the best system prompt for the work below from the user's prompt library.

            Task: \(task)
            Goals: \(goals.isEmpty ? "—" : goals)
            Notes: \(notes.isEmpty ? "—" : notes)
            """
        let listing: String
        if candidates.isEmpty {
            listing = "No library candidates matched the keyword search — draft one from scratch."
        } else {
            listing = candidates.enumerated().map { index, candidate in
                """
                [\(index + 1)] \(candidate.title) — \(candidate.description)
                ---
                \(candidate.body)
                ---
                """
            }.joined(separator: "\n")
        }
        return """
            \(brief)

            Candidate prompts (ranked by keyword search over the library):
            \(listing)

            Instructions:
            - Pick the single best candidate, or combine and redraft several into one \
            prompt (the library includes prompt-engineering prompts — apply their \
            techniques when redrafting).
            - If none fit well, say so and ask whether to draft a combined/custom one.
            - If you need more information to choose well, ask concise questions and \
            STOP — do not output the markers yet.
            - When ready, output the final system prompt between these exact markers:
            FORGE_PROMPT_BEGIN
            <final system prompt>
            FORGE_PROMPT_END
            - After the markers, add one short line explaining the choice.
            Forge installs the text between the markers as the active system prompt \
            automatically.
            """
    }

    /// Installs a FORGE_PROMPT_BEGIN/END block from a finished reply as the
    /// active system prompt (Smart Select flow).
    private func applySmartSelectedPromptIfPresent(messageID: UUID) {
        guard let ci = conversations.firstIndex(where: { conversation in
            conversation.messages.contains { $0.id == messageID }
        }) else { return }
        let conversationID = conversations[ci].id
        guard let content = messageContent(conversationID: conversationID, messageID: messageID),
            let begin = content.range(of: "FORGE_PROMPT_BEGIN"),
            let end = content.range(of: "FORGE_PROMPT_END", range: begin.upperBound..<content.endIndex)
        else { return }
        let prompt = String(content[begin.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        smartPromptSelectionActive = false
        lastPromptContent = prompt
        applySystemPrompt(prompt, externalLabel: "Smart Select")
        if var conversation = selectedConversation, conversation.id == conversationID {
            conversation.systemPrompt = prompt
            selectedConversation = conversation
        }
        appendSystemMessage(
            conversationID: conversationID,
            content: "Smart Select: installed the drafted system prompt (\(prompt.count) chars) as the active system prompt."
        )
        scheduleSave()
    }

    private func appendSystemMessage(conversationID: UUID, content: String) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        var conversation = conversations[ci]
        conversation.messages.append(ChatMessage(role: .system, content: content))
        conversation.updatedAt = Date()
        conversations[ci] = conversation
    }

    private static func parseMCPCallRequest(from content: String) -> MCPCallRequest? {
        // Never treat hidden reasoning as an instruction to execute a process or
        // network tool. Only explicit Forge call formats in visible answer text
        // are executable; arbitrary JSON in prose is data, not authority.
        let visible = content.replacingOccurrences(
            of: #"(?is)<think\b[^>]*>.*?</think>"#,
            with: "",
            options: .regularExpression)
            .replacingOccurrences(
                of: #"(?is)<think\b[^>]*>.*$"#,
                with: "",
                options: .regularExpression)
        if let marker = visible.range(of: "FORGE_MCP_CALL"),
           let request = parseMCPCallJSONObject(from: String(visible[marker.upperBound...]))
        {
            return request
        }
        if let request = parseMCPInvokeXML(from: visible) { return request }
        if let request = parseMCPDisplayFormat(from: visible) { return request }
        return nil
    }

    /// Parses the transcript display format Forge itself writes for executed calls
    /// ("MCP request: `server.tool`" followed by a JSON arguments block). Models
    /// see that format in their own history and imitate it on the next call instead
    /// of emitting FORGE_MCP_CALL — without this parser the agent loop silently
    /// stops the moment a model copies the display format.
    private static func parseMCPDisplayFormat(from content: String) -> MCPCallRequest? {
        guard let labelRange = content.range(
            of: #"MCP request:\s*`([^`\n]+)`"#, options: .regularExpression)
        else { return nil }
        let label = String(content[labelRange])
        guard let firstTick = label.firstIndex(of: "`"),
              let lastTick = label.lastIndex(of: "`"),
              firstTick < lastTick
        else { return nil }
        let rawName = String(label[label.index(after: firstTick)..<lastTick])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = rawName.firstIndex(of: ".") else { return nil }
        let serverID = String(rawName[..<dot])
        let toolName = canonicalizeMCPToolName(
            String(rawName[rawName.index(after: dot)...]), serverID: serverID)
        guard !serverID.isEmpty, !toolName.isEmpty else { return nil }
        // Require an actual arguments object after the label so prose that merely
        // mentions a past request ("the MCP request: `x.y` failed") doesn't fire.
        let tail = String(content[labelRange.upperBound...])
        guard let json = firstJSONObject(in: tail),
              let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                as? [String: Any]
        else { return nil }
        return MCPCallRequest(serverID: serverID, toolName: toolName, arguments: arguments)
    }

    private static func parseMCPCallJSONObject(from text: String) -> MCPCallRequest? {
        guard let jsonText = firstJSONObject(in: text),
              let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))
                as? [String: Any]
        else { return nil }

        let server =
            (object["server"] as? String)
            ?? (object["serverID"] as? String)
            ?? (object["entry"] as? String)
            ?? ""
        let tool =
            (object["tool"] as? String)
            ?? (object["name"] as? String)
            ?? (object["toolName"] as? String)
            ?? ""
        let arguments =
            (object["arguments"] as? [String: Any])
            ?? object.filter { !["server", "serverID", "entry", "tool", "name", "toolName"].contains($0.key) }
        let serverID = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = canonicalizeMCPToolName(
            tool.trimmingCharacters(in: .whitespacesAndNewlines),
            serverID: serverID)
        guard !serverID.isEmpty, !toolName.isEmpty else { return nil }
        return MCPCallRequest(serverID: serverID, toolName: toolName, arguments: arguments)
    }

    /// Parses `<invoke name="desktop-commander.read_file">` and `<parameter name="path">` blocks.
    private static func parseMCPInvokeXML(from content: String) -> MCPCallRequest? {
        guard let invokeStart = content.range(of: "<invoke"),
              let nameRange = content[invokeStart.lowerBound...].range(
                of: #"name="([^"]+)""#, options: .regularExpression)
        else { return nil }

        let nameMatch = String(content[nameRange])
        guard let quoted = nameMatch.split(separator: "\"").dropFirst().first else { return nil }
        let rawName = String(quoted)
        let serverID: String
        let toolName: String
        if let dot = rawName.firstIndex(of: ".") {
            serverID = String(rawName[..<dot])
            toolName = String(rawName[rawName.index(after: dot)...])
        } else {
            serverID = "desktop-commander"
            toolName = rawName
        }

        var arguments: [String: Any] = [:]
        var searchStart = invokeStart.upperBound
        while let paramStart = content[searchStart...].range(of: "<parameter"),
              let close = content[paramStart.lowerBound...].range(of: "</parameter>")
        {
            let block = String(content[paramStart.lowerBound..<close.upperBound])
            if let keyRange = block.range(of: #"name="([^"]+)""#, options: .regularExpression),
               let valueStart = block.range(of: ">"),
               let valueEnd = block.range(of: "</parameter>")
            {
                let keyMatch = String(block[keyRange])
                if let key = keyMatch.split(separator: "\"").dropFirst().first {
                    let value = String(block[valueStart.upperBound..<valueEnd.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    arguments[String(key)] = value
                }
            }
            searchStart = close.upperBound
            if let invokeEnd = content[invokeStart.lowerBound...].range(of: "</invoke>"),
               searchStart >= invokeEnd.lowerBound
            {
                break
            }
        }

        guard !serverID.isEmpty, !toolName.isEmpty else { return nil }
        return MCPCallRequest(serverID: serverID, toolName: toolName, arguments: arguments)
    }

    private static func canonicalizeMCPToolName(_ raw: String, serverID: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let prefix = "\(serverID)."
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        guard let lastDot = trimmed.lastIndex(of: ".") else { return trimmed }
        return String(trimmed[trimmed.index(after: lastDot)...])
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func readableMCPResult(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(decoding: data, as: UTF8.self)
        }
        if let dict = object as? [String: Any] {
            if let content = dict["content"] as? [[String: Any]] {
                let text = content.compactMap { item in
                    item["text"] as? String
                }.joined(separator: "\n\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            if let structured = dict["structuredContent"] {
                return prettyJSONString(structured)
            }
        }
        return prettyJSONString(object)
    }

    private static func prettyJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func clippedForPrompt(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max))
    }

    /// Unload and reload with the fast standard MLX loader (use after bounded/deferred).
    func reloadModelStandard(_ model: LocalModel) {
        engine.unload(model.id)
        engine.loadAndActivate(model, policy: .eager)
        scheduleSave()
    }

    /// Ordered quit path — drain MLX/GGUF before the process tears down Metal.
    func shutdownForQuit() async {
        stopGenerating()
        if case .running = server.state { server.stop() }
        await engine.shutdown()
        saveNow()
    }

    func stopGenerating() {
        cancellationGeneration &+= 1
        flushAllStreamBuffers()
        engine.stop()
        claudeTask?.cancel()
        openRouterTasks.values.forEach { $0.cancel() }
        openRouterTasks.removeAll()
        openAITask?.cancel()
        zaiRunControl?.stop()
        zaiRunControl = nil
        zaiTask?.cancel()
        zaiTask = nil
        braveSearchTask?.cancel()
        braveSearchTask = nil
        isClaudeGenerating = false
        isOpenRouterGenerating = false
        isOpenAIGenerating = false
        isZAIGenerating = false
        isBraveSearchGenerating = false
        streamingMessageID = nil
        streamingMessageIDs.removeAll()
        streamingTextByMessageID.removeAll()
        streamingReasoningByMessageID.removeAll()
        streamReasoningBuffers.removeAll()
        invalidReasoningStreamMessageIDs.removeAll()
        scheduleSave()
    }

    private func appendToMessage(
        conversationID: UUID, messageID: UUID, mutate: (inout ChatMessage) -> Void
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var conversation = conversations[ci]
        guard let mi = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(&conversation.messages[mi])
        conversation.updatedAt = Date()
        conversations[ci] = conversation
    }

    private func enqueueStreamDelta(
        _ delta: InferenceStreamDelta, conversationID: UUID, messageID: UUID
    ) {
        guard streamingMessageIDs.contains(messageID) else { return }
        streamBufferConversationIDs[messageID] = conversationID

        var appendedText = false
        switch delta {
        case .reasoning(let text):
            guard !text.isEmpty else { return }
            streamReasoningBuffers[messageID, default: ""] += text
            appendedText = true
        case .content(let text):
            guard !text.isEmpty else { return }
            streamBuffers[messageID, default: ""] += text
            appendedText = true
        case .invalidReasoningStructure:
            invalidReasoningStreamMessageIDs.insert(messageID)
        }

        guard appendedText else { return }
        guard streamFlushTasks[messageID] == nil else { return }
        streamFlushTasks[messageID] = Task { [weak self] in
            // Batch UI updates — rewriting conversations every flush blocked scroll input.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.flushStreamBuffer(messageID)
        }
    }

    private func flushStreamBuffer(_ messageID: UUID) {
        streamFlushTasks[messageID]?.cancel()
        streamFlushTasks[messageID] = nil
        if let reasoning = streamReasoningBuffers.removeValue(forKey: messageID),
            !reasoning.isEmpty
        {
            streamingReasoningByMessageID[messageID, default: ""] += reasoning
        }
        guard let delta = streamBuffers.removeValue(forKey: messageID), !delta.isEmpty else {
            return
        }
        streamingTextByMessageID[messageID, default: ""] += delta
    }

    private func finishStreamBuffer(_ messageID: UUID) {
        streamFlushTasks[messageID]?.cancel()
        streamFlushTasks[messageID] = nil
        let reasoningStructureValid =
            invalidReasoningStreamMessageIDs.remove(messageID) == nil
        if let reasoning = streamReasoningBuffers.removeValue(forKey: messageID),
            !reasoning.isEmpty
        {
            streamingReasoningByMessageID[messageID, default: ""] += reasoning
        }
        if let delta = streamBuffers.removeValue(forKey: messageID), !delta.isEmpty {
            streamingTextByMessageID[messageID, default: ""] += delta
        }
        guard let conversationID = streamBufferConversationIDs[messageID] else {
            streamingTextByMessageID.removeValue(forKey: messageID)
            streamingReasoningByMessageID.removeValue(forKey: messageID)
            return
        }
        let reasoning = streamingReasoningByMessageID[messageID] ?? ""
        let content = streamingTextByMessageID[messageID] ?? ""
        appendToMessage(conversationID: conversationID, messageID: messageID) {
            // Persist reasoning and visible content separately; only content is
            // replayed into later model turns.
            $0.reasoning = reasoning
            $0.reasoningStructureValid = reasoningStructureValid
            $0.content = content
        }
        streamBufferConversationIDs[messageID] = nil
    }

    private func flushAllStreamBuffers() {
        for messageID in Array(streamBufferConversationIDs.keys) {
            finishStreamBuffer(messageID)
        }
        for task in streamFlushTasks.values {
            task.cancel()
        }
        streamFlushTasks.removeAll()
    }

    // MARK: - Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        Persistence.save(
            state: PersistedState(
                conversations: conversations,
                selectedConversationID: selectedConversationID))
        Persistence.save(
            settings: PersistedSettings(
                generation: settings,
                promptPresets: promptPresets,
                extraModelDirectories: store.extraDirectories.map(\.path),
                extraModelDirectoryBookmarks: store.extraDirectories.compactMap {
                    directoryBookmarks[$0]
                },
                promptDirectories: promptDirectories.map(\.path),
                promptDirectoryBookmarks: promptDirectories.compactMap {
                    promptDirectoryBookmarks[$0]
                },
                commanderDirectories: commanderDirectories.map(\.path),
                commanderDirectoryBookmarks: commanderDirectories.compactMap {
                    commanderDirectoryBookmarks[$0]
                },
                lastPromptContent: lastPromptContent,
                activePromptPresetID: activePromptPresetID,
                activePromptExternalLabel: activePromptExternalLabel,
                serverEnabled: serverEnabled,
                serverPort: serverPort,
                serverExposeToNetwork: serverExposeToNetwork))
    }

    /// Helper for photo review via MCP (strict list item).
    /// Takes image attachments (typically from pendingImages or a message's attachedImageData),
    /// base64-encodes the first, finds a suitable connected MCP server (prefers ones with
    /// "photo"/"vision"/"review"/"image" in id), calls the tool "review_photo" with the image
    /// under "image_base64" + a query, then appends the result as a .system message.
    ///
    /// Example call (from chat or button):
    /// await app.reviewAttachedPhotoWithMCP(using: someImageDatas)
    ///
    /// Pairs with MCP server configured like:
    /// { "mcpServers": { "photo-review": { "url": "http://127.0.0.1:8765" } } }
    /// where the server implements tool "review_photo" expecting "image_base64".
    func reviewAttachedPhotoWithMCP(using imageData: [Data]) async {
        guard let firstImage = imageData.first else {
            composerText = "Attach a photo first (photo button), then press review."
            return
        }

        // Prefer a connected MCP tool that actually reviews images — match on
        // TOOL names, not server ids (no configured server ships `review_photo`).
        let visionTool = mcp.selectedConnectedTools().first { binding in
            let name = binding.tool.name.lowercased()
            return name.contains("photo") || name.contains("vision")
                || (name.contains("image") && (name.contains("review") || name.contains("describe")))
        }

        if let visionTool {
            do {
                let resultData = try await mcp.callTool(
                    entryID: visionTool.serverID,
                    name: visionTool.tool.name,
                    arguments: [
                        "image_base64": firstImage.base64EncodedString(),
                        "query": "Provide a detailed review and description of this photo."
                    ]
                )
                let resultString = String(data: resultData, encoding: .utf8) ?? "<binary result>"
                guard var current = selectedConversation else { return }
                current.messages.append(ChatMessage(
                    role: .system,
                    content: "MCP Photo Review via \(visionTool.id):\n\(resultString)"
                ))
                selectedConversation = current
                scheduleSave()
                return
            } catch {
                // Fall through to the model-based review below.
            }
        }

        // No vision MCP tool — review with whatever model is selected (cloud
        // clients and local VLMs all accept attached image data now).
        composerText =
            "Review the attached photo in detail: describe the contents, notable details, and transcribe any visible text."
        send(images: imageData)
    }
}
