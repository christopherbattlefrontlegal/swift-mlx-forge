// Forge — Media Studio pane: cloud image/video generation, the generated-asset
// gallery, and an Apple Music transport.
//
// The Music section drives Music.app through its public scripting surface
// (play/pause, track info, volume, and the player's own EQ presets). It pipes
// in the functionality only; no other app's interface is embedded.

import AVKit
import AppKit
import SwiftUI

struct MediaView: View {
    @Environment(AppState.self) private var app
    @State private var library = MediaLibrary()
    @State private var provider: MediaProvider = .openAIImage
    @State private var prompt = ""
    @State private var imageSize = "1024x1024"
    @State private var videoSeconds = 4
    @State private var status = ""
    @State private var errorText = ""
    @State private var isGenerating = false
    @State private var selected: MediaAsset?
    @State private var generationTask: Task<Void, Never>?
    @AppStorage("media.model.openAIImage") private var openAIImageModel = "gpt-image-1"
    @AppStorage("media.model.grokImage") private var grokImageModel = "grok-2-image"
    @AppStorage("media.model.video") private var videoModel = "sora-2"

    var body: some View {
        HSplitView {
            generatePanel
                .frame(minWidth: 300, maxWidth: 360)
            VStack(spacing: 0) {
                viewer
                Divider()
                gallery
                Divider()
                MusicTransportBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.backgroundGradient)
        .onAppear {
            library.refresh()
            if selected == nil { selected = library.assets.first }
        }
        .onDisappear { generationTask?.cancel() }
    }

    // MARK: - Generation form

    private var generatePanel: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Label("Media Studio", systemImage: "wand.and.stars")
                .font(.headline)

            Picker("Provider", selection: $provider) {
                ForEach(MediaProvider.allCases) { p in
                    Label(p.label, systemImage: p.systemImage).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            modelPicker

            Text("Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 110, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(Theme.s2)
                .background(Theme.composerBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            if provider.isVideo {
                Picker("Length", selection: $videoSeconds) {
                    Text("4 seconds").tag(4)
                    Text("8 seconds").tag(8)
                    Text("12 seconds").tag(12)
                }
                Picker("Size", selection: $imageSize) {
                    ForEach(provider.imageSizes, id: \.self) { Text($0).tag($0) }
                }
            } else if provider.imageSizes.count > 1 {
                Picker("Size", selection: $imageSize) {
                    ForEach(provider.imageSizes, id: \.self) { Text($0).tag($0) }
                }
            }

            if !provider.hasKey {
                Label(
                    "Add an \(provider.keyHint) API key in Settings to use \(provider.label).",
                    systemImage: "key.slash")
                .font(.caption)
                .foregroundStyle(Theme.emberGlow)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.s2) {
                Button {
                    generate()
                } label: {
                    Label(
                        isGenerating ? "Generating…" : "Generate",
                        systemImage: provider.isVideo ? "video.badge.plus" : "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
                .disabled(
                    isGenerating || !provider.hasKey
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isGenerating {
                    Button("Cancel") {
                        generationTask?.cancel()
                    }
                    .controlSize(.small)
                }
            }

            if isGenerating || !status.isEmpty {
                HStack(spacing: Theme.s2) {
                    if isGenerating { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text("Generated files live in Application Support/Forge/Media.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.s4)
        .onChange(of: provider) { _, newValue in
            if !newValue.imageSizes.contains(imageSize) {
                imageSize = newValue.imageSizes.first ?? "1024x1024"
            }
        }
    }

    private var modelOptions: [String] {
        switch provider {
        case .openAIImage: return CloudModelCatalog.imageModels(.openAI)
        case .grokImage: return CloudModelCatalog.imageModels(.xAI)
        case .openAIVideo: return CloudModelCatalog.videoModels()
        }
    }

    private var modelBinding: Binding<String> {
        switch provider {
        case .openAIImage: return $openAIImageModel
        case .grokImage: return $grokImageModel
        case .openAIVideo: return $videoModel
        }
    }

    /// Model options come from the live provider catalogs (see Settings);
    /// the stored choice is kept in the list even if a refresh drops it.
    @ViewBuilder
    private var modelPicker: some View {
        let _ = app.cloudCatalogTick
        let options = modelOptions
        let binding = modelBinding
        let full = options.contains(binding.wrappedValue)
            ? options : options + [binding.wrappedValue]
        Picker("Model", selection: binding) {
            ForEach(full, id: \.self) { Text($0).tag($0) }
        }
    }

    private var selectedModel: String {
        switch provider {
        case .openAIImage: return openAIImageModel
        case .grokImage: return grokImageModel
        case .openAIVideo: return videoModel
        }
    }

    private func generate() {
        let requestPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestPrompt.isEmpty, !isGenerating else { return }
        isGenerating = true
        errorText = ""
        status = provider.isVideo ? "submitting render job" : "generating"
        let requestProvider = provider
        let requestModel = selectedModel
        let requestSize = imageSize
        let requestSeconds = videoSeconds
        generationTask = Task { @MainActor in
            defer {
                isGenerating = false
                generationTask = nil
            }
            do {
                let data: Data
                let fileExtension: String
                if requestProvider.isVideo {
                    data = try await MediaGenClient.generateVideo(
                        model: requestModel, prompt: requestPrompt,
                        seconds: requestSeconds, size: requestSize
                    ) { progress in
                        Task { @MainActor in self.status = progress }
                    }
                    fileExtension = "mp4"
                } else {
                    data = try await MediaGenClient.generateImage(
                        provider: requestProvider, model: requestModel,
                        prompt: requestPrompt, size: requestSize)
                    fileExtension = "png"
                }
                if let asset = library.save(
                    data, fileExtension: fileExtension, provider: requestProvider)
                {
                    selected = asset
                }
                status = "done"
            } catch is CancellationError {
                status = "cancelled"
            } catch {
                status = ""
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Viewer

    @ViewBuilder
    private var viewer: some View {
        Group {
            if let selected {
                if selected.isVideo {
                    VideoPlayer(player: AVPlayer(url: selected.url))
                        .id(selected.url)
                } else if let image = NSImage(contentsOf: selected.url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Theme.s3)
                } else {
                    placeholder("Could not read \(selected.filename)")
                }
            } else {
                placeholder("Generate an image or video, and it shows here.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 42))
                .foregroundStyle(Theme.steel)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Gallery

    private var gallery: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: Theme.s2) {
                ForEach(library.assets) { asset in
                    galleryTile(asset)
                }
            }
            .padding(Theme.s2)
        }
        .frame(height: 108)
    }

    private func galleryTile(_ asset: MediaAsset) -> some View {
        Button {
            selected = asset
        } label: {
            ZStack {
                if asset.isVideo {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Theme.assistantBubble)
                    VStack(spacing: Theme.s1) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.ember)
                        Text(asset.filename)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Theme.s1)
                } else if let thumb = NSImage(contentsOf: asset.url) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 120, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .stroke(
                        selected == asset ? Theme.ember : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
            Button("Delete", role: .destructive) {
                if selected == asset { selected = nil }
                library.delete(asset)
            }
        }
    }
}

// MARK: - Apple Music transport

/// Drives Music.app through its scripting interface. Functionality only; no
/// other application's window or interface is embedded.
@MainActor
private enum AppleMusicRemote {
    /// Last script failure, kept so the UI can explain a denial instead of
    /// silently doing nothing. Error -1743 is the Automation-permission block.
    private(set) static var lastError: (code: Int, message: String)?

    @discardableResult
    static func run(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            lastError = (
                (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0,
                (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown script error"
            )
            return nil
        }
        lastError = nil
        return result?.stringValue
    }

    static var permissionDenied: Bool {
        lastError?.code == -1743
    }

    static func playPause() { run("tell application \"Music\" to playpause") }
    static func next() { run("tell application \"Music\" to next track") }
    static func previous() { run("tell application \"Music\" to previous track") }

    static func nowPlaying() -> String {
        let script = """
            tell application "Music"
                if player state is playing or player state is paused then
                    return (name of current track) & " · " & (artist of current track)
                else
                    return ""
                end if
            end tell
            """
        let value = run(script) ?? ""
        return value.isEmpty ? "Nothing playing" : value
    }

    static func isPlaying() -> Bool {
        run("tell application \"Music\" to return player state is playing") == "true"
    }

    static func volume() -> Double {
        Double(run("tell application \"Music\" to return sound volume") ?? "") ?? 70
    }

    static func setVolume(_ value: Double) {
        run("tell application \"Music\" to set sound volume to \(Int(value.rounded()))")
    }

    static func eqPresetNames() -> [String] {
        // Lists coerce to text with the active delimiter, so set one first.
        let joined = run(
            """
            set AppleScript's text item delimiters to "|"
            tell application "Music" to set presetNames to name of every EQ preset
            set joined to presetNames as string
            set AppleScript's text item delimiters to ""
            return joined
            """)
        guard let joined, !joined.isEmpty else { return [] }
        return joined.split(separator: "|").map(String.init)
    }

    static func currentEQ() -> String {
        run("tell application \"Music\" to return name of current EQ preset") ?? ""
    }

    static func setEQ(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        run(
            """
            tell application "Music"
                set EQ enabled to true
                set current EQ preset to EQ preset "\(escaped)"
            end tell
            """)
    }
}

private struct MusicTransportBar: View {
    @State private var nowPlaying = "Apple Music"
    @State private var playing = false
    @State private var volume: Double = 70
    @State private var eqPresets: [String] = []
    @State private var currentEQ = ""
    @State private var connected = false

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "music.note")
                .foregroundStyle(Theme.ember)

            if connected {
                Button { AppleMusicRemote.previous(); refresh() } label: {
                    Image(systemName: "backward.fill")
                }
                Button { AppleMusicRemote.playPause(); refresh() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                Button { AppleMusicRemote.next(); refresh() } label: {
                    Image(systemName: "forward.fill")
                }

                Text(nowPlaying)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)

                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { AppleMusicRemote.setVolume(volume) }
                }
                .frame(width: 120)
                .help("Music volume")

                if !eqPresets.isEmpty {
                    Picker("EQ", selection: $currentEQ) {
                        ForEach(eqPresets, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 170)
                    .onChange(of: currentEQ) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        AppleMusicRemote.setEQ(newValue)
                    }
                    .help("Less this, more that: the player's EQ presets")
                }
            } else {
                Button {
                    connect()
                } label: {
                    Label("Play Apple Music", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
                if connectError.isEmpty {
                    Text("Pipes Music.app playback control into this tab.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(connectError)
                        .font(.caption2)
                        .foregroundStyle(Theme.emberGlow)
                        .lineLimit(2)
                    Button("Open Automation Settings") {
                        if let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2)
        .onReceive(refreshTimer) { _ in
            if connected { refresh() }
        }
    }

    @State private var connectError = ""

    private func connect() {
        // A real query, so the first press both triggers the macOS Automation
        // prompt and proves the pipe works before the transport appears.
        let state = AppleMusicRemote.run(
            "tell application \"Music\" to return player state as string")
        guard state != nil else {
            if AppleMusicRemote.permissionDenied {
                connectError =
                    "macOS blocked Forge from controlling Music. Allow Forge under "
                    + "Privacy & Security, Automation, then press the button again."
            } else {
                connectError = AppleMusicRemote.lastError.map {
                    "Music scripting failed (\($0.code)); \($0.message)"
                } ?? "Music scripting failed."
            }
            connected = false
            return
        }
        connectError = ""
        connected = true
        volume = AppleMusicRemote.volume()
        eqPresets = AppleMusicRemote.eqPresetNames()
        currentEQ = AppleMusicRemote.currentEQ()
        refresh()
    }

    private func refresh() {
        nowPlaying = AppleMusicRemote.nowPlaying()
        playing = AppleMusicRemote.isPlaying()
    }
}
