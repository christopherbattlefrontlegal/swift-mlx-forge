// Forge — JSON persistence for conversations and settings.
// Stored under ~/Library/Application Support/Forge/.

import Foundation

enum ForgePaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Managed model download root (HubCache layout: models--org--name/…).
    static var modelsRoot: URL {
        let dir = appSupport.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var conversationsFile: URL {
        appSupport.appendingPathComponent("conversations.json")
    }

    static var settingsFile: URL {
        appSupport.appendingPathComponent("settings.json")
    }

    /// User-editable MCP server list. Always under Application Support so launch
    /// never blocks on an external dev volume path baked into Info.plist.
    static var mcpConfigFile: URL {
        appSupport.appendingPathComponent("mcp.json")
    }
}

struct PersistedState: Codable {
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
}

/// A named, reusable system prompt shown in the inspector's preset menu.
struct PromptPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String
}

struct PersistedSettings: Codable {
    var generation = GenerationSettings()
    var promptPresets: [PromptPreset] = []
    var extraModelDirectories: [String] = []
    /// Security-scoped bookmarks for the user-added directories. Under the App
    /// Sandbox a plain path string grants no access after relaunch; the bookmark
    /// is what lets the next launch actually read the folder.
    var extraModelDirectoryBookmarks: [Data] = []
    /// User prompt folders for the chat prompt library (e.g. awesome-prompts style collections).
    /// Stored with bookmarks for sandbox persistence.
    var promptDirectories: [String] = []
    var promptDirectoryBookmarks: [Data] = []
    /// Workspace folders exposed to the built-in Forge commander MCP tools.
    /// Stored with bookmarks so sandboxed builds retain explicit user grants.
    var commanderDirectories: [String] = []
    var commanderDirectoryBookmarks: [Data] = []
    /// Last selected prompt content from the library (auto-applied to new conversations).
    var lastPromptContent: String = ""
    var lastLoadedModelPath: String?
    var loadedModelPaths: [String] = []
    var serverEnabled = false
    var serverPort = 3737

    init(
        generation: GenerationSettings = GenerationSettings(),
        promptPresets: [PromptPreset] = [],
        extraModelDirectories: [String] = [],
        extraModelDirectoryBookmarks: [Data] = [],
        promptDirectories: [String] = [],
        promptDirectoryBookmarks: [Data] = [],
        commanderDirectories: [String] = [],
        commanderDirectoryBookmarks: [Data] = [],
        lastPromptContent: String = "",
        lastLoadedModelPath: String? = nil,
        loadedModelPaths: [String] = [],
        serverEnabled: Bool = false,
        serverPort: Int = 3737
    ) {
        self.generation = generation
        self.promptPresets = promptPresets
        self.extraModelDirectories = extraModelDirectories
        self.extraModelDirectoryBookmarks = extraModelDirectoryBookmarks
        self.promptDirectories = promptDirectories
        self.promptDirectoryBookmarks = promptDirectoryBookmarks
        self.commanderDirectories = commanderDirectories
        self.commanderDirectoryBookmarks = commanderDirectoryBookmarks
        self.lastPromptContent = lastPromptContent
        self.lastLoadedModelPath = lastLoadedModelPath
        self.loadedModelPaths = loadedModelPaths
        self.serverEnabled = serverEnabled
        self.serverPort = serverPort
    }

    // Tolerant decoding: a settings file written by an older (or newer) build
    // must never wipe the user's configuration over a missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation =
            (try? c.decodeIfPresent(GenerationSettings.self, forKey: .generation))
            .flatMap { $0 } ?? GenerationSettings()
        promptPresets =
            (try? c.decodeIfPresent([PromptPreset].self, forKey: .promptPresets))
            .flatMap { $0 } ?? []
        extraModelDirectories =
            (try? c.decodeIfPresent([String].self, forKey: .extraModelDirectories))
            .flatMap { $0 } ?? []
        extraModelDirectoryBookmarks =
            (try? c.decodeIfPresent([Data].self, forKey: .extraModelDirectoryBookmarks))
            .flatMap { $0 } ?? []
        promptDirectories =
            (try? c.decodeIfPresent([String].self, forKey: .promptDirectories))
            .flatMap { $0 } ?? []
        promptDirectoryBookmarks =
            (try? c.decodeIfPresent([Data].self, forKey: .promptDirectoryBookmarks))
            .flatMap { $0 } ?? []
        commanderDirectories =
            (try? c.decodeIfPresent([String].self, forKey: .commanderDirectories))
            .flatMap { $0 } ?? []
        commanderDirectoryBookmarks =
            (try? c.decodeIfPresent([Data].self, forKey: .commanderDirectoryBookmarks))
            .flatMap { $0 } ?? []
        lastPromptContent = (try? c.decodeIfPresent(String.self, forKey: .lastPromptContent)) ?? ""
        lastLoadedModelPath = try? c.decodeIfPresent(String.self, forKey: .lastLoadedModelPath)
        loadedModelPaths =
            (try? c.decodeIfPresent([String].self, forKey: .loadedModelPaths))
            .flatMap { $0 } ?? []
        serverEnabled =
            (try? c.decodeIfPresent(Bool.self, forKey: .serverEnabled)).flatMap { $0 } ?? false
        serverPort =
            (try? c.decodeIfPresent(Int.self, forKey: .serverPort)).flatMap { $0 } ?? 3737
    }
}

enum Persistence {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: ForgePaths.conversationsFile),
            let state = try? decoder.decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    static func save(state: PersistedState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: ForgePaths.conversationsFile, options: .atomic)
    }

    static func loadSettings() -> PersistedSettings {
        guard let data = try? Data(contentsOf: ForgePaths.settingsFile),
            let settings = try? decoder.decode(PersistedSettings.self, from: data)
        else { return PersistedSettings() }
        return settings
    }

    static func save(settings: PersistedSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: ForgePaths.settingsFile, options: .atomic)
    }
}
