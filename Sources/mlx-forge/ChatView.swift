// Forge — chat surface: transcript, streaming bubbles, composer, tuning inspector.

import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app

    // Local popup state for large-text viewer. Using local @State (not AppState)
    // keeps the feature self-contained and avoids polluting the shared observable.
    @State private var showLargeTextPopup = false
    @State private var largeTextPopupContent = ""

    var body: some View {
        @Bindable var app = app
        Group {
            if let conversation = app.selectedConversation {
                if conversation.isEmpty && !app.canChat {
                    WelcomeView()
                } else {
                    TranscriptView(conversation: conversation, onShowLargeText: { content in
                        largeTextPopupContent = content
                        showLargeTextPopup = true
                    })
                }
            } else {
                WelcomeView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView()
        }
        .inspector(isPresented: $app.showInspector) {
            TuningInspector()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .background(Theme.backgroundGradient)
        .sheet(isPresented: $showLargeTextPopup) {
            LargeTextView(text: largeTextPopupContent) {
                showLargeTextPopup = false
            }
        }
    }
}

// MARK: - Welcome / empty state

struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: Theme.s5) {
            Spacer()
            ForgeMark(size: 56)
            VStack(spacing: Theme.s2) {
                Text("Forge")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(Theme.emberGradient)
                Text("Native MLX inference on Apple Silicon.\nNo Python. No server. Just Swift and metal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let loading = app.engine.loadingModels.first {
                VStack(spacing: Theme.s2) {
                    if let fraction = loading.value, fraction > 0, fraction < 1 {
                        ProgressView(value: fraction)
                            .frame(width: 260)
                    } else {
                        ProgressView()
                    }
                    Text("Loading \(URL(filePath: loading.key).lastPathComponent)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let message = app.engine.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420)
            } else {
                HStack(spacing: Theme.s3) {
                    Button {
                        app.showModelBrowser = true
                    } label: {
                        Label("Open Model Library", systemImage: "shippingbox")
                            .padding(.horizontal, Theme.s2)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)

                    if let first = app.store.localModels.first {
                        Button {
                            app.engine.loadAndActivate(first)
                        } label: {
                            Label("Load \(first.shortName)", systemImage: "bolt.fill")
                                .padding(.horizontal, Theme.s2)
                        }
                        .controlSize(.large)
                    }
                }
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @Environment(AppState.self) private var app
    let conversation: Conversation
    var onShowLargeText: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4) {
                ForEach(conversation.messages) { message in
                    MessageView(
                        message: message,
                        isStreaming: app.streamingMessageID == message.id,
                        onShowLargeText: onShowLargeText)
                        .id(message.id)
                }
            }
            .padding(Theme.s5)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Message bubble

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    var onShowLargeText: (String) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                // Scrollable container for long user messages (pastes, logs, etc.).
                // Internal ScrollView + maxHeight prevents the bubble (and transcript)
                // from stretching the entire window. "View full" button appears for
                // very large content and opens the popup without blocking send.
                VStack(alignment: .leading, spacing: Theme.s2) {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(MarkdownText.inline(message.content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)

                    if message.content.count > 500 {
                        HStack(spacing: Theme.s2) {
                            Text("\(message.content.count) chars")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("View full") {
                                onShowLargeText(message.content)
                            }
                            .font(.caption2.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ember)
                        }
                        .padding(.top, Theme.s1)
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
                .background(Theme.userBubble)
                .clipShape(.rect(cornerRadius: Theme.radiusLarge))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLarge)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Theme.s2) {
                header
                bubble
                if !isStreaming, message.tokensPerSecond != nil {
                    stats
                }
            }
        case .system:
            SystemMessagePanel(content: message.content)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.s2) {
            ForgeMark(size: 12)
            Text(message.modelName ?? "Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if message.content.isEmpty && isStreaming {
                Text("Thinking…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if isStreaming {
                Text(message.content)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if message.segments.isEmpty {
                MarkdownText(text: message.content)
            } else {
                ForEach(message.segments) { segment in
                    switch segment.kind {
                    case .thinking(let done):
                        ThinkingBlock(text: segment.text, done: done, isStreaming: isStreaming)
                    case .answer:
                        MarkdownText(text: segment.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.s4)
        .background(Theme.assistantBubble)
        .clipShape(.rect(cornerRadius: Theme.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var stats: some View {
        HStack(spacing: Theme.s3) {
            if let tps = message.tokensPerSecond {
                StatChip(
                    icon: "speedometer",
                    text: "\(tps.formatted(.number.precision(.fractionLength(1)))) tok/s")
            }
            if let count = message.generationTokenCount {
                StatChip(icon: "number", text: "\(count) tokens")
            }
            if let promptTokens = message.promptTokenCount, let time = message.promptTime {
                StatChip(
                    icon: "arrow.right.to.line",
                    text:
                        "\(promptTokens) prompt · \(time.formatted(.number.precision(.fractionLength(2))))s ttft")
            }
        }
        .padding(.leading, Theme.s1)
    }
}

private struct SystemMessagePanel: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            if !bodyText.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    MarkdownText(text: bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var lines: [String] {
        content.components(separatedBy: .newlines)
    }

    private var title: String {
        let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "System"
        return first.isEmpty ? "System" : first
    }

    private var bodyText: String {
        lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var icon: String {
        title.hasPrefix("MCP") ? "wrench.and.screwdriver" : "gearshape"
    }
}

/// Collapsible reasoning section for models that emit <think> traces.
struct ThinkingBlock: View {
    let text: String
    let done: Bool
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s2)
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "brain")
                    .foregroundStyle(Theme.emberGlow)
                Text(done ? "Reasoning" : "Reasoning…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !done && isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(Theme.s3)
        .background(.white.opacity(0.03))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    @State private var showPhotoPicker = false
    @State private var pendingImages: [Data] = []

    // Mode states for the frontline-style top bar (Depth/Style/Deliverable/Workflow).
    // On send we tag the prompt so the model adapts (works for both local and Claude).
    @State private var depthMode = "Balanced"
    @State private var styleMode = "Standard"
    @State private var deliverableMode = "Text"
    @State private var showAgentDispatch = false
    @State private var showAPIModelPicker = false
    @State private var showOpenRouterModelPicker = false
    @State private var showAnthropicModelPicker = false
    @State private var customOpenRouterModel = ""

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if app.isBusy {
                liveBar
            }

            // Mode bar matching the frontline screenshot UI: Depth, Style, Deliverable (with image icon), Workflow.
            // These are lightweight for now — they prepend tags to the prompt on send so the model (local or Claude)
            // can adapt output style/depth/deliverable. "Council" is available via the Graph button.
            HStack(spacing: Theme.s2) {
                Picker("Depth", selection: $depthMode) {
                    Text("Quick").tag("Quick")
                    Text("Balanced").tag("Balanced")
                    Text("Deep").tag("Deep")
                    Text("Exhaustive").tag("Exhaustive")
                }
                .pickerStyle(.menu)
                .font(.caption)

                Picker("Style", selection: $styleMode) {
                    Text("Concise").tag("Concise")
                    Text("Standard").tag("Standard")
                    Text("Detailed").tag("Detailed")
                    Text("Creative").tag("Creative")
                }
                .pickerStyle(.menu)
                .font(.caption)

                Picker("Deliverable", selection: $deliverableMode) {
                    Label("Text", systemImage: "text.alignleft").tag("Text")
                    Label("Code", systemImage: "chevron.left.forwardslash.chevron.right").tag("Code")
                    Label("Image", systemImage: "photo").tag("Image")
                    Label("Doc", systemImage: "doc.text").tag("Doc")
                }
                .pickerStyle(.menu)
                .font(.caption)

                Button("Workflow") {
                    // Placeholder action — could open a workflow picker or append a workflow tag.
                    app.composerText = (app.composerText.isEmpty ? "" : app.composerText + " ") + "[Workflow: step-by-step with verification]"
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                // Graph feature removed for App Store readiness (sandbox incompatibilities and incomplete state). Use prompt library + modes for advanced chats.
            }
            .padding(.horizontal, Theme.s3)
            .padding(.top, Theme.s2)

            // The input area: text editor on top that starts small (1 line) and grows as you type (up to 10 lines),
            // then a fixed bottom bar with the attachment/prompt icons (horizontal) + send button.
            // This prevents the whole thing starting huge/empty; it only expands with content.
            VStack(spacing: 0) {
                // Growing text area
                ZStack(alignment: .topLeading) {
                    if app.composerText.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $app.composerText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 44, idealHeight: 96, maxHeight: 180)
                        .focused($focused)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.top, Theme.s3)
                .padding(.bottom, Theme.s1)

                // Bottom command bar. Sections are deliberately spread across the wide composer
                // so the controls read as grouped actions instead of one cramped icon run.
                HStack(spacing: 0) {
                    HStack(spacing: Theme.s3) {
                        Button {
                            pickPhoto()
                        } label: {
                            ToolbarIcon("photo.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .help("Attach photo for review or context (user-selected; sandbox-safe). Data is available for local VLM or MCP photo-review tools.")

                        Button {
                            Task {
                                await app.reviewAttachedPhotoWithMCP(using: pendingImages)
                            }
                        } label: {
                            ToolbarIcon("eye.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Review attached photo(s) using a connected MCP photo/vision tool")

                        Button {
                            pickPhoto() // placeholder for general attach
                        } label: {
                            ToolbarIcon("doc.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .help("Attach file")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        Menu {
                            Button("Add Prompt Folder...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.prompt = "Add Prompt Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    app.addPromptDirectory(url)
                                }
                            }
                            Divider()
                            if app.availablePrompts().isEmpty {
                                Text("No prompts — add a folder above")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(app.availablePrompts(), id: \.category) { category, items in
                                    Section(category) {
                                        ForEach(items, id: \.url) { name, url in
                                            Button(name) {
                                                if let content = app.loadPromptContent(from: url) {
                                                    app.lastPromptContent = content
                                                    app.applySystemPrompt(content)
                                                    if var conv = app.selectedConversation {
                                                        conv.systemPrompt = content
                                                        app.selectedConversation = conv
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            ToolbarIcon("books.vertical")
                        }
                        .menuStyle(.borderlessButton)
                        .help("Prompt library — add your prompting folders and select a prompt for the chat (categorized scroll menu)")

                        Button {
                            if app.hasBraveSearchKey {
                                app.braveSearchEnabled.toggle()
                            } else {
                                app.composerText +=
                                    (app.composerText.isEmpty ? "" : " ")
                                    + "[use web search / MCP tool if available]"
                            }
                        } label: {
                            ToolbarIcon("globe")
                                .foregroundStyle(
                                    app.braveSearchEnabled ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(
                            app.hasBraveSearchKey
                                ? (app.braveSearchEnabled
                                    ? "Brave Search on — send for web-grounded answers"
                                    : "Brave Search off — click to enable web-grounded answers")
                                : "Web search — add Brave API key in Settings (⌘,) or use MCP tools")

                        Button {
                            app.composerText += (app.composerText.isEmpty ? "" : " ") + "[enhance / council review]"
                        } label: {
                            ToolbarIcon("wand.and.stars")
                        }
                        .buttonStyle(.plain)
                        .help("Enhance or multi-agent council review via MCP/tools")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        Button {
                            if app.isCodingOrchestratorRunning {
                                app.stopCodingOrchestrator()
                            } else if !app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                app.runCodingOrchestrator(task: app.composerText)
                            }
                        } label: {
                            ToolbarIcon(app.isCodingOrchestratorRunning ? "stop.fill" : "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .disabled(!app.hasOpenRouterKey)
                        .help(app.isCodingOrchestratorRunning ? "Stop code loop (\(app.codingOrchestratorPhase))" : "Code loop: planner→coder→auditor→fixer→tester via OpenRouter")

                        Button {
                            showAgentDispatch = true
                        } label: {
                            ToolbarIcon("person.2.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Multi-agent dispatch: send current prompt (with top Depth/Style/Deliverable modes) to loaded locals, Anthropic, and OpenRouter. Click several; they run in parallel where possible.")

                        Button {
                            app.showHeadlessHelper = true
                        } label: {
                            Label("Headless", systemImage: "terminal.fill")
                                .font(.callout.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.s3)
                                .frame(height: 38)
                                .background(.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Headless Command Cheat Sheet")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        // Right side as requested: loaded model name, API server switch, cloud provider switches
                        Toggle("API", isOn: Binding(
                            get: { app.serverEnabled },
                            set: { enabled in
                                app.serverEnabled = enabled
                                if enabled { showAPIModelPicker = true }
                            }
                        ))
                            .font(.callout.weight(.semibold))
                            .controlSize(.regular)
                            .toggleStyle(.switch)
                            .help("API Server")
                            .popover(isPresented: $showAPIModelPicker, arrowEdge: .top) {
                                LocalModelPicker()
                                    .environment(app)
                            }

                        if app.serverEnabled {
                            apiModelMenu
                        }

                        Toggle("OpenRouter", isOn: Binding(
                            get: { !app.openRouterModelIDs.isEmpty },
                            set: { enabled in
                                if enabled {
                                    if app.openRouterModelIDs.isEmpty {
                                        app.setOpenRouterModel(OpenRouterClient.defaultModelID, selected: true)
                                    }
                                    showOpenRouterModelPicker = true
                                } else {
                                    app.clearOpenRouterModels()
                                }
                            }
                        ))
                        .font(.callout.weight(.semibold))
                        .controlSize(.regular)
                        .toggleStyle(.switch)
                        .help("OpenRouter API key")
                        .popover(isPresented: $showOpenRouterModelPicker, arrowEdge: .top) {
                            OpenRouterModelPicker(customModel: $customOpenRouterModel)
                                .environment(app)
                        }

                        if !app.openRouterModelIDs.isEmpty {
                            openRouterModelMenu
                        }

                        Toggle("Anthropic", isOn: Binding(
                            get: { app.claudeModelID != nil },
                            set: { enabled in
                                if enabled {
                                    app.claudeModelID = app.claudeModelID ?? AnthropicClient.models[0].id
                                    showAnthropicModelPicker = true
                                } else {
                                    app.claudeModelID = nil
                                }
                            }
                        ))
                            .font(.callout.weight(.semibold))
                            .controlSize(.regular)
                            .toggleStyle(.switch)
                            .help("Anthropic API key")
                            .popover(isPresented: $showAnthropicModelPicker, arrowEdge: .top) {
                                CloudModelPicker(
                                    title: "Anthropic Model",
                                    systemImage: "sparkles",
                                    models: AnthropicClient.models,
                                    selection: Binding(
                                        get: { app.claudeModelID ?? AnthropicClient.models[0].id },
                                        set: { app.claudeModelID = $0 }),
                                    customModel: .constant(""),
                                    allowsCustom: false)
                            }

                        if let claudeID = app.claudeModelID, !claudeID.isEmpty {
                            cloudModelMenu(
                                title: AnthropicClient.label(for: claudeID),
                                systemImage: "sparkles",
                                models: AnthropicClient.models,
                                selection: Binding(
                                    get: { app.claudeModelID ?? AnthropicClient.models[0].id },
                                    set: { app.claudeModelID = $0 }),
                                customModel: .constant(""),
                                allowsCustom: false)
                        }

                        if !app.engine.loadedModels.isEmpty || app.engine.isLoadingAnything {
                            Button {
                                app.stopGenerating()
                                app.engine.unloadAll()
                                app.scheduleSave()
                            } label: {
                                Image(systemName: "eject.fill")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .background(.white.opacity(0.055), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Eject all loaded/loading local models")
                        }
                    }

                    Spacer(minLength: Theme.s6)

                    if app.isBusy {
                        Button {
                            app.stopGenerating()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.bold))
                                .frame(width: 24, height: 24)
                                .background(.red.opacity(0.85))
                                .foregroundStyle(.white)
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .help("Stop generating")
                    } else {
                        Button {
                            performSend()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .frame(width: 24, height: 24)
                                .background(app.canSend ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.quaternary))
                                .foregroundStyle(.white)
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!app.canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                    }
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
            }
            .glassCard(radius: Theme.radiusLarge)
            .padding(.horizontal, Theme.s5)
            .padding(.bottom, Theme.s4)
            .padding(.top, Theme.s2)
        }
        .popover(isPresented: $showAgentDispatch, arrowEdge: .top) {
            agentDispatchPopover
        }
        .background(.clear)
        .onAppear { focused = true }
        .fileImporter(
            isPresented: $showPhotoPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }

                    if let data = try? Data(contentsOf: url) {
                        pendingImages.append(data)

                        // Visual token in the text so the user sees the attachment.
                        // The actual Data travels with the message on send.
                        // See AppState.reviewAttachedPhotoWithMCP for how this Data is base64'd and
                        // sent to an MCP "review_photo" tool under "image_base64".
                        let token = "[photo:\(url.lastPathComponent)]"
                        if app.composerText.isEmpty {
                            app.composerText = token + " "
                        } else {
                            app.composerText += " " + token
                        }

                        // Auto Review Photo with MCP if a suitable connected server exists (per strict list "either auto or button").
                        let hasSuitable = app.mcp.entries.contains { entry in
                            if case .connected = entry.status {
                                let idLower = entry.id.lowercased()
                                return idLower.contains("photo") || idLower.contains("vision") || idLower.contains("review") || idLower.contains("image")
                            }
                            return false
                        }
                        if hasSuitable {
                            Task {
                                await app.reviewAttachedPhotoWithMCP(using: pendingImages)
                            }
                        }
                    }
                }
            case .failure(let error):
                // Surface in a real app (e.g. via a toast or lastError).
                print("Photo picker error: \(error)")
            }
        }
    }

    private var apiModelMenu: some View {
        Menu {
            if app.engine.loadedModels.isEmpty {
                Text("No loaded models")
            } else {
                ForEach(app.engine.loadedModels) { entry in
                    Button {
                        app.engine.activeModelID = entry.id
                    } label: {
                        Label(
                            entry.model.shortName,
                            systemImage: app.engine.activeModelID == entry.id
                                ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            ModelSelectorLabel(
                title: app.engine.activeModel?.model.shortName ?? "No model",
                systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .help("Select local API model")
    }

    private var openRouterModelMenu: some View {
        Menu {
            Button("Select All") {
                app.selectAllOpenRouterModels()
            }
            Button("Clear") {
                app.clearOpenRouterModels()
            }
            Divider()
            ForEach(OpenRouterClient.models, id: \.id) { model in
                Button {
                    app.setOpenRouterModel(
                        model.id,
                        selected: !app.isOpenRouterModelSelected(model.id))
                } label: {
                    Label(
                        model.label,
                        systemImage: app.isOpenRouterModelSelected(model.id)
                            ? "checkmark.circle.fill" : "circle")
                }
            }
            let customIDs = app.openRouterModelIDs.filter { selected in
                !OpenRouterClient.models.contains { $0.id == selected }
            }
            if !customIDs.isEmpty {
                Divider()
                ForEach(customIDs, id: \.self) { modelID in
                    Button {
                        app.setOpenRouterModel(modelID, selected: false)
                    } label: {
                        Label(OpenRouterClient.label(for: modelID), systemImage: "checkmark.circle.fill")
                    }
                }
            }
            Divider()
            Button("Custom model...") {
                customOpenRouterModel = ""
                showOpenRouterModelPicker = true
            }
        } label: {
            ModelSelectorLabel(
                title: app.openRouterSelectionSummary,
                systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuStyle(.borderlessButton)
        .help("Select OpenRouter models")
    }

    private func cloudModelMenu(
        title: String,
        systemImage: String,
        models: [(id: String, label: String)],
        selection: Binding<String>,
        customModel: Binding<String>,
        allowsCustom: Bool
    ) -> some View {
        Menu {
            ForEach(models, id: \.id) { model in
                Button {
                    selection.wrappedValue = model.id
                } label: {
                    Label(
                        model.label,
                        systemImage: selection.wrappedValue == model.id
                            ? "checkmark.circle.fill" : "circle")
                }
            }
            if allowsCustom {
                Divider()
                Button("Custom model...") {
                    customModel.wrappedValue = selection.wrappedValue
                    showOpenRouterModelPicker = true
                }
            }
        } label: {
            ModelSelectorLabel(title: title, systemImage: systemImage)
        }
        .menuStyle(.borderlessButton)
        .help("Select model")
    }

    private func pickPhoto() {
        showPhotoPicker = true
    }

    private func performSend() {
        let tags = "[Depth: \(depthMode)] [Style: \(styleMode)] [Deliverable: \(deliverableMode)] "
        if !app.composerText.hasPrefix("[Depth:") {
            app.composerText = tags + app.composerText
        }
        let imagesToSend = pendingImages
        pendingImages = []
        app.send(images: imagesToSend)
    }

    // Helpers for the AGENTS bottom space dispatch (cloud providers + numbered local MLX agents).
    // Captures the current top config (modes) and prompt, then delegates to AppState for parallel launch + monitoring.
    private func shortNameForButton(_ model: LocalModel) -> String {
        var s = model.shortName
        s = s.replacingOccurrences(of: "-Heretic-Thinking-8bit", with: "")
        s = s.replacingOccurrences(of: "-Heretic-Thinking", with: "")
        if s.contains("Qwen") { s = s.replacingOccurrences(of: "Qwen", with: "Qwen ") }
        let parts = s.split(separator: "-").prefix(3).map(String.init).joined(separator: " ")
        return parts.count > 18 ? String(parts.prefix(18)) + "…" : parts
    }

    private func dispatchTo(target: AppState.AgentTarget) {
        var text = app.composerText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Support clicking additional agents from the popover after the first one cleared the box,
            // or when composer is empty: re-use the last user prompt as the task for this agent.
            if let lastUser = app.selectedConversation?.messages.last(where: { $0.role == .user })?.content {
                text = lastUser
            }
        }
        let tags = "[Depth: \(depthMode)] [Style: \(styleMode)] [Deliverable: \(deliverableMode)] "
        if !text.hasPrefix("[Depth:") && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = tags + text
        }
        let imgs = pendingImages
        pendingImages = []
        app.dispatchToAgent(prompt: text, target: target, images: imgs)
        app.composerText = ""
    }

    private func dispatchToAll() {
        let tags = "[Depth: \(depthMode)] [Style: \(styleMode)] [Deliverable: \(deliverableMode)] "
        var text = app.composerText
        if !text.hasPrefix("[Depth:") && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = tags + text
        }
        let imgs = pendingImages
        pendingImages = []
        app.composerText = ""
        let loaded = Array(app.engine.loadedModels.enumerated())
        for (idx, entry) in loaded {
            let sname = shortNameForButton(entry.model)
            app.dispatchToAgent(prompt: text, target: .local(modelID: entry.id, number: idx + 1, shortName: sname), images: imgs)
        }
        for clm in AnthropicClient.models {
            app.dispatchToAgent(prompt: text, target: .claude(modelID: clm.id, label: clm.label), images: imgs)
        }
        for model in OpenRouterClient.models {
            app.dispatchToAgent(prompt: text, target: .openRouter(modelID: model.id, label: model.label), images: imgs)
        }
    }

    private var placeholder: String {
        if app.braveSearchEnabled {
            return "Ask Brave \(app.braveSearchConfig.enableResearch ? "Research" : "Answers")…"
        }
        if let openRouterID = app.openRouterModelID, !openRouterID.isEmpty {
            return "Message \(OpenRouterClient.label(for: openRouterID))…"
        }
        if let claudeID = app.claudeModelID, !claudeID.isEmpty {
            return "Message \(AnthropicClient.label(for: claudeID))…"
        }
        if let active = app.engine.activeModel {
            return "Message \(active.model.shortName)…"
        }
        if app.engine.isLoadingAnything { return "Model loading…" }
        return "Load a model or enable Brave / cloud APIs to start"
    }

    private var liveBar: some View {
        HStack(spacing: Theme.s3) {
            ProgressView()
                .controlSize(.small)
            Text(liveLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s1)
    }

    private var liveLabel: String {
        if let advisory = app.engine.loadAdvisory, !app.engine.isLoadingAnything {
            return advisory
        }
        if let materializingID = app.engine.materializingModelID,
            let model = app.engine.loadedModels.first(where: { $0.id == materializingID })?.model
        {
            return "Materializing \(model.shortName) weights (first token — large deferred models can take several minutes)…"
        }
        if app.engine.isLoadingAnything,
            let (modelID, fraction) = app.engine.loadingModels.first
        {
            let name =
                app.store.localModels.first(where: { $0.id == modelID })?.shortName ?? "model"
            if let fraction {
                let pct = Int((fraction * 100).rounded())
                return "Loading \(name)… \(pct)%"
            }
            return "Loading \(name)…"
        }
        if !app.inFlightAgentLabels.isEmpty {
            let labels = app.inFlightAgentLabels.values.joined(separator: ", ")
            if app.isBraveSearchGenerating {
                return "Agents: \(labels) · Brave researching…"
            }
            if app.isClaudeGenerating {
                return "Agents: \(labels) · Claude responding…"
            }
            if app.isOpenRouterGenerating {
                return "Agents: \(labels) · OpenRouter responding…"
            }
            let count = app.engine.liveTokenCount
            let tps = app.engine.liveTokensPerSecond
            if tps > 0 {
                return
                    "Agents: \(labels) · \(count) tokens · \(tps.formatted(.number.precision(.fractionLength(1)))) tok/s"
            }
            return "Agents: \(labels) · \(count) tokens"
        }
        if app.isBraveSearchGenerating {
            return app.braveSearchConfig.enableResearch
                ? "Brave is researching…" : "Brave is answering…"
        }
        if app.isClaudeGenerating {
            return "Claude is responding…"
        }
        if app.isOpenRouterGenerating {
            return "OpenRouter is responding…"
        }
        let count = app.engine.liveTokenCount
        let tps = app.engine.liveTokensPerSecond
        if tps > 0 {
            return "\(count) tokens · \(tps.formatted(.number.precision(.fractionLength(1)))) tok/s"
        }
        return "\(count) tokens"
    }

    // Compact popover triggered from the agents icon in the bottom composer bar.
    // Lists cloud provider options + numbered locals so user can click any button(s)
    // to dispatch the prompt (top modes from the bar above are applied). This keeps the main
    // composer compact (no more huge always-on block that destroyed the layout).
    private var agentDispatchPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multi-agent dispatch")
                .font(.headline)
            Text("Prompt + top bar (Depth/Style/Deliverable) + system prompt will be sent. Click multiple buttons to run cloud providers in parallel or locals through the engine gate. Monitoring shows in the live bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !app.inFlightAgentLabels.isEmpty {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("Monitoring: \(app.inFlightAgentLabels.values.joined(separator: " • "))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.emberGlow)
                    Spacer()
                    Button("Stop all") { app.stopGenerating() }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }

            if !app.engine.loadedModels.isEmpty {
                Text("Loaded locals (use numbers for refs like \"agent 1 do X\")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let loaded = Array(app.engine.loadedModels.enumerated())
                        ForEach(loaded, id: \.1.id) { idx, entry in
                            let num = idx + 1
                            let sname = shortNameForButton(entry.model)
                            Button {
                                dispatchTo(target: .local(modelID: entry.id, number: num, shortName: sname))
                                // leave open so user can click more agents
                            } label: {
                                Text("\(num).\(sname) ▶")
                                    .font(.caption2.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.ember)
                        }
                    }
                }
            }

            Text("Anthropic (Claude) — click any")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AnthropicClient.models, id: \.id) { clm in
                        Button {
                            dispatchTo(target: .claude(modelID: clm.id, label: clm.label))
                        } label: {
                            Text("\(clm.label) ▶")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Text("OpenRouter — click any")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(OpenRouterClient.models, id: \.id) { model in
                        Button {
                            dispatchTo(target: .openRouter(modelID: model.id, label: model.label))
                        } label: {
                            Text("\(model.label) ▶")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Button {
                    dispatchToAll()
                } label: {
                    Label("All agents at once ▶", systemImage: "paperplane.fill")
                        .font(.caption2.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)

                Spacer()

                Button("Close") {
                    showAgentDispatch = false
                }
                .font(.caption)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(minWidth: 420, maxWidth: 520)
        .background(Theme.backgroundGradient)
    }
}

private struct CloudModelPicker: View {
    let title: String
    let systemImage: String
    let models: [(id: String, label: String)]
    @Binding var selection: String
    @Binding var customModel: String
    let allowsCustom: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ForEach(models, id: \.id) { model in
                Button {
                    selection = model.id
                } label: {
                    HStack {
                        Image(systemName: selection == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == model.id ? Theme.ember : .secondary)
                        Text(model.label)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }

            if allowsCustom {
                Divider()
                HStack(spacing: Theme.s2) {
                    TextField("custom model slug", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .onSubmit { applyCustomModel() }
                    Button("Use") {
                        applyCustomModel()
                    }
                    .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(Theme.s3)
        .frame(width: 300)
        .background(Theme.backgroundGradient)
    }

    private func applyCustomModel() {
        let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = value
        customModel = ""
    }
}

private struct OpenRouterModelPicker: View {
    @Environment(AppState.self) private var app
    @Binding var customModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Label("OpenRouter Models", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Text("\(app.openRouterModelIDs.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.s2) {
                Button("All") {
                    app.selectAllOpenRouterModels()
                }
                .buttonStyle(.bordered)
                Button("None") {
                    app.clearOpenRouterModels()
                }
                .buttonStyle(.bordered)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Divider()
            HStack(spacing: Theme.s2) {
                TextField("custom model slug", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit { applyCustomModel() }
                Button("Add") {
                    applyCustomModel()
                }
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.s3)
        .frame(width: 330)
        .background(Theme.backgroundGradient)
    }

    private func applyCustomModel() {
        let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        app.setOpenRouterModel(value, selected: true)
        customModel = ""
    }
}

private struct LocalModelPicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label("API Model", systemImage: "cpu")
                .font(.headline)

            if app.engine.loadedModels.isEmpty {
                Text("No loaded models")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.engine.loadedModels) { entry in
                    Button {
                        app.engine.activeModelID = entry.id
                    } label: {
                        HStack {
                            Image(
                                systemName: app.engine.activeModelID == entry.id
                                    ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(app.engine.activeModelID == entry.id ? Theme.ember : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.model.shortName)
                                    .lineLimit(1)
                                Text(entry.model.quantization ?? entry.model.architecture ?? entry.model.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(Theme.s3)
        .frame(width: 300)
        .background(Theme.backgroundGradient)
    }
}

private struct ModelSelectorLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.s2)
        .frame(height: 28)
        .frame(maxWidth: 150)
        .background(.white.opacity(0.055), in: Capsule())
    }
}

private struct ToolbarIcon: View {
    let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.045), in: Circle())
            .contentShape(Circle())
    }
}
