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
        var roots: [URL] = []
        var cursor = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            roots.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else { break }
            cursor = parent
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        for root in roots {
            let dist = root.appendingPathComponent("BundledTools/ai-design-prompt/dist", isDirectory: true)
            if FileManager.default.fileExists(atPath: dist.appendingPathComponent("index.html").path) {
                return dist
            }
        }
        return nil
    }
}

/// Serves the bundled dist directory over a private scheme. file:// loading is a
/// dead end for this site: loadFileURL trips CORS on the `crossorigin` module
/// script, and loadHTMLString never grants the web process read access to the
/// ./assets subresources — both end in a silent blank white page.
private final class DesignSiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "forge-design"
    private let root: URL

    init(root: URL) { self.root = root }

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
        "css": "text/css", "svg": "image/svg+xml", "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
        "map": "application/json", "txt": "text/plain",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var relative = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        relative.removeFirst()  // leading "/"
        let file = root.appendingPathComponent(relative)
        guard file.path.hasPrefix(root.path),  // no traversal
            let data = try? Data(contentsOf: file)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
            ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct DesignPromptView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var webView = DesignPromptView.makeWebView()
    @State private var loadError: String?
    @State private var isLoading = true

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let root = DesignPromptLocator.siteRoot() {
            configuration.setURLSchemeHandler(
                DesignSiteSchemeHandler(root: root),
                forURLScheme: DesignSiteSchemeHandler.scheme)
        }
        return WKWebView(frame: .zero, configuration: configuration)
    }

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
        guard DesignPromptLocator.siteRoot() != nil else {
            loadError =
                "Build the web app first:\nBundledTools/ai-design-prompt → npm install && npm run build"
            isLoading = false
            return
        }
        webView.load(
            URLRequest(url: URL(string: "\(DesignSiteSchemeHandler.scheme)://site/index.html")!))
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
