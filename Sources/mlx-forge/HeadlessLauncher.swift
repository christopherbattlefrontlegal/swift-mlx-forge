// Forge — headless command composer.
//
// This never runs `claude`. It builds a reviewed command string for the operator
// to copy into their own terminal. The safe preview is commented with `#` on
// every command line; the ready-to-run copy path is explicit and separately gated
// for bypass-permissions commands.

import Foundation
import Observation

@MainActor
@Observable
final class HeadlessLauncher {

    static let models: [(id: String, label: String)] = [
        ("", "Default (omit --model)"),
        ("sonnet", "Sonnet (latest)"),
        ("opus", "Opus (latest)"),
        ("haiku", "Haiku (fast/cheap)"),
        ("claude-sonnet-4-5", "Pinned: Sonnet 4.5"),
        ("claude-opus-4-1", "Pinned: Opus 4.1"),
        ("custom", "Custom..."),
    ]

    static let fallbackModels: [(id: String, label: String)] = [
        ("", "No fallback"),
        ("sonnet", "Sonnet (latest)"),
        ("opus", "Opus (latest)"),
        ("haiku", "Haiku (fast/cheap)"),
        ("claude-sonnet-4-5", "Pinned: Sonnet 4.5"),
        ("claude-opus-4-1", "Pinned: Opus 4.1"),
        ("custom", "Custom..."),
    ]

