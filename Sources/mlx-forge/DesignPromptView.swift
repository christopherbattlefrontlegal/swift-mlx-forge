// Forge — embedded WebKit surface for the bundled AI design prompt generator.

import AppKit
import SwiftUI
import WebKit

enum DesignPromptLocator {
    /// Ordered fallbacks: app bundle → repo dist → Downloads copy.
    static func siteRoot() -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("DesignPrompt", isDirectory: true),
            repoDistRoot(),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Downloads/ai-design-prompt-main/dist", isDirectory: true),
        ].compactMap { $0 }

        for root in candidates where fm.fileExists(atPath: root.appendingPathComponent("index.html").path) {
            return root
        }
        return nil
    }

    private static func repoDistRoot() -> URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let roots = [
            exe.deletingLastPathComponent(),
            exe.deletingLastPathComponent().deletingLastPathComponent(),
            exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: "/Volumes/TB4_1TB/swift-mlx-forge"),
        ]
        for root in roots {
            let dist = root.appendingPathComponent("BundledTools/ai-design-prompt/dist", isDirectory: true)
            if FileManager.default.fileExists(atPath: dist.appendingPathComponent("index.html").path) {
                return dist
            }
        }
        return nil
    }
}

struct DesignPromptView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var webView = WKWebView()
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                DesignPromptWebView(webView: webView, onLoadFinished: {
                    isLoading = false
                }, onLoadFailed: { message in
                    isLoading = false
                    loadError = message
                })
                if isLoading {
                    ProgressView("Loading prompt generator…")
                        .controlSize(.large)
                }
                if let loadError {
                    ContentUnavailableView {
                        Label("Prompt Generator Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Open in Browser") { openInBrowser() }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .onAppear { loadSite() }
    }

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Label("Design Prompt Generator", systemImage: "paintpalette.fill")
                .font(.headline)
            Spacer()
            Button("Paste into Chat") { pasteGeneratedPromptIntoComposer() }
                .help("Copy the generated prompt from the page into the Forge composer")
            Button("Open in Browser") { openInBrowser() }
                .help("Open the same page in your default browser (Safari, Chrome, etc.)")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.s4)
    }

    private func loadSite() {
        guard let root = DesignPromptLocator.siteRoot() else {
            loadError =
                "Build the web app first:\nBundledTools/ai-design-prompt → npm install && npm run build"
            isLoading = false
            return
        }
        let index = root.appendingPathComponent("index.html")
        webView.loadFileURL(index, allowingReadAccessTo: root)
    }

    private func openInBrowser() {
        if let root = DesignPromptLocator.siteRoot() {
            NSWorkspace.shared.open(root.appendingPathComponent("index.html"))
        } else if let url = URL(string: "http://localhost:5173") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pasteGeneratedPromptIntoComposer() {
        webView.evaluateJavaScript(
            """
            (function() {
              const el = document.querySelector('.whitespace-pre-wrap');
              return el ? el.textContent.trim() : '';
            })();
            """
        ) { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            Task { @MainActor in
                app.composerText = text
                dismiss()
            }
        }
    }
}

private struct DesignPromptWebView: NSViewRepresentable {
    let webView: WKWebView
    let onLoadFinished: () -> Void
    let onLoadFailed: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFinished: onLoadFinished, onLoadFailed: onLoadFailed)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoadFinished: () -> Void
        let onLoadFailed: (String) -> Void

        init(onLoadFinished: @escaping () -> Void, onLoadFailed: @escaping (String) -> Void) {
            self.onLoadFinished = onLoadFinished
            self.onLoadFailed = onLoadFailed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadFinished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFailed(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadFailed(error.localizedDescription)
        }
    }
}