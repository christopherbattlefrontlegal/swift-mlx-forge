// Forge — Claude Code headless command helper.
//
// This is a composer only. It builds a safe commented command preview and a
// separately gated ready-to-run command. Forge does not execute the command.

import AppKit
import SwiftUI

struct LauncherView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var copiedMode: String?
    @State private var pendingDangerPreset: HeadlessLauncher.Preset?
    @State private var pendingDangerPermission: HeadlessLauncher.PermissionMode?
    @State private var confirmDangerPreset = false
    @State private var confirmDangerPermission = false
    @State private var didRefreshMCP = false
    @State private var showAdvanced = false
    @State private var newMCPName = ""
    @State private var newMCPURL = ""
    @State private var newMCPError = ""
    @State private var mcpRegistryQuery = ""

    private let columns = [GridItem(.adaptive(minimum: 360), spacing: Theme.s3)]

    var body: some View {
        @Bindable var hl = app.launcher
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    quickStartSection(hl)
                    missionSection(hl)
                    essentialsSection(hl)
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: Theme.s3) {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3) {
                                advancedPickers(hl)
                            }
                            toolsSection(hl)
                            systemPromptSection(hl)
                            mcpSection(hl)
                        }
                        .padding(.top, Theme.s3)
                    } label: {
                        Label(
                            showAdvanced ? "Hide advanced Claude Code options" : "Show advanced Claude Code options",
                            systemImage: "gearshape.2"
                        )
                        .font(.headline)
                    }
                    .padding(Theme.s3)
                    .glassCard()
                }
                .padding(Theme.s4)
            }
            Divider()
            outputBar(hl)
        }
        .frame(width: 900, height: 780)
        .background(Theme.backgroundGradient)
        .confirmationDialog(
            "Use bypass mode in an isolated sandbox?",
            isPresented: $confirmDangerPreset,
            titleVisibility: .visible
        ) {
            Button("Enable bypassPermissions", role: .destructive) {
                if let preset = pendingDangerPreset {
                    hl.applyPreset(preset)
                }
                pendingDangerPreset = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDangerPreset = nil
            }
        } message: {
            Text("This removes Claude Code's permission and safety checks. Anthropic recommends it only inside an isolated container or VM.")
        }
        .confirmationDialog(
            "Bypass all permissions?",
            isPresented: $confirmDangerPermission,
            titleVisibility: .visible
        ) {
            Button("Use bypassPermissions", role: .destructive) {
                if let permission = pendingDangerPermission {
                    hl.permissionMode = permission
                    hl.reviewed = false
                }
                pendingDangerPermission = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDangerPermission = nil
            }
        } message: {
            Text("This is the highest-risk permission mode. Anthropic recommends it only inside an isolated container or VM.")
        }
        .task {
            guard !didRefreshMCP else { return }
            didRefreshMCP = true
            app.launcher.refreshMCP()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "terminal")
                .foregroundStyle(Theme.emberGradient)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code Headless Builder")
                    .font(.headline)
                Text("Create a non-interactive `claude -p` task. Forge builds the command but never runs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.launcher.refreshMCP()
            } label: {
                Label("Rescan MCP", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Re-read MCP servers from ~/.claude.json and the selected working directory's .mcp.json")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(Theme.s4)
    }

    // MARK: - Mission

    @ViewBuilder
    private func quickStartSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("1. Start with a run style", icon: "sparkles") {
            HStack(alignment: .top, spacing: Theme.s3) {
                Picker("Run style", selection: Binding(
                    get: { hl.selectedPreset },
                    set: { newValue in
                        if newValue.isDangerous {
                            pendingDangerPreset = newValue
                            confirmDangerPreset = true
                        } else {
                            hl.applyPreset(newValue)
                        }
                    }
                )) {
                    ForEach(HeadlessLauncher.Preset.allCases) { preset in
                        Label(preset.label, systemImage: preset.icon).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(hl.selectedPreset.label)
                        .font(.callout.weight(.semibold))
                    Text(hl.selectedPreset.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func missionSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Label("2. Describe the task", systemImage: "text.alignleft")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    hl.insertMissionScaffold()
                } label: {
                    Label(
                        hl.hasMissionScaffold ? "Scaffold added" : "Add mission scaffold",
                        systemImage: hl.hasMissionScaffold ? "checkmark" : "wand.and.stars"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hl.hasMissionScaffold)
                .help("Add an editable Anthropic-style execution contract around the task")
            }
            TextEditor(text: $hl.prompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 106)
                .padding(Theme.s2)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.prompt.isEmpty {
                        Text("Example: Run the tests, fix the failing cases, and summarize what changed.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s3)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()

        card("3. Choose the project", icon: "folder") {
            HStack(spacing: Theme.s2) {
                TextField("/path/to/project", text: $hl.workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Browse") { browse($hl.workingDirectory, refreshMCP: true) }
            }
            Text("Claude Code reads project instructions and settings from this folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.s2) {
                TextField("Optional output folder", text: $hl.outputFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Browse") { browse($hl.outputFolder) }
            }
            Text("Forge creates the output folder first, grants access when it is outside the project, and tells Claude to put generated artifacts there.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func essentialsSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("4. Confirm the essentials", icon: "checklist") {
            HStack(alignment: .top, spacing: Theme.s4) {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Permission behavior")
                        .font(.callout.weight(.semibold))
                    Picker("Permission behavior", selection: Binding(
                        get: { hl.permissionMode },
                        set: { newValue in
                            if newValue.isDangerous {
                                pendingDangerPermission = newValue
                                confirmDangerPermission = true
                            } else {
                                hl.permissionMode = newValue
                                hl.reviewed = false
                            }
                        }
                    )) {
                        ForEach(HeadlessLauncher.PermissionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    Text(hl.permissionMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Model")
                        .font(.callout.weight(.semibold))
                    Picker("Model", selection: $hl.model) {
                        ForEach(HeadlessLauncher.models, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    if hl.model == "custom" {
                        TextField("Full model ID", text: $hl.customModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    } else {
                        Text("Aliases follow the latest model available to your account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Result")
                        .font(.callout.weight(.semibold))
                    Picker("Result format", selection: $hl.outputFormat) {
                        ForEach(HeadlessLauncher.OutputFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    Text(hl.outputFormat.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private func advancedPickers(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl

        pickerCard("Additional Folder Access", icon: "folder.badge.plus") {
            TextEditor(text: $hl.additionalDirectories)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 54)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.additionalDirectories.isEmpty {
                        Text("Existing paths, one per line")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s2)
                            .allowsHitTesting(false)
                    }
                }
            Text("Adds file access only. Claude does not load most project configuration from these folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        pickerCard("Fallback Model", icon: "arrow.triangle.branch") {
            Picker("Fallback", selection: $hl.fallbackModel) {
                ForEach(HeadlessLauncher.fallbackModels, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            if hl.fallbackModel == "custom" {
                TextField("Full fallback model ID", text: $hl.customFallbackModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            Text("Used automatically only when the primary model is overloaded or unavailable. Leave this off for normal runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        pickerCard("Task Input Format", icon: "arrow.down.doc") {
            Picker("Input format", selection: $hl.inputFormat) {
                ForEach(HeadlessLauncher.InputFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .font(.callout)
            Text(hl.inputFormat.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        pickerCard("Structured JSON Result", icon: "curlybraces.square") {
            Text("Optional JSON Schema")
                .font(.callout.weight(.semibold))
            TextEditor(text: $hl.jsonSchema)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 46)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.jsonSchema.isEmpty {
                        Text("Paste a JSON Schema here")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s2)
                            .allowsHitTesting(false)
                    }
                }
            Text("After Claude finishes, validate its structured result against this schema. Requires “One JSON result after completion” under Result above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        pickerCard("Live JSON Event Options", icon: "waveform.path.ecg") {
            Text("These are for software consuming a live JSON event stream. Most one-shot terminal tasks should leave them off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            explainedToggle(
                "Stream partial text as it is generated",
                detail: "Adds token-level partial events. Requires Live JSON event stream output.",
                isOn: $hl.includePartialMessages
            )
            explainedToggle(
                "Include hook lifecycle events",
                detail: "Reports hook starts and completions. Requires Live JSON event stream output.",
                isOn: $hl.includeHookEvents
            )
            explainedToggle(
                "Echo streamed user input",
                detail: "Re-emits stdin user messages as acknowledgments. Requires streaming JSON input and output.",
                isOn: $hl.replayUserMessages
            )
            explainedToggle(
                "Suggest the next user prompt",
                detail: "Emits a predicted next prompt after each turn. Requires Live JSON event stream output and Verbose.",
                isOn: $hl.promptSuggestions
            )
        }

        pickerCard("Permission Overrides", icon: "shield.lefthalf.filled", danger: hl.permissionMode.isDangerous) {
            Text("Advanced escape hatches. Most headless runs should leave both off and use Permission behavior above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            explainedToggle(
                "Allow switching to bypass mode later",
                detail: "Adds bypassPermissions to Claude Code's mode cycle without starting there. Mainly useful in an interactive session.",
                isOn: $hl.allowDangerouslySkipPermissions
            )
            explainedToggle(
                "Start with every permission check bypassed",
                detail: "Runs without permission prompts or safety checks. Use only inside an isolated container or VM.",
                isOn: $hl.dangerouslySkipPermissions
            )
        }

        pickerCard("Conversation & Session", icon: "clock.arrow.circlepath") {
            Picker("Conversation", selection: $hl.sessionMode) {
                ForEach(HeadlessLauncher.SessionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            Text(hl.sessionMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hl.sessionMode == .resume {
                TextField("Session ID or display name to resume", text: $hl.sessionValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            Divider()
            TextField("Optional UUID for the new conversation", text: $hl.sessionID)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Text("Usually leave the UUID blank and let Claude Code create one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Optional display name", text: $hl.sessionName)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            explainedToggle(
                "Fork a resumed conversation",
                detail: "Continue its context under a new session ID instead of modifying the original session.",
                isOn: $hl.forkSession
            )
            explainedToggle(
                "Do not save this conversation",
                detail: "The session cannot be resumed later because Claude Code will not persist it to disk.",
                isOn: $hl.noSessionPersistence
            )
        }

        pickerCard("Limits", icon: "speedometer") {
            Text("Optional stopping limits for unattended work. Leave a field blank for Claude Code's normal behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.s2) {
                TextField("Maximum agent turns", text: Binding(
                    get: { hl.maxTurns },
                    set: { hl.maxTurns = $0.filter(\.isNumber) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                TextField("Maximum API cost (USD)", text: $hl.maxBudgetUSD)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            explainedToggle(
                "Verbose turn-by-turn output",
                detail: "Show full turn details. Also required when emitting prompt suggestions.",
                isOn: $hl.verbose
            )
            explainedToggle(
                "Enable diagnostic logging",
                detail: "Turn on Claude Code debug output for troubleshooting API, MCP, hook, or startup problems.",
                isOn: $hl.debug
            )
            if hl.debug {
                TextField("Optional debug categories, e.g. api,mcp", text: $hl.debugFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            TextField("Optional debug log file path", text: $hl.debugFile)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }

        pickerCard("Runtime", icon: "gearshape.2") {
            Picker("Google Chrome", selection: $hl.chromeMode) {
                ForEach(HeadlessLauncher.ChromeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Text(hl.chromeMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            explainedToggle(
                "Bare mode (faster scripted startup)",
                detail: "Skip CLAUDE.md, hooks, skills, plugins, MCP discovery, and auto-memory. Basic Bash, read, and edit tools remain available.",
                isOn: $hl.bare
            )
            explainedToggle(
                "Safe mode (troubleshoot configuration)",
                detail: "Temporarily disable customizations such as CLAUDE.md, skills, plugins, hooks, MCP, agents, and output styles while keeping authentication, models, built-in tools, and permissions.",
                isOn: $hl.safeMode
            )
            explainedToggle(
                "Screen-reader-friendly output",
                detail: "Render flat text without decorative borders or animations for assistive technology and simpler output capture.",
                isOn: $hl.axScreenReader
            )
            explainedToggle(
                "Auto-connect the active IDE",
                detail: "Connect at startup when exactly one supported IDE is available, so Claude can use that editor integration.",
                isOn: $hl.ide
            )
            explainedToggle(
                "Disable slash commands and skills",
                detail: "Prevent built-in commands, custom commands, and skills from being invoked during this session.",
                isOn: $hl.disableSlashCommands
            )
            explainedToggle(
                "Optimize the system prompt for shared caching",
                detail: "Move machine-specific details into the first user message. Useful for scripted multi-user workloads; usually unnecessary for a local one-off run.",
                isOn: $hl.excludeDynamicSystemPromptSections
            )
        }

        pickerCard("Settings & Reasoning", icon: "slider.horizontal.below.rectangle") {
            Text("One-run settings override")
                .font(.callout.weight(.semibold))
            TextField("Settings JSON file path or inline JSON", text: $hl.settings)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Text("Supply a JSON file or JSON object whose keys override matching settings for this run. Omitted keys continue using normal file-based settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Settings sources to load")
                .font(.callout.weight(.semibold))
            TextField("Optional: user,project,local", text: $hl.settingSources)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Text("Leave blank for normal loading. User is ~/.claude/settings.json; project is shared .claude/settings.json; local is your gitignored .claude/settings.local.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Reasoning effort", selection: $hl.effortLevel) {
                ForEach(HeadlessLauncher.EffortLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            Text("Lower effort is faster and cheaper for straightforward work; higher effort gives supported models more room for difficult reasoning. Default suits most tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Optional advisor model, e.g. opus", text: $hl.advisorModel)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Text("Let the main model consult a second model at important moments, such as choosing an approach, getting unstuck, or checking completion. Best for long, complex tasks and may use more tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private func toolsSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("Tools", icon: "hammer") {
            Text("1. Choose which built-in Claude Code tools exist")
                .font(.callout.weight(.semibold))
            Picker("Tool availability", selection: $hl.builtInToolsMode) {
                ForEach(HeadlessLauncher.BuiltInToolsMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(hl.builtInToolsMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hl.builtInToolsMode == .custom {
                TextField("Bash,Edit,Read or default", text: $hl.builtInTools)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            Divider()
            Text("2. Choose which tool calls need approval")
                .font(.callout.weight(.semibold))
            Picker("Approval policy", selection: $hl.toolRestriction) {
                ForEach(HeadlessLauncher.ToolRestriction.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(hl.toolRestriction.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.s2)], alignment: .leading, spacing: Theme.s2) {
                ForEach(HeadlessLauncher.commonTools, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(
                        get: { hl.containsTool(tool) },
                        set: { hl.setTool(tool, enabled: $0) }
                    ))
                    .toggleStyle(.button)
                    .font(.callout)
                }
            }
            .disabled(hl.toolRestriction == .none)

            TextEditor(text: $hl.toolList)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(Theme.s1)
                .background(Theme.codeBackground)
                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                .overlay(alignment: .topLeading) {
                    if hl.toolList.isEmpty {
                        Text("Read Edit Bash(git diff *)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(Theme.s2)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(hl.toolRestriction == .none)

            Text("“Custom built-in tools” means a subset of Claude Code's own tools. Your MCP integrations are separate and appear in the MCP Servers section below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("permission prompt MCP tool", text: $hl.permissionPromptTool)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Text("Advanced: name an MCP tool that can answer permission requests during a non-interactive run. Leave blank unless you have built that approval service.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - System Prompt

    @ViewBuilder
    private func systemPromptSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("System Prompt", icon: "quote.bubble") {
            HStack(spacing: Theme.s2) {
                Picker("Mode", selection: $hl.systemPromptMode) {
                    ForEach(HeadlessLauncher.SystemPromptMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Menu {
                    if app.promptPresets.isEmpty && app.availablePrompts().isEmpty {
                        Text("No prompt library entries")
                    }
                    ForEach(app.promptPresets) { preset in
                        Button(preset.name) {
                            hl.systemPromptText = preset.text
                            if hl.systemPromptMode == .none { hl.systemPromptMode = .append }
                        }
                        .disabled(hl.systemPromptMode.usesFile)
                    }
                    ForEach(app.availablePrompts(), id: \.category) { category, items in
                        Section(category) {
                            ForEach(items, id: \.url) { name, url in
                                Button(name) {
                                    if hl.systemPromptMode.usesFile {
                                        hl.systemPromptText = url.path
                                    } else if let content = app.loadPromptContent(from: url) {
                                        hl.systemPromptText = content
                                        if hl.systemPromptMode == .none { hl.systemPromptMode = .append }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Insert From Library", systemImage: "book.closed")
                }
                .disabled(hl.systemPromptMode == .none)
            }

            Text(hl.systemPromptMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hl.systemPromptMode.usesFile {
                TextField("prompt file path", text: $hl.systemPromptText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            } else {
                TextEditor(text: $hl.systemPromptText)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(Theme.s1)
                    .background(Theme.codeBackground)
                    .clipShape(.rect(cornerRadius: Theme.radiusSmall))
            }
        }
    }

    // MARK: - MCP

    @ViewBuilder
    private func mcpSection(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        card("MCP Servers", icon: "server.rack") {
            if hl.discoveredMCP.isEmpty {
                Text("No configured MCP servers found in Claude, this project, or Forge.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Your configured servers")
                    .font(.callout.weight(.semibold))
                Text("Check a server to include its existing configuration in this headless run. Forge also pre-approves that server's MCP tools so the run does not stop for a prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MCPServerChecklist(servers: hl.discoveredMCP, selected: $hl.selectedMCP)
            }

            Divider()
            HStack {
                Text("Anthropic-documented integrations")
                    .font(.callout.weight(.semibold))
                Spacer()
                Link(destination: URL(string: "https://claude.ai/directory")!) {
                    Label("Browse directory", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
            }
            Text("Add an editable remote-server configuration to this command. Services may ask you to authenticate in an interactive Claude Code session before a headless run can use them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.s2)], alignment: .leading, spacing: Theme.s2) {
                ForEach(HeadlessLauncher.documentedMCPIntegrations) { integration in
                    MCPIntegrationCard(
                        integration: integration,
                        included: hl.isMCPIncluded(integration.id),
                        add: { hl.includeMCPIntegration(integration) })
                }
            }

            Divider()
            HStack {
                Text("Search the official MCP Registry")
                    .font(.callout.weight(.semibold))
                Spacer()
                Link(destination: URL(string: "https://registry.modelcontextprotocol.io")!) {
                    Label("Open registry", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
            }
            Text("Search the broader MCP ecosystem by server name. Forge can translate remote servers and common npm, PyPI, NuGet, and Docker packages into editable Claude Code configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.s2) {
                TextField("Try legal, database, research, browser, GitHub…", text: $mcpRegistryQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { searchRegistry(hl) }
                Button("Search") { searchRegistry(hl) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .disabled(hl.isSearchingMCPRegistry)
                if hl.isSearchingMCPRegistry {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack(spacing: Theme.s1) {
                ForEach(["legal", "database", "research", "GitHub", "browser", "productivity"], id: \.self) { suggestion in
                    Button(suggestion) {
                        mcpRegistryQuery = suggestion
                        searchRegistry(hl)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if !hl.mcpRegistryError.isEmpty {
                Text(hl.mcpRegistryError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !hl.mcpRegistryResults.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.s2)], alignment: .leading, spacing: Theme.s2) {
                    ForEach(hl.mcpRegistryResults) { result in
                        MCPRegistryResultCard(
                            result: result,
                            included: hl.isMCPIncluded(result.id),
                            add: { hl.includeMCPRegistryResult(result) })
                    }
                }
            }

            Divider()
            Text("Add any remote MCP server")
                .font(.callout.weight(.semibold))
            HStack(spacing: Theme.s2) {
                TextField("Short name", text: $newMCPName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField("https://server.example/mcp", text: $newMCPURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Add to command") {
                    if let error = hl.addRemoteMCP(name: newMCPName, urlString: newMCPURL) {
                        newMCPError = error
                    } else {
                        newMCPName = ""
                        newMCPURL = ""
                        newMCPError = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
            }
            if !newMCPError.isEmpty {
                Text(newMCPError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Edit raw MCP configuration") {
                TextEditor(text: $hl.manualMCPConfig)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(Theme.s1)
                    .background(Theme.codeBackground)
                    .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                Text("One JSON configuration or file path per line. Use this for headers, tokens, stdio commands, or configurations copied from a server's documentation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            explainedToggle(
                "Use only the MCP configurations shown here",
                detail: "Ignore every other MCP configuration Claude Code would normally discover for this run.",
                isOn: $hl.strictMCP
            )
                .disabled(hl.selectedMCP.isEmpty && hl.manualMCPConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Output

    @ViewBuilder
    private func outputBar(_ hl: HeadlessLauncher) -> some View {
        @Bindable var hl = hl
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Label("Command preview", systemImage: "terminal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if hl.isDangerous {
                    Label("Bypass mode", systemImage: "exclamationmark.octagon.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                } else if hl.validationMessages.isEmpty {
                    Label("Ready to copy", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            ScrollView(.vertical) {
                Text(hl.annotatedCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(hl.validationMessages.isEmpty ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s3)
            }
            .frame(height: 148)
            .background(Theme.codeBackground)
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))

            if !hl.validationMessages.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(hl.validationMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !hl.advisoryMessages.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(hl.advisoryMessages, id: \.self) { message in
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: Theme.s3) {
                if hl.isDangerous {
                    Toggle(isOn: $hl.reviewed) {
                        Text("I reviewed this bypassPermissions command.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button {
                    copy(hl.annotatedCommand, mode: "safe")
                } label: {
                    Label(copiedMode == "safe" ? "Preview copied" : "Copy safe preview", systemImage: copiedMode == "safe" ? "checkmark" : "doc.on.doc")
                        .padding(.horizontal, Theme.s2)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!hl.canCompose)

                Button {
                    copy(hl.commandText, mode: "ready")
                } label: {
                    Label(copiedMode == "ready" ? "Command copied" : "Copy command", systemImage: copiedMode == "ready" ? "checkmark" : "paperplane.fill")
                        .padding(.horizontal, Theme.s2)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(hl.isDangerous ? .red : Theme.ember)
                .disabled(!hl.canCompose || (hl.isDangerous && !hl.reviewed))
            }
        }
        .padding(Theme.s3)
        .background(.ultraThinMaterial)
        .onChange(of: hl.commandText) {
            copiedMode = nil
            hl.reviewed = false
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func pickerCard(_ title: String, icon: String, danger: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(danger ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            content()
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func explainedToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func browse(_ binding: Binding<String>, refreshMCP: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
            if refreshMCP {
                app.launcher.refreshMCP()
            }
        }
    }

    private func searchRegistry(_ hl: HeadlessLauncher) {
        Task { await hl.searchMCPRegistry(mcpRegistryQuery) }
    }

    private func copy(_ text: String, mode: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMode = mode
    }
}

private struct MCPServerChecklist: View {
    let servers: [HeadlessLauncher.DiscoveredMCP]
    @Binding var selected: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: Theme.s2)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s2) {
            ForEach(servers) { server in
                Toggle(isOn: Binding(
                    get: { selected.contains(server.name) },
                    set: { isOn in
                        if isOn {
                            selected.insert(server.name)
                        } else {
                            selected.remove(server.name)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name)
                            .font(.callout.monospaced())
                        Text(server.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

private struct MCPIntegrationCard: View {
    let integration: HeadlessLauncher.MCPIntegration
    let included: Bool
    let add: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(.callout.weight(.semibold))
                Text(integration.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(integration.setupNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.s2)
            Button(included ? "Added" : "Add", action: add)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(included)
        }
        .padding(Theme.s2)
        .background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }
}

private struct MCPRegistryResultCard: View {
    let result: HeadlessLauncher.MCPRegistryResult
    let included: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(result.transport)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(result.setupNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            HStack {
                Text(result.serverName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let websiteURL = result.websiteURL {
                    Link("Details", destination: websiteURL)
                        .font(.caption)
                }
                Button(included ? "Added" : result.canAdd ? "Add" : "Manual", action: add)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(included || !result.canAdd)
            }
        }
        .padding(Theme.s2)
        .background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }
}
