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
        ("fable", "Fable (latest)"),
        ("claude-sonnet-4-5", "Pinned: Sonnet 4.5"),
        ("claude-opus-4-1", "Pinned: Opus 4.1"),
        ("custom", "Custom..."),
    ]

    static let fallbackModels: [(id: String, label: String)] = [
        ("", "No fallback"),
        ("sonnet", "Sonnet (latest)"),
        ("opus", "Opus (latest)"),
        ("haiku", "Haiku (fast/cheap)"),
        ("fable", "Fable (latest)"),
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
        case defaultMode = "default"
        case plan
        case auto
        case acceptEdits
        case dontAsk
        case bypassPermissions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Default (omit)"
            case .defaultMode: return "Default (--permission-mode default)"
            case .plan: return "Plan only (read, no writes)"
            case .auto: return "Auto"
            case .acceptEdits: return "Accept edits"
            case .dontAsk: return "Don't ask"
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
        case text
        case streamJSON

        var id: String { rawValue }

        var value: String {
            switch self {
            case .none: return ""
            case .text: return "text"
            case .streamJSON: return "stream-json"
            }
        }

        var label: String {
            switch self {
            case .none: return "Default (omit -> text)"
            case .text: return "text"
            case .streamJSON: return "stream-json"
            }
        }
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
        case replaceFile
        case appendFile

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None (omit)"
            case .replace: return "Replace prompt (--system-prompt)"
            case .append: return "Append prompt (--append-system-prompt)"
            case .replaceFile: return "Replace from file (--system-prompt-file)"
            case .appendFile: return "Append from file (--append-system-prompt-file)"
            }
        }

        var flag: String? {
            switch self {
            case .none: return nil
            case .replace: return "--system-prompt"
            case .append: return "--append-system-prompt"
            case .replaceFile: return "--system-prompt-file"
            case .appendFile: return "--append-system-prompt-file"
            }
        }

        var usesFile: Bool {
            self == .replaceFile || self == .appendFile
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

    enum BuiltInToolsMode: String, CaseIterable, Identifiable {
        case none
        case defaultTools
        case custom
        case disabled

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Default (omit)"
            case .defaultTools: return "--tools default"
            case .custom: return "Custom --tools"
            case .disabled: return "Disable all built-in tools"
            }
        }

        var commandValue: String? {
            switch self {
            case .none: return nil
            case .defaultTools: return "default"
            case .custom: return nil
            case .disabled: return ""
            }
        }
    }

    enum ChromeMode: String, CaseIterable, Identifiable {
        case none
        case enable
        case disable

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Chrome default"
            case .enable: return "--chrome"
            case .disable: return "--no-chrome"
            }
        }

        var flag: String? {
            switch self {
            case .none: return nil
            case .enable: return "--chrome"
            case .disable: return "--no-chrome"
            }
        }
    }

    enum EffortLevel: String, CaseIterable, Identifiable {
        case none
        case low
        case medium
        case high
        case xhigh
        case max

        var id: String { rawValue }
        var value: String? { self == .none ? nil : rawValue }

        var label: String {
            switch self {
            case .none: return "Default (omit)"
            case .low: return "low"
            case .medium: return "medium"
            case .high: return "high"
            case .xhigh: return "xhigh"
            case .max: return "max"
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
    var allowDangerouslySkipPermissions = false { didSet { defaults.set(allowDangerouslySkipPermissions, forKey: "hl.allowDangerouslySkipPermissions") } }
    var dangerouslySkipPermissions = false { didSet { defaults.set(dangerouslySkipPermissions, forKey: "hl.dangerouslySkipPermissions") } }

    var toolRestriction: ToolRestriction = .none { didSet { defaults.set(toolRestriction.rawValue, forKey: "hl.toolRestriction") } }
    var toolList = "" { didSet { defaults.set(toolList, forKey: "hl.toolList") } }
    var builtInToolsMode: BuiltInToolsMode = .none { didSet { defaults.set(builtInToolsMode.rawValue, forKey: "hl.builtInToolsMode") } }
    var builtInTools = "" { didSet { defaults.set(builtInTools, forKey: "hl.builtInTools") } }
    var permissionPromptTool = "" { didSet { defaults.set(permissionPromptTool, forKey: "hl.permissionPromptTool") } }

    var systemPromptMode: SystemPromptMode = .none { didSet { defaults.set(systemPromptMode.rawValue, forKey: "hl.systemPromptMode") } }
    var systemPromptText = "" { didSet { defaults.set(systemPromptText, forKey: "hl.systemPromptText") } }

    var maxTurns = "" { didSet { defaults.set(maxTurns, forKey: "hl.maxTurns") } }
    var maxBudgetUSD = "" { didSet { defaults.set(maxBudgetUSD, forKey: "hl.maxBudgetUSD") } }
    var verbose = false { didSet { defaults.set(verbose, forKey: "hl.verbose") } }
    var debug = false { didSet { defaults.set(debug, forKey: "hl.debug") } }
    var debugFilter = "" { didSet { defaults.set(debugFilter, forKey: "hl.debugFilter") } }
    var debugFile = "" { didSet { defaults.set(debugFile, forKey: "hl.debugFile") } }

    var sessionMode: SessionMode = .none { didSet { defaults.set(sessionMode.rawValue, forKey: "hl.sessionMode") } }
    var sessionValue = "" { didSet { defaults.set(sessionValue, forKey: "hl.sessionValue") } }
    var sessionID = "" { didSet { defaults.set(sessionID, forKey: "hl.sessionID") } }
    var sessionName = "" { didSet { defaults.set(sessionName, forKey: "hl.sessionName") } }
    var forkSession = false { didSet { defaults.set(forkSession, forKey: "hl.forkSession") } }
    var noSessionPersistence = false { didSet { defaults.set(noSessionPersistence, forKey: "hl.noSessionPersistence") } }

    var includePartialMessages = false { didSet { defaults.set(includePartialMessages, forKey: "hl.includePartialMessages") } }
    var includeHookEvents = false { didSet { defaults.set(includeHookEvents, forKey: "hl.includeHookEvents") } }
    var replayUserMessages = false { didSet { defaults.set(replayUserMessages, forKey: "hl.replayUserMessages") } }
    var promptSuggestions = false { didSet { defaults.set(promptSuggestions, forKey: "hl.promptSuggestions") } }
    var jsonSchema = "" { didSet { defaults.set(jsonSchema, forKey: "hl.jsonSchema") } }

    private(set) var discoveredMCP: [DiscoveredMCP] = []
    var selectedMCP: Set<String> = [] {
        didSet { defaults.set(Array(selectedMCP).sorted(), forKey: "hl.selectedMCP") }
    }
    var strictMCP = false { didSet { defaults.set(strictMCP, forKey: "hl.strictMCP") } }
    var manualMCPConfig = "" { didSet { defaults.set(manualMCPConfig, forKey: "hl.manualMCPConfig") } }

    var settings = "" { didSet { defaults.set(settings, forKey: "hl.settings") } }
    var settingSources = "" { didSet { defaults.set(settingSources, forKey: "hl.settingSources") } }
    var bare = false { didSet { defaults.set(bare, forKey: "hl.bare") } }
    var safeMode = false { didSet { defaults.set(safeMode, forKey: "hl.safeMode") } }
    var axScreenReader = false { didSet { defaults.set(axScreenReader, forKey: "hl.axScreenReader") } }
    var disableSlashCommands = false { didSet { defaults.set(disableSlashCommands, forKey: "hl.disableSlashCommands") } }
    var excludeDynamicSystemPromptSections = false { didSet { defaults.set(excludeDynamicSystemPromptSections, forKey: "hl.excludeDynamicSystemPromptSections") } }
    var ide = false { didSet { defaults.set(ide, forKey: "hl.ide") } }
    var chromeMode: ChromeMode = .none { didSet { defaults.set(chromeMode.rawValue, forKey: "hl.chromeMode") } }
    var effortLevel: EffortLevel = .none { didSet { defaults.set(effortLevel.rawValue, forKey: "hl.effortLevel") } }
    var advisorModel = "" { didSet { defaults.set(advisorModel, forKey: "hl.advisorModel") } }

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
        allowDangerouslySkipPermissions = defaults.bool(forKey: "hl.allowDangerouslySkipPermissions")
        dangerouslySkipPermissions = defaults.bool(forKey: "hl.dangerouslySkipPermissions")
        toolRestriction = ToolRestriction(rawValue: defaults.string(forKey: "hl.toolRestriction") ?? "") ?? .none
        toolList = defaults.string(forKey: "hl.toolList") ?? ""
        builtInToolsMode = BuiltInToolsMode(rawValue: defaults.string(forKey: "hl.builtInToolsMode") ?? "") ?? .none
        builtInTools = defaults.string(forKey: "hl.builtInTools") ?? ""
        permissionPromptTool = defaults.string(forKey: "hl.permissionPromptTool") ?? ""
        systemPromptMode = SystemPromptMode(rawValue: defaults.string(forKey: "hl.systemPromptMode") ?? "") ?? .none
        systemPromptText = defaults.string(forKey: "hl.systemPromptText") ?? ""
        maxTurns = defaults.string(forKey: "hl.maxTurns") ?? ""
        maxBudgetUSD = defaults.string(forKey: "hl.maxBudgetUSD") ?? ""
        verbose = defaults.bool(forKey: "hl.verbose")
        debug = defaults.bool(forKey: "hl.debug")
        debugFilter = defaults.string(forKey: "hl.debugFilter") ?? ""
        debugFile = defaults.string(forKey: "hl.debugFile") ?? ""
        sessionMode = SessionMode(rawValue: defaults.string(forKey: "hl.sessionMode") ?? "") ?? .none
        sessionValue = defaults.string(forKey: "hl.sessionValue") ?? ""
        sessionID = defaults.string(forKey: "hl.sessionID") ?? ""
        sessionName = defaults.string(forKey: "hl.sessionName") ?? ""
        forkSession = defaults.bool(forKey: "hl.forkSession")
        noSessionPersistence = defaults.bool(forKey: "hl.noSessionPersistence")
        includePartialMessages = defaults.bool(forKey: "hl.includePartialMessages")
        includeHookEvents = defaults.bool(forKey: "hl.includeHookEvents")
        replayUserMessages = defaults.bool(forKey: "hl.replayUserMessages")
        promptSuggestions = defaults.bool(forKey: "hl.promptSuggestions")
        jsonSchema = defaults.string(forKey: "hl.jsonSchema") ?? ""
        selectedMCP = Set(defaults.stringArray(forKey: "hl.selectedMCP") ?? [])
        strictMCP = defaults.bool(forKey: "hl.strictMCP")
        manualMCPConfig = defaults.string(forKey: "hl.manualMCPConfig") ?? ""
        settings = defaults.string(forKey: "hl.settings") ?? ""
        settingSources = defaults.string(forKey: "hl.settingSources") ?? ""
        bare = defaults.bool(forKey: "hl.bare")
        safeMode = defaults.bool(forKey: "hl.safeMode")
        axScreenReader = defaults.bool(forKey: "hl.axScreenReader")
        disableSlashCommands = defaults.bool(forKey: "hl.disableSlashCommands")
        excludeDynamicSystemPromptSections = defaults.bool(forKey: "hl.excludeDynamicSystemPromptSections")
        ide = defaults.bool(forKey: "hl.ide")
        chromeMode = ChromeMode(rawValue: defaults.string(forKey: "hl.chromeMode") ?? "") ?? .none
        effortLevel = EffortLevel(rawValue: defaults.string(forKey: "hl.effortLevel") ?? "") ?? .none
        advisorModel = defaults.string(forKey: "hl.advisorModel") ?? ""
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
        permissionMode.isDangerous || dangerouslySkipPermissions || selectedPreset.isDangerous
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
        if let maxBudgetError {
            messages.append(maxBudgetError)
        }
        if sessionMode == .resume && sessionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("--resume requires a session ID.")
        }
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSessionID.isEmpty && UUID(uuidString: trimmedSessionID) == nil {
            messages.append("--session-id must be a valid UUID.")
        }
        if forkSession && sessionMode == .none {
            messages.append("--fork-session requires --resume or --continue.")
        }
        if systemPromptMode != .none && systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(systemPromptMode.usesFile ? "System prompt file mode is selected but the path is empty." : "System prompt mode is selected but the prompt is empty.")
        }
        if builtInToolsMode == .custom && builtInTools.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Custom --tools is selected but empty.")
        }
        if dangerouslySkipPermissions && permissionMode != .none && permissionMode != .bypassPermissions {
            messages.append("--dangerously-skip-permissions conflicts with the selected permission mode.")
        }
        if includePartialMessages && outputFormat != .streamJSON {
            messages.append("--include-partial-messages requires --output-format stream-json.")
        }
        if includeHookEvents && outputFormat != .streamJSON {
            messages.append("--include-hook-events requires --output-format stream-json.")
        }
        if replayUserMessages && (inputFormat != .streamJSON || outputFormat != .streamJSON) {
            messages.append("--replay-user-messages requires stream-json input and output.")
        }
        if promptSuggestions && (outputFormat != .streamJSON || !verbose) {
            messages.append("--prompt-suggestions requires stream-json output and --verbose.")
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

    private var maxBudgetError: String? {
        let trimmed = maxBudgetUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Decimal(string: trimmed), value > 0 else {
            return "--max-budget-usd must be a positive number."
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
        lineList(additionalDirectories)
    }

    private var manualMCPConfigArguments: [String] {
        lineList(manualMCPConfig)
    }

    private func lineList(_ raw: String) -> [String] {
        raw
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

    private var builtInToolsArgument: String? {
        switch builtInToolsMode {
        case .none:
            return nil
        case .defaultTools, .disabled:
            return builtInToolsMode.commandValue
        case .custom:
            let trimmed = builtInTools.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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
        if inputFormat != .none {
            segments.append("--input-format \(shellQuote(inputFormat.value))")
        }
        if dangerouslySkipPermissions {
            segments.append("--dangerously-skip-permissions")
        } else if let permission = permissionMode.flagValue {
            segments.append("--permission-mode \(shellQuote(permission))")
        }
        if allowDangerouslySkipPermissions {
            segments.append("--allow-dangerously-skip-permissions")
        }
        if let turns = Int(maxTurns.trimmingCharacters(in: .whitespacesAndNewlines)), turns >= 1 {
            segments.append("--max-turns \(turns)")
        }
        let budget = maxBudgetUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Decimal(string: budget) != nil {
            segments.append("--max-budget-usd \(shellQuote(budget))")
        }
        if let toolArgument {
            segments.append("\(toolArgument.flag) \(shellQuote(toolArgument.value))")
        }
        if let builtInToolsArgument {
            segments.append("--tools \(shellQuote(builtInToolsArgument))")
        }
        let permissionTool = permissionPromptTool.trimmingCharacters(in: .whitespacesAndNewlines)
        if !permissionTool.isEmpty {
            segments.append("--permission-prompt-tool \(shellQuote(permissionTool))")
        }
        if let systemPromptFlag = systemPromptMode.flag {
            let text = systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append("\(systemPromptFlag) \(shellQuote(text))")
            }
        }
        if let mcpConfigArgument {
            segments.append("--mcp-config \(shellQuote(mcpConfigArgument))")
        }
        for config in manualMCPConfigArguments {
            segments.append("--mcp-config \(shellQuote(config))")
        }
        if strictMCP && (!selectedMCP.isEmpty || !manualMCPConfigArguments.isEmpty) {
            segments.append("--strict-mcp-config")
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
        let explicitSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitSessionID.isEmpty {
            segments.append("--session-id \(shellQuote(explicitSessionID))")
        }
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            segments.append("--name \(shellQuote(name))")
        }
        if forkSession {
            segments.append("--fork-session")
        }
        if noSessionPersistence {
            segments.append("--no-session-persistence")
        }
        if includeHookEvents {
            segments.append("--include-hook-events")
        }
        if includePartialMessages {
            segments.append("--include-partial-messages")
        }
        if replayUserMessages {
            segments.append("--replay-user-messages")
        }
        if promptSuggestions {
            segments.append("--prompt-suggestions")
        }
        let schema = jsonSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schema.isEmpty {
            segments.append("--json-schema \(shellQuote(schema))")
        }
        let settingsValue = settings.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settingsValue.isEmpty {
            segments.append("--settings \(shellQuote(settingsValue))")
        }
        let sources = settingSources.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sources.isEmpty {
            segments.append("--setting-sources \(shellQuote(sources))")
        }
        if bare {
            segments.append("--bare")
        }
        if safeMode {
            segments.append("--safe-mode")
        }
        if axScreenReader {
            segments.append("--ax-screen-reader")
        }
        if disableSlashCommands {
            segments.append("--disable-slash-commands")
        }
        if excludeDynamicSystemPromptSections {
            segments.append("--exclude-dynamic-system-prompt-sections")
        }
        if ide {
            segments.append("--ide")
        }
        if let chromeFlag = chromeMode.flag {
            segments.append(chromeFlag)
        }
        if debug {
            let filter = debugFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(filter.isEmpty ? "--debug" : "--debug \(shellQuote(filter))")
        }
        let debugPath = debugFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !debugPath.isEmpty {
            segments.append("--debug-file \(shellQuote(debugPath))")
        }
        if let effort = effortLevel.value {
            segments.append("--effort \(shellQuote(effort))")
        }
        let advisor = advisorModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !advisor.isEmpty {
            segments.append("--advisor \(shellQuote(advisor))")
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
