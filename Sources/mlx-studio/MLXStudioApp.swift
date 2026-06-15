// MLX Studio
// LM-Studio-like native macOS UI for the forge_swift_open_source package (Path A: wrap the CLI binary).
// - Pick any local absolute MLX model dir (the exact same paths that worked in CLI).
// - "Load" spawns `mlx-runtime serve --model /abs/path ...` (the binary you already use).
// - Model loads **once** in the child process and stays resident -> fast, consistent responses.
// - All generation controls (temp, topP, maxTokens, system) are live-synced to the running serve
//   via the JSON-lines protocol (reuses the same GenerateArguments semantics).
// - Chat with streaming, stop, new chat. No Python, no server, direct disk MLX.
//
// Recommended (path-agnostic):
//   cd /path/to/your/forge_swift_open_source
//   swift build -c release
//   ./scripts/build-metallib.sh release   # once, or after `swift package clean`
//   # Then open directly (no terminal window needed after this):
//   open MLX\ Studio.app     # (or the one in .build if you prefer raw exe)
//
// Window + layout now follow the loaded SwiftUI design skill (8pt Spacing/Radius tokens,
// reusable GlassCard, clipShape(.rect), max 4 font levels via system + .caption/.callout,
// Reduce Motion, task() where appropriate, no random numbers, icon labels, content-driven
// log height to extend the left pane, sidebar resizable, NSWindow minSize). See brand-spec.md
// for the protected cinematic glass brand asset (do not override palette).
//
// The built "MLX Studio.app" (checked into this tree) is self-contained
// (mlx-studio + mlx-runtime + mlx.metallib all inside Contents/MacOS/).
// Copy it anywhere (e.g. ~/Applications or /Applications) for permanent
// direct double-click / Spotlight launch, completely independent of
// external drives or keeping any terminal open. The auto-detect uses
// Bundle.main + siblings so it works after the move.
//
// From a harness tree (dev only):
//   cd /path/to/SWIFT_RUNTIME
//   swift build -c release --package-path forge_swift_open_source
//   open forge_swift_open_source/MLX\ Studio.app
//
// The Auto-detect for the runtime binary (and the "Auto" button) is deliberately
// location-agnostic: it prefers the sibling next to the running studio executable,
// plus relative walks up the tree. You can keep this project at any path.
// (No hard-coded volume-specific paths in the source.)
//
// Requires the runtime binary + metallib (the script handles the latter for pure swift build).

import AppKit
import Foundation
import SwiftUI

// MARK: - App bootstrap (works for swift build executable on macOS)

@main
struct MLXStudioMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MLXStudioAppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

final class MLXStudioAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "MLX Studio"
        window.minSize = NSSize(width: 920, height: 640)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Protocol (must match the one in LLMTool.swift ServeCommand)

struct StudioCommand: Codable, Sendable {
    let cmd: String
    let prompt: String?
    let key: String?
    let value: String?
}

struct StudioEvent: Codable, Sendable {
    let event: String
    let text: String?
    let model: String?
    let promptTime: Double?
    let tokensPerSecond: Double?
    let message: String?

    init(event: String, text: String? = nil, model: String? = nil, promptTime: Double? = nil, tokensPerSecond: Double? = nil, message: String? = nil) {
        self.event = event
        self.text = text
        self.model = model
        self.promptTime = promptTime
        self.tokensPerSecond = tokensPerSecond
        self.message = message
    }
}

// Lightweight model descriptor for the dropdown (scanned from centralized root)
struct DiscoveredModel: Identifiable, Hashable {
    let id = UUID()
    let name: String   // subfolder name, shown in UI
    let path: String   // full absolute path to the model dir (passed as --model)
}

// MARK: - Cinematic Glass Theme (dark sci-fi workstation)
let bgDeep      = Color(red: 0.025, green: 0.030, blue: 0.045)
let panelGlass  = Color.white.opacity(0.055)
let cyanCore    = Color(red: 0.00, green: 0.82, blue: 1.00)
let violetGlow  = Color(red: 0.55, green: 0.25, blue: 1.00)
let blueAction  = Color(red: 0.10, green: 0.42, blue: 1.00)
let textPrimary = Color.white.opacity(0.92)
let textMuted   = Color.white.opacity(0.55)
let borderSoft  = Color.white.opacity(0.10)
let errorAccent = violetGlow  // no bright red in the palette

