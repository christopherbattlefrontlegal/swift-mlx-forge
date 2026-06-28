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
                .frame(minWidth: 980, minHeight: 640)
                .onDisappear { appState.saveNow() }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window paints, replace the static .icns in the Dock.
        dockFlame.prime()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockFlame.start()
        AppState.shared.beginMCP()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stopGenerating()
        AppState.shared.engine.unloadAll()
        AppState.shared.saveNow()
        dockFlame.stop()
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    /// Inspector attaches one frame after the window appears so launch doesn't
    /// resize twice (window open → inspector column → window jump).
    @State private var inspectorAttached = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            ChatView()
        }
        .inspector(isPresented: inspectorPresented) {
            TuningInspector()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .background(Theme.backgroundGradient)
        .onAppear {
            DispatchQueue.main.async {
                inspectorAttached = true
            }
        }
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ModelPickerControl()
            }
            ToolbarItem(placement: .navigation) {
                UnloadModelsToolbarButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if case .running = app.server.state {
                    Label("API", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.okGreen)
                        .help("API server running — \(app.server.baseURL ?? "")")
                }
                MemoryBadge()
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        app.showInspector.toggle()
                    }
                } label: {
                    Label("Tuning", systemImage: "slider.horizontal.3")
                }
                .help("Show generation parameters")
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)
        ) { _ in
            app.stopGenerating()
            app.engine.unloadAll()
            app.saveNow()
        }
        .onDisappear {
            app.stopGenerating()
            app.engine.unloadAll()
            app.saveNow()
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { inspectorAttached && app.showInspector },
            set: { newValue in
                inspectorAttached = true
                app.showInspector = newValue
            }
        )
    }
}
