// Forge — model library: installed models, Hugging Face discovery, downloads.

import AppKit
import SwiftUI

struct ModelBrowserView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case installed = "Installed"
        case discover = "Discover"
        case downloads = "Downloads"
    }

    @State private var tab: Tab = .installed
    @State private var showAccount = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .installed: InstalledList()
            case .discover: DiscoverList()
            case .downloads: DownloadsList()
            }
        }
        .frame(width: 640, height: 560)
        .background(Theme.backgroundGradient)
    }

    private var header: some View {
        HStack(spacing: Theme.s3) {
            ForgeMark(size: 16)
            Text("Model Library")
                .font(.headline)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    if tab == .downloads {
                        let active = app.store.downloads.filter { !$0.finished && $0.failed == nil }
                        Text(active.isEmpty ? tab.rawValue : "\(tab.rawValue) (\(active.count))")
                    } else {
                        Text(tab.rawValue)
                    }
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            Spacer()
            Button {
                showAccount = true
            } label: {
                Image(systemName: app.store.hasToken ? "key.fill" : "key")
                    .font(.body)
                    .foregroundStyle(app.store.hasToken ? AnyShapeStyle(Theme.emberGlow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAccount, arrowEdge: .bottom) {
                HuggingFaceTokenPopover()
                    .environment(app)
            }
            .help("Hugging Face access token")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.s4)
    }
}

// MARK: - Hugging Face token

private struct HuggingFaceTokenPopover: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Label("Hugging Face Token", systemImage: "key.horizontal")
                .font(.headline)

            Text(
                app.store.hasToken
                    ? "A token is stored securely in your Keychain. It is used for gated and private models, downloads, and search."
                    : "Paste an access token (hf_…) to download gated or private models. Stored in the macOS Keychain — never written to disk in plain text."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("hf_xxxxxxxxxxxxxxxxxxxx", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { save() }

            HStack {
                if app.store.hasToken {
                    Button("Remove Token", role: .destructive) {
                        app.store.setToken(nil)
                        draft = ""
                    }
                }
                Spacer()
                Link("Get a token…", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    .font(.caption)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.s4)
        .frame(width: 380)
    }

    private func save() {
        let token = draft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        app.store.setToken(token)
        draft = ""
    }
}

// MARK: - Installed

private struct InstalledList: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if app.store.localModels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.s2) {
                        ForEach(app.store.localModels) { model in
                            InstalledRow(model: model) {
                                app.engine.loadAndActivate(model)
                                app.scheduleSave()
                            }
                        }
                    }
                    .padding(Theme.s4)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addFolder()
                } label: {
                    Label("Add Model Folder…", systemImage: "folder.badge.plus")
                }
                .help("Add a folder containing MLX models (config.json + safetensors)")
                Spacer()
                if app.store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    app.store.refreshLocal()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(app.store.isScanning)
            }
            .padding(Theme.s3)
            .background(.ultraThinMaterial)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.s3) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No models installed yet")
                .font(.headline)
            Text("Grab one from the Discover tab, or add a local folder below.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder that contains MLX models"
        if panel.runModal() == .OK, let url = panel.url {
            // Register the *selected* URL — that's the one the sandbox grant (and the
            // security-scoped bookmark) covers. The scanner now treats a root that is
            // itself a model folder as a model, so a direct pick works too.
            app.addModelDirectory(url)
        }
    }
}

private struct InstalledRow: View {
    @Environment(AppState.self) private var app
    let model: LocalModel
    let onLoad: () -> Void

    private var isLoaded: Bool { app.engine.isLoaded(model.id) }
    private var isActive: Bool { app.engine.activeModelID == model.id }
    private var isLoading: Bool { app.engine.loadingModels.keys.contains(model.id) }
    private var loadedEntry: InferenceEngine.Loaded? {
        app.engine.loadedModels.first { $0.id == model.id }
    }

    private var loadHelp: String {
        if model.isGGUF {
            return "Load this GGUF file on the llama.cpp backend."
        }
        return "Standard MLX load — fastest for MoE models like Qwen A3B. Use this."
    }

