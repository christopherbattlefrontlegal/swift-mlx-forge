// Forge — shared UI components: model picker, memory badge, markdown rendering.

import AppKit
import SwiftUI

// MARK: - Model picker (toolbar)

struct ModelPickerControl: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            if !app.engine.loadedModels.isEmpty {
                Section("Loaded — switch instantly") {
                    ForEach(app.engine.loadedModels) { entry in
                        Button {
                            app.claudeModelID = nil
                            app.engine.activeModelID = entry.id
                    } label: {
                        if app.claudeModelID == nil, app.engine.activeModelID == entry.id {
                            Label(menuDisplay(for: entry.model), systemImage: "checkmark")
                        } else {
                            Label(menuDisplay(for: entry.model), systemImage: "bolt.fill")
                        }
                    }
                }
                }
                Section {
                    Menu("Unload…") {
                        ForEach(app.engine.loadedModels) { entry in
                            Button(menuDisplay(for: entry.model)) {
                                app.engine.unload(entry.id)
                                app.scheduleSave()
                            }
                        }
                        Divider()
                        Button("Unload All") {
                            app.engine.unloadAll()
                            app.scheduleSave()
                        }
                    }
                }
            }
            let coldModels = app.store.localModels.filter { !app.engine.isLoaded($0.id) }
            if !coldModels.isEmpty {
                Section("Library — load into memory") {
                    ForEach(coldModels) { model in
                        Button(menuDisplay(for: model)) {
                            app.claudeModelID = nil
                            app.engine.loadAndActivate(model)
                            app.scheduleSave()
                        }
                    }
                }
            }
            if app.hasOpenRouterKey {
                Section("OpenRouter presets") {
                    ForEach(OpenRouterClient.models, id: \.id) { model in
                        Button {
                            if app.isOpenRouterModelSelected(model.id) {
                                app.setPrimaryOpenRouterModel(model.id)
                            } else {
                                app.setOpenRouterModel(model.id, selected: true)
                            }
                        } label: {
                            if app.openRouterModelID == model.id {
                                Label(model.label, systemImage: "checkmark.circle.fill")
                            } else if app.isOpenRouterModelSelected(model.id) {
                                Label(model.label, systemImage: "circle.fill")
                            } else {
                                Label(model.label, systemImage: "circle")
                            }
                        }
                    }
                    if !app.openRouterCatalog.isEmpty {
                        Divider()
                        ForEach(app.openRouterCatalog) { entry in
                            if !OpenRouterClient.models.contains(where: { $0.id == entry.id }) {
                                Button {
                                    app.setOpenRouterModel(entry.id, selected: true)
                                } label: {
                                    Label(entry.label, systemImage: "circle")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Select all presets") { app.selectAllOpenRouterModels() }
                    Button("Clear selection") { app.clearOpenRouterModels() }
                    Button("Refresh live catalog") { app.refreshOpenRouterCatalog() }
                }
            }
            Section("Claude (API key)") {
                ForEach(AnthropicClient.models, id: \.id) { claude in
                    Button {
                        app.claudeModelID = claude.id
                    } label: {
                        if app.claudeModelID == claude.id {
                            Label(claude.label, systemImage: "checkmark")
                        } else {
                            Label(claude.label, systemImage: "cloud")
                        }
                    }
                }
                if !app.hasAnthropicKey {
                    Text("Set an API key in the Tuning panel to use Claude")
                }
            }
            Divider()
            Button("Browse & Download…") {
                app.showModelBrowser = true
            }
        } label: {
            HStack(spacing: 4) {
                statusDot
                // Multi-model display with numbers, short names. Supports loading many (click + in menu to add).
                // Each gets 1. 2. 3. for agent refs like "model 1 do X".
                let loaded = Array(app.engine.loadedModels.enumerated())
                if loaded.isEmpty {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                } else {
                    ForEach(loaded.prefix(4), id: \.1.id) { idx, entry in
                        Text("\(idx + 1). \(shortDisplay(for: entry.model)) · \(compactRuntime(for: entry.model))")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .background(
                                (app.engine.activeModelID == entry.id && app.claudeModelID == nil)
                                    ? Theme.ember.opacity(0.2) : Color.clear
                            )
                            .clipShape(.capsule)
                    }
                }
                if loaded.count > 4 {
                    Text("+\(loaded.count - 4)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.s2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active model — loaded models switch instantly")
    }

    private var title: String {
        if let claude = app.claudeModelID, !claude.isEmpty {
            return AnthropicClient.label(for: claude)
        }
        if !app.openRouterModelIDs.isEmpty {
            return app.openRouterSelectionSummary
        }
        if let loading = app.engine.loadingModels.first {
            let name = URL(filePath: loading.key).lastPathComponent
            if let fraction = loading.value, fraction > 0, fraction < 1 {
                return "Loading \(name)… \(Int(fraction * 100))%"
            }
            return "Loading \(name)…"
        }
        if let active = app.engine.activeModel {
            return shortDisplay(for: active.model)
        }
        return app.engine.lastError == nil ? "Select a model" : "Load failed"
    }

    private func menuDisplay(for model: LocalModel) -> String {
        "\(shortDisplay(for: model)) — \(model.runtimeDetails)"
    }

    private func compactRuntime(for model: LocalModel) -> String {
        let details = model.runtimeDetails.replacingOccurrences(of: " · ", with: " ")
        return details.count > 22 ? String(details.prefix(22)) : details
    }

    private func shortDisplay(for model: LocalModel) -> String {
        var s = model.shortName
        // Shrink long names as requested: e.g. "Qwen3.6-40B-Heretic-Thinking-8bit" -> "Qwen 3.6 40B"
        s = s.replacingOccurrences(of: "-Heretic-Thinking-8bit", with: "")
        s = s.replacingOccurrences(of: "-Heretic-Thinking", with: "")
        if s.contains("Qwen") {
            s = s.replacingOccurrences(of: "Qwen", with: "Qwen ")
        }
        // General: take first 2-3 meaningful parts
        let parts = s.split(separator: "-").prefix(3).map(String.init).joined(separator: " ")
        return parts.count > 20 ? String(parts.prefix(20)) + "…" : parts
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .shadow(color: dotColor.opacity(0.8), radius: 3)
    }

    private var dotColor: Color {
        if let claude = app.claudeModelID, !claude.isEmpty {
            return app.hasAnthropicKey ? Theme.okGreen : Theme.emberGlow
        }
        if app.engine.isLoadingAnything { return Theme.emberGlow }
        if app.engine.activeModel != nil { return Theme.okGreen }
        if app.engine.lastError != nil { return .red }
        return Theme.steel
    }
}

struct UnloadModelsToolbarButton: View {
    @Environment(AppState.self) private var app

    private var canUnload: Bool {
        !app.engine.loadedModels.isEmpty || app.engine.isLoadingAnything
    }

    var body: some View {
        Button {
            app.stopGenerating()
            app.engine.unloadAll()
            app.scheduleSave()
        } label: {
            Label("Unload", systemImage: "eject.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Theme.s2)
                .padding(.vertical, Theme.s1)
        }
        .buttonStyle(.bordered)
        .disabled(!canUnload)
        .help(
            app.engine.isLoadingAnything
                ? "Abort model loading and unload all local models"
                : "Unload all local models from memory")
    }
}

// MARK: - Memory badge (toolbar)

struct MemoryBadge: View {
    @Environment(AppState.self) private var app

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.s1) {
            Image(systemName: "memorychip")
                .font(.caption)
            Text(label)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, Theme.s1)
        .glassCard(radius: Theme.radiusSmall)
        .onReceive(timer) { _ in
            app.engine.refreshMemory()
        }
        .help("MLX GPU memory (active / peak) of unified memory")
    }

    private var label: String {
        let active = Format.bytes(app.engine.activeMemory)
        if app.engine.activeMemory == 0 { return "GPU idle" }
        return "\(active)"
    }
}

// MARK: - Markdown rendering

/// Renders assistant text: fenced code blocks get a monospaced panel with a
/// copy button; everything else renders as inline markdown.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            ForEach(Self.blocks(in: text)) { block in
                switch block.kind {
                case .prose:
                    Text(Self.inline(block.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language):
                    CodeBlock(code: block.text, language: language)
                }
            }
        }
    }

    struct Block: Identifiable {
        enum Kind {
            case prose
            case code(language: String?)
        }
        let id: Int
        var kind: Kind
        var text: String
    }

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false
        var nextID = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(Block(id: nextID, kind: .prose, text: joined))
                nextID += 1
            }
            prose = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(
                        Block(id: nextID, kind: .code(language: language), text: code.joined(separator: "\n")))
                    nextID += 1
                    code = []
                    inCode = false
                } else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                    language = tag.isEmpty ? nil : String(tag)
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            // Still-streaming, unterminated fence.
            blocks.append(Block(id: nextID, kind: .code(language: language), text: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        sanitizeLinks(&attributed)
        return attributed
    }

    /// Schemes safe to hand to NSWorkspace.open on a click.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Model output is untrusted. Markdown link parsing yields clickable `.link`
    /// runs that flow to NSWorkspace.open with *any* scheme — `file://`, custom
    /// app schemes, etc. — turning a one-line answer into a one-click app launch
    /// or a phishing target with a forged label. Strip the link attribute from
    /// any run whose scheme isn't web/mail; the visible text remains as plain text.
    private static func sanitizeLinks(_ attributed: inout AttributedString) {
        var unsafeRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            guard let link = run.link else { continue }
            let scheme = link.scheme?.lowercased()
            if scheme == nil || !allowedLinkSchemes.contains(scheme!) {
                unsafeRanges.append(run.range)
            }
        }
        for range in unsafeRanges {
            attributed[range].link = nil
        }
    }
}

struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.okGreen : .secondary)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            .background(.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(Theme.s3)
            }
        }
        .background(Theme.codeBackground)
        .clipShape(.rect(cornerRadius: Theme.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Copy

/// LM Studio–style copy control — icon-only or labeled.
struct CopyClipButton: View {
    var label: String? = nil
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            if let label {
                Label(
                    copied ? "Copied" : label,
                    systemImage: copied ? "checkmark" : "square.on.square")
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Theme.okGreen : .secondary)
        .help(copied ? "Copied" : (label ?? "Copy"))
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

// MARK: - Small bits

struct StatChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
