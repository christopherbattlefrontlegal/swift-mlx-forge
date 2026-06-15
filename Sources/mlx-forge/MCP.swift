// Forge — MCP (Model Context Protocol) server configuration + HTTP client.
//
// MCP servers are loaded from the local `mcp.json` if present, then
// fallen back to `~/Library/Application Support/Forge/mcp-servers.json`.
// using the same shape as Claude Desktop's config file. Saving the file applies
// immediately (the manager watches it). HTTP(S) transports connect in-process;
// "command" entries launch stdio MCP servers in the developer build.

import Foundation
import Observation

// MARK: - Config file

/// One entry under "mcpServers". Either `url` (HTTP/SSE transport) or
/// `command`+`args` (stdio transport).
struct MCPServerConfig: Codable {
    var url: String?
    var headers: [String: String]?
    var command: String?
    var args: [String]?
    var env: [String: String]?
}

struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig] = [:]
}

struct MCPTool: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let description: String
}

struct MCPToolBinding: Identifiable, Hashable, Sendable {
    let serverID: String
    let tool: MCPTool

    var id: String { "\(serverID).\(tool.name)" }
}

enum MCPError: LocalizedError {
    case badResponse
    case http(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Malformed response from MCP server."
        case .http(let code): return "HTTP \(code) from MCP server."
        case .server(let message): return message
        }
    }
}

// MARK: - Manager

@MainActor
@Observable
final class MCPManager {

    enum Status: Equatable {
        case disabled
        case connecting
        case connected(tools: [MCPTool])
        case failed(String)
    }

    struct Entry: Identifiable {
        let id: String  // key in the "mcpServers" dictionary
        let config: MCPServerConfig
        var status: Status
        let builtIn: Bool

        var isBuiltIn: Bool { builtIn }