// MARK: - Design Tokens (8pt grid + brand radii per loaded swiftui-design-skill layout-patterns + anti-ai-slop "No Random Spacing")
// All spacing/padding/radii now expressed as tokens so the UI follows the 8pt system and is not arbitrary.
// The cinematic glass palette (bgDeep, panelGlass, cyanCore, violetGlow, blueAction) is the protected brand asset for MLX Studio.
// See brand-spec.md for the full spec.

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    static let s: CGFloat = 6   // tight controls / fields (intentional for dense cinematic workstation)
    static let m: CGFloat = 10  // cards / main surfaces
}

enum Layout {
    static let sidebarMin: CGFloat = 300
    static let sidebarMax: CGFloat = 380
    static let logMinHeight: CGFloat = 140
}

// MARK: - Main UI (recreates the LM Studio control + chat feel)

struct ContentView: View {
    @State private var modelPath: String = ""
    @State private var binaryPath: String = ""
    @State private var process: Process?
    @State private var toChild: Pipe?
    @State private var fromChild: Pipe?

    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var isLoaded = false
    @State private var status = "Select a local MLX model directory and Load"
    @State private var lastError: String?

    // Generation controls - bound live to the serve process after load
    @State private var systemPrompt: String = "You are a helpful assistant."
    @State private var temperature: Double = 0.6
    @State private var topP: Double = 1.0
    @State private var maxTokens: Double = 512
    @State private var presencePenalty: Double = 0.0
    @State private var frequencyPenalty: Double = 0.0
    @State private var stats: String = ""

    @State private var isGenerating = false

    // Centralized models root + discovered list for dropdown selection (per feature spec)
    @State private var modelsRoot: String = ""
    @State private var discoveredModels: [DiscoveredModel] = []
    @State private var selectedModelPath: String = ""
    @State private var parametersExpanded: Bool = true
    @State private var showAdvanced = false
    @State private var animPhase: Double = 0
    @State private var logLines: [String] = []

    private func autoDetectBinary() {
        let fm = FileManager.default

        // 1. Prefer sibling next to the running studio executable.
        // This works for:
        // - Raw `swift build` exes in .build/release/ (studio + runtime are siblings)
        // - Bundled .app when we co-locate mlx-runtime + mlx.metallib in Contents/MacOS/
        // No hard-coded volume paths. Survives moving the app or .app bundle anywhere.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            let sibling = dir.appendingPathComponent("mlx-runtime")
            if fm.isExecutableFile(atPath: sibling.path) {
                binaryPath = sibling.path
                return
            }
        }

        // 2. Fallback using CommandLine.arguments[0] (useful for some launch contexts)
        if let firstArg = CommandLine.arguments.first, !firstArg.isEmpty {
            let argURL = URL(fileURLWithPath: firstArg).resolvingSymlinksInPath()
            let dir = argURL.deletingLastPathComponent()
            let sibling = dir.appendingPathComponent("mlx-runtime")
            if fm.isExecutableFile(atPath: sibling.path) {
                binaryPath = sibling.path
                return
            }
        }

