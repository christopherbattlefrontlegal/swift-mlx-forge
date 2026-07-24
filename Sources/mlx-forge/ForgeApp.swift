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
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDisappear { appState.saveNow() }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            WindowPlacement(
                .center,
                size: context.defaultDisplay.visibleRect.size)
        }
        .windowIdealPlacement { _, context in
            WindowPlacement(
                .center,
                size: context.defaultDisplay.visibleRect.size)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appState.newConversation()
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Model") {
                Button("Browse Models…") {
                    appState.showModelBrowser = true
                }
                .keyboardShortcut("m")
                Button("Headless Helper…") {
                    appState.showHeadlessHelper = true
                }
                .keyboardShortcut("h")
                Divider()
                Button(appState.showAgentGraph ? "Show Chat" : "Show Agent Graph") {
                    appState.showAgentGraph.toggle()
                }
                .keyboardShortcut("g")
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        dockFlame.stop()
        AppState.shared.saveGraphsNow()
        Task { @MainActor in
            await AppState.shared.shutdownForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var initializedPanelVisibility = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 260,
                    max: 340)
        } detail: {
            // Two workbenches share the detail column: the chat surface and the
            // agent graph. The tuning inspector belongs to chat only — the graph
            // has its own per-block inspector.
            if app.showAgentGraph {
                AgentGraphView()
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                UnloadModelsToolbarButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Workbench", selection: $app.showAgentGraph) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(false)
                    Label("Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Switch between the chat surface and the agent graph")

                if case .running = app.server.state {
                    Label("API", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.okGreen)
                        .help("API server running — \(app.server.baseURL ?? "")")
                }
                MemoryBadge()
                Button {
                    toggleInspectorPanel()
                } label: {
                    Label("Tuning", systemImage: "slider.horizontal.3")
                }
                .disabled(app.showAgentGraph)
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