        /// Short transport label for the UI: host for url entries, the command
        /// line for stdio entries.
        var transport: String {
            if isBuiltIn { return "Built in workspace tools" }
            if let url = config.url { return URL(string: url)?.host ?? url }
            if let command = config.command {
                return ([command] + (config.args ?? [])).joined(separator: " ")
            }
            return "—"
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var lastLoaded: Date?
    private(set) var selectedToolsByServer: [String: [String]] = [:] {
        didSet { UserDefaults.standard.set(selectedToolsByServer, forKey: "mcp.selectedTools") }
    }
    var commanderRoots: [URL] = [] {
        didSet { reload() }
    }

    /// `mcp.json` is useful during local development while `mcp-servers.json` keeps
    /// portable settings for installed runs.
    static var projectConfigFile: URL {
        resolveProjectConfigFile()
    }

    /// Kept for migration/recovery if this file is unavailable.
    static var configFile: URL {
        ForgePaths.appSupport.appendingPathComponent("mcp-servers.json")
    }

    static var legacySandboxConfigFile: URL {
        URL(filePath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.forge.mlx/Data/Library/Application Support/Forge/mcp-servers.json")
    }

    nonisolated fileprivate static let commanderID = "desktop-commander"

    private var watcher: DispatchSourceFileSystemObject?
    private var disabledServerIDs = Set(
        UserDefaults.standard.stringArray(forKey: "mcp.disabledServers") ?? []
    ) {
        didSet {
            UserDefaults.standard.set(Array(disabledServerIDs).sorted(), forKey: "mcp.disabledServers")
        }
    }

    init() {
        selectedToolsByServer = Self.loadSelectedTools()
    }

    func start() {
        ensureTemplate()
        reload()
        watch()
    }

    /// Choose a writable and portable config location.
    private static func resolveProjectConfigFile() -> URL {
        let candidates = discoverCandidateProjectConfigPaths()
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }

        let localDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.isWritableFile(atPath: localDir.path) {
            return localDir.appendingPathComponent("mcp.json")
        }
        return configFile
    }

    private static func discoverCandidateProjectConfigPaths() -> [URL] {
        var roots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let parent = current.deletingLastPathComponent()
        if parent != current {
            roots.append(parent)
        }
        if parent != FileManager.default.homeDirectoryForCurrentUser {
            let ancestor = parent.deletingLastPathComponent()
            if ancestor != parent {
                roots.append(ancestor)
            }
        }
        return roots.map { $0.appendingPathComponent("mcp.json") }
    }

    /// First launch: write an empty config so there's a file to edit.
    private func ensureTemplate() {
        let url = Self.projectConfigFile
        if loadConfig(at: url) != nil { return }
        if let legacy = try? Data(contentsOf: Self.legacySandboxConfigFile),
           (try? JSONDecoder().decode(MCPConfigFile.self, from: legacy)) != nil {
            try? legacy.write(to: url, options: .atomic)
            return
        }
        let template = "{\n  \"mcpServers\": {\n  }\n}\n"
        try? template.data(using: .utf8)?.write(to: url)
    }

    func reload() {
        var allServers: [String: MCPServerConfig] = [:]

        if let file = loadConfig(at: Self.projectConfigFile) {
            allServers.merge(file.mcpServers) { _, new in new }
        }
        lastLoaded = Date()
        var nextEntries: [Entry] = []
        if allServers[Self.commanderID] == nil {
            configureDefaultTool(for: Self.commanderID, tools: BuiltinCommander.tools)
            nextEntries.append(
                Entry(
                    id: Self.commanderID,
                    config: MCPServerConfig(url: nil, headers: nil, command: nil, args: nil, env: nil),
                    status: isServerEnabled(Self.commanderID) ? .connected(tools: BuiltinCommander.tools) : .disabled,
                    builtIn: true))
        }
        nextEntries += allServers.keys.sorted().map {
            Entry(
                id: $0,
                config: allServers[$0]!,
                status: isServerEnabled($0) ? .connecting : .disabled,
                builtIn: false)
        }
        entries = nextEntries
        for entry in entries {
            guard !entry.isBuiltIn else { continue }
            guard isServerEnabled(entry.id) else { continue }
            if let urlString = entry.config.url {
                connect(
                    entryID: entry.id, urlString: urlString,
                    headers: entry.config.headers ?? [:])
            } else if let command = entry.config.command {
                connectStdio(
                    entryID: entry.id,
                    command: command,
                    args: entry.config.args ?? [],
                    env: entry.config.env ?? [:])
            } else {
                setStatus(entry.id, .failed("entry needs a \"url\" or \"command\" field"))
            }
        }
    }

    @discardableResult
    func addHTTPServer(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Server name is required." }
        guard trimmedName.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[]:,\"'")) == nil
        else { return "Use a simple server name without JSON punctuation." }
        guard let url = URL(string: trimmedURL), Self.isAllowedTransport(url) else {
            return "URL must be https, or plain http on loopback only."
        }

        var file = loadPrimaryConfig()
        file.mcpServers[trimmedName] = MCPServerConfig(
            url: trimmedURL, headers: nil, command: nil, args: nil, env: nil)
        savePrimaryConfig(file)
        reload()
        return nil
    }

    func removeServer(name: String) {
        var file = loadPrimaryConfig()
        file.mcpServers.removeValue(forKey: name)
        savePrimaryConfig(file)
        disabledServerIDs.remove(name)
        selectedToolsByServer[name] = nil
        reload()
    }

    func isServerEnabled(_ id: String) -> Bool {
        !disabledServerIDs.contains(id)
    }

