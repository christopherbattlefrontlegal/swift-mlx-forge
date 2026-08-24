// Forge — native, in-process MLX runtime for Apple Silicon.
// SwiftUI app entry point. Built as a plain SwiftPM executable; when launched
// from a terminal we promote ourselves to a regular app with a dock presence.

import AppKit
import SwiftUI

@main
struct ForgeApp: App {
    @State private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Load Keychain secrets once before AppState touches any has*Key checks.
        SecretsStore.warmCache()

        // Required when running as a bare SPM executable (no bundle): give the
        // process a real UI lifecycle so windows, menus, and focus work.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("Forge", id: "main") {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDisappear { appState.saveNow() }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appState.newConversation()
                }
                .keyboardShortcut("n")
                Divider()
                Button("Open Graph Project…") {
                    sendGraphCommand(.openProject)
                }
                .keyboardShortcut("o")
                Button("Import Graph…") {
                    sendGraphCommand(.importGraph)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Model") {
                Button("Browse Models…") {
                    appState.showModelBrowser = true
                }
                .keyboardShortcut("m")
                Button("Claude Code Builder…") {
                    appState.showHeadlessHelper = true
                }
                .keyboardShortcut("h")
                Divider()
                Button(appState.showRivet ? "Show Chat" : "Show Forge Graph") {
                    appState.showMediaStudio = false
                    appState.showRivet.toggle()
                }
                .keyboardShortcut("g")
                Button("Show Media Studio") {
                    appState.showRivet = false
                    appState.showMediaStudio = true
                }
                .keyboardShortcut("e")
                Button("Unload All Models") {
                    appState.stopGenerating()
                    appState.engine.unloadAll()
                    appState.scheduleSave()
                }
                .disabled(appState.engine.loadedModels.isEmpty && !appState.engine.isLoadingAnything)
            }
        }

        Settings {
            ForgeSettingsView()
                .environment(appState)
        }
    }

    private func sendGraphCommand(_ command: ForgeGraphCommand) {
        appState.showMediaStudio = false
        if appState.showRivet {
            NotificationCenter.default.post(name: .forgeGraphCommand, object: command)
        } else {
            appState.showRivet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .forgeGraphCommand, object: command)
            }
        }
    }
}

/// Owns the live Dock fire for the lifetime of the running app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockFlame = DockFlame()
    private var isShuttingDown = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window paints, replace the static .icns in the Dock.
        dockFlame.prime()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockFlame.start()
        AppState.shared.beginMCP()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        if let window = sender.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        dockFlame.stop()
        Task { @MainActor in
            await AppState.shared.shutdownForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum WorkbenchTab: Hashable {
    case chat, graph, media
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var initializedPanelVisibility = false

    /// Three panes over the two underlying flags; Media wins when both are set.
    private var workbenchSelection: Binding<WorkbenchTab> {
        Binding(
            get: {
                if app.showMediaStudio { return .media }
                return app.showRivet ? .graph : .chat
            },
            set: { tab in
                app.showMediaStudio = (tab == .media)
                app.showRivet = (tab == .graph)
            })
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 260,
                    max: 340)
        } detail: {
            // Chat, Rivet, and Media share the detail column and the same model library.
            if app.showMediaStudio {
                MediaView()
            } else if app.showRivet {
                RivetView()
            } else {
                ChatView()
                    .inspector(isPresented: $app.showInspector) {
                        TuningInspector()
                            .inspectorColumnWidth(
                                min: 300,
                                ideal: 340,
                                max: 420)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(nil, value: columnVisibility)
        .animation(nil, value: app.showInspector)
        .background(Theme.backgroundGradient)
        .sheet(isPresented: $app.showModelBrowser) {
            ModelBrowserView()
                .environment(app)
        }
        .sheet(isPresented: $app.showHeadlessHelper) {
            LauncherView()
                .environment(app)
        }
        .sheet(isPresented: $app.showDesignPrompt) {
            DesignPromptView()
                .environment(app)
        }
        .sheet(isPresented: $app.showSystemPromptEditor) {
            SystemPromptEditor()
                .environment(app)
        }
        .sheet(isPresented: $app.showTournament) {
            TournamentView()
                .environment(app)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                UnloadModelsToolbarButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Workbench", selection: workbenchSelection) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .tag(WorkbenchTab.chat)
                    Label("Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .tag(WorkbenchTab.graph)
                    Label("Media", systemImage: "photo.on.rectangle.angled")
                        .tag(WorkbenchTab.media)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 225)
                .help("Switch between Forge chat, Forge Graph, and the Media Studio")

                if case .running = app.server.state {
                    Label("API", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.okGreen)
                        .help("API server running — \(app.server.baseURL ?? "")")
                }
                MemoryBadge()
                Button {
                    app.showTournament = true
                } label: {
                    Label("Tournament", systemImage: "trophy")
                }
                .help("Configure and run a model tournament")
                Button {
                    toggleInspectorPanel()
                } label: {
                    Label("Tuning", systemImage: "slider.horizontal.3")
                }
                .disabled(app.showRivet || app.showMediaStudio)
                .help("Show or hide the tuning panel")
            }
        }
        .onDisappear {
            app.saveNow()
        }
        .onAppear {
            guard !initializedPanelVisibility else { return }
            initializedPanelVisibility = true
            columnVisibility = .all
            app.showInspector = true
        }
    }

    private func toggleInspectorPanel() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            app.showInspector.toggle()
        }
    }

}