    private var loadStatusLabel: String {
        guard let entry = loadedEntry else { return "Loaded" }
        if entry.weightLoadPolicy == .deferred {
            return isActive ? "Active · deferred" : "Deferred"
        }
        if entry.weightLoadPolicy == .boundedEager {
            return isActive ? "Active · bounded" : "Bounded"
        }
        return isActive ? "Active" : "Loaded"
    }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(isLoaded ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(.secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: Theme.s2) {
                    Text(Format.bytes(model.sizeBytes))
                    if let architecture = model.architecture { Text("· \(architecture)") }
                    if let quantization = model.quantization { Text("· \(quantization)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            if isLoading {
                HStack(spacing: Theme.s2) {
                    if let fraction = app.engine.loadingModels[model.id] ?? nil {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                            .frame(width: 56)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isLoaded {
                VStack(alignment: .trailing, spacing: Theme.s1) {
                    Label(loadStatusLabel, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? Theme.emberGlow : Theme.okGreen)
                    if loadedEntry?.weightLoadPolicy == .boundedEager
                        || loadedEntry?.weightLoadPolicy == .deferred
                    {
                        Button("Reload Standard") {
                            app.reloadModelStandard(model)
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Unload and reload with the fast standard MLX path")
                    }
                }
            } else {
                HStack(spacing: Theme.s2) {
                    Button("Load") {
                        app.engine.loadAndActivate(model, policy: .eager)
                        app.scheduleSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .controlSize(.small)
                    .help(loadHelp)

                    if !model.isGGUF {
                        Menu {
                            Button("Bounded eager") {
                                app.engine.loadAndActivate(model, policy: .boundedEager)
                                app.scheduleSave()
                            }
                            .disabled(model.prefersStandardMLXLoad)
                            Button("Deferred (lazy)") {
                                app.engine.loadAndActivate(model, policy: .deferred)
                                app.scheduleSave()
                            }
                            .disabled(model.prefersStandardMLXLoad)
                            .help(
                                model.isVeryLargeForDeferredLoad
                                    ? "Skips final weight eval at load; first send materializes the full checkpoint (several minutes on 100B+ models). UI stays responsive but wait for the status bar."
                                    : WeightLoadPolicy.deferred.help)
                            if model.prefersStandardMLXLoad {
                                Text("MoE models use standard Load only")
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .help(
                            "Dense LLMs only — lowers peak RAM while loading. MoE/A3B models ignore this and use Load.")
                    }
                }
            }

            Menu {
                if isLoaded {
                    Button("Make Active") {
                        app.engine.activeModelID = model.id
                    }
                    Button("Unload from Memory") {
                        app.engine.unload(model.id)
                        app.scheduleSave()
                    }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.directory])
                }
                if model.isManaged {
                    Button("Delete from Disk", role: .destructive) {
                        if isLoaded { app.engine.unload(model.id) }
                        app.store.delete(model)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(Theme.s3)
        .glassCard()
    }
}

// MARK: - Discover

private struct DiscoverList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var store = app.store
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Search Hugging Face for MLX models…",
                    text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { store.search() }
                    .onChange(of: store.searchQuery) { store.search() }
                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(Theme.s3)
            .glassCard()
            .padding(Theme.s4)

            if let error = store.searchError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, Theme.s2)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.s2) {
                    if store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("FEATURED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, Theme.s1)
                        ForEach(ModelStore.featured) { model in
                            RemoteRow(model: model)
                        }
                    } else {
                        ForEach(store.searchResults) { model in
                            RemoteRow(model: model)
                        }
                        if store.searchResults.isEmpty && !store.isSearching {
                            Text("No MLX models found for “\(store.searchQuery)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Theme.s6)
                        }
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s4)
            }
        }
    }
}

private struct RemoteRow: View {
    @Environment(AppState.self) private var app
    let model: RemoteModel

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.emberGlow)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.shortName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: Theme.s2) {
                    Text(model.organization)
                    if let downloads = model.downloads {
                        Label(Format.count(downloads), systemImage: "arrow.down.circle")
                    }
                    if let likes = model.likes {
                        Label(Format.count(likes), systemImage: "heart")
                    }
                    if let size = model.sizeHint {
                        Text(size)
                            .padding(.horizontal, Theme.s1)
                            .background(.white.opacity(0.08))
                            .clipShape(.capsule)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(Theme.s3)
        .glassCard()
    }

    @ViewBuilder
    private var trailing: some View {
        if app.store.isDownloaded(model.id) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.okGreen)
        } else if let download = app.store.activeDownload(for: model.id) {
            DownloadProgressGauge(download: download)
        } else {
            Button {
                app.store.download(model.id)
            } label: {
                Label("Get", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ember)
            .controlSize(.small)
        }
    }
}

struct DownloadProgressGauge: View {
    var download: ModelStore.DownloadTask

    var body: some View {
        HStack(spacing: Theme.s2) {
            ProgressView(value: max(0, min(1, download.fraction)))
                .frame(width: 80)
            Text("\(Int(download.fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Downloads

private struct DownloadsList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.store.downloads.isEmpty {
                VStack(spacing: Theme.s3) {
                    Spacer()
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No downloads")
                        .font(.headline)
                    Text("Models you download appear here with live progress.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.s2) {
                        ForEach(app.store.downloads) { download in
                            DownloadRow(download: download)
                        }
                    }
                    .padding(Theme.s4)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Clear Finished") {
                            app.store.clearFinishedDownloads()
                        }
                    }
                    .padding(Theme.s3)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }
}

private struct DownloadRow: View {
    @Environment(AppState.self) private var app
    var download: ModelStore.DownloadTask

    var body: some View {
        HStack(spacing: Theme.s3) {
            statusIcon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(download.id)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let failure = download.failed {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if !download.finished {
                    ProgressView(value: max(0, min(1, download.fraction)))
                    if download.totalBytes > 0 {
                        Text("\(Format.bytes(download.completedBytes)) of \(Format.bytes(download.totalBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if download.finished {
                Text("Done")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.okGreen)
            } else if download.failed == nil {
                Button {
                    app.store.cancelDownload(download)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        }
        .padding(Theme.s3)
        .glassCard()
    }

    @ViewBuilder
    private var statusIcon: some View {
        if download.finished {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.okGreen)
        } else if download.failed != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