    func setServerEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledServerIDs.remove(id)
        } else {
            disabledServerIDs.insert(id)
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            reload()
            return
        }
        let entry = entries[index]
        if enabled {
            entries[index].status = .connecting
            if !entry.isBuiltIn {
                if let urlString = entry.config.url {
                    connect(entryID: entry.id, urlString: urlString, headers: entry.config.headers ?? [:])
                } else if let command = entry.config.command {
                    connectStdio(entryID: entry.id, command: command, args: entry.config.args ?? [], env: entry.config.env ?? [:])
                } else {
                    entries[index].status = .failed("entry needs a \"url\" or \"command\" field")
                }
            } else {
                entries[index].status = .connected(tools: BuiltinCommander.tools)
            }
        } else {
            entries[index].status = .disabled
        }
    }

    func tools(for entryID: String) -> [MCPTool] {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return [] }
        if case .connected(let tools) = entry.status { return tools }
        return []
    }

    func selectedTool(for entryID: String) -> String? {
        selectedToolsByServer[entryID]?.first
    }

    func selectedTools(for entryID: String) -> [String] {
        selectedToolsByServer[entryID] ?? []
    }

    func setSelectedTool(_ toolName: String, for entryID: String) {
        let value = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedToolsByServer[entryID] = value.isEmpty ? nil : [value]
    }

    func setTool(_ toolName: String, enabled: Bool, for entryID: String) {
        let value = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var selected = Set(selectedToolsByServer[entryID] ?? [])
        if enabled {
            selected.insert(value)
        } else {
            selected.remove(value)
        }
        selectedToolsByServer[entryID] = selected.isEmpty ? nil : selected.sorted()
    }

    func setAllTools(_ enabled: Bool, for entryID: String) {
        if enabled {
            let names = tools(for: entryID).map(\.name)
            selectedToolsByServer[entryID] = names.isEmpty ? nil : names
        } else {
            selectedToolsByServer[entryID] = nil
        }
    }

    func isToolSelected(_ toolName: String, for entryID: String) -> Bool {
        selectedToolsByServer[entryID]?.contains(toolName) == true
    }

    func selectedConnectedTools() -> [MCPToolBinding] {
        entries.flatMap { entry -> [MCPToolBinding] in
            guard isServerEnabled(entry.id),
                  case .connected(let tools) = entry.status
            else { return [] }
            let selected = Set(selectedToolsByServer[entry.id] ?? [])
            return tools
                .filter { selected.contains($0.name) }
                .map { MCPToolBinding(serverID: entry.id, tool: $0) }
        }
    }

    private func setStatus(_ id: String, _ status: Status) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
        }
    }

    private func connect(entryID: String, urlString: String, headers: [String: String]) {
        guard let url = URL(string: urlString), Self.isAllowedTransport(url) else {
            setStatus(entryID, .failed("URL must be https, or plain http on loopback only"))
            return
        }
        Task {
            do {
                let tools = try await MCPHTTPClient(endpoint: url, extraHeaders: headers)
                    .listTools()
                self.configureDefaultTool(for: entryID, tools: tools)
                self.setStatus(entryID, .connected(tools: tools))
            } catch {
                self.setStatus(entryID, .failed(error.localizedDescription))
            }
        }
    }

    private func connectStdio(
        entryID: String, command: String, args: [String], env: [String: String]
    ) {
        Task {
            do {
                let tools = try await MCPStdioClient(command: command, args: args, env: env)
                    .listTools()
                self.configureDefaultTool(for: entryID, tools: tools)
                self.setStatus(entryID, .connected(tools: tools))
            } catch {
                self.setStatus(entryID, .failed(error.localizedDescription))
            }
        }
    }

    private func configureDefaultTool(for entryID: String, tools: [MCPTool]) {
        let toolNames = tools.map(\.name)
        guard !toolNames.isEmpty else {
            selectedToolsByServer[entryID] = nil
            return
        }
        if let selected = selectedToolsByServer[entryID] {
            let valid = selected.filter { toolNames.contains($0) }
            if !valid.isEmpty {
                selectedToolsByServer[entryID] = valid
                return
            }
        }
        selectedToolsByServer[entryID] = toolNames
    }

    private static func loadSelectedTools() -> [String: [String]] {
        let raw = UserDefaults.standard.dictionary(forKey: "mcp.selectedTools") ?? [:]
        var result: [String: [String]] = [:]
        for (server, value) in raw {
            if let tools = value as? [String] {
                let cleaned = tools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !cleaned.isEmpty { result[server] = Array(Set(cleaned)).sorted() }
            } else if let tool = value as? String {
                let cleaned = tool.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { result[server] = [cleaned] }
            }
        }
        return result
    }

    /// Invokes a tool on a previously discovered (connected) MCP server entry.
    /// Looks up the config by entryID and performs the call.
    /// Throws if the entry is not an HTTP server or the call fails.
    ///
    /// Returns the raw JSON result as Data (decode with JSONSerialization on the caller side).
    /// This keeps everything Sendable across actor boundaries.
    func callTool(entryID: String, name: String, arguments: [String: Any]) async throws -> Data {
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw MCPError.server("MCP entry '\(entryID)' not found")
        }
        if entry.isBuiltIn {
            return try BuiltinCommander.call(
                name: name, arguments: arguments, roots: effectiveCommanderRoots)
        }
        let normalizedArguments = Self.normalizedArguments(
            arguments, toolName: name, entry: entry)
        let argsPayload = try JSONSerialization.data(withJSONObject: normalizedArguments)
        if let urlString = entry.config.url, let url = URL(string: urlString) {
            let headers = entry.config.headers ?? [:]
            let endpoint = url
            let nameCopy = name
            // Serialize args on the actor, pass only Sendable Data into the detached task.
            return try await Task.detached {
                let args = (try? JSONSerialization.jsonObject(with: argsPayload) as? [String: Any]) ?? [:]
                let client = MCPHTTPClient(endpoint: endpoint, extraHeaders: headers)
                return try await client.callToolReturningData(name: nameCopy, arguments: args)
            }.value
        }

        if let command = entry.config.command {
            return try await MCPStdioClient(
                command: command,
                args: entry.config.args ?? [],
                env: entry.config.env ?? [:]
            ).callToolReturningData(name: name, argumentsData: argsPayload)
        }

        throw MCPError.server("MCP entry '\(entryID)' needs a \"url\" or \"command\" field")
    }

    /// Loopback may be plaintext; anything leaving the machine must be TLS.
    static func isAllowedTransport(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        let host = url.host ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Re-runs `reload()` whenever the config file is written. Editors save
    /// atomically (write + rename), so re-arm on delete/rename to follow the
    /// new inode.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(Self.projectConfigFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let rearm = source.data.contains(.delete) || source.data.contains(.rename)
            self.reload()
            if rearm { self.watch() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func loadPrimaryConfig() -> MCPConfigFile {
        guard let file = loadConfig(at: Self.projectConfigFile) else { return MCPConfigFile() }
        return file
    }

    private func loadConfig(at url: URL) -> MCPConfigFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPConfigFile.self, from: data)
    }

    private func savePrimaryConfig(_ file: MCPConfigFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: Self.projectConfigFile, options: .atomic)
        }
    }

    private var effectiveCommanderRoots: [URL] {
        var roots = [ForgePaths.appSupport]
        for root in commanderRoots where !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    private static func normalizedArguments(
        _ arguments: [String: Any], toolName: String, entry: Entry
    ) -> [String: Any] {
        let commandLine = ([entry.config.command] + (entry.config.args ?? []))
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let usesLegacyPDFReaderSchema =
            commandLine.contains("@shtse8/pdf-reader-mcp")
            || commandLine.contains("@sylphx/pdf-reader-mcp")
        guard toolName == "read_pdf", usesLegacyPDFReaderSchema else { return arguments }

        var result = arguments
        if let path = result["path"] as? String {
            result.removeValue(forKey: "path")
            result["sources"] = [["path": relativeToHome(path)]]
        }
        if let sources = result["sources"] as? [[String: Any]] {
            result["sources"] = sources.map { source in
                var next = source
                if let path = next["path"] as? String {
                    next["path"] = relativeToHome(path)
                }
                return next
            }
        }
        return result
    }

    private static func relativeToHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        let relative = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : relative
    }
}

