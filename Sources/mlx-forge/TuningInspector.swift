// Forge — generation tuning inspector: sampling, limits, system prompt, API/MCP status.

import AppKit
import SwiftUI

struct TuningInspector: View {
    @Environment(AppState.self) private var app
    @State private var showPromptEditor = false
    @State private var showPresetNamePrompt = false
    @State private var presetNameDraft = ""
    @AppStorage("inspector.serverExpanded") private var serverExpanded = false
    @AppStorage("inspector.samplingExpanded") private var samplingExpanded = true
    @AppStorage("inspector.reasoningExpanded") private var reasoningExpanded = true
    @AppStorage("inspector.promptExpanded") private var promptExpanded = true
    @AppStorage("inspector.modelsExpanded") private var modelsExpanded = true
    @AppStorage("inspector.mcpExpanded") private var mcpExpanded = true

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                collapsibleSection(
                    "Sampling & Limits", icon: "dice", expanded: $samplingExpanded,
                    detail:
                        "t \(app.settings.temperature.formatted(.number.precision(.fractionLength(2))))"
                ) {
                    ParameterSlider(
                        label: "Temperature", value: $app.settings.temperature,
                        range: 0...1, hardLimit: 0...2, fractionDigits: 2)
                        .help("Usual range 0–1. MLX allows up to 2 if you type it in.")
                    ParameterSlider(
                        label: "Top P", value: $app.settings.topP,
                        range: 0...1, hardLimit: 0...1, fractionDigits: 2)
                    ParameterSlider(
                        label: "Min P", value: $app.settings.minP,
                        range: 0...1, hardLimit: 0...1, fractionDigits: 2)
                    IntField(
                        label: "Top K", value: $app.settings.topK,
                        limit: 0...100_000, zeroMeans: "off")
                    IntField(
                        label: "Max tokens", value: $app.settings.maxTokens,
                        limit: 0...10_000_000, zeroMeans: "∞",
                        presets: [4096, 16384, 65536, 262_144, 1_000_000, 10_000_000, 0])
                    IntField(
                        label: "Max KV cache", value: $app.settings.maxKVSize,
                        limit: 0...10_000_000, zeroMeans: "∞")
                        .help(
                            "Caps how many past tokens stay in GPU memory (the KV cache). "
                                + "0 = unlimited. Lower this if long chats run out of RAM.")
                    RepetitionPenaltySlider(value: $app.settings.repetitionPenalty)
                    Button("Reset sampling to defaults") {
                        var next = app.settings
                        next.resetSamplingToDefaults()
                        app.settings = next
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(
                        "Temperature 0.7, top-p 0.95, repetition 1.0 (off), max tokens 4096, KV cache unlimited.")
                    Picker("API auto-load policy", selection: $app.settings.weightLoadPolicy) {
                        ForEach(WeightLoadPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .help(WeightLoadPolicy.eager.help)
                }

                collapsibleSection(
                    "Reasoning", icon: "brain", expanded: $reasoningExpanded,
                    detail: reasoningSectionDetail
                ) {
                    localThinkingSection
                    Toggle("Show reasoning in chat", isOn: $app.settings.reasoningEnabled)
                        .help(
                            "System prompt → user prompt → reasoning → answer. "
                                + "For local Qwen models, use Thinking mode above to control whether the model thinks; "
                                + "this toggle controls whether `` blocks appear in the transcript. "
                                + "Claude: adaptive thinking + effort. "
                                + "OpenAI: reasoning.effort + summary. "
                                + "OpenRouter: reasoning.effort.")
                    if app.settings.reasoningEnabled {
                        Picker(
                            "Cloud reasoning effort",
                            selection: Binding(
                                get: {
                                    CloudReasoningEffort(rawValue: app.settings.anthropicEffort)
                                        ?? .high
                                },
                                set: { app.settings.anthropicEffort = $0.rawValue })
                        ) {
                            ForEach(CloudReasoningEffort.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.menu)
                        Toggle(
                            "Reasoning summary (Claude + OpenAI)",
                            isOn: $app.settings.anthropicThinkingSummarized)
                        .help(
                            "Claude Opus 4.8+ and OpenAI Responses API reasoning.summary: auto.")
                    }
                }

                collapsibleSection(
                    "System Prompt", icon: "text.quote", expanded: $promptExpanded,
                    detail: systemPromptSectionDetail
                ) {
                    HStack {
                        Menu {
                            if app.promptPresets.isEmpty {
                                Text("No presets saved yet")
                            }
                            ForEach(app.promptPresets) { preset in
                                Button {
                                    app.applySystemPrompt(preset.text, preset: preset)
                                } label: {
                                    Label(
                                        preset.name,
                                        systemImage: app.activePromptPresetID == preset.id
                                            && preset.text == app.settings.systemPrompt
                                            ? "checkmark" : "")
                                }
                            }
                            Divider()
                            Button("Save Current as Preset…") {
                                presetNameDraft = ""
                                showPresetNamePrompt = true
                            }
                            .disabled(
                                app.settings.systemPrompt
                                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if !app.promptPresets.isEmpty {
                                Menu("Delete Preset") {
                                    ForEach(app.promptPresets) { preset in
                                        Button(preset.name, role: .destructive) {
                                            app.removePromptPreset(preset)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Presets", systemImage: "bookmark")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Spacer()

                        if !app.settings.systemPrompt.isEmpty {
                            Text(app.systemPromptSourceLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.emberGlow)
                                .lineLimit(1)
                        }
                        Text(promptSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Button {
                            showPromptEditor = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open the system prompt in a large resizable editor")
                    }

                    TextEditor(text: systemPromptBinding)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 56, maxHeight: 120)
                        .padding(Theme.s2)
                        .background(.black.opacity(0.25))
                        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                }

                collapsibleSection(
                    "Loaded Models", icon: "cpu", expanded: $modelsExpanded,
                    detail: ModelMemoryBudget.catalogSubtitle(app.memoryBudgetSnapshot)
                ) {
                    Text(ModelMemoryBudget.catalogMenuLabel(app.memoryBudgetSnapshot))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !app.engine.loadedModels.isEmpty {
                        ForEach(app.engine.loadedModels) { entry in
                            LoadedModelRow(entry: entry)
                        }
                    } else {
                        Text("No models resident — load from Model Library (⌘M).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                collapsibleSection(
                    "API Server", icon: "network", expanded: $serverExpanded,
                    badge: serverRunning
                ) {
                    Toggle(isOn: $app.serverEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("OpenAI-compatible server")
                                .font(.callout)
                            Text("Local agents connect via the OpenAI SDK")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.ember)

                    IntField(
                        label: "Port", value: $app.serverPort,
                        limit: 1024...65535)

                    switch app.server.state {
                    case .running:
                        if let url = app.server.baseURL {
                            HStack(spacing: Theme.s2) {
                                Circle()
                                    .fill(Theme.okGreen)
                                    .frame(width: 7, height: 7)
                                Text(url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Copy base URL")
                            }
                            labeledValue("Requests served", "\(app.server.requestsServed)")
                            if app.server.activeRequests > 0 {
                                labeledValue("In flight", "\(app.server.activeRequests)")
                            }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .stopped:
                        Text("Loopback only (127.0.0.1) — nothing leaves this Mac.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                collapsibleSection(
                    "MCP Servers", icon: "server.rack", expanded: $mcpExpanded,
                    badge: mcpOperational,
                    detail: mcpSummary
                ) {
                    MCPInspectorPanel()
                        .environment(app)
                }
            }
            .padding(Theme.s3)
        }
        .scrollContentBackground(.hidden)
        .background(.black.opacity(0.15))
        .sheet(isPresented: $showPromptEditor) {
            SystemPromptEditor()
                .environment(app)
        }
        .alert("Save Preset", isPresented: $showPresetNamePrompt) {
            TextField("Preset name", text: $presetNameDraft)
            Button("Save") { savePreset() }
                .disabled(presetNameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stores the current system prompt under a name in the Presets menu.")
        }
    }

    @ViewBuilder
    private var localThinkingSection: some View {
        if let active = app.engine.activeModel, !active.model.isGGUF {
            if active.chatTemplateSupportsThinkingToggle {
                Toggle("Thinking mode", isOn: localThinkingEnabledBinding)
                    .disabled(active.chatTemplateThinkingOnly)
                    .help(
                        active.chatTemplateThinkingOnly
                            ? "This model's chat template is thinking-only — enable_thinking cannot be turned off."
                            : "Passes enable_thinking into the chat template. On = reasoning blocks; off = direct answers.")
            } else if active.chatTemplateThinkingBuiltIn {
                HStack {
                    Text("Thinking mode")
                        .font(.callout)
                    Spacer()
                    Text("Always on")
                        .font(.callout)
                        .foregroundStyle(Theme.emberGlow)
                }
                .help(
                    "This checkpoint's chat template always opens a reasoning block at generation time "
                        + "(typical stock Qwen3). Turn on \"Show reasoning in chat\" below to see it.")
            } else if active.chatTemplateHasTemplate {
                Text(
                    "No enable_thinking toggle in this model's template — reasoning follows the checkpoint as-is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    "No chat template on this model (e.g. ASR/embedding) — thinking controls don't apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reasoningSectionDetail: String {
        var parts: [String] = []
        if let active = app.engine.activeModel, !active.model.isGGUF {
            if active.chatTemplateSupportsThinkingToggle {
                parts.append(app.settings.localThinkingEnabled ? "think" : "no-think")
            } else if active.chatTemplateThinkingBuiltIn {
                parts.append("think·on")
            } else if !active.chatTemplateHasTemplate {
                parts.append("n/a")
            }
        }
        parts.append(app.settings.reasoningEnabled ? "show · \(app.settings.anthropicEffort)" : "hidden")
        return parts.joined(separator: " · ")
    }

    private var serverRunning: Bool {
        if case .running = app.server.state { return true }
        return false
    }

    private var mcpOperational: Bool {
        app.mcp.entries.contains { entry in
            if case .connected(let tools) = entry.status {
                return app.mcp.isServerEnabled(entry.id) && !tools.isEmpty
            }
            return false
        }
    }

    private var mcpSummary: String {
        let enabled = app.mcp.entries.filter { app.mcp.isServerEnabled($0.id) }.count
        let connected = app.mcp.entries.filter {
            if case .connected = $0.status { return true }
            return false
        }.count
        return "\(connected)/\(enabled) online"
    }

    private func savePreset() {
        let name = presetNameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Same name = overwrite, so presets stay editable in place.
        let preset: PromptPreset
        if let index = app.promptPresets.firstIndex(where: { $0.name == name }) {
            app.promptPresets[index].text = app.settings.systemPrompt
            preset = app.promptPresets[index]
        } else {
            preset = PromptPreset(name: name, text: app.settings.systemPrompt)
            app.promptPresets.append(preset)
        }
        app.applySystemPrompt(app.settings.systemPrompt, preset: preset)
        presetNameDraft = ""
    }

    private var systemPromptSectionDetail: String {
        if app.settings.systemPrompt.isEmpty { return "empty" }
        return "\(app.systemPromptSourceLabel) · \(promptSummary)"
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { app.settings.systemPrompt },
            set: { newValue in
                var next = app.settings
                next.systemPrompt = newValue
                app.settings = next
            })
    }

    private var localThinkingEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.settings.localThinkingEnabled },
            set: { newValue in
                var next = app.settings
                next.localThinkingEnabled = newValue
                app.settings = next
            })
    }

    private var promptSummary: String {
        let prompt = app.settings.systemPrompt
        if prompt.isEmpty { return "Empty — model default." }
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        return "\(words)w · \(prompt.count)c"
    }

    @ViewBuilder
    private func section(
        _ title: String, icon: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func collapsibleSection(
        _ title: String, icon: String, expanded: Binding<Bool>, badge: Bool = false,
        detail: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Label(title, systemImage: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if let detail, !expanded.wrappedValue {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if badge && !expanded.wrappedValue {
                        Circle()
                            .fill(Theme.okGreen)
                            .frame(width: 7, height: 7)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                content()
            }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MCPInspectorPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if app.mcp.entries.isEmpty {
                Text("No MCP servers configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.mcp.entries) { entry in
                    MCPInspectorRow(entry: entry)
                }
            }
        }
    }
}

private struct MCPInspectorRow: View {
    @Environment(AppState.self) private var app
    let entry: MCPManager.Entry

    private var enabled: Bool { app.mcp.isServerEnabled(entry.id) }
    private var tools: [MCPTool] { app.mcp.tools(for: entry.id) }
    private var selectedToolNames: [String] { app.mcp.selectedTools(for: entry.id) }
    private var selectedTools: [MCPTool] {
        let selected = Set(selectedToolNames)
        return tools.filter { selected.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .center, spacing: Theme.s2) {
                refreshStatusButton

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.id)
                        .font(.caption.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusForeground)
                        .lineLimit(1)
                        .help(statusDetail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !tools.isEmpty {
                    Text("\(selectedTools.count)/\(tools.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(minWidth: 34, alignment: .center)
                        .background(.white.opacity(0.055))
                        .clipShape(.capsule)
                        .minimumScaleFactor(0.85)
                        .help("Enabled tools")
                }

                Toggle("Enabled", isOn: Binding(
                    get: { enabled },
                    set: { app.mcp.setServerEnabled(entry.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(enabled ? "Turn MCP server off" : "Turn MCP server on")

                Button {
                    revealCurrentTarget()
                } label: {
                    Image(systemName: entry.isBuiltIn ? "folder" : "doc.text.magnifyingglass")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(entry.isBuiltIn ? "Reveal built-in MCP workspace folder" : "Reveal MCP config file")
            }

            VStack(alignment: .leading, spacing: Theme.s1) {
                HStack(spacing: Theme.s2) {
                    Text("Tools")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    toolMenu
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .help(detailText)
            }

            HStack(spacing: Theme.s2) {
                Text(transportSummary)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(entry.transport)
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.s2)
        .background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }

    private var refreshStatusButton: some View {
        Button {
            app.mcp.reload()
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 11, height: 11)
                .padding(6)
                .contentShape(.circle)
            .background(statusColor.opacity(0.16))
            .clipShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Refresh MCP status: \(statusLabel)")
    }

    private var toolMenu: some View {
        Menu {
            if tools.isEmpty {
                Text("No tools reported")
            } else {
                Button("Enable all tools") {
                    app.mcp.setAllTools(true, for: entry.id)
                }
                Button("Disable all tools") {
                    app.mcp.setAllTools(false, for: entry.id)
                }
                Divider()
                ForEach(tools) { tool in
                    Button {
                        app.mcp.setTool(
                            tool.name,
                            enabled: !app.mcp.isToolSelected(tool.name, for: entry.id),
                            for: entry.id)
                    } label: {
                        Label(
                            tool.name,
                            systemImage: app.mcp.isToolSelected(tool.name, for: entry.id)
                                ? "checkmark.square.fill" : "square")
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.s1) {
                Text(selectedToolTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: Theme.s1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s2)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055))
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))
        }
        .menuStyle(.borderlessButton)
        .disabled(!enabled || tools.isEmpty)
        .help(toolSelectionHelp)
    }

    private var selectedToolTitle: String {
        guard !tools.isEmpty else { return "No tools" }
        guard !selectedTools.isEmpty else { return "None enabled" }
        if selectedTools.count == tools.count { return "All enabled" }
        if selectedTools.count == 1 {
            return Self.shortToolTitle(selectedTools[0].name)
        }
        return "\(selectedTools.count) enabled"
    }

    private var detailText: String {
        guard enabled else { return "Off" }
        guard !tools.isEmpty else { return shortStatusDetail }
        guard !selectedTools.isEmpty else { return "No tools enabled" }
        if selectedTools.count == 1 {
            return Self.shortToolSummary(selectedTools[0])
        }
        return "\(selectedTools.count) tools enabled"
    }

    private var detailColor: Color {
        selectedTools.isEmpty ? statusForeground : .secondary
    }

    private var toolSelectionHelp: String {
        guard !selectedTools.isEmpty else { return "No MCP tools enabled for this server." }
        return selectedTools.map(\.name).joined(separator: ", ")
    }

    private var transportSummary: String {
        if entry.isBuiltIn { return "built-in" }
        if entry.config.url != nil { return "http" }
        guard let command = entry.config.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { return "unknown" }
        switch command {
        case "node":
            return "node"
        case "uv":
            return "uv"
        case "npx":
            return "npx"
        default:
            return Self.clipped(command, max: 14)
        }
    }

    private var shortStatusDetail: String {
        guard enabled else { return "Off" }
        switch entry.status {
        case .disabled:
            return "Off"
        case .available:
            return "Idle"
        case .connecting:
            return "Starting"
        case .connected(let tools):
            return tools.isEmpty ? "No tools" : "Ready"
        case .failed:
            return "Failed"
        }
    }

    private static func shortToolTitle(_ name: String) -> String {
        switch name.lowercased() {
        case "sequentialthinking":
            return "thinking"
        case "get_config":
            return "config"
        case "read_pdf":
            return "read pdf"
        case "read_pdf_page":
            return "pdf page"
        case "get_pdf_metadata":
            return "pdf meta"
        case "legal_think":
            return "legal think"
        case "create_entities":
            return "create"
        default:
            let words = name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map(String.init)
            if words.isEmpty { return clipped(name, max: 16) }
            return clipped(words.prefix(2).joined(separator: " "), max: 16)
        }
    }

    private static func shortToolSummary(_ tool: MCPTool) -> String {
        switch tool.name.lowercased() {
        case "legal_think":
            return "Legal reasoning"
        case "status":
            return "Status"
        case "get_config":
            return "Config"
        case "list_roots":
            return "Roots"
        case "read_file":
            return "Read file"
        case "write_file":
            return "Write file"
        case "list_directory":
            return "List files"
        case "search_files":
            return "Search files"
        case "create_entities":
            return "Create entities"
        case "create_relations":
            return "Create links"
        case "read_graph":
            return "Read graph"
        case "search_nodes":
            return "Search graph"
        case "open_nodes":
            return "Open nodes"
        case "read_pdf":
            return "PDF text"
        case "read_pdf_page":
            return "PDF page"
        case "get_pdf_metadata":
            return "PDF metadata"
        case "search_pdf":
            return "PDF search"
        case "sequentialthinking":
            return "Step reasoning"
        default:
            return shortToolTitle(tool.name)
        }
    }

    private static func clipped(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max))
    }

    private var statusLabel: String {
        guard enabled else { return "off" }
        switch entry.status {
        case .disabled:
            return "off"
        case .available:
            return "idle"
        case .connecting:
            return "checking"
        case .connected(let tools):
            return tools.isEmpty ? "empty" : "online"
        case .failed:
            return "failed"
        }
    }

    private var statusSummary: String {
        guard enabled else { return "off" }
        switch entry.status {
        case .disabled:
            return "off"
        case .available:
            return "idle · click to check"
        case .connecting:
            return entry.config.command == nil ? "checking tools" : "starting stdio"
        case .connected(let tools):
            if tools.isEmpty { return "online · no tools" }
            return "online · \(tools.count) tools"
        case .failed:
            return entry.config.command == nil ? "connection failed" : "launch failed"
        }
    }

    private var statusDetail: String {
        guard enabled else { return "Server is off." }
        switch entry.status {
        case .disabled:
            return "Server is off."
        case .available:
            return "Configured. Click refresh to connect and list tools."
        case .connecting:
            return entry.config.command == nil
                ? "Connecting and listing tools."
                : "Launching the stdio command and listing tools."
        case .connected(let tools):
            return tools.isEmpty ? "Connected, but no tools were reported." : "\(tools.count) tools available."
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        guard enabled else { return .gray }
        switch entry.status {
        case .disabled:
            return .gray
        case .available:
            return .gray
        case .connected(let tools):
            return tools.isEmpty ? .yellow : Theme.okGreen
        case .connecting:
            return .yellow
        case .failed:
            return .red
        }
    }

    private var statusForeground: Color {
        switch entry.status {
        case .failed:
            return .red
        case .available:
            return .secondary
        case .connecting:
            return .yellow
        case .connected(let tools):
            return tools.isEmpty ? .yellow : .secondary
        case .disabled:
            return .secondary
        }
    }

    private func revealCurrentTarget() {
        if entry.isBuiltIn {
            NSWorkspace.shared.activateFileViewerSelecting([ForgePaths.appSupport])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([MCPManager.projectConfigFile])
        }
    }
}

/// One resident model in the inspector: activate, inspect, eject.
private struct LoadedModelRow: View {
    @Environment(AppState.self) private var app
    let entry: InferenceEngine.Loaded

    private var isActive: Bool { app.engine.activeModelID == entry.id }
    private var needsStandardReload: Bool {
        entry.weightLoadPolicy == .boundedEager
            || entry.weightLoadPolicy == .deferred
    }

    var body: some View {
        HStack(spacing: Theme.s2) {
            Button {
                app.engine.activeModelID = entry.id
            } label: {
                Image(systemName: isActive ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active model" : "Make active")

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.model.shortName)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text(
                    [
                        Format.bytes(entry.model.sizeBytes),
                        entry.model.quantization,
                        entry.model.architecture,
                        entry.weightLoadPolicy?.shortLabel,
                    ]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.engine.unload(entry.id)
                app.scheduleSave()
            } label: {
                Image(systemName: "eject")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unload from memory")
        }
    }
}

/// Large, resizable system prompt editor opened from the inspector.
struct SystemPromptEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { app.settings.systemPrompt },
            set: { newValue in
                var next = app.settings
                next.systemPrompt = newValue
                app.settings = next
            })
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "text.quote")
                    .foregroundStyle(Theme.emberGlow)
                Text("System Prompt")
                    .font(.headline)
                Spacer()
                Text(footerSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.s4)

            Divider()

            TextEditor(text: systemPromptBinding)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(Theme.s3)
                .background(.black.opacity(0.25))
                .focused($focused)

            Divider()

            HStack {
                Button("Clear", role: .destructive) {
                    app.applySystemPrompt("")
                }
                .disabled(app.settings.systemPrompt.isEmpty)
                Text("Changes apply live to the next message.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.s4)
        }
        .frame(
            minWidth: 560, idealWidth: 720, maxWidth: .infinity,
            minHeight: 420, idealHeight: 540, maxHeight: .infinity)
        .background(Theme.backgroundGradient)
        .onAppear { focused = true }
    }

    private var footerSummary: String {
        let prompt = app.settings.systemPrompt
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        return "\(words) words · \(prompt.count) chars"
    }
}

/// Slider with a directly-editable numeric field. Typed values may exceed the
/// slider's visual range (up to `hardLimit`); the slider just pins at its end.
/// Repetition penalty: 1.0 = off (MLX standard). Useful tuning is usually 1.05–1.15.
private struct RepetitionPenaltySlider: View {
    @Binding var value: Double

    var body: some View {
        VStack(spacing: Theme.s1) {
            HStack {
                Text("Repetition penalty")
                    .font(.callout)
                Spacer()
                if value <= 1.0001 {
                    Text("off")
                        .font(.callout)
                        .foregroundStyle(Theme.emberGlow)
                }
                TextField(
                    "", value: Binding(
                        get: { value },
                        set: { value = min(max($0, 1.0), 2.0) }),
                    format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64)
                    .padding(.horizontal, Theme.s1)
                    .background(.white.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 4))
            }
            Slider(
                value: Binding(
                    get: { min(max(value, 1.0), 1.2) },
                    set: { value = $0 }),
                in: 1.0...1.2)
                .tint(Theme.ember)
                .controlSize(.small)
        }
        .help("1.0 = off. Values above 1.0 discourage repetition (try 1.05–1.1).")
    }
}

struct ParameterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let hardLimit: ClosedRange<Double>
    let fractionDigits: Int

    var body: some View {
        VStack(spacing: Theme.s1) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                TextField(
                    "", value: Binding(
                        get: { value },
                        set: { value = min(max($0, hardLimit.lowerBound), hardLimit.upperBound) }),
                    format: .number.precision(.fractionLength(0...fractionDigits)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64)
                    .padding(.horizontal, Theme.s1)
                    .background(.white.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 4))
            }
            Slider(
                value: Binding(
                    get: { min(max(value, range.lowerBound), range.upperBound) },
                    set: { value = $0 }),
                in: range)
                .tint(Theme.ember)
                .controlSize(.small)
        }
    }
}

/// Integer entry field: type any value (clamped to `limit`), Enter commits.
/// `zeroMeans` renders next to the field when the value is 0 (e.g. "∞", "off").
/// Optional presets appear in a menu for one-click jumps.
struct IntField: View {
    let label: String
    @Binding var value: Int
    let limit: ClosedRange<Int>
    var zeroMeans: String?
    var presets: [Int] = []

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            if value == 0, let zeroMeans {
                Text(zeroMeans)
                    .font(.callout)
                    .foregroundStyle(Theme.emberGlow)
            }
            TextField(
                "", value: Binding(
                    get: { value },
                    set: { value = min(max($0, limit.lowerBound), limit.upperBound) }),
                format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84)
                .padding(.horizontal, Theme.s1)
                .padding(.vertical, 1)
                .background(.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 4))
            if !presets.isEmpty {
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(presetLabel(preset)) {
                            value = preset
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func presetLabel(_ preset: Int) -> String {
        if preset == 0 { return zeroMeans ?? "0" }
        if preset >= 1_000_000, preset.isMultiple(of: 1_000_000) {
            return "\(preset / 1_000_000)M"
        }
        if preset >= 1_024, preset.isMultiple(of: 1_024) {
            return "\(preset / 1_024)K"
        }
        return "\(preset)"
    }
}
