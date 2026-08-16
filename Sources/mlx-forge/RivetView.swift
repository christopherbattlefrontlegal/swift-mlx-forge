// Forge — embedded Ironclad Rivet graph IDE.
//
// Rivet remains a normal browser client. Forge serves its compiled frontend and
// OpenAI-compatible API from one loopback origin; only Forge loads model weights.

import AppKit
import SwiftUI
import WebKit

enum RivetLocator {
    /// Ordered fallbacks: packaged app resources, then a source-tree build.
    static func siteRoot() -> URL? {
        let fileManager = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Rivet", isDirectory: true),
            repositoryDistRoot(),
        ].compactMap { $0 }

        return candidates.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }

    private static func repositoryDistRoot() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var candidates: [URL] = []
        var cursor = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else { break }
            cursor = parent
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        for candidate in candidates {
            let root = candidate.appendingPathComponent("BundledTools/rivet/dist", isDirectory: true)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) {
                return root
            }
        }
        return nil
    }
}

struct RivetView: View {
    @Environment(AppState.self) private var app
    @State private var webView = RivetView.makeWebView()
    @State private var loadError: String?
    @State private var loadedURL: URL?
    @State private var cacheToken = UUID().uuidString

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    var body: some View {
        VStack(spacing: 0) {
            // Exactly the same direct-from-disk model controls used by Chat.
            ModelSlotBar()
            Divider()
            statusBar
            Divider()
            ZStack {
                RivetWebView(webView: webView, onLoadFailed: { loadError = $0 })
                if loadedURL == nil, loadError == nil {
                    ProgressView("Starting Forge Graph…")
                        .controlSize(.large)
                }
                if let loadError {
                    ContentUnavailableView {
                        Label("Forge Graph Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") {
                            self.loadError = nil
                            app.ensureRivetServer()
                            loadWhenReady()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundGradient)
        .onAppear {
            guard RivetLocator.siteRoot() != nil else {
                loadError = "The bundled Rivet frontend is missing. Run scripts/build-rivet.sh."
                return
            }
            app.ensureRivetServer()
            loadWhenReady()
        }
        .onChange(of: app.server.state) { _, _ in loadWhenReady() }
    }

    private var statusBar: some View {
        HStack(spacing: Theme.s2) {
            Label("Forge Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
            Text("Inference: Forge OpenAI-compatible server")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let baseURL = app.server.baseURL {
                Text(baseURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } else if case .failed(let message) = app.server.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.s3)
        .frame(height: 30)
        .background(.white.opacity(0.025))
    }

    private func loadWhenReady() {
        guard let baseURL = app.server.baseURL else { return }
        let graphRoot = baseURL.replacingOccurrences(of: "/v1", with: "/rivet/")
        guard var components = URLComponents(string: graphRoot) else { return }
        // Use a fresh, Forge-owned browser origin. Older embedded Rivet builds
        // persisted incompatible IndexedDB state under 127.0.0.1; localhost is
        // the same loopback listener and is already covered by the server's
        // Host/Origin allowlist, but keeps that legacy data intact and separate.
        components.host = "localhost"
        components.queryItems = [URLQueryItem(name: "forge-build", value: cacheToken)]
        guard let url = components.url,
            loadedURL != url
        else { return }
        loadedURL = url
        webView.load(
            URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30))
    }
}

private struct RivetWebView: NSViewRepresentable {
    let webView: WKWebView
    let onLoadFailed: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFailed: onLoadFailed)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onLoadFailed: (String) -> Void

        init(onLoadFailed: @escaping (String) -> Void) {
            self.onLoadFailed = onLoadFailed
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if ["http", "https", "blob", "about"].contains(url.scheme?.lowercased() ?? "") {
                if url.host == "127.0.0.1" || url.host == "localhost" || url.scheme == "blob"
                    || url.scheme == "about"
                {
                    return .allow
                }
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
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