// MARK: - Built-in desktop-commander tools

private enum BuiltinCommander {
    static let tools: [MCPTool] = [
        MCPTool(
            name: "list_roots",
            description: "List folders available to the built-in Desktop Commander tools."),
        MCPTool(
            name: "list_directory",
            description: "List files in an allowed workspace folder. Arguments: path, limit."),
        MCPTool(
            name: "read_file",
            description: "Read a UTF-8 text file from an allowed workspace. Arguments: path, maxBytes."),
        MCPTool(
            name: "write_file",
            description: "Write UTF-8 text to a file under an allowed workspace. Arguments: path, content, createDirectories."),
        MCPTool(
            name: "search_files",
            description: "Search file and folder names under an allowed workspace. Arguments: path, query, limit."),
        MCPTool(
            name: "get_file_info",
            description: "Return basic metadata for a file or folder under an allowed workspace.")
    ]

    static func call(name: String, arguments: [String: Any], roots: [URL]) throws -> Data {
        switch name {
        case "list_roots":
            return try result(
                rootListText(roots),
                structured: ["roots": roots.map { ["path": $0.path] }])
        case "list_directory":
            let url = try resolve(arguments["path"] as? String ?? ".", roots: roots)
            let limit = cappedInt(arguments["limit"], default: 200, max: 1_000)
            return try listDirectory(url, limit: limit)
        case "read_file":
            let url = try resolve(requiredString(arguments, "path"), roots: roots)
            let maxBytes = cappedInt(arguments["maxBytes"], default: 200_000, max: 1_000_000)
            return try readFile(url, maxBytes: maxBytes)
        case "write_file":
            let url = try resolve(requiredString(arguments, "path"), roots: roots)
            let content = try requiredString(arguments, "content")
            let createDirectories = (arguments["createDirectories"] as? Bool) ?? false
            return try writeFile(url, content: content, createDirectories: createDirectories)
        case "search_files":
            let url = try resolve(arguments["path"] as? String ?? ".", roots: roots)
            let query = try requiredString(arguments, "query")
            let limit = cappedInt(arguments["limit"], default: 100, max: 500)
            return try searchFiles(url, query: query, limit: limit, roots: roots)
        case "get_file_info":
            let url = try resolve(requiredString(arguments, "path"), roots: roots)
            return try fileInfo(url)
        default:
            throw MCPError.server("Unknown built-in commander tool: \(name)")
        }
    }

