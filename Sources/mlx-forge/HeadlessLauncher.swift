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

    static let missionScaffoldHeading = "## Mission execution contract"
    static let missionTaskDelimiter = "\n\n## Task\n"

    static let missionScaffold = """
    \(missionScaffoldHeading)

    Execute the task below fully and precisely.

    - Follow the task and all stated constraints exactly. Stay within scope.
    - Inspect the relevant context, files, and existing patterns before acting.
    - Carry the task through to its requested outcome. Do not stop at explanation, planning, or a partial implementation unless the task asks for that.
    - Preserve unrelated work and make only necessary changes.
    - Verify the result with the strongest relevant available checks, such as tests, a build, linting, or direct inspection. Fix failures caused by your work.
    - In the final response, report the concrete outcome and the evidence used to verify it.
    """ + missionTaskDelimiter

    static let models: [(id: String, label: String)] = [
        ("", "Default (omit --model)"),
        ("sonnet", "Sonnet (latest)"),
        ("opus", "Opus (latest)"),
        ("haiku", "Haiku (fast/cheap)"),
        ("fable", "Fable (latest)"),
        ("custom", "Specific model ID…"),
    ]

    static let fallbackModels: [(id: String, label: String)] = [
        ("", "No fallback"),
        ("sonnet", "Sonnet (latest)"),
        ("opus", "Opus (latest)"),
        ("haiku", "Haiku (fast/cheap)"),
        ("fable", "Fable (latest)"),
        ("custom", "Specific model ID…"),
    ]

    enum Preset: String, CaseIterable, Identifiable {
        case none
        case readOnlyReview
        case safeCodeEdit
        case autonomousCode
        case fullAutonomous
        case researchWeb
        case gitWorkflow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "Custom"
            case .readOnlyReview: return "Review only"
            case .safeCodeEdit: return "Edit code"
            case .autonomousCode: return "Run autonomously"
            case .fullAutonomous: return "Isolated sandbox"
            case .researchWeb: return "Research the web"
            case .gitWorkflow: return "Inspect Git changes"
            }
        }

        var detail: String {
            switch self {
            case .none: return "Keep every option under your control."
            case .readOnlyReview: return "Analyze and report without changing files."
            case .safeCodeEdit: return "Apply file edits; unapproved commands stop the run."
            case .autonomousCode: return "Use Auto mode with Anthropic's background safety checks."
            case .fullAutonomous: return "Bypass every permission check—only for a container or VM."
            case .researchWeb: return "Read the project and use Anthropic's web tools."
            case .gitWorkflow: return "Read the repository and inspect diffs, status, and history."
            }
        }

        var icon: String {
            switch self {
            case .none: return "slider.horizontal.3"
            case .readOnlyReview: return "doc.text.magnifyingglass"
            case .safeCodeEdit: return "pencil.and.outline"
            case .autonomousCode: return "bolt.shield"
            case .fullAutonomous: return "shippingbox"
            case .researchWeb: return "globe"
            case .gitWorkflow: return "arrow.triangle.branch"
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
            case .none: return "Use Claude settings"
            case .defaultMode: return "Ask before actions"
            case .plan: return "Review only"
            case .auto: return "Auto (safety checked)"
            case .acceptEdits: return "Edit files automatically"
            case .dontAsk: return "Only pre-approved tools"
            case .bypassPermissions: return "Bypass all checks"
            }
        }

        var detail: String {
            switch self {
            case .none: return "Use the permission mode from Claude Code settings."
            case .defaultMode: return "Reads are allowed; actions that need approval stop a non-interactive run."
            case .plan: return "Claude can inspect and plan, but cannot edit files."
            case .auto: return "Longer unattended work with Anthropic's background safety classifier."
            case .acceptEdits: return "File edits and common file operations proceed; other commands still need approval."
            case .dontAsk: return "Anything not explicitly pre-approved is denied instead of prompting."
            case .bypassPermissions: return "No permission or safety checks. Use only in an isolated container or VM."
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
            case .none: return "Text (default — no flag)"
            case .text: return "Text (explicit flag)"
            case .json: return "One JSON result after completion"
            case .streamJSON: return "Live JSON event stream"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Print the final response as readable text. Forge omits --output-format because text is already Claude Code's default."
            case .text:
                return "Print the same readable final response, but explicitly add --output-format text."
            case .json:
                return "Emit one JSON result after the run finishes. Choose this when a script will parse the result or when using a JSON Schema."
            case .streamJSON:
                return "Emit newline-delimited JSON events while Claude works. Choose this for a program consuming live progress, not ordinary terminal reading."
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
            case .none: return "Text (default — no flag)"
            case .text: return "Text (explicit flag)"
            case .streamJSON: return "Streaming JSON from stdin"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Send the task as ordinary text. Forge omits --input-format because text is already Claude Code's default."
            case .text:
                return "Send the same ordinary text, but explicitly add --input-format text."
            case .streamJSON:
                return "Read newline-delimited JSON messages from standard input. This is for another program controlling Claude, not a normal one-shot task."
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
            case .none: return "Use permission mode"
            case .allowedTools: return "Pre-approve listed tools"
            case .disallowedTools: return "Always deny listed tools"
            }
        }

        var flag: String? {
            switch self {
            case .none: return nil
            case .allowedTools: return "--allowedTools"
            case .disallowedTools: return "--disallowedTools"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Do not add a per-tool approval or denial list. The selected permission mode decides when Claude must ask."
            case .allowedTools:
                return "Listed tools run without an approval prompt. Other tools remain visible and still follow the selected permission mode."
            case .disallowedTools:
                return "Listed tools or matching calls are denied. This controls permission; Tool availability separately controls which built-in tools Claude can see."
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
            case .none: return "Use Claude's default prompt"
            case .replace: return "Replace Claude's prompt"
            case .append: return "Add instructions (recommended)"
            case .replaceFile: return "Replace from a file"
            case .appendFile: return "Add instructions from a file"
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

        var detail: String {
            switch self {
            case .none:
                return "Keep Claude Code's standard system instructions."
            case .replace:
                return "Replace the standard system prompt with this text. This also removes Claude Code's default tool and safety guidance."
            case .append:
                return "Keep Claude Code's standard instructions and add your own rules at the end. This is the safest customization."
            case .replaceFile:
                return "Load a file and use it instead of Claude Code's standard system prompt."
            case .appendFile:
                return "Load a file and append its instructions to Claude Code's standard system prompt."
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
            case .continueLast: return "Continue latest in this project"
            case .resume: return "Resume by ID or name"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Start a separate conversation for this task."
            case .continueLast:
                return "Continue the most recent conversation associated with the selected project."
            case .resume:
                return "Continue a particular saved conversation by its session ID or display name."
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
            case .none: return "Use normal tool availability"
            case .defaultTools: return "All default built-in tools"
            case .custom: return "Only selected built-in tools"
            case .disabled: return "Disable all built-in tools"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Do not add --tools. Claude Code uses its normal configured set of built-in tools."
            case .defaultTools:
                return "Explicitly expose Claude Code's full default built-in tool set."
            case .custom:
                return "Restrict built-in tools to the names you enter, such as Bash, Edit, and Read. MCP tools are unaffected."
            case .disabled:
                return "Expose no built-in tools. MCP tools can still be available unless separately denied."
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
            case .none: return "Use Claude Code's Chrome setting"
            case .enable: return "Enable Google Chrome integration"
            case .disable: return "Disable Google Chrome integration"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Do not override Chrome integration for this run."
            case .enable:
                return "Let Claude use its Google Chrome integration for browser automation and web testing."
            case .disable:
                return "Turn off Claude Code's Google Chrome integration for this run."
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
        let source: String
        var id: String { name }
    }

    struct MCPIntegration: Identifiable, Hashable {
        let id: String
        let name: String
        let summary: String
        let setupNote: String
        let configJSON: String
    }

    struct MCPRegistryResult: Identifiable, Hashable {
        let id: String
        let serverName: String
        let title: String
        let summary: String
        let transport: String
        let setupNote: String
        let websiteURL: URL?
        let configJSON: String?

        var canAdd: Bool { configJSON != nil }
    }

    static let documentedMCPIntegrations: [MCPIntegration] = [
        MCPIntegration(
            id: "notion", name: "Notion", summary: "Pages, databases, and workspace content",
            setupNote: "Authenticate when Claude Code asks.",
            configJSON: #"{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.com/mcp"}}}"#),
        MCPIntegration(
            id: "sentry", name: "Sentry", summary: "Errors, incidents, and application monitoring",
            setupNote: "Run /mcp interactively if authentication is required.",
            configJSON: #"{"mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"}}}"#),
        MCPIntegration(
            id: "slack", name: "Slack", summary: "Channels, messages, and workspace search",
            setupNote: "Authenticate and approve the Slack scopes Claude needs.",
            configJSON: #"{"mcpServers":{"slack":{"type":"http","url":"https://mcp.slack.com/mcp"}}}"#),
        MCPIntegration(
            id: "stripe", name: "Stripe", summary: "Payments and Stripe account data",
            setupNote: "Authenticate before using account tools.",
            configJSON: #"{"mcpServers":{"stripe":{"type":"http","url":"https://mcp.stripe.com"}}}"#),
        MCPIntegration(
            id: "paypal", name: "PayPal", summary: "PayPal payments and account workflows",
            setupNote: "Authenticate before using account tools.",
            configJSON: #"{"mcpServers":{"paypal":{"type":"http","url":"https://mcp.paypal.com/mcp"}}}"#),
        MCPIntegration(
            id: "hubspot", name: "HubSpot", summary: "CRM records and HubSpot workflows",
            setupNote: "Authenticate before using CRM tools.",
            configJSON: #"{"mcpServers":{"hubspot":{"type":"http","url":"https://mcp.hubspot.com/anthropic"}}}"#),
        MCPIntegration(
            id: "github", name: "GitHub", summary: "Repositories, issues, and pull requests",
            setupNote: "Replace YOUR_GITHUB_PAT in the editable JSON with a fine-grained token.",
            configJSON: #"{"mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer YOUR_GITHUB_PAT"}}}}"#),
    ]

    private let defaults: UserDefaults

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
    private(set) var mcpRegistryResults: [MCPRegistryResult] = []
    private(set) var isSearchingMCPRegistry = false
    private(set) var mcpRegistryError = ""
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    }

    // MARK: - Presets

    func applyPreset(_ preset: Preset) {
        selectedPreset = preset
        guard preset != .none else {
            reviewed = false
            return
        }

        // Presets are deterministic starting points. Clear every option they
        // own so switching away from a dangerous preset cannot leave a hidden
        // bypass flag or stale tool policy behind.
        permissionMode = .defaultMode
        allowDangerouslySkipPermissions = false
        dangerouslySkipPermissions = false
        toolRestriction = .none
        toolList = ""
        builtInToolsMode = .none
        builtInTools = ""
        selectedMCP.removeAll()
        manualMCPConfig = ""
        strictMCP = false
        permissionPromptTool = ""
        maxTurns = ""

        switch preset {
        case .none:
            assertionFailure("Handled above")
        case .readOnlyReview:
            permissionMode = .plan
            toolRestriction = .allowedTools
            toolList = "Read Grep Glob"
        case .safeCodeEdit:
            permissionMode = .acceptEdits
            toolRestriction = .allowedTools
            toolList = "Read Edit Write Grep Glob Bash(git diff *) Bash(git status *)"
        case .autonomousCode:
            permissionMode = .auto
        case .fullAutonomous:
            permissionMode = .bypassPermissions
            maxTurns = "20"
        case .researchWeb:
            permissionMode = .dontAsk
            toolRestriction = .allowedTools
            toolList = "Read WebFetch WebSearch Grep"
        case .gitWorkflow:
            permissionMode = .dontAsk
            toolRestriction = .allowedTools
            toolList = "Read Grep Glob Bash(git diff *) Bash(git status *) Bash(git log *)"
        }
        reviewed = false
    }

    // MARK: - MCP discovery

    func refreshMCP() {
        var found: [String: DiscoveredMCP] = [:]

        func ingest(_ mcpServers: Any?, source: String) {
            guard let dict = mcpServers as? [String: Any] else { return }
            for (name, cfg) in dict where found[name] == nil {
                if let data = try? JSONSerialization.data(withJSONObject: cfg),
                   let json = String(data: data, encoding: .utf8) {
                    found[name] = DiscoveredMCP(name: name, configJSON: json, source: source)
                }
            }
        }

        let home = NSHomeDirectory()
        let selectedProject = URL(filePath: workingDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        if let data = try? Data(contentsOf: URL(filePath: home + "/.claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ingest(root["mcpServers"], source: "Claude user config")
            if let projects = root["projects"] as? [String: Any] {
                for (path, project) in projects {
                    let normalized = URL(filePath: path)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                    guard normalized == selectedProject else { continue }
                    ingest(
                        (project as? [String: Any])?["mcpServers"],
                        source: "Claude project config")
                }
            }
        }

        let projectMCP = URL(filePath: selectedProject).appendingPathComponent(".mcp.json")
        if let data = try? Data(contentsOf: projectMCP),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ingest(root["mcpServers"], source: "Project .mcp.json")
        }

        let forgeMCP = ForgePaths.mcpConfigFile
        if let data = try? Data(contentsOf: forgeMCP),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ingest(root["mcpServers"], source: "Forge MCP config")
        }

        discoveredMCP = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedMCP.formIntersection(Set(found.keys))
    }

    func isMCPIncluded(_ name: String) -> Bool {
        selectedMCP.contains(name) || manualMCPServerNames.contains(name)
    }

    func includeMCPIntegration(_ integration: MCPIntegration) {
        if discoveredMCP.contains(where: { $0.name == integration.id }) {
            selectedMCP.insert(integration.id)
        } else if !manualMCPServerNames.contains(integration.id) {
            appendManualMCPConfig(integration.configJSON)
        }
        reviewed = false
    }

    func includeMCPRegistryResult(_ result: MCPRegistryResult) {
        guard let configJSON = result.configJSON else { return }
        if discoveredMCP.contains(where: { $0.name == result.id }) {
            selectedMCP.insert(result.id)
        } else if !manualMCPServerNames.contains(result.id) {
            appendManualMCPConfig(configJSON)
        }
        reviewed = false
    }

    func searchMCPRegistry(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            mcpRegistryResults = []
            mcpRegistryError = "Enter at least two characters, such as legal, database, research, or GitHub."
            return
        }

        isSearchingMCPRegistry = true
        mcpRegistryError = ""
        defer { isSearchingMCPRegistry = false }

        var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: "24"),
        ]
        guard let url = components.url else {
            mcpRegistryError = "Forge could not create the registry search URL."
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                mcpRegistryError = "The official MCP Registry did not return a successful response."
                return
            }
            mcpRegistryResults = Self.parseMCPRegistryResults(data: data)
            if mcpRegistryResults.isEmpty {
                mcpRegistryError = "No registry servers matched “\(trimmed)”. Try a broader term."
            }
        } catch {
            mcpRegistryError = "Could not search the official MCP Registry: \(error.localizedDescription)"
        }
    }

    static func parseMCPRegistryResults(data: Data) -> [MCPRegistryResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["servers"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let server = entry["server"] as? [String: Any],
                  let serverName = server["name"] as? String else { return nil }

            let title = (server["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title?.isEmpty == false ? title! : registryDisplayName(serverName)
            let summary = (server["description"] as? String) ?? "No description supplied by the publisher."
            let websiteString = (server["websiteUrl"] as? String)
                ?? ((server["repository"] as? [String: Any])?["url"] as? String)
            let websiteURL = websiteString.flatMap(URL.init(string:))
            let id = registryConfigID(serverName)

            if let remote = preferredRemote(server["remotes"] as? [[String: Any]]),
               let url = remote["url"] as? String,
               let rawType = remote["type"] as? String {
                let type = rawType == "streamable-http" ? "http" : rawType
                let config = registryConfigJSON(
                    id: id, entry: ["type": type, "url": url])
                return MCPRegistryResult(
                    id: id,
                    serverName: serverName,
                    title: displayTitle,
                    summary: summary,
                    transport: type.uppercased(),
                    setupNote: "Remote server. It may request OAuth or other authentication when first connected.",
                    websiteURL: websiteURL,
                    configJSON: config)
            }

            if let package = preferredPackage(server["packages"] as? [[String: Any]]) {
                let packageType = (package["registryType"] as? String) ?? "package"
                let identifier = (package["identifier"] as? String) ?? ""
                let version = package["version"] as? String
                let generated = registryPackageConfig(
                    id: id, packageType: packageType, identifier: identifier,
                    version: version, package: package)
                return MCPRegistryResult(
                    id: id,
                    serverName: serverName,
                    title: displayTitle,
                    summary: summary,
                    transport: packageType.uppercased(),
                    setupNote: generated.note,
                    websiteURL: websiteURL,
                    configJSON: generated.json)
            }

            return MCPRegistryResult(
                id: id,
                serverName: serverName,
                title: displayTitle,
                summary: summary,
                transport: "Manual setup",
                setupNote: "The registry entry does not provide a remote URL or a package Forge can translate automatically.",
                websiteURL: websiteURL,
                configJSON: nil)
        }
    }

    private static func preferredRemote(_ remotes: [[String: Any]]?) -> [String: Any]? {
        guard let remotes else { return nil }
        let order = ["streamable-http", "http", "sse", "ws"]
        return remotes.sorted {
            let left = order.firstIndex(of: ($0["type"] as? String) ?? "") ?? order.count
            let right = order.firstIndex(of: ($1["type"] as? String) ?? "") ?? order.count
            return left < right
        }.first { ($0["url"] as? String)?.isEmpty == false }
    }

    private static func preferredPackage(_ packages: [[String: Any]]?) -> [String: Any]? {
        guard let packages else { return nil }
        let order = ["npm", "pypi", "nuget", "oci", "cargo", "mcpb"]
        return packages.sorted {
            let left = order.firstIndex(of: ($0["registryType"] as? String) ?? "") ?? order.count
            let right = order.firstIndex(of: ($1["registryType"] as? String) ?? "") ?? order.count
            return left < right
        }.first
    }

    private static func registryPackageConfig(
        id: String,
        packageType: String,
        identifier: String,
        version: String?,
        package: [String: Any]
    ) -> (json: String?, note: String) {
        guard !identifier.isEmpty else {
            return (nil, "The registry package is missing its install identifier.")
        }

        let command: String
        var args: [String]
        switch packageType {
        case "npm":
            command = (package["runtimeHint"] as? String) ?? "npx"
            let pinned = version.map { "\(identifier)@\($0)" } ?? identifier
            args = command == "npx" ? ["-y", pinned] : [pinned]
        case "pypi":
            command = (package["runtimeHint"] as? String) ?? "uvx"
            args = [identifier]
        case "nuget":
            command = (package["runtimeHint"] as? String) ?? "dnx"
            args = [identifier]
        case "oci":
            command = "docker"
            args = ["run", "--rm", "-i", identifier]
        case "cargo":
            return (nil, "Cargo servers require a one-time cargo install before Forge can launch the resulting binary.")
        case "mcpb":
            return (nil, "MCPB bundles require download and checksum verification before installation.")
        default:
            return (nil, "Forge does not yet translate \(packageType) packages automatically.")
        }

        if let runtimeArguments = package["runtimeArguments"] as? [[String: Any]] {
            for argument in runtimeArguments {
                if let value = argument["value"] as? String, !value.isEmpty {
                    args.append(value)
                } else if argument["isRequired"] as? Bool == true {
                    let name = (argument["name"] as? String) ?? "ARGUMENT"
                    args.append("<REQUIRED: \(name)>")
                }
            }
        }

        var env: [String: String] = [:]
        var requiredNames: [String] = []
        if let variables = package["environmentVariables"] as? [[String: Any]] {
            for variable in variables {
                guard let name = variable["name"] as? String, !name.isEmpty else { continue }
                if let defaultValue = variable["default"] as? String {
                    env[name] = defaultValue
                } else if variable["isRequired"] as? Bool == true {
                    env[name] = "<REQUIRED: \(name)>"
                    requiredNames.append(name)
                }
            }
        }

        var entry: [String: Any] = ["command": command, "args": args]
        if !env.isEmpty { entry["env"] = env }
        let note = requiredNames.isEmpty
            ? "Local \(packageType) package. Review the generated command before running it."
            : "Needs values for: \(requiredNames.joined(separator: ", ")). Edit the raw JSON before running."
        return (registryConfigJSON(id: id, entry: entry), note)
    }

    private static func registryConfigJSON(id: String, entry: [String: Any]) -> String? {
        let root: [String: Any] = ["mcpServers": [id: entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func registryConfigID(_ serverName: String) -> String {
        let leaf = serverName.split(separator: "/").last.map(String.init) ?? serverName
        let cleaned = leaf.map { character -> Character in
            character.isLetter || character.isNumber || "._-".contains(character) ? character : "-"
        }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func registryDisplayName(_ serverName: String) -> String {
        registryConfigID(serverName)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    @discardableResult
    func addRemoteMCP(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Enter a short server name." }
        let allowedName = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmedName.unicodeScalars.allSatisfy(allowedName.contains) else {
            return "Use only letters, numbers, periods, underscores, or hyphens in the name."
        }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased() else {
            return "Enter a complete MCP server URL."
        }
        let host = url.host?.lowercased() ?? ""
        let loopbackHosts = Set(["localhost", "127.0.0.1", "::1"])
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            return "Use HTTPS, or HTTP only for a server running on this Mac."
        }
        guard !isMCPIncluded(trimmedName) else { return "That server is already included." }

        let object: [String: Any] = [
            "mcpServers": [
                trimmedName: ["type": "http", "url": trimmedURL]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Forge could not create the MCP configuration."
        }
        appendManualMCPConfig(json)
        reviewed = false
        return nil
    }

    private func appendManualMCPConfig(_ json: String) {
        let existing = manualMCPConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        manualMCPConfig = existing.isEmpty ? json : existing + "\n" + json
    }

    // MARK: - Validation

    var hasMissionScaffold: Bool {
        prompt.contains(Self.missionScaffoldHeading)
    }

    var hasMeaningfulPrompt: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard hasMissionScaffold,
              let taskRange = prompt.range(of: Self.missionTaskDelimiter) else {
            return true
        }
        return !prompt[taskRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    func insertMissionScaffold() {
        guard !hasMissionScaffold else { return }
        let existingTask = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = Self.missionScaffold + existingTask
        reviewed = false
    }

    var isDangerous: Bool {
        permissionMode.isDangerous || dangerouslySkipPermissions || selectedPreset.isDangerous
    }

    var validationMessages: [String] {
        var messages: [String] = []

        if !hasMeaningfulPrompt {
            messages.append("Describe what you want Claude to do.")
        }
        let directory = resolvedWorkingDirectory
        if directory.isEmpty {
            messages.append("Choose a project folder, or enter a working directory.")
        } else if !isExistingDirectory(directory) {
            messages.append("The working directory does not exist: \(directory)")
        }
        for extraDirectory in extraDirectoryList {
            let path = resolvedPath(extraDirectory)
            if !isExistingDirectory(path) {
                messages.append("Additional directory does not exist: \(path)")
            }
        }
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
        if toolRestriction != .none && toolTokens(toolList).isEmpty {
            messages.append("Choose at least one tool for the selected tool policy.")
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
        let schema = jsonSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !schema.isEmpty {
            if outputFormat != .json {
                messages.append("Structured output requires --output-format json.")
            }
            if let data = schema.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) == nil {
                messages.append("The JSON Schema is not valid JSON.")
            }
        }
        return messages
    }

    var advisoryMessages: [String] {
        var messages: [String] = []
        if permissionMode == .defaultMode {
            messages.append("In a non-interactive run, actions needing approval stop instead of opening a prompt.")
        } else if permissionMode == .auto {
            messages.append("Auto mode requires an eligible Anthropic account; Claude Code reports an error if it is unavailable.")
        }
        if systemPromptMode == .replace || systemPromptMode == .replaceFile {
            messages.append("Replacing the system prompt also removes Claude Code's default tool and safety guidance.")
        }
        if bare {
            messages.append("Bare mode is optimized for scripts but skips CLAUDE.md, hooks, plugins, MCP auto-discovery, and keychain/OAuth credentials.")
        }
        return messages
    }

    var canCompose: Bool {
        hasMeaningfulPrompt && validationMessages.isEmpty
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

    private var manualMCPServerNames: Set<String> {
        var names = Set<String>()
        for config in manualMCPConfigArguments {
            guard let data = config.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any] else { continue }
            names.formUnion(servers.keys)
        }
        return names
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

    private var resolvedWorkingDirectory: String {
        expandTilde(workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolvedPath(_ path: String) -> String {
        let expanded = expandTilde(path)
        guard !expanded.hasPrefix("/") else {
            return URL(filePath: expanded).standardizedFileURL.path
        }
        return URL(
            filePath: expanded,
            relativeTo: URL(filePath: resolvedWorkingDirectory, directoryHint: .isDirectory)
        ).standardizedFileURL.path
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var outputFolderNeedsAdditionalAccess: Bool {
        guard let outputFolderPath else { return false }
        let working = URL(filePath: resolvedWorkingDirectory).standardizedFileURL.path
        let output = resolvedPath(outputFolderPath)
        return output != working && !output.hasPrefix(working + "/")
    }

    private var emittedAdditionalDirectories: [String] {
        var directories: [String] = []
        if let outputFolderPath, outputFolderNeedsAdditionalAccess {
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
        selectedMCP.union(manualMCPServerNames).sorted().map { "mcp__\($0)__*" }
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
            segments.append("--add-dir \(shellQuote(expandTilde(directory)))")
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

        let claudeCommand = lines.joined(separator: " \\\n  ")
        var setupCommands: [String] = []
        let directory = resolvedWorkingDirectory
        if !directory.isEmpty {
            setupCommands.append("cd \(shellQuote(directory))")
        }
        if let outputFolderPath {
            setupCommands.append("mkdir -p \(shellQuote(expandTilde(outputFolderPath)))")
        }
        setupCommands.append(claudeCommand)
        return setupCommands.joined(separator: " && \\\n")
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