    enum Preset: String, CaseIterable, Identifiable {
        case none
        case readOnlyReview
        case safeCodeEdit
        case fullAutonomous
        case researchWeb
        case gitWorkflow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None (manual below)"
            case .readOnlyReview: return "Read-only review"
            case .safeCodeEdit: return "Safe code edit"
            case .fullAutonomous: return "Full autonomous"
            case .researchWeb: return "Research/web"
            case .gitWorkflow: return "Git workflow"
            }
        }

        var isDangerous: Bool { self == .fullAutonomous }
    }

    enum PermissionMode: String, CaseIterable, Identifiable {
        case none
        case plan
        case acceptEdits
        case bypassPermissions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Default (omit)"
            case .plan: return "Plan only (read, no writes)"
            case .acceptEdits: return "Accept edits"
            case .bypassPermissions: return "Bypass all permissions"
            }
        }

        var isDangerous: Bool { self == .bypassPermissions }
        var flagValue: String? { self == .none ? nil : rawValue }
    }

    enum OutputFormat: String, CaseIterable, Identifiable {
        case none
        case text
        case json
        case streamJSON

        var id: String { rawValue }

        var value: String {
            switch self {
            case .none: return ""
            case .streamJSON: return "stream-json"
            default: return rawValue
            }
        }

        var label: String {
            switch self {
            case .none: return "Default (omit -> text)"
            case .text: return "text"
            case .json: return "json"
            case .streamJSON: return "stream-json"
            }
        }
    }

    enum InputFormat: String, CaseIterable, Identifiable {
        case none
        case streamJSON

        var id: String { rawValue }
        var value: String { self == .streamJSON ? "stream-json" : "" }
        var label: String { self == .none ? "Default (omit)" : "stream-json" }
    }

    enum ToolRestriction: String, CaseIterable, Identifiable {
        case none
        case allowedTools
        case disallowedTools

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None (omit)"
            case .allowedTools: return "Allowlist (--allowedTools)"
            case .disallowedTools: return "Denylist (--disallowedTools)"
            }
        }

        var flag: String? {
            switch self {
            case .none: return nil
            case .allowedTools: return "--allowedTools"
            case .disallowedTools: return "--disallowedTools"
            }
        }
    }

    enum SystemPromptMode: String, CaseIterable, Identifiable {
        case none
        case replace
        case append

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None (omit)"
            case .replace: return "Replace prompt (--system-prompt)"
            case .append: return "Append prompt (--append-system-prompt)"
            }
        }

        var flag: String? {
            switch self {
            case .none: return nil
            case .replace: return "--system-prompt"
            case .append: return "--append-system-prompt"
            }
        }
    }

    enum SessionMode: String, CaseIterable, Identifiable {
        case none
        case continueLast
        case resume

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "New session"
            case .continueLast: return "--continue"
            case .resume: return "--resume <session id>"
            }
        }
    }

    struct DiscoveredMCP: Identifiable, Hashable {
        let name: String
        let configJSON: String
        var id: String { name }
    }

    private let defaults = UserDefaults.standard

    var prompt = ""

    var selectedPreset: Preset = .none { didSet { defaults.set(selectedPreset.rawValue, forKey: "hl.preset") } }
    var workingDirectory = NSHomeDirectory() { didSet { defaults.set(workingDirectory, forKey: "hl.workdir") } }
    var additionalDirectories = "" { didSet { defaults.set(additionalDirectories, forKey: "hl.adddirs") } }
    var outputFolder = "" { didSet { defaults.set(outputFolder, forKey: "hl.outputFolder") } }

    var model = "" { didSet { defaults.set(model, forKey: "hl.model") } }
    var customModel = "" { didSet { defaults.set(customModel, forKey: "hl.customModel") } }
    var fallbackModel = "" { didSet { defaults.set(fallbackModel, forKey: "hl.fallbackModel") } }
    var customFallbackModel = "" { didSet { defaults.set(customFallbackModel, forKey: "hl.customFallbackModel") } }

    var outputFormat: OutputFormat = .none { didSet { defaults.set(outputFormat.rawValue, forKey: "hl.outputFormat") } }
    var inputFormat: InputFormat = .none { didSet { defaults.set(inputFormat.rawValue, forKey: "hl.inputFormat") } }
    var permissionMode: PermissionMode = .plan { didSet { defaults.set(permissionMode.rawValue, forKey: "hl.permission") } }

    var toolRestriction: ToolRestriction = .none { didSet { defaults.set(toolRestriction.rawValue, forKey: "hl.toolRestriction") } }
    var toolList = "" { didSet { defaults.set(toolList, forKey: "hl.toolList") } }

    var systemPromptMode: SystemPromptMode = .none { didSet { defaults.set(systemPromptMode.rawValue, forKey: "hl.systemPromptMode") } }
    var systemPromptText = "" { didSet { defaults.set(systemPromptText, forKey: "hl.systemPromptText") } }

    var maxTurns = "" { didSet { defaults.set(maxTurns, forKey: "hl.maxTurns") } }
    var verbose = false { didSet { defaults.set(verbose, forKey: "hl.verbose") } }

    var sessionMode: SessionMode = .none { didSet { defaults.set(sessionMode.rawValue, forKey: "hl.sessionMode") } }
    var sessionValue = "" { didSet { defaults.set(sessionValue, forKey: "hl.sessionValue") } }

    private(set) var discoveredMCP: [DiscoveredMCP] = []
    var selectedMCP: Set<String> = [] {
        didSet { defaults.set(Array(selectedMCP).sorted(), forKey: "hl.selectedMCP") }
    }
    var strictMCP = false { didSet { defaults.set(strictMCP, forKey: "hl.strictMCP") } }

    var reviewed = false

    init() {
        selectedPreset = Preset(rawValue: defaults.string(forKey: "hl.preset") ?? "") ?? .none
        workingDirectory = defaults.string(forKey: "hl.workdir") ?? NSHomeDirectory()
        additionalDirectories = defaults.string(forKey: "hl.adddirs") ?? ""
        outputFolder = defaults.string(forKey: "hl.outputFolder") ?? ""
        model = defaults.string(forKey: "hl.model") ?? ""
        customModel = defaults.string(forKey: "hl.customModel") ?? ""
        fallbackModel = defaults.string(forKey: "hl.fallbackModel") ?? ""
        customFallbackModel = defaults.string(forKey: "hl.customFallbackModel") ?? ""
        outputFormat = OutputFormat(rawValue: defaults.string(forKey: "hl.outputFormat") ?? "") ?? .none
        inputFormat = InputFormat(rawValue: defaults.string(forKey: "hl.inputFormat") ?? "") ?? .none
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "hl.permission") ?? "") ?? .plan
        toolRestriction = ToolRestriction(rawValue: defaults.string(forKey: "hl.toolRestriction") ?? "") ?? .none
        toolList = defaults.string(forKey: "hl.toolList") ?? ""
        systemPromptMode = SystemPromptMode(rawValue: defaults.string(forKey: "hl.systemPromptMode") ?? "") ?? .none
        systemPromptText = defaults.string(forKey: "hl.systemPromptText") ?? ""
        maxTurns = defaults.string(forKey: "hl.maxTurns") ?? ""
        verbose = defaults.bool(forKey: "hl.verbose")
        sessionMode = SessionMode(rawValue: defaults.string(forKey: "hl.sessionMode") ?? "") ?? .none
        sessionValue = defaults.string(forKey: "hl.sessionValue") ?? ""
        selectedMCP = Set(defaults.stringArray(forKey: "hl.selectedMCP") ?? [])
        strictMCP = defaults.bool(forKey: "hl.strictMCP")
        refreshMCP()
    }

    // MARK: - Presets

    func applyPreset(_ preset: Preset) {
        selectedPreset = preset
        switch preset {
        case .none:
            break
        case .readOnlyReview:
            permissionMode = .plan
            toolRestriction = .allowedTools
            toolList = "Read Grep Glob"
        case .safeCodeEdit:
            permissionMode = .acceptEdits
            toolRestriction = .allowedTools
            toolList = "Read Edit Write Grep Glob"
        case .fullAutonomous:
            permissionMode = .bypassPermissions
            maxTurns = "20"
        case .researchWeb:
            toolRestriction = .allowedTools
            toolList = "Read WebFetch WebSearch Grep"
        case .gitWorkflow:
            toolRestriction = .allowedTools
            toolList = "Read Edit Bash(git diff *) Bash(git status *) Bash(git log *)"
        }
        reviewed = false
    }

    // MARK: - MCP discovery

    func refreshMCP() {
        var found: [String: String] = [:]

        func ingest(_ mcpServers: Any?) {
            guard let dict = mcpServers as? [String: Any] else { return }
            for (name, cfg) in dict where found[name] == nil {
                if let data = try? JSONSerialization.data(withJSONObject: cfg),
                   let json = String(data: data, encoding: .utf8) {
                    found[name] = json
                }
            }
        }

        let home = NSHomeDirectory()
        if let data = try? Data(contentsOf: URL(filePath: home + "/.claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ingest(root["mcpServers"])
            if let projects = root["projects"] as? [String: Any] {
                for (_, project) in projects {
                    ingest((project as? [String: Any])?["mcpServers"])
                }
            }
        }

        let projectMCP = workingDirectory + "/.mcp.json"
        if let data = try? Data(contentsOf: URL(filePath: projectMCP)),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ingest(root["mcpServers"])
        }

        discoveredMCP = found.keys.sorted().map {
            DiscoveredMCP(name: $0, configJSON: found[$0]!)
        }
        selectedMCP.formIntersection(Set(found.keys))
    }

    // MARK: - Validation

    var isDangerous: Bool {
        permissionMode.isDangerous || selectedPreset.isDangerous
    }

    var validationMessages: [String] {
        var messages: [String] = []

        if model == "custom" && customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Custom model is selected but empty.")
        }
        if fallbackModel == "custom" && customFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Custom fallback model is selected but empty.")
        }
        if let maxTurnsError {
            messages.append(maxTurnsError)
        }
        if sessionMode == .resume && sessionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("--resume requires a session ID.")
        }
        if systemPromptMode != .none && systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("System prompt mode is selected but the prompt is empty.")
        }
        return messages
    }

    var canCompose: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validationMessages.isEmpty
    }

    private var maxTurnsError: String? {
        let trimmed = maxTurns.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), value >= 1 else {
            return "--max-turns must be a whole number of 1 or greater."
        }
        return nil
    }

    // MARK: - Tool editing

    static let commonTools = [
        "Read",
        "Edit",
        "Write",
        "Grep",
        "Glob",
        "WebFetch",
        "WebSearch",
        "Bash(git diff *)",
        "Bash(git status *)",
        "Bash(git log *)",
    ]

    func containsTool(_ tool: String) -> Bool {
        toolTokens(toolList).contains(tool)
    }

    func setTool(_ tool: String, enabled: Bool) {
        var tokens = toolTokens(toolList)
        if enabled {
            if !tokens.contains(tool) { tokens.append(tool) }
        } else {
            tokens.removeAll { $0 == tool }
        }
        toolList = tokens.joined(separator: " ")
    }

    // MARK: - Command assembly

    private var extraDirectoryList: [String] {
        additionalDirectories
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var outputFolderPath: String? {
        let trimmed = outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var emittedAdditionalDirectories: [String] {
        var directories: [String] = []
        if let outputFolderPath {
            directories.append(outputFolderPath)
        }
        directories += extraDirectoryList

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    private var emittedModel: String? {
        let value = model == "custom" ? customModel : model
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var emittedFallbackModel: String? {
        let value = fallbackModel == "custom" ? customFallbackModel : fallbackModel
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var selectedMCPToolTokens: [String] {
        selectedMCP.sorted().map { "mcp__\($0)__*" }
    }

    private var mcpConfigArgument: String? {
        guard !selectedMCP.isEmpty else { return nil }
        let chosen = discoveredMCP.filter { selectedMCP.contains($0.name) }
        guard !chosen.isEmpty else { return nil }
        let body = chosen.map { "\(jsonString($0.name)): \($0.configJSON)" }.joined(separator: ",")
        return "{\"mcpServers\":{\(body)}}"
    }

    private var toolArgument: (flag: String, value: String)? {
        let explicit = toolTokens(toolList)
        switch toolRestriction {
        case .none:
            let mcpTokens = selectedMCPToolTokens
            return mcpTokens.isEmpty ? nil : ("--allowedTools", mcpTokens.joined(separator: " "))
        case .allowedTools:
            let combined = explicit + selectedMCPToolTokens.filter { !explicit.contains($0) }
            return combined.isEmpty ? nil : ("--allowedTools", combined.joined(separator: " "))
        case .disallowedTools:
            return explicit.isEmpty ? nil : ("--disallowedTools", explicit.joined(separator: " "))
        }
    }

    private var optionSegments: [String] {
        var segments: [String] = []

        if let emittedModel {
            segments.append("--model \(shellQuote(emittedModel))")
        }
        if let emittedFallbackModel {
            segments.append("--fallback-model \(shellQuote(emittedFallbackModel))")
        }
        if outputFormat != .none {
            segments.append("--output-format \(shellQuote(outputFormat.value))")
        }
        if outputFormat == .streamJSON && inputFormat == .streamJSON {
            segments.append("--input-format \(shellQuote(inputFormat.value))")
        }
        if let permission = permissionMode.flagValue {
            segments.append("--permission-mode \(shellQuote(permission))")
        }
        if let turns = Int(maxTurns.trimmingCharacters(in: .whitespacesAndNewlines)), turns >= 1 {
            segments.append("--max-turns \(turns)")
        }
        if let toolArgument {
            segments.append("\(toolArgument.flag) \(shellQuote(toolArgument.value))")
        }
        if let systemPromptFlag = systemPromptMode.flag {
            let text = systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append("\(systemPromptFlag) \(shellQuote(text))")
            }
        }
        if let mcpConfigArgument {
            segments.append("--mcp-config \(shellQuote(mcpConfigArgument))")
            if strictMCP {
                segments.append("--strict-mcp-config")
            }
        }
        for directory in emittedAdditionalDirectories {
            segments.append("--add-dir \(shellQuote(directory))")
        }
        switch sessionMode {
        case .none:
            break
        case .continueLast:
            segments.append("--continue")
        case .resume:
            let value = sessionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                segments.append("--resume \(shellQuote(value))")
            }
        }
        if verbose {
            segments.append("--verbose")
        }

        return segments
    }

    var commandText: String {
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptValue = missionPromptWithOutputFolder(base: promptText.isEmpty ? "<your prompt>" : promptText)
        var lines = ["claude -p \(shellQuote(promptValue))"]
        lines += optionSegments

        var command = lines.joined(separator: " \\\n  ")
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty && directory != NSHomeDirectory() {
            command = "cd \(shellQuote(directory)) && \\\n" + command
        }
        return command
    }

    private func missionPromptWithOutputFolder(base: String) -> String {
        guard let outputFolderPath else { return base }
        return """
        \(base)

        Output folder: \(outputFolderPath)
        Put all generated files, reports, logs, and final artifacts in the output folder. Create it if needed. Do not scatter generated output elsewhere unless the task explicitly requires it.
        """
    }

    var annotatedCommand: String {
        var header = [
            "# SAFETY ON: Forge composed this command. It did not run it.",
            "# Review every flag before using Copy ready-to-run.",
        ]
        if isDangerous {
            header.append("# DANGER: bypassPermissions is selected.")
        }
        let commented = commandText
            .components(separatedBy: "\n")
            .map { "# \($0)" }
            .joined(separator: "\n")
        return (header + [commented]).joined(separator: "\n")
    }

    // MARK: - Shell helpers

    private func toolTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0

        for character in raw {
            if character == "(" {
                depth += 1
                current.append(character)
            } else if character == ")" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character.isWhitespace && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { tokens.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { tokens.append(trimmed) }
        return tokens
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