    private static func listDirectory(_ url: URL, limit: Int) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPError.server("Path is not a directory: \(url.path)")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
        let rows = children.map { child -> [String: Any] in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return [
                "name": child.lastPathComponent,
                "path": child.path,
                "type": values?.isDirectory == true ? "directory" : "file",
                "size": values?.fileSize ?? 0,
                "modified": values?.contentModificationDate?.description ?? ""
            ]
        }
        let text = rows.map { row in
            "\(row["type"] ?? "file")\t\(row["size"] ?? 0)\t\(row["name"] ?? "")"
        }.joined(separator: "\n")
        return try result(text.isEmpty ? "(empty)" : text, structured: ["entries": Array(rows)])
    }

    private static func readFile(_ url: URL, maxBytes: Int) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw MCPError.server("Path is not a readable file: \(url.path)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let truncated = data.count > maxBytes
        let textData = truncated ? data.prefix(maxBytes) : data[...]
        guard let text = String(data: Data(textData), encoding: .utf8) else {
            throw MCPError.server("File is not valid UTF-8 text: \(url.path)")
        }
        return try result(
            text,
            structured: ["path": url.path, "bytesRead": textData.count, "truncated": truncated])
    }

    private static func writeFile(
        _ url: URL, content: String, createDirectories: Bool
    ) throws -> Data {
        guard content.utf8.count <= 1_000_000 else {
            throw MCPError.server("Refusing to write more than 1 MB through built-in commander.")
        }
        let parent = url.deletingLastPathComponent()
        if createDirectories {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        return try result(
            "Wrote \(content.utf8.count) bytes to \(url.path)",
            structured: ["path": url.path, "bytesWritten": content.utf8.count])
    }

    private static func searchFiles(
        _ url: URL, query: String, limit: Int, roots: [URL]
    ) throws -> Data {
        let needle = query.lowercased()
        guard !needle.isEmpty else { throw MCPError.server("query is required") }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { throw MCPError.server("Unable to enumerate: \(url.path)") }

        var hits: [[String: Any]] = []
        for case let item as URL in enumerator {
            guard contains(item, roots: roots) else { continue }
            if item.lastPathComponent.lowercased().contains(needle) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                hits.append([
                    "path": item.path,
                    "name": item.lastPathComponent,
                    "type": values?.isDirectory == true ? "directory" : "file"
                ])
                if hits.count >= limit { break }
            }
        }
        let text = hits.map { "\($0["type"] ?? "file")\t\($0["path"] ?? "")" }
            .joined(separator: "\n")
        return try result(text.isEmpty ? "No matches." : text, structured: ["matches": hits])
    }

    private static func fileInfo(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .isReadableKey, .isWritableKey
        ])
        let info: [String: Any] = [
            "path": url.path,
            "type": values.isDirectory == true ? "directory" : "file",
            "size": values.fileSize ?? 0,
            "created": values.creationDate?.description ?? "",
            "modified": values.contentModificationDate?.description ?? "",
            "readable": values.isReadable ?? false,
            "writable": values.isWritable ?? false
        ]
        let text = info.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return try result(text, structured: info)
    }

    private static func resolve(_ rawPath: String, roots: [URL]) throws -> URL {
        guard !roots.isEmpty else {
            throw MCPError.server("No commander roots are available.")
        }
        let raw = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: URL
        if raw.isEmpty || raw == "." {
            candidate = roots[0]
        } else if raw == "~" {
            candidate = URL(filePath: NSHomeDirectory())
        } else if raw.hasPrefix("~/") {
            candidate = URL(filePath: NSHomeDirectory())
                .appendingPathComponent(String(raw.dropFirst(2)))
        } else if raw.hasPrefix("/") {
            candidate = URL(filePath: raw)
        } else {
            candidate = roots[0].appendingPathComponent(raw)
        }

        let safeURL = candidate.standardizedFileURL
        guard contains(safeURL, roots: roots) else {
            throw MCPError.server(
                "Path is outside allowed commander roots. Add the folder in Settings > MCP Servers.")
        }
        return safeURL
    }

    private static func contains(_ url: URL, roots: [URL]) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private static func requiredString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.server("\(key) is required")
        }
        return value
    }

    private static func cappedInt(_ value: Any?, default defaultValue: Int, max maxValue: Int) -> Int {
        if let int = value as? Int { return min(Swift.max(int, 1), maxValue) }
        if let string = value as? String, let int = Int(string) {
            return min(Swift.max(int, 1), maxValue)
        }
        return defaultValue
    }

    private static func rootListText(_ roots: [URL]) -> String {
        roots.enumerated().map { index, root in "\(index + 1). \(root.path)" }
            .joined(separator: "\n")
    }

    private static func result(_ text: String, structured: [String: Any]) throws -> Data {
        let payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: - Stdio client (Claude Desktop-style command entries)

struct MCPStdioClient: Sendable {
    let command: String
    let args: [String]
    let env: [String: String]

    func listTools() async throws -> [MCPTool] {
        try await Task.detached {
            let session = try StdioSession(command: command, args: args, env: env)
            defer { session.stop() }

            _ = try session.request(
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [String: String](),
                    "clientInfo": ["name": "Forge", "version": "1.0"],
                ])
            try session.notify(method: "notifications/initialized")
            let result = try session.request(
                id: 2, method: "tools/list", params: [String: String]())

            guard let tools = result["tools"] as? [[String: Any]] else { return [] }
            return tools.compactMap { tool in
                guard let name = tool["name"] as? String else { return nil }
                return MCPTool(
                    name: name,
                    description: (tool["description"] as? String) ?? "")
            }
        }.value
    }

    func callToolReturningData(name: String, argumentsData: Data) async throws -> Data {
        let command = command
        let args = args
        let env = env
        return try await Task.detached {
            let callArguments =
                (try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]) ?? [:]
            let session = try StdioSession(command: command, args: args, env: env)
            defer { session.stop() }

            _ = try session.request(
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [String: String](),
                    "clientInfo": ["name": "Forge", "version": "1.0"],
                ])
            try session.notify(method: "notifications/initialized")
            let result = try session.request(
                id: 10,
                method: "tools/call",
                params: ["name": name, "arguments": callArguments])
            return try JSONSerialization.data(withJSONObject: result)
        }.value
    }

    private final class StdioSession: @unchecked Sendable {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let error = Pipe()
        private let lock = NSLock()
        private var outputBuffer = Data()
        private var errorBuffer = Data()

        init(command: String, args: [String], env: [String: String]) throws {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [command] + args
            process.environment = Self.processEnvironment(extra: env)
            process.currentDirectoryURL = URL(filePath: NSHomeDirectory())
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.appendOutput(data)
            }
            error.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.appendError(data)
            }

            do {
                try process.run()
            } catch {
                throw MCPError.server("Unable to launch stdio MCP command '\(command)': \(error.localizedDescription)")
            }
        }

        private static func processEnvironment(extra: [String: String]) -> [String: String] {
            var base = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            let mcpPath = [
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "\(home)/.local/bin",
                "\(home)/.volta/bin",
                "\(home)/.bun/bin",
                "\(home)/.cargo/bin",
                "\(home)/.swiftly/bin",
                "\(home)/.lmstudio/bin",
            ]
            let existing = [base["PATH"], extra["PATH"]].compactMap { $0 }
            base["PATH"] = (mcpPath + existing).joined(separator: ":")
            base["HOME"] = base["HOME"] ?? home
            base["SHELL"] = base["SHELL"] ?? "/bin/zsh"
            return base.merging(extra) { _, new in new }
        }

        func stop() {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? input.fileHandleForWriting.close()
        }

        func request(id: Int, method: String, params: Any) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                let payload = try readMessage(timeout: 20)
                if let number = payload["id"] as? NSNumber, number.intValue == id {
                    if let error = payload["error"] as? [String: Any] {
                        throw MCPError.server((error["message"] as? String) ?? "MCP server error")
                    }
                    return (payload["result"] as? [String: Any]) ?? [:]
                }
            }
        }

        func notify(method: String) throws {
            try send(["jsonrpc": "2.0", "method": method])
        }

        private func send(_ payload: [String: Any]) throws {
            let body = try JSONSerialization.data(withJSONObject: payload)
            input.fileHandleForWriting.write(body)
            input.fileHandleForWriting.write(Data("\n".utf8))
        }

        private func readMessage(timeout: TimeInterval) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let body = popMessageBody() {
                    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    else { continue }
                    return json
                }
                if !process.isRunning {
                    throw MCPError.server("MCP stdio process exited. \(stderrSummary)")
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw MCPError.server("Timed out waiting for MCP stdio response. \(stderrSummary)")
        }

        private func appendOutput(_ data: Data) {
            lock.lock()
            outputBuffer.append(data)
            lock.unlock()
        }

        private func appendError(_ data: Data) {
            lock.lock()
            errorBuffer.append(data)
            if errorBuffer.count > 32_768 {
                errorBuffer.removeFirst(errorBuffer.count - 32_768)
            }
            lock.unlock()
        }

        private func popMessageBody() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return Self.extractLine(from: &outputBuffer)
        }

        private var stderrSummary: String {
            lock.lock()
            let data = errorBuffer
            lock.unlock()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "" : String(text.prefix(500))
        }

        private static func extractLine(from buffer: inout Data) -> Data? {
            guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
            var line = Data(buffer[buffer.startIndex..<newline])
            if line.last == 0x0D {
                line.removeLast()
            }
            buffer.removeSubrange(buffer.startIndex...newline)
            return line.isEmpty ? nil : line
        }
    }
}