        // 3. Dev-time relative fallbacks (no absolute TB4 or volume-specific paths)
        let candidates = [
            ".build/release/mlx-runtime",
            ".build/arm64-apple-macosx/release/mlx-runtime",
            "forge_swift_open_source/.build/release/mlx-runtime",
            "../.build/release/mlx-runtime",
            "../../.build/release/mlx-runtime"
        ]
        for c in candidates {
            let standardized = (c as NSString).standardizingPath
            if fm.isExecutableFile(atPath: standardized) {
                binaryPath = standardized
                return
            }
        }
    }

    private func pickModelDirectory() {
        let p = NSOpenPanel()
        p.title = "Choose local MLX model directory"
        p.message = "Select the folder containing config.json + model.safetensors (flat or HF cache layout)"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.prompt = "Use This Folder"
        if p.runModal() == .OK, let url = p.url {
            modelPath = url.path
        }
    }

    private func pickBinary() {
        let p = NSOpenPanel()
        p.title = "Locate mlx-runtime binary"
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowedContentTypes = [] // any executable
        p.prompt = "Use This Binary"
        if p.runModal() == .OK, let url = p.url {
            binaryPath = url.path
        }
    }

    // New per spec: pick a *root* containing many model subfolders, then scan for usable ones.
    private func pickModelsRoot() {
        let p = NSOpenPanel()
        p.title = "Choose centralized models root directory"
        p.message = "Select the folder that contains subfolders, each holding one MLX model (config.json + *.safetensors)"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.prompt = "Use This Folder"
        if p.runModal() == .OK, let url = p.url {
            modelsRoot = url.path
            UserDefaults.standard.set(modelsRoot, forKey: "mlxStudio.modelsRoot")
            scanModels()
        }
    }

    private func scanModels() {
        discoveredModels.removeAll()
        selectedModelPath = ""
        guard !modelsRoot.isEmpty else { return }
        let rootURL = URL(fileURLWithPath: modelsRoot)
        guard let items = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let configURL = item.appendingPathComponent("config.json")
                if FileManager.default.fileExists(atPath: configURL.path) {
                    // Simple heuristic for a real MLX model dir: has config + at least one .safetensors
                    let hasSafetensors = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))?
                        .contains { $0.pathExtension.lowercased() == "safetensors" } ?? false
                    if hasSafetensors {
                        let name = item.lastPathComponent
                        discoveredModels.append(DiscoveredModel(name: name, path: item.path))
                    }
                }
            }
        }
        discoveredModels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // If we had a previous selection under this root, try to restore it
        if let previous = UserDefaults.standard.string(forKey: "mlxStudio.lastSelectedModel"), discoveredModels.contains(where: { $0.path == previous }) {
            selectedModelPath = previous
            modelPath = previous
        }
    }

    private func loadModel() {
        lastError = nil

        // Prefer the dropdown selection (centralized root) if present; fall back to modelPath for compatibility
        let effectiveModel = !selectedModelPath.isEmpty ? selectedModelPath : modelPath
        if !effectiveModel.isEmpty {
            modelPath = effectiveModel
            selectedModelPath = effectiveModel
        }

        guard !modelPath.isEmpty else {
            lastError = "Select a model from the dropdown (or set Models Root) first"
            appendToLog("✕ No model selected")
            return
        }
        guard !binaryPath.isEmpty else {
            lastError = "Locate the mlx-runtime binary (swift build -c release first)"
            appendToLog("✕ No runtime binary")
            return
        }

        // Persist last chosen for convenience across restarts
        if !modelPath.isEmpty {
            UserDefaults.standard.set(modelPath, forKey: "mlxStudio.lastSelectedModel")
        }

        logLines.removeAll()
        appendToLog("→ Load Selected: \(URL(fileURLWithPath: modelPath).lastPathComponent)")

        unloadModel(quiet: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        var cliArgs: [String] = [
            "serve",
            "--model", modelPath,
            "--temperature", String(temperature),
            "--top-p", String(topP),
            "--max-tokens", String(Int(maxTokens)),
            "--presence-penalty", String(presencePenalty),
            "--frequency-penalty", String(frequencyPenalty)
        ]
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            cliArgs += ["--system", trimmedSystem]
        }
        proc.arguments = cliArgs

        // Run from the binary's directory (helps metallib lookup for non-Xcode builds)
        let binDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: binDir.path) {
            proc.currentDirectoryURL = binDir
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            lastError = "Failed to launch runtime: \(error.localizedDescription)"
            appendToLog("✕ Failed to launch: \(error.localizedDescription)")
            return
        }

        process = proc
        toChild = stdinPipe
        fromChild = stdoutPipe

        appendToLog("Runtime process spawned")

        // Capture stderr (many load-time failures, Metal errors, OOM messages, Swift traces
        // go here rather than stdout). Surface them in the Activity Log so the user can
        // see *exactly* what went wrong if the load breaks or stops.
        Task.detached {
            let h = stderrPipe.fileHandleForReading
            var buf = Data()
            do {
                for try await byte in h.bytes {
                    buf.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        if let line = String(data: buf, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                            Task { @MainActor in
                                self.appendToLog("! \(line)")  // "!" prefix = stderr / diagnostic
                            }
                        }
                        buf.removeAll(keepingCapacity: true)
                    }
                }
            } catch { /* ignore */ }
        }

        isLoaded = false
        status = "Loading model (first time reads weights from disk)..."
        appendToLog("Waiting for model load (first read from disk)...")
        messages.removeAll()
        stats = ""
        isGenerating = false

        // Observe child death. If this happens before "ready", it's a load failure.
        // We log a clear message, capture the exit code, stop the loading indicator
        // (by nil'ing process), and let lastError show in the UI.
        proc.terminationHandler = { p in
            let code = p.terminationStatus
            Task { @MainActor in
                if !isLoaded {
                    appendToLog("✕ Runtime process exited (code \(code)) before ready")
                    lastError = "Load failed (process exit code \(code) — see Activity Log)"
                    status = "Load failed"
                }
                process = nil
                isLoaded = false
            }
        }

        // Start the NDJSON event reader
        Task { @MainActor in
            await self.readProtocol(from: stdoutPipe)
        }

        // Send initial system (already passed on CLI, but ensure)
        // The serve starts with the flags we gave.
    }

    private func unloadModel(quiet: Bool = false) {
        if let p = process, p.isRunning {
            // Ask politely
            sendCommand(StudioCommand(cmd: "quit", prompt: nil, key: nil, value: nil))
            // Modern concurrency per swiftui-agent-skill (no GCD)
            Task.detached {
                try? await Task.sleep(for: .milliseconds(400))
                if p.isRunning { p.terminate() }
            }
        }
        process = nil
        toChild = nil
        fromChild = nil
        isLoaded = false
        isGenerating = false
        if !quiet {
            status = "Unloaded"
        }
        appendToLog("Unloaded")
    }

    private func appendToLog(_ text: String) {
        // Called only from main-thread contexts (button actions, @MainActor Task for protocol reader,
        // and handleProtocolLine which runs under the main-actor task). Direct @State mutation is safe here.
        logLines.append(text)
        if logLines.count > 25 {
            logLines.removeFirst(logLines.count - 25)
        }
    }

    private func sendCommand(_ cmd: StudioCommand) {
        guard let pipe = toChild, let p = process, p.isRunning else { return }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(cmd), let line = String(data: data, encoding: .utf8) else { return }
        let payload = (line + "\n").data(using: .utf8)!
        pipe.fileHandleForWriting.write(payload)
    }

    private func applyControl(key: String, stringValue: String) {
        guard isLoaded else { return }
        sendCommand(StudioCommand(cmd: "set", prompt: nil, key: key, value: stringValue))
    }

    private func sendCurrentPrompt() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isLoaded, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, content: text))
        messages.append(ChatMessage(role: .assistant, content: "", isStreaming: true))

        input = ""
        isGenerating = true
        stats = ""

        sendCommand(StudioCommand(cmd: "prompt", prompt: text, key: nil, value: nil))
    }

    private func stopCurrent() {
        sendCommand(StudioCommand(cmd: "stop", prompt: nil, key: nil, value: nil))
        isGenerating = false
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].isStreaming = false
        }
    }

    private func newChat() {
        sendCommand(StudioCommand(cmd: "reset", prompt: nil, key: nil, value: nil))
        messages.removeAll()
        stats = ""
    }

    // Async line reader for the protocol events coming from the serve binary
    private func readProtocol(from pipe: Pipe) async {
        let fh = pipe.fileHandleForReading
        var buf = Data()
        do {
            for try await byte in fh.bytes {
                buf.append(byte)
                if byte == UInt8(ascii: "\n") {
                    if let line = String(data: buf, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        if !line.hasPrefix("{") {
                            // Surface plain-text progress from the runtime (e.g. "Loading /path...", "Loaded ...")
                            // These were previously dropped silently. This gives the visible log during load.
                            Task { @MainActor in self.appendToLog(line) }
                        }
                        handleProtocolLine(line)
                    }
                    buf.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            // Pipe closed or read error.
            // If we never saw "ready", this is a load break (crash, bad weights, OOM, etc.).
            // Make it visible in the log + stop the pulsing "Loading..." indicator.
            Task { @MainActor in
                if !self.isLoaded {
                    if self.process != nil {
                        self.appendToLog("✕ Runtime connection lost during load (no more output)")
                        if self.lastError == nil {
                            self.lastError = "Load stopped — see Activity Log for details (stdout/stderr lines above)"
                        }
                        self.status = "Load failed"
                        self.process = nil
                    }
                }
                self.isLoaded = false
            }
        }
    }

    private func handleProtocolLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONDecoder().decode(StudioEvent.self, from: data) else {
            return
        }

        switch ev.event {
        case "ready":
            isLoaded = true
            status = "Loaded • \(ev.model ?? modelPath) • stays resident (fast)"
            lastError = nil
            appendToLog("✓ Ready • model resident (fast)")

        case "token":
            if let idx = messages.indices.last,
               messages[idx].role == .assistant,
               messages[idx].isStreaming {
                messages[idx].content += ev.text ?? ""
            } else {
                messages.append(ChatMessage(role: .assistant, content: ev.text ?? "", isStreaming: true))
            }

        case "info":
            if let idx = messages.indices.last, messages[idx].role == .assistant {
                messages[idx].isStreaming = false
            }
            isGenerating = false
            if let tps = ev.tokensPerSecond {
                stats = String(format: "%.1f tokens/s  •  prompt %.2fs", tps, ev.promptTime ?? 0)
            }

        case "stopped":
            if let idx = messages.indices.last, messages[idx].role == .assistant {
                messages[idx].isStreaming = false
            }
            isGenerating = false

        case "error":
            lastError = ev.message ?? "unknown error"
            isGenerating = false
            if !isLoaded {
                status = "Load failed"
            }
            if let idx = messages.indices.last, messages[idx].role == .assistant, messages[idx].isStreaming {
                messages[idx].isStreaming = false
            }
            appendToLog("✕ \(ev.message ?? "unknown error")")

        case "bye":
            appendToLog("Runtime quit (bye)")
            unloadModel(quiet: true)

        default:
            break
        }
    }

    var body: some View {
        ZStack {
            // Deep navy cinematic background + subtle animated mesh/lava/shimmer energy
            bgDeep.ignoresSafeArea()
            ShimmerMeshView(phase: animPhase)

            HSplitView {
                // LEFT SIDEBAR CONTROLS (LM Studio layout preserved)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    // Title
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("MLX Studio")
                            .font(.title3.bold())
                            .foregroundStyle(textPrimary)
                        Text("Native • Direct disk • Persistent")
                            .font(.caption)
                            .foregroundStyle(textMuted)
                    }

                    // Model selection + load status in PanelGlassContainer-style rounded glass card
                    GlassCard {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("Models Root Directory")
                                .font(.caption.bold())
                                .foregroundStyle(textMuted)

                            HStack(spacing: Spacing.xs) {
                                TextField("/path/to/all-my-mlx-models", text: $modelsRoot)
                                    .textFieldStyle(.plain)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(textPrimary)
                                    .padding(Spacing.xs)
                                    .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Color.black.opacity(0.2)))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(borderSoft, lineWidth: 0.5))
                                Button("Choose…") { pickModelsRoot() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(blueAction)
                                    .font(.caption)
                                Button("Scan") { scanModels() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(blueAction)
                                    .font(.caption)
                                    .disabled(modelsRoot.isEmpty)
                            }

                            if !discoveredModels.isEmpty {
                                Picker("Select model", selection: $selectedModelPath) {
                                    ForEach(discoveredModels) { m in
                                        Text(m.name).tag(m.path)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.caption)
                                .foregroundStyle(textPrimary)
                            } else if !modelsRoot.isEmpty {
                                Text("No models detected. Subfolders must contain config.json + safetensors.")
                                    .font(.caption)
                                    .foregroundStyle(textMuted)
                            } else {
                                Text("Choose a root folder containing model subfolders.")
                                    .font(.caption)
                                    .foregroundStyle(textMuted)
                            }

                            HStack(spacing: Spacing.s) {
                                // Electric blue primary action
                                Button(action: { loadModel() }) {
                                    Text(isLoaded ? "Reload Selected" : "Load Selected")
                                        .font(.caption.bold())
                                        .foregroundStyle(textPrimary)
                                        .padding(.horizontal, Spacing.m)
                                        .padding(.vertical, Spacing.xs)
                                        .background(Capsule().fill(blueAction))
                                }
                                .buttonStyle(.plain)
                                .disabled((selectedModelPath.isEmpty && modelPath.isEmpty) || binaryPath.isEmpty)

                                Button("Unload") { unloadModel() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(textMuted)
                                    .disabled(!isLoaded)
                            }

                            // Status + ReactorCoreIndicator-style cyan/violet active status
                            HStack(spacing: Spacing.xs) {
                                let isLoading = (process != nil && !isLoaded)
                                if isLoading || isLoaded {
                                    ReactorCoreIndicator(isActive: true)
                                }
                                let display: String = {
                                    if isLoading {
                                        let n = max(1, (Int(animPhase * 4) % 4))
                                        return "Loading model" + String(repeating: ".", count: n) + " (reading weights)"
                                    } else {
                                        return status
                                    }
                                }()
                                Text(display)
                                    .font(.caption)
                                    .foregroundStyle(isLoading ? cyanCore : (isLoaded ? cyanCore : textMuted))
                                    .lineLimit(2)
                            }

                            if let err = lastError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(errorAccent)
                                    .lineLimit(3)
                            }

                            // Short activity log inside the Models Root Directory glass card.
                            // Extends the card (and left sidebar) downward using available room.
                            // Surfaces the runtime's own "Loading ..." / "Loaded ..." lines (previously silent)
                            // plus key events so user sees exactly what's happening on Load Selected.
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack(spacing: Spacing.xs) {
                                    Text("Activity Log")
                                        .font(.caption.bold())
                                        .foregroundStyle(textMuted)
                                    Spacer()
                                    if !logLines.isEmpty {
                                        Button("Clear") { logLines.removeAll() }
                                            .font(.caption)
                                            .foregroundStyle(blueAction)
                                    }
                                }
                                ScrollViewReader { proxy in
                                    ScrollView(.vertical, showsIndicators: true) {
                                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                                            if logLines.isEmpty {
                                                Text("Load Selected to see live progress (Loading ... / Loaded ... from runtime)")
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(textMuted.opacity(0.6))
                                                    .italic()
                                            }
                                            ForEach(logLines.indices.suffix(15), id: \.self) { i in
                                                Text(logLines[i])
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(textMuted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .id(i)
                                            }
                                        }
                                    }
                                    .frame(minHeight: Layout.logMinHeight, maxHeight: .infinity)
                                    .padding(.vertical, Spacing.xs)
                                    .padding(.horizontal, Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                            .fill(Color.black.opacity(0.22))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                            .stroke(borderSoft, lineWidth: 0.5)
                                    )
                                    .onChange(of: logLines.count) { _, _ in
                                        if let last = logLines.indices.last {
                                            withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                                        }
                                    }
                                }
                            }
                            .padding(.top, Spacing.xs)
                        }
                    }

                    // Runtime hidden per request: "Runtime: Auto-detected" + small gear button (cyan) for Advanced
                    HStack(spacing: Spacing.xs) {
                        Text("Runtime: Auto-detected")
                            .font(.caption)
                            .foregroundStyle(textMuted)
                        Spacer()
                        Button {
                            showAdvanced = true
                        } label: {
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: "gearshape")
                                    .font(.caption)
                                Text("Advanced")
                                    .font(.caption)
                            }
                            .foregroundStyle(cyanCore)
                        }
                        .buttonStyle(.plain)
                        .help("Advanced")
                    }
                    .padding(.horizontal, Spacing.xs)

                    // Generation Parameters (fixed layout: label left, editable value pill right, slider below, clear spacing)
                    DisclosureGroup(isExpanded: $parametersExpanded) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Spacing.m) {
                                // System prompt
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text("System prompt")
                                        .font(.caption)
                                        .foregroundStyle(textMuted)
                                    TextEditor(text: $systemPrompt)
                                        .font(.callout)
                                        .foregroundStyle(textPrimary)
                                        .frame(minHeight: 56, maxHeight: 80)
                                        .scrollContentBackground(.hidden)
                                        .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Color.black.opacity(0.25)))
                                        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(borderSoft, lineWidth: 0.5))
                                    Button("Apply System + New Chat") {
                                        applyControl(key: "system", stringValue: systemPrompt)
                                        newChat()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(blueAction)
                                    .disabled(!isLoaded)
                                }

                                // Each setting: label left + pill right, slider directly below, clear inter-row spacing
                                ParamSliderRow(
                                    label: "Temperature",
                                    value: $temperature,
                                    range: 0...2,
                                    step: 0.05,
                                    format: "%.2f",
                                    onCommit: { applyControl(key: "temperature", stringValue: String(temperature)) }
                                )
                                ParamSliderRow(
                                    label: "Top P",
                                    value: $topP,
                                    range: 0...1,
                                    step: 0.05,
                                    format: "%.2f",
                                    onCommit: { applyControl(key: "topP", stringValue: String(topP)) }
                                )
                                ParamSliderRow(
                                    label: "Max tokens",
                                    value: $maxTokens,
                                    range: 32...4096,
                                    step: 32,
                                    format: "%.0f",
                                    onCommit: { applyControl(key: "maxTokens", stringValue: String(Int(maxTokens))) }
                                )
                                ParamSliderRow(
                                    label: "Presence Penalty",
                                    value: $presencePenalty,
                                    range: 0...2,
                                    step: 0.05,
                                    format: "%.2f",
                                    onCommit: { applyControl(key: "presencePenalty", stringValue: String(presencePenalty)) }
                                )
                                ParamSliderRow(
                                    label: "Frequency Penalty",
                                    value: $frequencyPenalty,
                                    range: 0...2,
                                    step: 0.05,
                                    format: "%.2f",
                                    onCommit: { applyControl(key: "frequencyPenalty", stringValue: String(frequencyPenalty)) }
                                )
                            }
                        }
                    } label: {
                        Text("Generation Parameters")
                            .font(.caption.bold())
                            .foregroundStyle(textMuted)
                    }

                    Spacer(minLength: 4)

                    if !stats.isEmpty {
                        Text(stats)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(textMuted)
                    }

                    Button("New Chat") { newChat() }
                        .buttonStyle(.plain)
                        .foregroundStyle(textMuted)
                        .font(.caption)
                        .disabled(!isLoaded)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(Spacing.m)
                .frame(minWidth: Layout.sidebarMin, maxWidth: Layout.sidebarMax, alignment: .topLeading)
                .background(Color.clear)

                // RIGHT CHAT WORKSPACE + bottom input bar (layout preserved)
                VStack(spacing: 0) {
                    ScrollViewReader { scroller in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Spacing.s) {
                                ForEach(messages) { msg in
                                    MessageRow(message: msg)
                                        .id(msg.id)
                                }
                                if messages.isEmpty && isLoaded {
                                    Text("Model is loaded and resident. Send a message to start.")
                                        .font(.callout)
                                        .foregroundStyle(textMuted)
                                        .padding(.top, Spacing.xl)
                                }
                            }
                            .padding(Spacing.m)
                        }
                        .background(panelGlass.opacity(0.12))
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                withAnimation { scroller.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }

                    // Glass input bar
                    HStack {
                        TextField("Type a message… (Enter to send)", text: $input)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(textPrimary)
                            .padding(Spacing.s)
                            .background(Capsule().fill(Color.black.opacity(0.25)))
                            .overlay(Capsule().stroke(borderSoft, lineWidth: 0.5))
                            .onSubmit { sendCurrentPrompt() }
                            .disabled(!isLoaded || isGenerating)

                        // Electric blue (or violet for stop) primary action
                        Button(action: {
                            if isGenerating { stopCurrent() } else { sendCurrentPrompt() }
                        }) {
                            Text(isGenerating ? "Stop" : "Send")
                                .font(.caption.bold())
                                .foregroundStyle(textPrimary)
                                .padding(.horizontal, Spacing.m)
                                .padding(.vertical, Spacing.xs)
                                .background(Capsule().fill(isGenerating ? violetGlow : blueAction))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return)
                        .disabled(!isLoaded || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating))
                    }
                    .padding(Spacing.s)
                    .background(panelGlass)
                }
                .background(Color.clear)
            }
            .task {
                if binaryPath.isEmpty { autoDetectBinary() }
                // Restore centralized models root + scan (per spec)
                if modelsRoot.isEmpty, let saved = UserDefaults.standard.string(forKey: "mlxStudio.modelsRoot") {
                    modelsRoot = saved
                    scanModels()
                }
                // Also restore last selected model path if it matches a discovered one
                if selectedModelPath.isEmpty, let last = UserDefaults.standard.string(forKey: "mlxStudio.lastSelectedModel") {
                    if discoveredModels.contains(where: { $0.path == last }) || FileManager.default.fileExists(atPath: last) {
                        selectedModelPath = last
                        modelPath = last
                    }
                }
                // Kick off the subtle animated shimmer / energy feel
                withAnimation(.linear(duration: 18).repeatForever(autoreverses: true)) {
                    animPhase = 1.0
                }
            }

            // When user picks a different model in the dropdown, sync it so Load uses it
            .onChange(of: selectedModelPath) { _, newPath in
                if !newPath.isEmpty {
                    modelPath = newPath
                }
            }
            .sheet(isPresented: $showAdvanced) {
                // Advanced sheet contains the original runtime binary controls (hidden from main sidebar)
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Advanced Runtime")
                        .font(.headline)
                        .foregroundStyle(textPrimary)

                    Text("Runtime binary (mlx-runtime)")
                        .font(.caption.bold())
                        .foregroundStyle(textMuted)

                    HStack(spacing: Spacing.xs) {
                        TextField(".../mlx-runtime", text: $binaryPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(textPrimary)
                            .textFieldStyle(.plain)
                            .padding(Spacing.xs)
                            .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Color.black.opacity(0.2)))
                            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(borderSoft))
                        Button("Pick") { pickBinary() }
                            .foregroundStyle(blueAction)
                        Button("Auto") { autoDetectBinary() }
                            .foregroundStyle(blueAction)
                    }

                    Text("Build once with `swift build -c release --package-path forge_swift_open_source` (and run the metallib script if using direct exe).")
                        .font(.caption)
                        .foregroundStyle(textMuted)

                    Spacer()

                    Button("Close") { showAdvanced = false }
                        .foregroundStyle(textPrimary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(blueAction))
                        .buttonStyle(.plain)
                }
                .padding(Spacing.m)
                .frame(width: 480, height: 200)
                .background(bgDeep)
            }
            .frame(minWidth: 920, minHeight: 640)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
                Text(message.content)
                    .padding(Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .fill(panelGlass)
                            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(borderSoft, lineWidth: 0.5))
                    )
                    .clipShape(.rect(cornerRadius: Radius.m))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                        .padding(Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .fill(Color.white.opacity(0.035))
                                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(borderSoft, lineWidth: 0.5))
                        )
                        .clipShape(.rect(cornerRadius: Radius.m))
                        .foregroundStyle(textPrimary)
                        .textSelection(.enabled)
                    if message.isStreaming {
                        Text("streaming…")
                            .font(.caption)
                            .foregroundStyle(textMuted)
                    }
                }
                Spacer(minLength: 60)
            }
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var content: String
    var isStreaming: Bool = false

    enum Role { case user, assistant }
}

