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

    private enum CodingKeys: String, CodingKey {
        case conversations, selectedConversationID
    }

    init(conversations: [Conversation] = [], selectedConversationID: UUID? = nil) {
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        selectedConversationID = try c.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
    }
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
    /// Last selected prompt content from the library (auto-applied to new conversations).
    var lastPromptContent: String = ""
    /// Saved preset id when the inspector prompt matches a named preset.
    var activePromptPresetID: UUID?
    /// Display label when the prompt came from a file/library pick (not a saved preset).
    var activePromptExternalLabel: String?
    var serverEnabled = false
    var serverPort = 3737
    /// Serve the API on all interfaces (LAN) instead of loopback only.
    var serverExposeToNetwork = false

    init(
        generation: GenerationSettings = GenerationSettings(),
        promptPresets: [PromptPreset] = [],
        extraModelDirectories: [String] = [],
        extraModelDirectoryBookmarks: [Data] = [],
        promptDirectories: [String] = [],
        promptDirectoryBookmarks: [Data] = [],
        lastPromptContent: String = "",
        activePromptPresetID: UUID? = nil,
        activePromptExternalLabel: String? = nil,
        serverEnabled: Bool = false,
        serverPort: Int = 3737,
        serverExposeToNetwork: Bool = false
    ) {
        self.generation = generation
        self.promptPresets = promptPresets
        self.extraModelDirectories = extraModelDirectories
        self.extraModelDirectoryBookmarks = extraModelDirectoryBookmarks
        self.promptDirectories = promptDirectories
        self.promptDirectoryBookmarks = promptDirectoryBookmarks
        self.lastPromptContent = lastPromptContent
        self.activePromptPresetID = activePromptPresetID
        self.activePromptExternalLabel = activePromptExternalLabel
        self.serverEnabled = serverEnabled
        self.serverPort = serverPort
        self.serverExposeToNetwork = serverExposeToNetwork
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
        lastPromptContent = (try? c.decodeIfPresent(String.self, forKey: .lastPromptContent)) ?? ""
        activePromptPresetID = try? c.decodeIfPresent(UUID.self, forKey: .activePromptPresetID)
        activePromptExternalLabel =
            (try? c.decodeIfPresent(String.self, forKey: .activePromptExternalLabel)).flatMap { $0 }
        serverEnabled =
            (try? c.decodeIfPresent(Bool.self, forKey: .serverEnabled)).flatMap { $0 } ?? false
        serverPort =
            (try? c.decodeIfPresent(Int.self, forKey: .serverPort)).flatMap { $0 } ?? 3737
        serverExposeToNetwork =
            (try? c.decodeIfPresent(Bool.self, forKey: .serverExposeToNetwork))
            .flatMap { $0 } ?? false
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
        let url = ForgePaths.conversationsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedState()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            preserveCorruptFile(at: url)
            return PersistedState()
        }
    }

    static func save(state: PersistedState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: ForgePaths.conversationsFile, options: .atomic)
    }

    static func loadSettings() -> PersistedSettings {
        let url = ForgePaths.settingsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedSettings()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(PersistedSettings.self, from: data)
        } catch {
            preserveCorruptFile(at: url)
            return PersistedSettings()
        }
    }

    static func save(settings: PersistedSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: ForgePaths.settingsFile, options: .atomic)
    }

    /// App startup may immediately save default state after a decode failure.
    /// Preserve the unreadable source first so that recovery remains possible.
    private static func preserveCorruptFile(at url: URL) {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let filename = ext.isEmpty
            ? "\(stem).corrupt-\(suffix)"
            : "\(stem).corrupt-\(suffix).\(ext)"
        let backup = url.deletingLastPathComponent().appendingPathComponent(filename)
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