// MARK: - HTTP client (streamable-HTTP JSON-RPC)

/// Minimal MCP client: initialize → notifications/initialized → tools/list.
/// Speaks JSON-RPC 2.0 over POST; accepts plain JSON or SSE-framed responses.
struct MCPHTTPClient {
    let endpoint: URL
    let extraHeaders: [String: String]

    func listTools() async throws -> [MCPTool] {
        let (initialized, sessionID) = try await rpc(
            id: 1, method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: String](),
                "clientInfo": ["name": "Forge", "version": "1.0"],
            ],
            sessionID: nil)
        _ = initialized
        try await notify(method: "notifications/initialized", sessionID: sessionID)

        let (result, _) = try await rpc(
            id: 2, method: "tools/list", params: [String: String](),
            sessionID: sessionID)
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return MCPTool(
                name: name,
                description: (tool["description"] as? String) ?? "")
        }
    }

    /// Perform a full initialize + tools/call in one go (stateless per-invocation).
    /// Returns the raw JSON result as Data (Sendable).
    /// 
    /// For photo review or image tools, serialize the image into `arguments` however the target
    /// MCP server expects it (e.g. "image_base64": "<base64 data>", "query": "detailed review").
    ///
    /// Sample mcp-servers.json for a photo review MCP server:
    /// {
    ///   "mcpServers": {
    ///     "local-photo-review": { "url": "http://127.0.0.1:8765" }
    ///   }
    /// }
    /// Server should implement tool "review_photo" that accepts "image_base64".
    func callToolReturningData(name: String, arguments: [String: Any]) async throws -> Data {
        let (initialized, sessionID) = try await rpc(
            id: 1, method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: String](),
                "clientInfo": ["name": "Forge", "version": "1.0"],
            ],
            sessionID: nil)
        _ = initialized
        try await notify(method: "notifications/initialized", sessionID: sessionID)

        let (result, _) = try await rpc(
            id: 10,
            method: "tools/call",
            params: [ "name": name, "arguments": arguments ],
            sessionID: sessionID)
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func request(method: String, body: [String: Any], sessionID: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        return request
    }

    private func rpc(
        id: Int, method: String, params: Any, sessionID: String?
    ) async throws -> (result: [String: Any], sessionID: String?) {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let (data, response) = try await URLSession.shared.data(
            for: request(method: method, body: body, sessionID: sessionID))
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode)
        }
        let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let payload = try Self.jsonPayload(from: data, contentType: contentType)
        if let error = payload["error"] as? [String: Any] {
            throw MCPError.server((error["message"] as? String) ?? "MCP server error")
        }
        return ((payload["result"] as? [String: Any]) ?? [:], newSession)
    }

    private func notify(method: String, sessionID: String?) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        _ = try? await URLSession.shared.data(
            for: request(method: method, body: body, sessionID: sessionID))
    }

    /// Servers may answer a POST with `application/json` or with a one-event
    /// `text/event-stream`; unwrap either into the JSON-RPC envelope.
    static func jsonPayload(from data: Data, contentType: String) throws -> [String: Any] {
        if contentType.contains("text/event-stream") {
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPError.badResponse
            }
            let dataLines = text.split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            for line in dataLines {
                if let lineData = line.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any],
                    json["result"] != nil || json["error"] != nil
                {
                    return json
                }
            }
            throw MCPError.badResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MCPError.badResponse }
        return json
    }
}
