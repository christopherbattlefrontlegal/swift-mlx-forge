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
    @AppStorage("inspector.promptExpanded") private var promptExpanded = true
    @AppStorage("inspector.modelsExpanded") private var modelsExpanded = true
    @AppStorage("inspector.mcpExpanded") private var mcpExpanded = true

    var body: some View {
        @Bindable var app = app
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                collapsibleSection(
                    "Sampling & Limits", icon: "dice", expanded: $samplingExpanded,
                    detail:
                        "t \(app.settings.temperature.formatted(.number.precision(.fractionLength(2))))"
                ) {
                    ParameterSlider(
                        label: "Temperature", value: $app.settings.temperature,
                        range: 0...2, hardLimit: 0...10, fractionDigits: 2)
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
                        .help("Caps context memory (tokens); ∞ keeps everything.")
                    ParameterSlider(
                        label: "Repetition penalty", value: $app.settings.repetitionPenalty,
                        range: 1.0...1.5, hardLimit: 1.0...3.0, fractionDigits: 2)
                    Picker("API auto-load policy", selection: $app.settings.weightLoadPolicy) {
                        ForEach(WeightLoadPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .help(
                        "Only affects models the API server loads automatically — not chat speed for an already-loaded model. Use Model Library → Load for chat; MoE models (A3B, etc.) always use standard load."
                    )
                }

                collapsibleSection(
                    "System Prompt", icon: "text.quote", expanded: $promptExpanded,
                    detail: systemPromptSectionDetail
                ) {
                    VStack(alignment: .leading, spacing: Theme.s2) {
                        HStack(spacing: Theme.s2) {
                        Menu {
                            if app.promptPresets.isEmpty {
                                Text("No presets saved yet")
                            }
                            ForEach(app.promptPresets) { preset in
                                Button {
                                    app.applySystemPrompt(preset.text, presetID: preset.id)
                                } label: {
                                    if app.activePromptPresetID == preset.id {
                                        Label(preset.name, systemImage: "checkmark")
                                    } else {
                                        Text(preset.name)
                                    }
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
                                            app.promptPresets.removeAll { $0.id == preset.id }
                                            if app.activePromptPresetID == preset.id {
                                                app.activePromptPresetID = nil
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: Theme.s1) {
                                Image(systemName: "bookmark.fill")
                                Text(app.systemPromptPresetLabel)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.borderlessButton)
                        .layoutPriority(1)

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

                        Text(promptSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    TextEditor(text: $app.settings.systemPrompt)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 56, maxHeight: 120)
                        .padding(Theme.s2)
                        .background(.black.opacity(0.25))
                        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                        .onChange(of: app.settings.systemPrompt) { _, _ in
                            app.reconcileActivePromptPreset()
                        }
                }

                if !app.engine.loadedModels.isEmpty {
                    collapsibleSection(
                        "Loaded Models", icon: "cpu", expanded: $modelsExpanded,
                        detail: "\(app.engine.loadedModels.count) loaded"
                    ) {
                        ForEach(app.engine.loadedModels) { entry in
                            LoadedModelRow(entry: entry)
                        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(.black.opacity(0.15))
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
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
        if let index = app.promptPresets.firstIndex(where: { $0.name == name }) {
            app.promptPresets[index].text = app.settings.systemPrompt
            app.activePromptPresetID = app.promptPresets[index].id
        } else {
            let preset = PromptPreset(name: name, text: app.settings.systemPrompt)
            app.promptPresets.append(preset)
            app.activePromptPresetID = preset.id
        }
        presetNameDraft = ""
    }

    private var systemPromptSectionDetail: String {
        if app.settings.systemPrompt.isEmpty { return "empty" }
        let label = app.systemPromptPresetLabel
        if label == "Custom" || label == "None" {
            return promptSummary
        }
        return "\(label) · \(promptSummary)"
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
        .inspectorPanelCard()
    }

    @ViewBuilder
    private func collapsibleSection(
        _ title: String, icon: String, expanded: Binding<Bool>, badge: Bool = false,
        detail: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Button {
                expanded.wrappedValue.toggle()
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
        .inspectorPanelCard()
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
        if app.mcp.entries.isEmpty {
            Text("No MCP servers configured.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.s1) {
                ForEach(app.mcp.entries) { entry in
                    MCPInspectorRow(entry: entry)
                }
            }
        }
    }
}

private struct MCPInspectorRow: View {
    @Environment(AppState.self) private var app
    @State private var showToolsPopover = false
    let entry: MCPManager.Entry

    private var enabled: Bool { app.mcp.isServerEnabled(entry.id) }
    private var tools: [MCPTool] { app.mcp.tools(for: entry.id) }
    private var selectedToolNames: [String] { app.mcp.selectedTools(for: entry.id) }
    private var selectedTools: [MCPTool] {
        let selected = Set(selectedToolNames)
        return tools.filter { selected.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(alignment: .center, spacing: Theme.s2) {
                refreshStatusButton

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.id)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(rowSubtitle)
                        .font(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(rowSubtitleHelp)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Theme.s3) {
                Spacer(minLength: 0)
                toolMenuButton

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
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(entry.isBuiltIn ? "Reveal built-in MCP workspace folder" : "Reveal MCP config file")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var refreshStatusButton: some View {
        Button {
            app.mcp.reload()
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Refresh MCP status: \(statusLabel)")
    }

    private var toolMenuButton: some View {
        Button {
            showToolsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.callout)
                .foregroundStyle(enabled && !tools.isEmpty ? .secondary : .tertiary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || tools.isEmpty)
        .help(toolMenuHelp)
        .popover(isPresented: $showToolsPopover, arrowEdge: .bottom) {
            MCPToolChecklistPopover(entryID: entry.id, tools: tools)
                .environment(app)
        }
    }

    private var rowSubtitle: String {
        let transport = transportSummary
        guard enabled else { return "off · \(transport)" }
        switch entry.status {
        case .disabled:
            return "off · \(transport)"
        case .connecting:
            return "starting · \(transport)"
        case .connected:
            if tools.isEmpty {
                return "online · \(transport)"
            }
            return "online · \(selectedTools.count)/\(tools.count) tools · \(transport)"
        case .failed:
            return "failed · \(transport)"
        }
    }

    private var rowSubtitleHelp: String {
        var parts = [statusDetail]
        if !tools.isEmpty {
            parts.append("Tools: \(toolMenuHelp)")
        }
        return parts.joined(separator: "\n")
    }

    private var subtitleColor: Color {
        guard enabled else { return Color.secondary.opacity(0.75) }
        switch entry.status {
        case .failed:
            return .red
        case .connecting:
            return .yellow
        case .connected:
            return tools.isEmpty || selectedTools.isEmpty ? .yellow : .secondary
        case .disabled:
            return Color.secondary.opacity(0.75)
        }
    }

    private var toolMenuHelp: String {
        guard !tools.isEmpty else { return "No tools reported." }
        if selectedTools.isEmpty { return "No tools enabled." }
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
        case .connecting:
            return "checking"
        case .connected(let tools):
            return tools.isEmpty ? "empty" : "online"
        case .failed:
            return "failed"
        }
    }

    private var statusDetail: String {
        guard enabled else { return "Server is off." }
        switch entry.status {
        case .disabled:
            return "Server is off."
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
        case .connected(let tools):
            return tools.isEmpty ? .yellow : Theme.okGreen
        case .connecting:
            return .yellow
        case .failed:
            return .red
        }
    }

    private func revealCurrentTarget() {
        if entry.isBuiltIn {
            NSWorkspace.shared.activateFileViewerSelecting([ForgePaths.appSupport])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([MCPManager.configFile])
        }
    }
}

private struct MCPToolChecklistPopover: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let entryID: String
    let tools: [MCPTool]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Button("Enable all tools") {
                    app.mcp.setAllTools(true, for: entryID)
                }
                Button("Disable all tools") {
                    app.mcp.setAllTools(false, for: entryID)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            Divider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.s2) {
                    ForEach(tools) { tool in
                        Toggle(tool.name, isOn: Binding(
                            get: { app.mcp.isToolSelected(tool.name, for: entryID) },
                            set: { app.mcp.setTool(tool.name, enabled: $0, for: entryID) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(tool.name)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
        }
        .padding(Theme.s3)
        .frame(width: 330)
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
        VStack(alignment: .leading, spacing: Theme.s1) {
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
                app.unloadLocalModel(entry.id)
            } label: {
                Image(systemName: "eject")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unload from memory")
        }
        if needsStandardReload {
            Button("Reload with Standard Load (faster)") {
                app.reloadModelStandard(entry.model)
            }
            .font(.caption2.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(Theme.ember)
        }
        }
    }
}

/// Large, resizable system prompt editor opened from the inspector.
struct SystemPromptEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

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

            TextEditor(text: $app.settings.systemPrompt)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(Theme.s3)
                .background(.black.opacity(0.25))
                .focused($focused)

            Divider()

            HStack {
                Button("Clear", role: .destructive) {
                    app.clearSystemPrompt()
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
struct ParameterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let hardLimit: ClosedRange<Double>
    let fractionDigits: Int

    @State private var draft: Double?
    @State private var isDragging = false

    private var displayValue: Double {
        draft ?? value
    }

    var body: some View {
        VStack(spacing: Theme.s1) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                TextField(
                    "", value: Binding(
                        get: { displayValue },
                        set: { commit($0) }),
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
                    get: { min(max(displayValue, range.lowerBound), range.upperBound) },
                    set: { draft = $0 }),
                in: range,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing, let draft {
                        commit(draft)
                        self.draft = nil
                    }
                })
                .tint(Theme.ember)
                .controlSize(.small)
        }
        .onChange(of: value) { _, _ in
            if !isDragging { draft = nil }
        }
    }

    private func commit(_ raw: Double) {
        value = min(max(raw, hardLimit.lowerBound), hardLimit.upperBound)
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

/// Solid panel chrome for the inspector — avoids expensive material blur while scrolling.
private extension View {
    func inspectorPanelCard() -> some View {
        background(Theme.assistantBubble.opacity(0.92))
            .clipShape(.rect(cornerRadius: Theme.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}
