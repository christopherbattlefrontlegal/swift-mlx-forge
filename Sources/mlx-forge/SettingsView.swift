// Forge — app settings window (⌘,): Claude API key (Keychain) + MCP servers.
// Both lived in the right sidebar before; they're configuration, not tuning.

import AppKit
import SwiftUI

struct ForgeSettingsView: View {
    var body: some View {
        TabView {
            ClaudeKeySettings()
                .tabItem { Label("Cloud APIs", systemImage: "cloud") }
            PromptLibrarySettings()
                .tabItem { Label("Prompt Library", systemImage: "book.closed") }
            MCPSettings()
                .tabItem { Label("MCP Servers (advanced)", systemImage: "server.rack") }
        }
        .frame(width: 560, height: 420)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Cloud API keys

private struct ClaudeKeySettings: View {
    @Environment(AppState.self) private var app
    @State private var anthropicDraft = ""
    @State private var openRouterDraft = ""
    @State private var customOpenRouterModel = ""
    @State private var braveSearchDraft = ""

    var body: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.s4) {
            Label("Cloud API Providers", systemImage: "cloud")
                .font(.headline)

            providerCard(
                title: "OpenRouter",
                icon: "point.3.connected.trianglepath.dotted",
                description: app.hasOpenRouterKey
                    ? "A key is stored in your Keychain. Pick any OpenRouter models below to route chat through OpenRouter."
                    : "Stored in the macOS Keychain. Used for OpenRouter's OpenAI-compatible chat endpoint."
            ) {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    HStack {
                        Text(app.openRouterSelectionSummary)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("All") {
                            app.selectAllOpenRouterModels()
                        }
                        .controlSize(.small)
                        Button("None") {
                            app.clearOpenRouterModels()
                        }
                        .controlSize(.small)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            ForEach(OpenRouterClient.models, id: \.id) { model in
                                Toggle(isOn: Binding(
                                    get: { app.isOpenRouterModelSelected(model.id) },
                                    set: { app.setOpenRouterModel(model.id, selected: $0) }
                                )) {
                                    Text(model.label)
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }

                            ForEach(customOpenRouterSelections, id: \.self) { modelID in
                                Toggle(isOn: Binding(
                                    get: { app.isOpenRouterModelSelected(modelID) },
                                    set: { app.setOpenRouterModel(modelID, selected: $0) }
                                )) {
                                    Text(OpenRouterClient.label(for: modelID))
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }

                HStack(spacing: Theme.s2) {
                    TextField("custom model slug", text: $customOpenRouterModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("Add") {
                        let value = customOpenRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            app.setOpenRouterModel(value, selected: true)
                            customOpenRouterModel = ""
                        }
                    }
                    .disabled(customOpenRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: Theme.s2) {
                    SecureField(
                        app.hasOpenRouterKey ? "Replace key" : "OPENROUTER_API_KEY",
                        text: $openRouterDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { saveOpenRouter() }
                    Button("Save") { saveOpenRouter() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ember)
                        .disabled(openRouterDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasOpenRouterKey {
                        Button(role: .destructive) {
                            app.setOpenRouterKey(nil)
                            openRouterDraft = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove the stored OpenRouter key")
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("Code loop (OpenRouter)")
                        .font(.caption.weight(.semibold))
                    Text("Planner → coder → auditor → fixer → tester. Chat toolbar loop button.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: Binding(
                        get: { app.codingOrchestratorConfig.modelID },
                        set: { app.codingOrchestratorConfig.modelID = $0 })) {
                        ForEach(OpenRouterClient.models, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                        ForEach(app.openRouterCatalog) { entry in
                            Text(entry.label).tag(entry.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Stepper(
                        "Max rounds: \(app.codingOrchestratorConfig.maxRounds)",
                        value: Binding(
                            get: { app.codingOrchestratorConfig.maxRounds },
                            set: { app.codingOrchestratorConfig.maxRounds = max(1, min(10, $0)) }),
                        in: 1...10)
                    Button("Refresh model catalog") { app.refreshOpenRouterCatalog() }
                        .controlSize(.small)
                        .disabled(app.isOpenRouterCatalogLoading)
                    if let error = app.openRouterCatalogError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }

            providerCard(
                title: "Brave Search Answers",
                icon: "magnifyingglass.circle",
                description: app.hasBraveSearchKey
                    ? "Brave Answers key saved. Toggle Brave in chat or use the globe button to send web-grounded queries."
                    : "Web-grounded answers via Brave Search Answers API."
            ) {
                Toggle("Research mode (multi-search)", isOn: $app.braveSearchConfig.enableResearch)
                Toggle("Inline citations", isOn: $app.braveSearchConfig.enableCitations)
                HStack(spacing: Theme.s2) {
                    SecureField(
                        app.hasBraveSearchKey ? "Replace key" : "BRAVE_SEARCH_API_KEY",
                        text: $braveSearchDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    Button("Save") {
                        let key = braveSearchDraft.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        app.setBraveSearchKey(key)
                        braveSearchDraft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .disabled(braveSearchDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasBraveSearchKey {
                        Button(role: .destructive) {
                            app.setBraveSearchKey(nil)
                            braveSearchDraft = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            providerCard(
                title: "Anthropic Claude",
                icon: "cloud",
                description: app.hasAnthropicKey
                    ? "A key is stored in your Keychain. Pick a Claude model below to route chat through Anthropic."
                    : "Stored in the macOS Keychain. Billed to your Anthropic API account."
            ) {
                Picker("Model", selection: Binding(
                    get: { app.claudeModelID ?? AnthropicClient.models[0].id },
                    set: { app.claudeModelID = $0 }
                )) {
                    ForEach(AnthropicClient.models, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: Theme.s2) {
                    SecureField(
                        app.hasAnthropicKey ? "Replace key (sk-ant-…)" : "sk-ant-…",
                        text: $anthropicDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { saveAnthropic() }
                    Button("Save") { saveAnthropic() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ember)
                        .disabled(anthropicDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasAnthropicKey {
                        Button(role: .destructive) {
                            app.setAnthropicKey(nil)
                            anthropicDraft = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove the stored Anthropic key")
                    }
                }
            }

            Spacer()
        }
        .padding(Theme.s5)
    }

    private func providerCard<Content: View>(
        title: String,
        icon: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(Theme.s3)
        .background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }

    private func saveAnthropic() {
        let key = anthropicDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        app.setAnthropicKey(key)
        anthropicDraft = ""
    }

    private func saveOpenRouter() {
        let key = openRouterDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        app.setOpenRouterKey(key)
        app.openRouterModelID = app.openRouterModelID ?? OpenRouterClient.defaultModelID
        openRouterDraft = ""
    }

    private var customOpenRouterSelections: [String] {
        app.openRouterModelIDs.filter { selected in
            !OpenRouterClient.models.contains { $0.id == selected }
        }
    }
}

// MARK: - MCP servers

private struct MCPSettings: View {
    @Environment(AppState.self) private var app
    @State private var serverName = ""
    @State private var serverURL = ""
    @State private var configError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Label("MCP Servers", systemImage: "server.rack")
                .font(.headline)
            Text(
                "Forge includes a small built-in forge-commander fallback for workspace file tools. Full MCP servers, including Desktop Commander and memory graph, are declared in the local mcp.json."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack {
                    Label("Built-in Forge Commander", systemImage: "desktopcomputer")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(app.commanderDirectories.count + 1) root\(app.commanderDirectories.isEmpty ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Available out of the box as MCP server \"forge-commander\". It can list, read, write, inspect, and search files under Forge's app-support folder and any workspace folders you grant here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    commanderRootRow(ForgePaths.appSupport, removable: false)
                    ForEach(app.commanderDirectories, id: \.self) { dir in
                        commanderRootRow(dir, removable: true)
                    }
                }

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Add Workspace"
                    panel.message = "Select a folder that Forge's built-in forge-commander tools may access."
                    if panel.runModal() == .OK, let url = panel.url {
                        app.addCommanderDirectory(url)
                    }
                } label: {
                    Label("Add Workspace Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
            }
            .padding(Theme.s2)
            .background(.white.opacity(0.04))
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))

            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Add HTTP/SSE Server")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.s2) {
                    TextField("name", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    TextField("https://example.com/mcp or http://127.0.0.1:8765", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("Add") {
                        if let error = app.mcp.addHTTPServer(
                            name: serverName, urlString: serverURL)
                        {
                            configError = error
                        } else {
                            configError = ""
                            serverName = ""
                            serverURL = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                }
                if !configError.isEmpty {
                    Text(configError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(Theme.s2)
            .background(.white.opacity(0.04))
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))

            if app.mcp.entries.isEmpty {
                VStack(spacing: Theme.s2) {
                    Image(systemName: "server.rack")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No servers configured yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.s2) {
                        ForEach(app.mcp.entries) { entry in
                            MCPServerRow(entry: entry) {
                                app.mcp.removeServer(name: entry.id)
                            }
                        }
                    }
                }
            }

            Text("stdio command servers run in the local developer build. Mac App Store sandbox builds must use built-in tools or HTTP/SSE bridges.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([MCPManager.projectConfigFile])
                } label: {
                    Label("Reveal Config File", systemImage: "folder")
                }
                Button {
                    app.mcp.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text(MCPManager.projectConfigFile.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.s5)
    }

    private func commanderRootRow(_ url: URL, removable: Bool) -> some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: removable ? "folder" : "app.badge")
                .foregroundStyle(.secondary)
            Text(url.path)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.borderless)
            if removable {
                Button(role: .destructive) {
                    app.removeCommanderDirectory(url)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove workspace folder")
            }
        }
    }
}

private struct MCPServerRow: View {
    let entry: MCPManager.Entry
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.s2) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.id)
                    .font(.callout.weight(.semibold))
                Text(entry.transport)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusText
            if !entry.isBuiltIn {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove from Forge MCP config")
            }
        }
        .padding(Theme.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }

    @ViewBuilder
    private var statusDot: some View {
        switch entry.status {
        case .disabled:
            Circle().fill(.gray).frame(width: 8, height: 8)
        case .available:
            Circle().fill(.secondary).frame(width: 8, height: 8)
        case .connecting:
            ProgressView().controlSize(.mini)
        case .connected:
            Circle().fill(Theme.okGreen).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch entry.status {
        case .disabled:
            Text("off")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .available:
            Text("idle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .connecting:
            Text("connecting…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .connected(let tools):
            Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(tools.map(\.name).joined(separator: "\n"))
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

// MARK: - Prompt Library settings & instructions (for App Store / user docs)

private struct PromptLibrarySettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Label("Prompt Library", systemImage: "book.closed")
                .font(.headline)

            Text("Forge supports loading custom prompt collections from your folders (e.g. awesome-prompts or personal prompt engineering libraries). Subfolders are treated as categories for easy browsing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Capabilities / what it does
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Capabilities")
                    .font(.subheadline.weight(.semibold))
                Text("• Local MLX inference only (no cloud required for core features; optional Claude API).\n• Chat with scrolling composer and large-text popup viewer.\n• Attach photos for context/review (via VLM or MCP if configured).\n• Generation modes: Depth, Style, Deliverable, Workflow.\n• Prompt library: Add folders in chat (book icon) or here. Select any prompt file to set as system prompt.\n• Auto-applies last selected prompt to new conversations.\n• Local developer build supports stdio MCP servers; Mac App Store builds require the sandbox-compatible MCP path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.s2)
            .background(.white.opacity(0.05))
            .clipShape(.rect(cornerRadius: Theme.radiusSmall))

            if app.promptDirectories.isEmpty {
                Text("No prompt folders connected yet. Use the book icon in the chat composer to add your prompting folder (e.g. /Users/you/awesome-prompts/prompting).")
                    .font(.callout)
            } else {
                Text("Connected folders (click Reveal to manage):")
                    .font(.caption.weight(.semibold))
                ForEach(app.promptDirectories, id: \.self) { dir in
                    HStack {
                        Text(dir.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            // Simple remove; full bookmark cleanup on relaunch ok
                            app.removePromptDirectory(dir)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Button("Add Prompt Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select Prompt Folder"
                    if panel.runModal() == .OK, let url = panel.url {
                        app.addPromptDirectory(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)

                Button("Reload Prompts") {
                    // Triggers re-scan on next menu open
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("Prompts are read on-demand with user-granted access.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(Theme.s5)
    }
}
