// Forge — chat surface: transcript, streaming bubbles, composer, tuning inspector.

import AppKit
import PDFKit
import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app

    // Local popup state for large-text viewer. Using local @State (not AppState)
    // keeps the feature self-contained and avoids polluting the shared observable.
    @State private var showLargeTextPopup = false
    @State private var largeTextPopupContent = ""

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            ModelSlotBar()
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundGradient)
        .sheet(isPresented: $showLargeTextPopup, onDismiss: {
            largeTextPopupContent = ""
        }) {
            LargeTextView(text: largeTextPopupContent) {
                showLargeTextPopup = false
            }
        }
    }
}

// MARK: - Model slots

/// Top strip: one chip per engine slot showing what's loaded where, plus the
/// one chip per engine slot showing what's loaded where.
struct ModelSlotBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: Theme.s1) {
            HStack(spacing: Theme.s1) {
                ForEach(0..<ModelMemoryBudget.slotCount, id: \.self) { index in
                    slotChip(index)
                        .frame(minWidth: 84, maxWidth: .infinity)
                }
            }
            HStack {
                Button {
                    app.showModelBrowser = true
                } label: {
                    Label("Model Library", systemImage: "shippingbox")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer(minLength: Theme.s2)
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s1)
        .background(.white.opacity(0.02))
    }

