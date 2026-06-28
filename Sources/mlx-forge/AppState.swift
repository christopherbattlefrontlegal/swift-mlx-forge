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

    private var claudeSelected: Bool { (claudeModelID?.isEmpty == false) }
    private var openRouterSelected: Bool { !openRouterModelIDs.isEmpty }
    private var openAISelected: Bool { (openAIModelID?.isEmpty == false) }
    private var braveSearchSelected: Bool { braveSearchEnabled }
    /// Anything currently producing tokens (local OR Claude).
    var isBusy: Bool {
        engine.isGenerating || engine.isLoadingAnything || engine.materializingModelID != nil
            || isClaudeGenerating || isOpenRouterGenerating || isOpenAIGenerating
            || !inFlightAgentLabels.isEmpty
            || isMCPRunning || isCodingOrchestratorRunning || isBraveSearchGenerating
    }
    /// Whether a chat target is selected.
    var canChat: Bool {
        engine.activeModel != nil || claudeSelected || openRouterSelected || openAISelected
            || braveSearchSelected
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

    private func assignOpenRouterModelIDs(_ ids: [String]) {
        let normalized = Self.uniqueModelIDs(ids)
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

    var codingOrchestratorConfig: CodingOrchestratorConfig = {
        let modelID =
            UserDefaults.standard.string(forKey: "codingOrchestrator.modelID")
            ?? "qwen/qwen3-coder"
        let rounds = UserDefaults.standard.integer(forKey: "codingOrchestrator.maxRounds")
        return CodingOrchestratorConfig(
            modelID: modelID,
            maxRounds: rounds > 0 ? rounds : 3)
    }() {
        didSet {
            UserDefaults.standard.set(codingOrchestratorConfig.modelID, forKey: "codingOrchestrator.modelID")
            UserDefaults.standard.set(codingOrchestratorConfig.maxRounds, forKey: "codingOrchestrator.maxRounds")
        }
    }

    private(set) var isCodingOrchestratorRunning = false
    private(set) var codingOrchestratorPhase = ""
    private var codingOrchestratorTask: Task<Void, Never>?

    func runCodingOrchestrator(task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasOpenRouterKey, let key = SecretsStore.openRouterAPIKey else { return }
        guard var conversation = selectedConversation else { return }

        conversation.messages.append(ChatMessage(role: .user, content: trimmed))
        var assistant = ChatMessage(role: .assistant, content: "# Code loop\n\nStarting…\n")
        assistant.modelName = "Code loop · \(OpenRouterClient.label(for: codingOrchestratorConfig.modelID))"
        conversation.messages.append(assistant)
        conversation.refreshTitle()
        conversation.updatedAt = Date()
        selectedConversation = conversation

        let convID = conversation.id
        let messageID = assistant.id
        let config = codingOrchestratorConfig
        let client = OpenRouterClient(apiKey: key)

        isCodingOrchestratorRunning = true
        codingOrchestratorPhase = "Starting"
        codingOrchestratorTask?.cancel()
        codingOrchestratorTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isCodingOrchestratorRunning = false
                    self.codingOrchestratorPhase = ""
                    self.codingOrchestratorTask = nil
                    self.scheduleSave()
                }
            }
            do {
                _ = try await CodingOrchestrator.run(
                    task: trimmed,
                    config: config,
                    client: client,
                    onPhaseStart: { round, phase in
                        self.codingOrchestratorPhase = "R\(round) · \(phase.title)"
                    },
                    onPhaseComplete: { _, _, _ in },
                    onAppend: { chunk in
                        self.appendToMessage(conversationID: convID, messageID: messageID) {
                            $0.content += chunk
                        }
                    })
            } catch is CancellationError {
                self.appendToMessage(conversationID: convID, messageID: messageID) {
                    $0.content += "\n\n⏹ Code loop stopped.\n"
                }
            } catch {
                self.appendToMessage(conversationID: convID, messageID: messageID) {
                    $0.content += "\n\n⚠️ Code loop error: \(error.localizedDescription)\n"
                    $0.isError = true
                }
            }
        }
        scheduleSave()
    }

    func stopCodingOrchestrator() {
        codingOrchestratorTask?.cancel()
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

    // MARK: - Multi-agent dispatch (bottom advanced space)
    /// Lightweight target for clicking an agent button in the composer advanced area.
    /// Numbered locals for "model 1 / agent 1 do X" style orchestration + all Claude options.
    enum AgentTarget: Equatable, Hashable {
        case local(modelID: String, number: Int, shortName: String)
        case claude(modelID: String, label: String)
        case openRouter(modelID: String, label: String)
    }

    /// Currently streaming agent replies (messageID -> display label like "1.Qwen 3.6 40B" or "Claude Sonnet 4.6").
    /// Used for monitoring strip in the bottom composer area and to keep isBusy correct.
    private(set) var inFlightAgentLabels: [UUID: String] = [:]
    private var agentTasks: [UUID: Task<Void, Never>] = [:]

    var serverEnabled = false {
        didSet {
            guard oldValue != serverEnabled else { return }
            if serverEnabled {
                server.start(port: UInt16(clamping: serverPort))
            } else {
                server.stop()
            }
            scheduleSave()
        }
    }
    var serverPort = 3737 {
        didSet {
            guard oldValue != serverPort else { return }
            if serverEnabled { server.start(port: UInt16(clamping: serverPort)) }
            scheduleSave()
        }
    }

    var showModelBrowser = false
    var showLauncher = false
    var showInspector = true
    var showHeadlessHelper = false
    var showDesignPrompt = false

    var composerText = ""

    /// ID of the assistant message currently being streamed, if any.
    private(set) var streamingMessageID: UUID?

    private var saveTask: Task<Void, Never>?
    private var streamBuffers: [UUID: String] = [:]
    private var streamBufferConversationIDs: [UUID: UUID] = [:]
    private var streamFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var activeMCPCallCount = 0

    private var isMCPRunning: Bool { activeMCPCallCount > 0 }

    private enum ResponseBackend {
        case local(modelID: String, label: String)
        case claude(modelID: String)
        case openRouter(modelID: String)
        case openAI(modelID: String)

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
        server.defaultSettings = { [weak self] in self?.settings ?? GenerationSettings() }
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
        serverEnabled = persistedSettings.serverEnabled
        if serverEnabled {
            server.start(port: UInt16(clamping: serverPort))
        }

        assignOpenRouterModelIDs(openRouterModelIDs)
        refreshPrompts()
    }

    private var didBeginMCP = false

    /// Deferred past first frame so AppState init never blocks the window or Dock flame.
    func beginMCP() {
        guard !didBeginMCP else { return }
        didBeginMCP = true
        mcp.start()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            self?.mcp.connectAvailableServers()
        }
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

    /// Active system instructions for UI delineation and new turns.
    func effectiveSystemPrompt(for conversation: Conversation) -> String {
        baseSystemPrompt(for: conversation)
    }

    private var cloudReasoningEffort: CloudReasoningEffort {
        CloudReasoningEffort(rawValue: settings.anthropicEffort) ?? .high
    }

    private var anthropicStreamConfig: AnthropicStreamConfig {
        AnthropicStreamConfig(
            reasoningEnabled: settings.reasoningEnabled,
            effort: Self.anthropicEffort(from: cloudReasoningEffort),
            thinkingSummarized: settings.anthropicThinkingSummarized,
            maxTokens: settings.maxTokens > 0 ? settings.maxTokens : 8192)
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
        - After Forge returns the MCP result in the chat, answer the user using that result.
        """
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return base + "\n\n" + instruction
    }

    // MARK: - Sending

    var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if claudeSelected || openRouterSelected || openAISelected || braveSearchSelected {
            guard !isBusy && hasText else { return false }
            if claudeSelected && !hasAnthropicKey { return false }
            if openRouterSelected && !hasOpenRouterKey { return false }
            if openAISelected && !hasOpenAIKey { return false }
            if braveSearchSelected && !hasBraveSearchKey { return false }
            return true
        }
        return engine.activeModel != nil && !isBusy && hasText
    }

    func send(images: [Data] = []) {
        guard canSend, var conversation = selectedConversation else { return }
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        composerText = ""

        // Snapshot history BEFORE appending the new user message — the provider
        // re-hydrates from this and sends `prompt` as the new turn.
        let historySnapshot = conversation

        var userMessage = ChatMessage(role: .user, content: prompt)
        userMessage.attachedImageData = images
        conversation.messages.append(userMessage)

        if claudeSelected || openRouterSelected || openAISelected || braveSearchSelected {
            let selectedModels = openRouterModelIDs
            var openRouterTargets: [(modelID: String, messageID: UUID)] = []
            var claudeTarget: (modelID: String, messageID: UUID)?
            var openAITarget: (modelID: String, messageID: UUID)?
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
                ?? (braveSearchSelected ? "brave" : nil)
            selectedConversation = conversation

            let conversationID = conversation.id
            streamingMessageID =
                braveTarget ?? openAITarget?.messageID ?? openRouterTargets.last?.messageID
                ?? claudeTarget?.messageID
            if let claudeTarget {
                streamClaude(
                    model: claudeTarget.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: claudeTarget.messageID)
            }
            for target in openRouterTargets {
                streamOpenRouter(
                    model: target.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: target.messageID)
            }
            if let openAITarget {
                streamOpenAI(
                    model: openAITarget.modelID, history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: openAITarget.messageID)
            }
            if let braveTarget {
                streamBraveSearch(
                    history: historySnapshot, prompt: prompt,
                    conversationID: conversationID, messageID: braveTarget)
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
        streamingMessageID = messageID

        if let claudeID = claudeModelID, !claudeID.isEmpty {
            // Images for Claude vision require richer Message content (array of text+image blocks).
            // For now we send the text prompt (the token in composer makes it visible).
            // Full support + MCP photo tool call with base64 can be layered next.
            streamClaude(
                model: claudeID, history: historySnapshot, prompt: prompt,
                conversationID: conversationID, messageID: messageID)
            scheduleSave()
            return
        }

        let activeModelID = engine.activeModel?.id
        let activeModelLabel = engine.activeModel.map { localModelLabel($0.model) } ?? "Local"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let systemInstructions = await self.mcpEnrichedSystemPrompt(for: historySnapshot)
            let generationHistory = self.historyWithMCPInstructions(
                historySnapshot, mcpSystemPrompt: systemInstructions)
            self.engine.generate(
                conversation: generationHistory,
                prompt: prompt,
                images: images,
                settings: self.settings,
                systemInstructions: systemInstructions,
                onChunk: { [weak self] delta in
                    self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
                },
                onComplete: { [weak self] info, errorMessage in
                    guard let self else { return }
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
                    self.streamingMessageID = nil
                    self.scheduleSave()
                    if let activeModelID {
                        Task { @MainActor in
                            await self.handleMCPToolRequestIfNeeded(
                                backend: .local(modelID: activeModelID, label: activeModelLabel),
                                history: historySnapshot,
                                originalPrompt: prompt,
                                images: images,
                                conversationID: conversationID,
                                messageID: messageID)
                        }
                    }
                })
        }
        scheduleSave()
    }

    /// Dispatch the (already mode-tagged) prompt to one specific agent target.
    /// Supports clicking multiple agent buttons for parallel (Claude) or batched (local) execution.
    /// Each gets its own labeled assistant bubble. Uses the pre-dispatch snapshot + prompt
    /// so all agents on the same task see identical prior context (no cross-agent pollution on first turn).
    /// Follow-up clicks (empty composer) re-use the last user task prompt and current transcript
    /// (new agent sees prior agent outputs as context — useful for synthesis).
    func dispatchToAgent(prompt: String, target: AgentTarget, images: [Data] = []) {
        guard var conversation = selectedConversation else { return }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }

        // Snapshot before any user append for this dispatch batch. All agent backends use this + p.
        let preSnapshot = conversation

        let lastUser = conversation.messages.last(where: { $0.role == .user })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isFollowUp = (lastUser == p)

        if !isFollowUp {
            // Originating task for one or more agents: record it once in the transcript.
            var userMessage = ChatMessage(role: .user, content: p)
            userMessage.attachedImageData = images
            conversation.messages.append(userMessage)
            conversation.refreshTitle()
            conversation.updatedAt = Date()
            selectedConversation = conversation
        }

        // Append this agent's response placeholder (labeled for monitoring and UI).
        var assistant = ChatMessage(role: .assistant, content: "")
        let (label, claudeID, openRouterID, localID): (String, String?, String?, String?)
        switch target {
        case .local(let mid, let num, let short):
            label = "\(num).\(short)"
            claudeID = nil
            openRouterID = nil
            localID = mid
            assistant.modelName = label
        case .claude(let mid, let lab):
            label = lab
            claudeID = mid
            openRouterID = nil
            localID = nil
            assistant.modelName = "Agent • \(lab)"
        case .openRouter(let mid, let lab):
            label = lab
            claudeID = nil
            openRouterID = mid
            localID = nil
            assistant.modelName = "Agent • \(lab)"
        }
        conversation.messages.append(assistant)
        let messageID = assistant.id
        conversation.lastModelID = localID ?? claudeID ?? openRouterID ?? conversation.lastModelID
        selectedConversation = conversation

        inFlightAgentLabels[messageID] = label

        let convID = conversation.id

        // Fire the backend work. Claudes run concurrently; locals serialize inside the engine gate.
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.finishStreamBuffer(messageID)
                    self.inFlightAgentLabels.removeValue(forKey: messageID)
                    self.agentTasks.removeValue(forKey: messageID)
                    self.scheduleSave()
                }
            }
            if let cid = claudeID {
                await self.runClaudeAgentStream(
                    model: cid,
                    history: preSnapshot,
                    prompt: p,
                    conversationID: convID,
                    messageID: messageID
                )
            } else if let oid = openRouterID {
                await self.runOpenRouterAgentStream(
                    model: oid,
                    history: preSnapshot,
                    prompt: p,
                    conversationID: convID,
                    messageID: messageID
                )
            } else if let mid = localID {
                let systemInstructions = await self.mcpEnrichedSystemPrompt(for: preSnapshot)
                self.engine.generate(
                    conversation: self.historyWithMCPInstructions(
                        preSnapshot, mcpSystemPrompt: systemInstructions),
                    prompt: p,
                    images: images,
                    settings: self.settings,
                    systemInstructions: systemInstructions,
                    targetModelID: mid,
                    onChunk: { [weak self] delta in
                        self?.enqueueStreamDelta(delta, conversationID: convID, messageID: messageID)
                    },
                    onComplete: { [weak self] info, errMsg in
                        guard let self else { return }
                        self.finishStreamBuffer(messageID)
                        self.appendToMessage(conversationID: convID, messageID: messageID) {
                            if let info {
                                $0.tokensPerSecond = info.tokensPerSecond
                                $0.generationTokenCount = info.generationTokenCount
                                $0.promptTokenCount = info.promptTokenCount
                                $0.promptTime = info.promptTime
                            }
                            if let errMsg {
                                if $0.content.isEmpty {
                                    $0.content = "⚠️ \(errMsg)"
                                    $0.isError = true
                                } else {
                                    $0.content += "\n\n⚠️ agent interrupted: \(errMsg)"
                                }
                            }
                        }
                    }
                )
            }
        }
        agentTasks[messageID] = work
        scheduleSave()
    }

    /// Thin wrapper around the Anthropic client for an agent-specific stream (no singular claude flags).
    private func runClaudeAgentStream(
        model: String,
        history: Conversation,
        prompt: String,
        conversationID: UUID,
        messageID: UUID
    ) async {
        guard let key = SecretsStore.anthropicAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No Anthropic API key — add one in Settings (⌘,)."
                $0.isError = true
            }
            return
        }
        var msgs: [AnthropicClient.Message] = history.messages.compactMap { m in
            switch m.role {
            case .user: return .init(role: "user", text: m.content)
            case .assistant: return (m.content.isEmpty || m.isErrorMessage) ? nil : .init(role: "assistant", text: m.content)
            case .system: return nil
            }
        }
        msgs.append(.init(role: "user", text: prompt))
        let sys = await mcpEnrichedSystemPrompt(for: history)
        let client = AnthropicClient(apiKey: key)
        do {
            try await client.stream(
                model: model, system: sys, messages: msgs,
                config: anthropicStreamConfig
            ) { [weak self] delta in
                self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
            }
        } catch is CancellationError {
            // user stopped
        } catch {
            finishStreamBuffer(messageID)
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                if $0.content.isEmpty {
                    $0.content = "⚠️ \(error.localizedDescription)"
                    $0.isError = true
                } else {
                    $0.content += "\n\n⚠️ agent stream interrupted: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runOpenRouterAgentStream(
        model: String,
        history: Conversation,
        prompt: String,
        conversationID: UUID,
        messageID: UUID
    ) async {
        guard let key = SecretsStore.openRouterAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No OpenRouter API key — add one in Settings (⌘,)."
                $0.isError = true
            }
            return
        }
        var msgs: [OpenRouterClient.Message] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                return (message.content.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: message.content)
            case .system:
                return nil
            }
        }
        msgs.append(.init(role: "user", text: prompt))
        let sys = await mcpEnrichedSystemPrompt(for: history)
        let client = OpenRouterClient(apiKey: key)
        do {
            try await client.stream(
                model: model,
                system: sys,
                messages: msgs,
                config: openRouterStreamConfig,
                sessionID: conversationID.uuidString
            ) { [weak self] delta in
                self?.enqueueStreamDelta(delta, conversationID: conversationID, messageID: messageID)
            }
        } catch is CancellationError {
            // user stopped
        } catch {
            finishStreamBuffer(messageID)
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                if $0.content.isEmpty {
                    $0.content = "⚠️ \(error.localizedDescription)"
                    $0.isError = true
                } else {
                    $0.content += "\n\n⚠️ OpenRouter agent interrupted: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Routes a chat turn to the Anthropic API and streams deltas into the message.
    private func streamClaude(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        allowMCPFollowup: Bool = true
    ) {
        guard let key = SecretsStore.anthropicAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No Anthropic API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isClaudeGenerating = false
            streamingMessageID = nil
            return
        }

        var messages: [AnthropicClient.Message] = history.messages.compactMap { m in
            switch m.role {
            case .user: return .init(role: "user", text: m.content)
            case .assistant:
                // Skip empty placeholders and our own error notices — replaying a
                // "⚠️ …" bubble as an assistant turn poisons later context.
                return (m.content.isEmpty || m.isErrorMessage)
                    ? nil : .init(role: "assistant", text: m.content)
            case .system: return nil
            }
        }
        messages.append(.init(role: "user", text: prompt))
        let client = AnthropicClient(apiKey: key)

        isClaudeGenerating = true
        claudeTask = Task { [weak self] in
            let system: String
            if allowMCPFollowup {
                system = await self?.mcpEnrichedSystemPrompt(for: history)
                    ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            } else {
                system = self?.systemPrompt(for: history, includeMCP: false) ?? ""
            }
            do {
                try await client.stream(
                    model: model, system: system, messages: messages,
                    config: self?.anthropicStreamConfig ?? AnthropicStreamConfig()
                ) { delta in
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
            self?.finishStreamBuffer(messageID)
            self?.isClaudeGenerating = false
            if self?.streamingMessageID == messageID {
                self?.streamingMessageID = nil
            }
            if allowMCPFollowup {
                _ = await self?.handleMCPToolRequestIfNeeded(
                    backend: .claude(modelID: model),
                    history: history,
                    originalPrompt: prompt,
                    images: [],
                    conversationID: conversationID,
                    messageID: messageID)
            }
            self?.scheduleSave()
        }
    }

    /// Routes a chat turn to OpenRouter and streams deltas into the message.
    private func streamOpenRouter(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        allowMCPFollowup: Bool = true
    ) {
        guard let key = SecretsStore.openRouterAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No OpenRouter API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isOpenRouterGenerating = false
            streamingMessageID = nil
            return
        }

        var messages: [OpenRouterClient.Message] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                return (message.content.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: message.content)
            case .system:
                return nil
            }
        }
        messages.append(.init(role: "user", text: prompt))
        let client = OpenRouterClient(apiKey: key)

        isOpenRouterGenerating = true
        openRouterTasks[messageID] = Task { [weak self] in
            let system: String
            if allowMCPFollowup {
                system = await self?.mcpEnrichedSystemPrompt(for: history)
                    ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            } else {
                system = self?.systemPrompt(for: history, includeMCP: false) ?? ""
            }
            do {
                try await client.stream(
                    model: model,
                    system: system,
                    messages: messages,
                    config: self?.openRouterStreamConfig ?? OpenRouterStreamConfig(),
                    sessionID: conversationID.uuidString
                ) { delta in
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
            self?.finishStreamBuffer(messageID)
            self?.openRouterTasks.removeValue(forKey: messageID)
            self?.isOpenRouterGenerating = self?.openRouterTasks.isEmpty == false
            if self?.streamingMessageID == messageID {
                self?.streamingMessageID = nil
            }
            if allowMCPFollowup {
                _ = await self?.handleMCPToolRequestIfNeeded(
                    backend: .openRouter(modelID: model),
                    history: history,
                    originalPrompt: prompt,
                    images: [],
                    conversationID: conversationID,
                    messageID: messageID)
            }
            self?.scheduleSave()
        }
    }

    /// Routes a chat turn to the OpenAI Responses API and streams deltas into the message.
    private func streamOpenAI(
        model: String, history: Conversation, prompt: String,
        conversationID: UUID, messageID: UUID,
        allowMCPFollowup: Bool = true
    ) {
        guard let key = SecretsStore.openAIAPIKey, !key.isEmpty else {
            appendToMessage(conversationID: conversationID, messageID: messageID) {
                $0.content = "⚠️ No OpenAI API key set — add one in Settings (⌘,)."
                $0.isError = true
            }
            isOpenAIGenerating = false
            streamingMessageID = nil
            return
        }

        var turns: [OpenAIClient.Turn] = history.messages.compactMap { message in
            switch message.role {
            case .user:
                return .init(role: "user", text: message.content)
            case .assistant:
                return (message.content.isEmpty || message.isErrorMessage)
                    ? nil : .init(role: "assistant", text: message.content)
            case .system:
                return nil
            }
        }
        turns.append(.init(role: "user", text: prompt))
        let client = OpenAIClient(apiKey: key)

        isOpenAIGenerating = true
        openAITask = Task { [weak self] in
            let system: String
            if allowMCPFollowup {
                system = await self?.mcpEnrichedSystemPrompt(for: history)
                    ?? self?.systemPrompt(for: history, includeMCP: false) ?? ""
            } else {
                system = self?.systemPrompt(for: history, includeMCP: false) ?? ""
            }
            do {
                try await client.stream(
                    model: model,
                    system: system,
                    turns: turns,
                    config: self?.openAIStreamConfig ?? OpenAIStreamConfig()
                ) { delta in
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
            self?.finishStreamBuffer(messageID)
            self?.isOpenAIGenerating = false
            if self?.streamingMessageID == messageID {
                self?.streamingMessageID = nil
            }
            if allowMCPFollowup {
                _ = await self?.handleMCPToolRequestIfNeeded(
                    backend: .openAI(modelID: model),
                    history: history,
                    originalPrompt: prompt,
                    images: [],
                    conversationID: conversationID,
                    messageID: messageID)
            }
            self?.scheduleSave()
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
            if streamingMessageID == messageID { streamingMessageID = nil }
            return
        }

        let client = BraveAnswersClient(apiKey: key, config: braveSearchConfig)
        var citations: [BraveCitation] = []

        isBraveSearchGenerating = true
        braveSearchTask?.cancel()
        braveSearchTask = Task { [weak self] in
            do {
                try await client.stream(
                    query: prompt,
                    onChunk: { delta in
                        self?.enqueueStreamDelta(
                            delta, conversationID: conversationID, messageID: messageID)
                    },
                    onCitation: { citation in
                        citations.append(citation)
                    },
                    onUsage: { _ in }
                )
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
            if self?.streamingMessageID == messageID {
                self?.streamingMessageID = nil
            }
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

    @discardableResult
    private func handleMCPToolRequestIfNeeded(
        backend: ResponseBackend,
        history: Conversation,
        originalPrompt: String,
        images: [Data],
        conversationID: UUID,
        messageID: UUID
    ) async -> Bool {
        guard let content = messageContent(conversationID: conversationID, messageID: messageID),
              var request = Self.parseMCPCallRequest(from: content)
        else { return false }

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

        guard isMCPToolEnabled(request) else {
            let enabled = mcp.selectedTools(for: request.serverID)
                .sorted()
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
            let data = try await mcp.callTool(
                entryID: request.serverID,
                name: request.toolName,
                arguments: request.arguments)
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
                history: history,
                originalPrompt: originalPrompt,
                images: images,
                requestLabel: requestLabel,
                resultText: resultText,
                conversationID: conversationID)
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
        history: Conversation,
        originalPrompt: String,
        images: [Data],
        requestLabel: String,
        resultText: String,
        conversationID: UUID
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var assistant = ChatMessage(role: .assistant, content: "")
        assistant.modelName = "\(backend.modelName) • MCP"
        var conversation = conversations[ci]
        conversation.messages.append(assistant)
        conversation.updatedAt = Date()
        conversations[ci] = conversation
        let messageID = assistant.id
        streamingMessageID = messageID

        let prompt = """
            The MCP tool \(requestLabel) returned this result:

            \(resultText)

            Answer the user's original request using the MCP result. Original request:
            \(originalPrompt)
            """

        switch backend {
        case .local(let modelID, _):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let systemInstructions = await self.mcpEnrichedSystemPrompt(for: history)
                self.engine.generate(
                    conversation: self.historyWithMCPInstructions(
                        history, mcpSystemPrompt: systemInstructions),
                    prompt: prompt,
                    images: images,
                    settings: self.settings,
                    systemInstructions: systemInstructions,
                    targetModelID: modelID,
                onChunk: { [weak self] delta in
                    self?.enqueueStreamDelta(
                        delta, conversationID: conversationID, messageID: messageID)
                },
                onComplete: { [weak self] info, errorMessage in
                    guard let self else { return }
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
                    self.streamingMessageID = nil
                    self.scheduleSave()
                })
            }
        case .claude(let modelID):
            streamClaude(
                model: modelID,
                history: history,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                allowMCPFollowup: false)
        case .openRouter(let modelID):
            streamOpenRouter(
                model: modelID,
                history: history,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                allowMCPFollowup: false)
        case .openAI(let modelID):
            streamOpenAI(
                model: modelID,
                history: history,
                prompt: prompt,
                conversationID: conversationID,
                messageID: messageID,
                allowMCPFollowup: false)
        }
    }

    private func isMCPToolEnabled(_ request: MCPCallRequest) -> Bool {
        let serverID = mcp.resolveEntryID(request.serverID)
        let canonicalTool = Self.canonicalizeMCPToolName(request.toolName, serverID: serverID)
        if mcp.selectedPromptTools().contains(where: {
            $0.serverID == serverID && $0.tool.name == canonicalTool
        }) {
            return true
        }
        return mcp.tools(for: serverID).contains { $0.name == canonicalTool }
    }

    private func messageContent(conversationID: UUID, messageID: UUID) -> String? {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID })
        else { return nil }
        return conversations[ci].messages[mi].content
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
        if let marker = content.range(of: "FORGE_MCP_CALL"),
           let request = parseMCPCallJSONObject(from: String(content[marker.upperBound...]))
        {
            return request
        }
        if let request = parseMCPInvokeXML(from: content) { return request }
        if let request = parseMCPCallJSONObject(from: content) { return request }
        return nil
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
        flushAllStreamBuffers()
        engine.stop()
        claudeTask?.cancel()
        openRouterTasks.values.forEach { $0.cancel() }
        openRouterTasks.removeAll()
        openAITask?.cancel()
        braveSearchTask?.cancel()
        braveSearchTask = nil
        isClaudeGenerating = false
        isOpenRouterGenerating = false
        isOpenAIGenerating = false
        isBraveSearchGenerating = false
        streamingMessageID = nil
        stopCodingOrchestrator()
        // Cancel any parallel agent dispatches (locals are also covered by engine.stop via gate).
        for t in agentTasks.values { t.cancel() }
        agentTasks.removeAll()
        inFlightAgentLabels.removeAll()
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
        _ delta: String, conversationID: UUID, messageID: UUID
    ) {
        guard !delta.isEmpty else { return }
        streamBufferConversationIDs[messageID] = conversationID
        streamBuffers[messageID, default: ""] += delta
        guard streamFlushTasks[messageID] == nil else { return }
        streamFlushTasks[messageID] = Task { [weak self] in
            // Batch UI updates — sub-100ms flushes reparsed markdown on the main thread per token.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.flushStreamBuffer(messageID)
        }
    }

    private func flushStreamBuffer(_ messageID: UUID) {
        streamFlushTasks[messageID]?.cancel()
        streamFlushTasks[messageID] = nil
        guard let delta = streamBuffers.removeValue(forKey: messageID),
              !delta.isEmpty,
              let conversationID = streamBufferConversationIDs[messageID]
        else { return }
        appendToMessage(conversationID: conversationID, messageID: messageID) {
            $0.content += delta
        }
    }

    private func finishStreamBuffer(_ messageID: UUID) {
        flushStreamBuffer(messageID)
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
                lastLoadedModelPath: nil,
                loadedModelPaths: [],
                serverEnabled: serverEnabled,
                serverPort: serverPort))
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
            composerText = "No image data to review."
            return
        }
        let base64 = firstImage.base64EncodedString()

        // Find suitable connected entry per the spec.
        let connected = mcp.entries.filter { if case .connected = $0.status { return true }; return false }
        guard let suitable = connected.first(where: { entry in
            let idLower = entry.id.lowercased()
            return idLower.contains("photo") || idLower.contains("vision") || idLower.contains("review") || idLower.contains("image")
        }) ?? connected.first else {
            composerText = "No connected MCP server found. Add one in Settings > MCP Servers (HTTP/SSE only)."
            return
        }

        do {
            let resultData = try await mcp.callTool(
                entryID: suitable.id,
                name: "review_photo",
                arguments: [
                    "image_base64": base64,
                    "query": "Provide a detailed review and description of this photo."
                ]
            )
            let resultString = String(data: resultData, encoding: .utf8) ?? "<binary result>"

            // Append as system message so it shows in the chat transcript.
            guard var current = selectedConversation else { return }
            let resultMsg = ChatMessage(
                role: .system,
                content: "MCP Photo Review via \(suitable.id):\n\(resultString)"
            )
            current.messages.append(resultMsg)
            selectedConversation = current
            scheduleSave()
        } catch {
            composerText = "MCP photo review call failed: \(error.localizedDescription)"
        }
    }
}