// MARK: - Cinematic glass + energy components (emulated from requested visual language)

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Spacing.m)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .fill(panelGlass)
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .stroke(borderSoft, lineWidth: 0.75)
                }
            )
            .clipShape(.rect(cornerRadius: Radius.m))
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }
}

struct ReactorCoreIndicator: View {
    let isActive: Bool
    @State private var scale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(cyanCore.opacity(0.18))
                .frame(width: 16, height: 16)
                .scaleEffect(reduceMotion ? 1.0 : scale)
                .opacity(reduceMotion ? 0.7 : 1.0)
            Circle()
                .fill(violetGlow.opacity(0.22))
                .frame(width: 8, height: 8)
            Circle()
                .fill(cyanCore)
                .frame(width: 4, height: 4)
        }
        .onAppear {
            guard isActive && !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                scale = 1.35
            }
        }
    }
}

struct ShimmerMeshView: View {
    let phase: Double

    var body: some View {
        ZStack {
            // Subtle animated mesh / lava / shimmer energy (cyan + violet only, very low opacity)
            ForEach(0..<4, id: \.self) { i in
                let c = (i % 2 == 0) ? cyanCore : violetGlow
                let w = 380.0 + Double(i) * 70
                let h = 260.0 + Double(i) * 50
                let ox = sin(phase * (0.6 + Double(i) * 0.15) + Double(i)) * (55 + Double(i) * 8)
                let oy = cos(phase * (0.45 + Double(i) * 0.1) + Double(i) * 1.7) * (35 + Double(i) * 5)
                Ellipse()
                    .fill(c.opacity(0.028 + Double(i) * 0.006))
                    .frame(width: w, height: h)
                    .offset(x: ox, y: oy - 20)
                    .blur(radius: 55 + CGFloat(i) * 8)
                    .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

// Fixed Generation Parameters row per spec: label left, editable value pill right, slider below each, clear spacing
struct ParamSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let onCommit: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(textMuted)
                Spacer()
                // Editable pill (capsule, monospace, soft glass border)
                TextField("", text: $text)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(Capsule().fill(Color.white.opacity(0.035)))
                    .overlay(Capsule().stroke(borderSoft, lineWidth: 0.5))
                    .foregroundStyle(textPrimary)
                    .onChange(of: value, initial: true) { _, newV in
                        text = String(format: format, newV)
                    }
                    .onSubmit {
                        if let d = Double(text) {
                            value = max(range.lowerBound, min(range.upperBound, d))
                        } else {
                            text = String(format: format, value)
                        }
                        onCommit()
                    }
            }
            Slider(value: $value, in: range, step: step)
                .tint(cyanCore)
                .onChange(of: value) { _, _ in
                    onCommit()
                }
        }
    }
}