    @ViewBuilder
    private func slotChip(_ index: Int) -> some View {
        let assignments = app.effectiveModelSlotAssignments
        if let modelID = assignments[index],
            let entry = app.engine.loadedModels.first(where: { $0.id == modelID })
        {
            let isActive = app.engine.activeModelID == entry.id
            Menu {
                Button("Use for single chat") { app.engine.activeModelID = entry.id }
                Menu("Replace Slot") {
                    ForEach(app.store.localModels) { model in
                        Button(model.shortName) { app.assignModel(model, toSlot: index) }
                    }
                }
                Divider()
                Button("Clear Slot", role: .destructive) { app.clearModelSlot(index) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SLOT \(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isActive ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.secondary))
                    Text(entry.model.shortName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, Theme.s2)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .background(.white.opacity(isActive ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        isActive ? Theme.ember.opacity(0.6) : .white.opacity(0.06),
                        lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .disabled(app.isBusy)
            .help("Slot \(index + 1): \(entry.model.name)\(isActive ? " (active)" : "")")
        } else {
            Menu {
                ForEach(app.store.localModels) { model in
                    Button(model.shortName) { app.assignModel(model, toSlot: index) }
                }
                Divider()
                Button("Open Model Library…") { app.showModelBrowser = true }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SLOT \(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                    Label("Load model", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.s2)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        .white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            .menuStyle(.borderlessButton)
            .help("Slot \(index + 1) — empty. Click to open the model library.")
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

    private var anyMessageStreaming: Bool {
        !app.streamingMessageIDs.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4) {
                // Unmissable load state: a 100GB GGUF takes minutes to come up,
                // and the thin composer caption was the only signal before.
                if let loading = app.engine.loadingModels.first {
                    ModelLoadingBanner(
                        name: app.store.localModels.first(where: { $0.id == loading.key })?
                            .shortName
                            ?? URL(filePath: loading.key).lastPathComponent,
                        fraction: loading.value)
                }
                if !anyMessageStreaming, !conversation.copyableTranscript.isEmpty {
                    HStack {
                        Spacer()
                        CopyClipButton(
                            label: "Copy all", text: conversation.copyableTranscript)
                    }
                    .padding(.bottom, Theme.s1)
                }
                ForEach(Array(conversation.messages.enumerated()), id: \.element.id) {
                    _, message in
                    MessageRow(
                        message: message,
                        isStreaming: app.isMessageStreaming(message.id),
                        streamingText: app.streamingTextByMessageID[message.id],
                        streamingReasoning: app.streamingReasoningByMessageID[message.id],
                        onShowLargeText: onShowLargeText
                    )
                    .equatable()
                    .id(message.id)
                }
            }
            .padding(Theme.s5)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        // Keep the viewport user-owned while the final row grows during a stream.
        .defaultScrollAnchor(.top)
    }
}

/// Prominent in-transcript banner while a model loads into memory. Determinate
/// once the backend reports a fraction (GGUF: llama.cpp per-tensor progress;
/// MLX: shard progress), indeterminate spinner until the first callback.
private struct ModelLoadingBanner: View {
    let name: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.title3)
                    .foregroundStyle(Theme.ember)
                Text("Loading \(name)")
                    .font(.headline)
                Spacer(minLength: 0)
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.ember)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Theme.ember)
            }
            Text("Reading weights into memory — large models take several minutes. The percent is live; the app is not stuck.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.assistantBubble)
        .clipShape(.rect(cornerRadius: Theme.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge)
                .strokeBorder(Theme.ember.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Equatable wrapper so finished transcript rows skip re-layout when another message streams.
private struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let streamingText: String?
    let streamingReasoning: String?
    var onShowLargeText: (String) -> Void

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        guard lhs.message == rhs.message, lhs.isStreaming == rhs.isStreaming else { return false }
        if lhs.isStreaming || rhs.isStreaming {
            return lhs.streamingText == rhs.streamingText
                && lhs.streamingReasoning == rhs.streamingReasoning
        }
        return true
    }

    var body: some View {
        MessageView(
            message: message,
            isStreaming: isStreaming,
            streamingText: streamingText,
            streamingReasoning: streamingReasoning,
            onShowLargeText: onShowLargeText)
    }
}

// MARK: - Message bubble

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    var streamingText: String? = nil
    var streamingReasoning: String? = nil
    var onShowLargeText: (String) -> Void = { _ in }

    private var liveAssistantText: String {
        if isStreaming, let streamingText { return streamingText }
        return message.content
    }

    private var liveReasoning: String {
        if isStreaming, let streamingReasoning { return streamingReasoning }
        return ""
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: Theme.s2) {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: Theme.s1) {
                    if !message.copyableText.isEmpty {
                        CopyClipButton(text: message.copyableText)
                    }
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
            ForgeMark(size: 12, animated: false)
            Text(message.modelName ?? "Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
            if !isStreaming, !message.copyableText.isEmpty {
                CopyClipButton(text: message.copyableText)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if isStreaming {
                // Reasoning streams on its own channel (ThinkTagParser split),
                // so the reasoning block renders the instant the first thinking
                // token lands — not after </think> closes.
                if !liveReasoning.isEmpty {
                    LiveThinkingBlock(text: liveReasoning, done: false)
                }
                if !liveAssistantText.isEmpty {
                    StreamingPlainTextView(text: liveAssistantText)
                }
                if liveReasoning.isEmpty && liveAssistantText.isEmpty {
                    Text("Reasoning…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            } else if !message.segments.isEmpty {
                ForEach(message.segments) { segment in
                    switch segment.kind {
                    case .thinking(let done):
                        ThinkingBlock(
                            text: segment.text,
                            done: done,
                            isStreaming: false)
                    case .answer:
                        if !segment.text.isEmpty {
                            MarkdownText(text: segment.text)
                        }
                    }
                }
            } else if !message.content.isEmpty {
                MarkdownText(text: message.content)
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

// MARK: - Streaming text (AppKit)

/// Expanded-by-default reasoning block for in-flight generations. Uses the appending
/// NSTextView so token flushes don't relayout the whole transcript.
private struct LiveThinkingBlock: View {
    let text: String
    let done: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "brain")
                        .foregroundStyle(Theme.emberGlow)
                    Text(done ? "Reasoning" : "Reasoning…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !done {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                StreamingPlainTextView(text: text, secondary: true)
            }
        }
        .padding(Theme.s3)
        .background(.white.opacity(0.03))
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
    }
}

/// Live streaming text as plain SwiftUI `Text`. SwiftUI owns the layout, so the
/// row grows cleanly per flush — no AppKit text view whose measurement mutates
/// layout state and re-layouts (flashes) the whole window on every token flush.
/// Markdown is deliberately NOT parsed while streaming; the finished message
/// re-renders once through MarkdownText.
private struct StreamingPlainTextView: View {
    let text: String
    var secondary: Bool = false

    var body: some View {
        Text(verbatim: text)
            .font(secondary ? .callout : .body)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: Theme.s2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
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
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transaction { $0.animation = nil }
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
    @State private var attachmentError: String?
    @State private var isPreparingAttachments = false
    @State private var attachmentImportID: UUID?
    @State private var attachmentImportTask: Task<Void, Never>?

    // Mode states for the frontline-style top bar (Depth/Style/Deliverable/Workflow).
    // On send we tag the prompt so the model adapts (works for both local and Claude).
    @State private var depthMode = "Balanced"
    @State private var styleMode = "Standard"
    @State private var deliverableMode = "Text"
    @State private var workflowMode = "None"
    @State private var showSmartPromptSheet = false
    @State private var showAPIModelPicker = false
    @State private var showOpenRouterModelPicker = false
    @State private var showAnthropicModelPicker = false
    @State private var showOpenAIModelPicker = false
    @State private var customOpenRouterModel = ""

    nonisolated private static let maxImageBytes = 25 * 1_024 * 1_024
    nonisolated private static let maxPendingImageBytes = 64 * 1_024 * 1_024
    nonisolated private static let maxPendingImageCount = 8
    nonisolated private static let maxTextBytes = 1 * 1_024 * 1_024
    nonisolated private static let maxPDFBytes = 50 * 1_024 * 1_024
    nonisolated private static let maxInlineChars = 30_000
    nonisolated private static let maxAttachmentFileCount = 20
    nonisolated private static let maxComposerAttachmentChars = 120_000

    private enum PreparedAttachment: Sendable {
        case image(name: String, data: Data)
        case text(name: String, content: String, clipped: Bool)
        case failure(String)
        case cancelled
    }

    private enum BoundedRead: Sendable {
        case success(Data)
        case failure(String)
    }

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

                Picker("Workflow", selection: $workflowMode) {
                    Text("None").tag("None")
                    Text("Step-by-step + verify").tag("Step-by-step, verify each step")
                    Text("Plan, then execute").tag("Plan first, then execute the plan")
                    Text("Draft → critique → revise").tag("Draft, critique your draft, then revise")
                    Text("Research → synthesize").tag("Gather the facts first, then synthesize")
                }
                .pickerStyle(.menu)
                .font(.caption)

                Divider()
                    .frame(height: 18)

                Button {
                    app.showSystemPromptEditor = true
                } label: {
                    Label(
                        app.systemPromptSourceLabel == "empty"
                            ? "Add System Prompt" : app.systemPromptSourceLabel,
                        systemImage: "text.quote")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Open, clear, or save the system prompt")
            }
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, Theme.s2)
            .glassCard(radius: Theme.radiusMedium)
            .padding(.horizontal, Theme.s3)
            .padding(.top, Theme.s3)

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
                        .frame(minHeight: 44, idealHeight: 64, maxHeight: 180)
                        .focused($focused)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.top, Theme.s3)
                .padding(.bottom, Theme.s1)

                if isPreparingAttachments || !pendingImages.isEmpty || attachmentError != nil {
                    HStack(spacing: Theme.s2) {
                        if isPreparingAttachments {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Reading attachment…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !pendingImages.isEmpty {
                            Label(
                                "\(pendingImages.count) image\(pendingImages.count == 1 ? "" : "s") · \(Format.bytes(pendingImages.reduce(0) { $0 + $1.count }))",
                                systemImage: "paperclip")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.emberGlow)
                        }
                        if let attachmentError {
                            Text(attachmentError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if !pendingImages.isEmpty || isPreparingAttachments {
                            Button(pendingImages.isEmpty ? "Cancel" : "Clear Images") {
                                clearPendingAttachments()
                            }
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .help("Cancel attachment reading and remove all pending images")
                        } else if attachmentError != nil {
                            Button("Dismiss") { attachmentError = nil }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s1)
                }

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
                            let images = pendingImages
                            Task {
                                await app.reviewAttachedPhotoWithMCP(using: images)
                            }
                        } label: {
                            ToolbarIcon("eye.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(pendingImages.isEmpty || isPreparingAttachments)
                        .help("Explicitly send the attached photo to a selected vision MCP tool or the active model for review")

                        Button {
                            pickFiles()
                        } label: {
                            ToolbarIcon("doc.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .help("Attach files — text/code/JSON/Markdown are inlined as context, PDFs are text-extracted, images attach like photos")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        Menu {
                            Button {
                                showSmartPromptSheet = true
                            } label: {
                                Label("Smart Select…", systemImage: "wand.and.stars")
                            }
                            Divider()
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
                                                    app.applySystemPrompt(
                                                        content, externalLabel: name)
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
                            app.showDesignPrompt = true
                        } label: {
                            ToolbarIcon("paintpalette.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Design prompt generator — build structured web/UI design prompts in a WebView, then paste into chat")

                        Button {
                            app.braveSearchEnabled.toggle()
                        } label: {
                            ToolbarIcon("globe")
                                .foregroundStyle(
                                    app.braveSearchEnabled ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .disabled(!app.hasBraveSearchKey)
                        .help(
                            app.hasBraveSearchKey
                                ? (app.braveSearchEnabled
                                    ? "Brave Search on — send for web-grounded answers"
                                    : "Brave Search off — click to enable web-grounded answers")
                                : "Brave Search — add API key in Settings (⌘,)")

                        Button {
                            var next = app.settings
                            let enabled = !(next.reasoningEnabled && next.localThinkingEnabled)
                            next.reasoningEnabled = enabled
                            next.localThinkingEnabled = enabled
                            app.settings = next
                        } label: {
                            ToolbarIcon("brain")
                                .foregroundStyle(
                                    app.settings.reasoningEnabled && app.settings.localThinkingEnabled
                                        ? AnyShapeStyle(Theme.emberGradient)
                                        : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(
                            app.settings.reasoningEnabled && app.settings.localThinkingEnabled
                                ? "Thinking ON — click to turn reasoning off (cloud + local models)"
                                : "Thinking OFF — click to turn reasoning on (cloud + local models)")

                        Button {
                            app.enhanceComposerPrompt()
                        } label: {
                            if app.isEnhancingPrompt {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 38, height: 38)
                            } else {
                                ToolbarIcon("wand.and.stars")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            app.isEnhancingPrompt
                                || app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Enhance prompt — rewrites your draft into a clearer, more effective prompt (needs Anthropic or OpenRouter key)")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        Button {
                            app.showRivet = true
                        } label: {
                            ToolbarIcon("point.3.filled.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.plain)
                        .help("Forge Graph — build and run AI workflows")

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
                        .help("Build a Claude Code non-interactive command")
                    }

                    Spacer(minLength: Theme.s6)

                    HStack(spacing: Theme.s3) {
                        // Right side: local API and cloud-provider controls.
                        HStack(spacing: Theme.s1) {
                            Text("API")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Toggle("API", isOn: Binding(
                                get: { app.serverEnabled },
                                set: { enabled in
                                    app.serverEnabled = enabled
                                    if enabled { showAPIModelPicker = true }
                                }
                            ))
                                .labelsHidden()
                                .controlSize(.regular)
                                .toggleStyle(.switch)
                        }
                            .help("API Server")
                            .popover(isPresented: $showAPIModelPicker, arrowEdge: .top) {
                                LocalModelPicker()
                                    .environment(app)
                            }

                        if app.serverEnabled {
                            apiModelMenu
                        }

                        HStack(spacing: Theme.s1) {
                            Text("OpenRouter")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
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
                            .labelsHidden()
                            .controlSize(.regular)
                            .toggleStyle(.switch)
                        }
                        .help("OpenRouter API key")
                        .popover(isPresented: $showOpenRouterModelPicker, arrowEdge: .top) {
                            OpenRouterModelPicker(customModel: $customOpenRouterModel)
                                .environment(app)
                        }

                        if !app.openRouterModelIDs.isEmpty {
                            openRouterModelMenu
                        }

                        HStack(spacing: Theme.s1) {
                            Text("Anthropic")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
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
                                .labelsHidden()
                                .controlSize(.regular)
                                .toggleStyle(.switch)
                        }
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

                        HStack(spacing: Theme.s1) {
                            Text("OpenAI")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Toggle("OpenAI", isOn: Binding(
                                get: { app.openAIModelID != nil },
                                set: { enabled in
                                    if enabled {
                                        app.setPrimaryOpenAIModel(
                                            app.openAIModelID ?? OpenAIClient.models[0].id)
                                        showOpenAIModelPicker = true
                                    } else {
                                        app.openAIModelID = nil
                                    }
                                }
                            ))
                                .labelsHidden()
                                .controlSize(.regular)
                                .toggleStyle(.switch)
                        }
                            .help("OpenAI API key — Responses API with reasoning.effort")
                            .popover(isPresented: $showOpenAIModelPicker, arrowEdge: .top) {
                                CloudModelPicker(
                                    title: "OpenAI Model",
                                    systemImage: "brain.head.profile",
                                    models: OpenAIClient.models,
                                    selection: Binding(
                                        get: { app.openAIModelID ?? OpenAIClient.models[0].id },
                                        set: { app.setPrimaryOpenAIModel($0) }),
                                    customModel: .constant(""),
                                    allowsCustom: false)
                            }

                        if let openAIID = app.openAIModelID, !openAIID.isEmpty {
                            cloudModelMenu(
                                title: OpenAIClient.label(for: openAIID),
                                systemImage: "brain.head.profile",
                                models: OpenAIClient.models,
                                selection: Binding(
                                    get: { app.openAIModelID ?? OpenAIClient.models[0].id },
                                    set: { app.setPrimaryOpenAIModel($0) }),
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
                                .background(
                                    app.canSend && !isPreparingAttachments
                                        ? AnyShapeStyle(Theme.emberGradient)
                                        : AnyShapeStyle(.quaternary))
                                .foregroundStyle(.white)
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!app.canSend || isPreparingAttachments)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                    }
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
            }
            .glassCard(radius: Theme.radiusLarge)
            .padding(.horizontal, Theme.s5)
            .padding(.bottom, Theme.s2)
            .padding(.top, Theme.s2)
        }
        .sheet(isPresented: $showSmartPromptSheet) {
            SmartPromptSheet { task, goals, notes in
                app.startSmartPromptSelection(task: task, goals: goals, notes: notes)
            }
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
                    beginAttachmentImport([url], imagesOnly: true)
                }
            case .failure(let error):
                attachmentError = "Photo picker failed: \(error.localizedDescription)"
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
            if !app.openRouterCustomModels.isEmpty {
                Divider()
                ForEach(app.openRouterCustomModels, id: \.self) { modelID in
                    Button {
                        app.setOpenRouterModel(
                            modelID,
                            selected: !app.isOpenRouterModelSelected(modelID))
                    } label: {
                        Label(
                            OpenRouterClient.label(for: modelID),
                            systemImage: app.isOpenRouterModelSelected(modelID)
                                ? "checkmark.circle.fill" : "circle")
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

    /// General file attach: images join pendingImages; PDFs are text-extracted;
    /// everything else that decodes as text is inlined into the composer as a
    /// fenced context block (JSON, Markdown, Swift, Shell, Python, …).
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        beginAttachmentImport(panel.urls, imagesOnly: false)
    }

    private func clearPendingAttachments() {
        attachmentImportID = nil
        attachmentImportTask?.cancel()
        attachmentImportTask = nil
        isPreparingAttachments = false
        pendingImages.removeAll()
        attachmentError = nil
    }

    private func beginAttachmentImport(_ urls: [URL], imagesOnly: Bool) {
        guard !urls.isEmpty else { return }
        attachmentImportTask?.cancel()
        let selectedURLs = Array(urls.prefix(Self.maxAttachmentFileCount))
        let skippedCount = urls.count - selectedURLs.count
        let importID = UUID()
        attachmentImportID = importID
        isPreparingAttachments = true
        attachmentError = nil
        attachmentImportTask = Task { @MainActor in
            defer {
                if attachmentImportID == importID {
                    attachmentImportID = nil
                    attachmentImportTask = nil
                    isPreparingAttachments = false
                }
            }
            for url in selectedURLs {
                guard !Task.isCancelled, attachmentImportID == importID else { return }
                if imagesOnly, pendingImages.count >= Self.maxPendingImageCount {
                    attachmentError =
                        "Attachment limit reached (\(Self.maxPendingImageCount) images)."
                    break
                }
                let prepared = await Self.prepareAttachment(at: url, imagesOnly: imagesOnly)
                guard !Task.isCancelled, attachmentImportID == importID else { return }
                applyPreparedAttachment(prepared)
            }
            if skippedCount > 0, attachmentError == nil {
                attachmentError =
                    "Attached the first \(Self.maxAttachmentFileCount) files; skipped \(skippedCount)."
            }
        }
    }

    private func applyPreparedAttachment(_ attachment: PreparedAttachment) {
        switch attachment {
        case .image(let name, let data):
            guard pendingImages.count < Self.maxPendingImageCount else {
                attachmentError = "Attachment limit reached (\(Self.maxPendingImageCount) images)."
                return
            }
            let pendingBytes = pendingImages.reduce(0) { $0 + $1.count }
            guard pendingBytes + data.count <= Self.maxPendingImageBytes else {
                attachmentError = "Pending images may total at most \(Format.bytes(Self.maxPendingImageBytes))."
                return
            }
            pendingImages.append(data)
            if app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                app.composerText = "Review the attached image \(name)."
            }
        case .text(let name, let content, let clipped):
            let clippedNote = clipped
                ? "\n… [clipped to first \(Self.maxInlineChars) characters]" : ""
            let block =
                (app.composerText.isEmpty ? "" : "\n\n")
                + "[file: \(name)]\n```\n\(content)\(clippedNote)\n```"
            guard app.composerText.count + block.count <= Self.maxComposerAttachmentChars else {
                attachmentError =
                    "Inline attachments may use at most \(Self.maxComposerAttachmentChars) characters in the composer."
                return
            }
            app.composerText += block
        case .failure(let message):
            attachmentError = message
        case .cancelled:
            break
        }
    }

    private nonisolated static func prepareAttachment(
        at url: URL, imagesOnly: Bool
    ) async -> PreparedAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            prepareAttachmentSynchronously(at: url, imagesOnly: imagesOnly)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func prepareAttachmentSynchronously(
        at url: URL, imagesOnly: Bool
    ) -> PreparedAttachment {
        guard !Task.isCancelled else { return .cancelled }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let ext = url.pathExtension.lowercased()
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"])

        if imagesOnly || imageExtensions.contains(ext) {
            switch boundedData(at: url, limit: maxImageBytes) {
            case .success(let data):
                return data.isEmpty
                    ? .failure("\(name) is empty.")
                    : .image(name: name, data: data)
            case .failure(let message):
                return .failure("Could not attach \(name): \(message)")
            }
        }

        if ext == "pdf" {
            guard let size = fileSize(at: url) else {
                return .failure("Could not determine the size of \(name).")
            }
            guard size <= maxPDFBytes else {
                return .failure("\(name) is \(Format.bytes(size)); PDFs are limited to \(Format.bytes(maxPDFBytes)).")
            }
            guard !Task.isCancelled else { return .cancelled }
            guard let raw = PDFDocument(url: url)?.string,
                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .failure("Could not extract text from \(name).")
            }
            let clipped = raw.count > maxInlineChars
            return .text(
                name: name,
                content: clipped ? String(raw.prefix(maxInlineChars)) : raw,
                clipped: clipped)
        }

        switch boundedData(at: url, limit: maxTextBytes) {
        case .success(let data):
            guard !Task.isCancelled else { return .cancelled }
            let raw = String(data: data, encoding: .utf8)
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("\(name) is unsupported, binary, or empty.")
            }
            let clipped = raw.count > maxInlineChars
            return .text(
                name: name,
                content: clipped ? String(raw.prefix(maxInlineChars)) : raw,
                clipped: clipped)
        case .failure(let message):
            return .failure("Could not attach \(name): \(message)")
        }
    }

    private nonisolated static func boundedData(
        at url: URL, limit: Int
    ) -> BoundedRead {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                return .failure("file exceeds the \(Format.bytes(limit)) limit")
            }
            return .success(data)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated static func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    /// Mode tags prepended to every send/dispatch; the Workflow pick joins the
    /// Depth/Style/Deliverable tags so the model receives it as an instruction.
    private var modeTags: String {
        var tags: [String] = []
        if depthMode != "Balanced" { tags.append("[Depth: \(depthMode)]") }
        if styleMode != "Standard" { tags.append("[Style: \(styleMode)]") }
        if deliverableMode != "Text" { tags.append("[Deliverable: \(deliverableMode)]") }
        if workflowMode != "None" { tags.append("[Workflow: \(workflowMode)]") }
        return tags.isEmpty ? "" : tags.joined(separator: " ") + " "
    }

    private var shouldPrefixModeTags: Bool {
        let tags = modeTags
        return !tags.isEmpty
            && !app.composerText.hasPrefix("[Depth:")
            && !app.composerText.hasPrefix("[Style:")
            && !app.composerText.hasPrefix("[Deliverable:")
            && !app.composerText.hasPrefix("[Workflow:")
    }

    private func performSend() {
        guard !isPreparingAttachments else { return }
        let tags = modeTags
        if shouldPrefixModeTags {
            app.composerText = tags + app.composerText
        }
        let imagesToSend = pendingImages
        pendingImages = []
        app.send(images: imagesToSend)
    }

    private var placeholder: String {
        if app.braveSearchEnabled {
            return "Ask Brave \(app.braveSearchConfig.enableResearch ? "Research" : "Answers")…"
        }
        if let openRouterID = app.openRouterModelID, !openRouterID.isEmpty {
            return "Message \(OpenRouterClient.label(for: openRouterID))…"
        }
        if let openAIID = app.openAIModelID, !openAIID.isEmpty {
            return "Message \(OpenAIClient.label(for: openAIID))…"
        }
        if let claudeID = app.claudeModelID, !claudeID.isEmpty {
            return "Message \(AnthropicClient.label(for: claudeID))…"
        }
        let fanoutCount = app.engine.loadedModels.filter { app.isLocalFanoutSelected($0.id) }.count
        if fanoutCount >= 2 {
            return "Message \(fanoutCount) local models in parallel…"
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
                    ForEach(app.openRouterCustomModels, id: \.self) { modelID in
                        HStack(spacing: Theme.s1) {
                            Toggle(isOn: Binding(
                                get: { app.isOpenRouterModelSelected(modelID) },
                                set: { app.setOpenRouterModel(modelID, selected: $0) }
                            )) {
                                Text(OpenRouterClient.label(for: modelID))
                                    .lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                            Spacer(minLength: 0)
                            Button {
                                app.removeOpenRouterCustomModel(modelID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this model from the list")
                        }
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
        app.addOpenRouterCustomModel(value)
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
