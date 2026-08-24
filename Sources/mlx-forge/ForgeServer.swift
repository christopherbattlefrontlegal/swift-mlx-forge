// Forge — local OpenAI-compatible API server.
//
// Serves http://127.0.0.1:<port>/v1 so any OpenAI-SDK agent framework can run
// against the models loaded in Forge. Endpoints:
//
//   GET  /v1/models            — installed models (loaded ones marked)
//   POST /v1/chat/completions  — chat with optional SSE streaming
//   GET  /health               — liveness + loaded model summary
//
// Requests for an installed-but-not-loaded model auto-load it on first use.
// Binds to loopback only, and additionally enforces a Host-header allowlist +
// rejects cross-origin browser requests, so a website the user visits cannot
// reach this server (defeats DNS rebinding and drive-by access).

import Foundation
import MLXLMCommon
import Network
import Observation
import SystemConfiguration

/// `@unchecked Sendable` box for handing a non-Sendable value (ChatSession,
/// [Chat.Message]) into the server's off-main generation task. Safe because
/// `MLXGate` serializes all GPU work — only one generation touches the session
/// at a time, so there is no concurrent access across actors.
fileprivate struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
@Observable
final class ForgeServer {

    enum State: Equatable {
        case stopped
        case running(UInt16)
        case failed(String)
    }

    private(set) var state: State = .stopped
    private(set) var requestsServed = 0
    private(set) var activeRequests = 0

    weak var engine: InferenceEngine?
    weak var store: ModelStore?
    weak var mcp: MCPManager?
    /// Compiled Rivet browser app served from `/rivet/` on this same listener.
    /// Same-origin hosting lets Rivet use the API without weakening CORS.
    var rivetRoot: URL?
    /// Supplies default generation settings for requests that omit parameters.
    var defaultSettings: () -> GenerationSettings = { GenerationSettings() }
    /// Bearer token required for every non-OPTIONS request while listening on LAN.
    var apiKey: () -> String = { "" }

    private var listener: NWListener?
    private var startGeneration = 0
    /// In-flight request tasks. stop() cancels them so a long generation can't
    /// keep the GPU gate (and app shutdown) hostage after the listener closes.
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    /// The port we are actually bound to. Drives `localIdentity()` so Host/Origin
    /// enforcement is keyed off the real socket, not the observable `state` (which
    /// can briefly lag a stale listener's lifecycle events).
    private var boundPort: UInt16?
    /// Whether the bound listener accepts connections from the local network
    /// (LM Studio-style "serve on network") instead of loopback only.
    private(set) var exposedToNetwork = false

    var baseURL: String? {
        guard case .running(let port) = state else { return nil }
        return "http://127.0.0.1:\(port)/v1"
    }

    /// Every base URL the server is reachable at — loopback plus, when exposed to
    /// the network, each active LAN address and the machine's .local hostname.
    var reachableBaseURLs: [String] {
        guard case .running(let port) = state else { return [] }
        var urls = ["http://127.0.0.1:\(port)/v1"]
        if exposedToNetwork {
            urls += LocalNetwork.lanHosts().map { "http://\($0):\(port)/v1" }
        }
        return urls
    }

    // MARK: - Lifecycle

    /// Stops any existing listener, then binds after a short grace period so
    /// the cancelled socket is fully released (immediate rebind can hit
    /// EADDRINUSE even with address reuse enabled).
    func start(port: UInt16, exposeToNetwork: Bool = false) {
        stop()
        startGeneration &+= 1
        let generation = startGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == self.startGeneration else { return }
            self.bind(port: port, exposeToNetwork: exposeToNetwork)
        }
    }

    private func bind(port: UInt16, exposeToNetwork: Bool) {
        FileHandle.standardError.write(
            Data("[forge-server] bind(port: \(port), network: \(exposeToNetwork))\n".utf8))
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if !exposeToNetwork {
                // Loopback only (default) — the models never leave the machine.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            } else {
                // Serve on all interfaces so other machines on the LAN can attach.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.any), port: NWEndpoint.Port(rawValue: port)!)
            }
            exposedToNetwork = exposeToNetwork
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                FileHandle.standardError.write(
                    Data("[forge-server] state: \(newState)\n".utf8))
                Task { @MainActor [weak self, weak listener] in
                    // Ignore events from a listener we've already replaced — a stale
                    // `.cancelled` from the old socket must not flip the live one's state.
                    guard let self, listener === self.listener else { return }
                    switch newState {
                    case .ready: self.state = .running(port)
                    case .failed(let error): self.state = .failed(error.localizedDescription)
                    case .cancelled: self.state = .stopped
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            self.boundPort = port
        } catch {
            FileHandle.standardError.write(
                Data("[forge-server] listener init failed: \(error)\n".utf8))
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        // Also invalidate a delayed bind that has not created its listener yet.
        startGeneration &+= 1
        listener?.cancel()
        listener = nil
        boundPort = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        state = .stopped
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        let requestID = UUID()
        requestTasks[requestID] = Task { [weak self] in
            do {
                let request = try await HTTPRequest.read(from: connection)
                await self?.route(request, on: connection)
            } catch {
                await HTTPResponse.sendError(
                    on: connection, status: "400 Bad Request",
                    message: "Bad request.", allowOrigin: nil)
            }
            connection.cancel()
            self?.requestTasks.removeValue(forKey: requestID)
        }
    }

    /// The Host/Origin values that are legitimately us. Anything else is either a
    /// DNS-rebinding attempt (attacker domain resolved to 127.0.0.1 → forged Host)
    /// or a drive-by request from a website the user happens to be visiting.
    /// When serving on the network, the machine's LAN addresses and hostnames are
    /// also us — anything else still gets rejected.
    private func localIdentity() -> (hosts: Set<String>, origins: Set<String>)? {
        guard let port = boundPort else { return nil }
        var hostNames = ["127.0.0.1", "localhost", "[::1]"]
        if exposedToNetwork {
            hostNames += LocalNetwork.lanHosts()
        }
        let hosts = Set(hostNames.map { "\($0):\(port)" })
        let origins = Set(hostNames.map { "http://\($0):\(port)" })
        return (hosts, origins)
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) async {
        requestsServed += 1
        activeRequests += 1
        defer { activeRequests -= 1 }

        // --- Local-origin enforcement -------------------------------------------------
        // Loopback binding alone does NOT protect against the user's own browser: any
        // site can POST to 127.0.0.1. We require the Host header to be our exact
        // loopback host:port (kills DNS rebinding), and reject any cross-origin
        // browser request outright (kills drive-by access + the model-load DoS).
        let host = request.headers["host"] ?? ""
        let origin = request.headers["origin"]
        // Fail closed: if we can't establish our own identity (server not yet
        // `.running`), reject rather than skip enforcement.
        guard let identity = localIdentity() else {
            await HTTPResponse.sendError(
                on: connection, status: "503 Service Unavailable",
                message: "Server not ready.", allowOrigin: nil)
            return
        }
        if !identity.hosts.contains(host) {
            await HTTPResponse.sendError(
                on: connection, status: "403 Forbidden",
                message: "Host not allowed.", allowOrigin: nil)
            return
        }
        if let origin, !identity.origins.contains(origin) {
            await HTTPResponse.sendError(
                on: connection, status: "403 Forbidden",
                message: "Cross-origin request blocked.", allowOrigin: nil)
            return
        }
        // Only ever echo back a validated loopback origin — never a wildcard.
        let allowOrigin: String? = origin.flatMap {
            localIdentity()?.origins.contains($0) == true ? $0 : nil
        }

        // Match on the path only — `/v1/models?foo=1` must route like `/v1/models`.
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? request.path
        if exposedToNetwork && request.method != "OPTIONS" {
            let expected = apiKey()
            let authorization = request.headers["authorization"] ?? ""
            let supplied = authorization.hasPrefix("Bearer ")
                ? String(authorization.dropFirst("Bearer ".count)) : ""
            guard !expected.isEmpty, Self.constantTimeEqual(supplied, expected) else {
                await HTTPResponse.sendError(
                    on: connection, status: "401 Unauthorized",
                    message: "A valid Forge bearer token is required.",
                    allowOrigin: allowOrigin)
                return
            }
        }
        if request.method == "GET",
            path == "/rivet" || path.hasPrefix("/rivet/")
                || path.hasPrefix("/monacoeditorwork/")
        {
            await handleRivetAsset(path: path, on: connection, allowOrigin: allowOrigin)
            return
        }
        switch (request.method, path) {
        case ("OPTIONS", _):
            await HTTPResponse.send(
                on: connection, status: "204 No Content", contentType: nil, body: Data(),
                allowOrigin: allowOrigin)
        case ("GET", "/health"), ("GET", "/"):
            await handleHealth(on: connection, allowOrigin: allowOrigin)
        case ("GET", "/v1/models"):
            await handleModels(on: connection, allowOrigin: allowOrigin)
        case ("POST", "/v1/forge/mcp/tools"):
            await handleMCPTools(on: connection, allowOrigin: allowOrigin)
        case ("POST", "/v1/forge/mcp/call"):
            await handleMCPCall(request, on: connection, allowOrigin: allowOrigin)
        case ("POST", "/v1/chat/completions"):
            await handleChat(request, on: connection, allowOrigin: allowOrigin)
        default:
            await HTTPResponse.sendError(
                on: connection, status: "404 Not Found",
                message: "Unknown endpoint.", allowOrigin: allowOrigin)
        }
    }

    nonisolated private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int(index < left.count ? left[index] : 0)
                ^ Int(index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    // MARK: - Endpoints

    private func handleRivetAsset(
        path: String, on connection: NWConnection, allowOrigin: String?
    ) async {
        guard let root = rivetRoot?.standardizedFileURL.resolvingSymlinksInPath() else {
            await HTTPResponse.sendError(
                on: connection, status: "404 Not Found",
                message: "Rivet frontend is not bundled.", allowOrigin: allowOrigin)
            return
        }

        let encodedRelative: String
        if path == "/rivet" || path == "/rivet/" {
            encodedRelative = "index.html"
        } else if path.hasPrefix("/rivet/") {
            encodedRelative = String(path.dropFirst("/rivet/".count))
        } else {
            // Monaco's Vite plugin emits root-relative worker paths.
            encodedRelative = String(path.dropFirst())
        }
        guard let relative = encodedRelative.removingPercentEncoding,
            !relative.split(separator: "/").contains("..")
        else {
            await HTTPResponse.sendError(
                on: connection, status: "400 Bad Request",
                message: "Invalid asset path.", allowOrigin: allowOrigin)
            return
        }

        let file = root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            await HTTPResponse.sendError(
                on: connection, status: "404 Not Found",
                message: "Rivet asset not found.", allowOrigin: allowOrigin)
            return
        }
        await HTTPResponse.send(
            on: connection, status: "200 OK",
            contentType: Self.rivetMIMEType(for: file.pathExtension), body: data,
            allowOrigin: allowOrigin)
    }

    nonisolated private static func rivetMIMEType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }

    private func handleHealth(on connection: NWConnection, allowOrigin: String?) async {
        let loaded = engine?.loadedModels.map(\.model.name) ?? []
        let body: [String: Any] = [
            "status": "ok",
            "engine": "forge-mlx",
            "loaded_models": loaded,
        ]
        await HTTPResponse.sendJSON(on: connection, object: body, allowOrigin: allowOrigin)
    }

    private func handleModels(on connection: NWConnection, allowOrigin: String?) async {
        let loadedNames = Set(engine?.loadedModels.map(\.model.name) ?? [])
        let models = (store?.localModels ?? []).map { model -> [String: Any] in
            [
                "id": model.name,
                "object": "model",
                "owned_by": "forge",
                "loaded": loadedNames.contains(model.name),
            ]
        }
        await HTTPResponse.sendJSON(
            on: connection, object: ["object": "list", "data": models], allowOrigin: allowOrigin)
    }

    private func handleChat(
        _ request: HTTPRequest, on connection: NWConnection, allowOrigin: String?
    ) async {
        var chat: ChatCompletionRequest
        do {
            chat = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)
        } catch {
            await HTTPResponse.sendError(
                on: connection, status: "400 Bad Request",
                message: "Invalid request body.", allowOrigin: allowOrigin)
            return
        }

        if chat.model == "forge/local" {
            guard let localName = engine?.activeModel?.model.name
                ?? engine?.loadedModels.first?.model.name
            else {
                await HTTPResponse.sendError(
                    on: connection, status: "409 Conflict",
                    message: "Load a local model before using Graph Architect.",
                    allowOrigin: allowOrigin)
                return
            }
            chat.model = localName
        }

        // Resolve (auto-loading if installed but cold). On failure, return a generic
        // message over the wire — load errors can embed local filesystem paths.
        let entry: InferenceEngine.Loaded
        do {
            entry = try await resolveModel(named: chat.model)
        } catch {
            FileHandle.standardError.write(
                Data("[forge-server] model resolve failed: \(error)\n".utf8))
            await HTTPResponse.sendError(
                on: connection, status: "404 Not Found",
                message: "Model is not available.", allowOrigin: allowOrigin)
            return
        }

        var parameters = InferenceEngine.parameters(from: defaultSettings())
        if let temperature = chat.temperature { parameters.temperature = Float(temperature) }
        if let topP = chat.top_p { parameters.topP = Float(topP) }
        if let maxTokens = chat.max_tokens ?? chat.max_completion_tokens {
            parameters.maxTokens = maxTokens > 0 ? min(maxTokens, 32_768) : nil
        }
        if let configured = parameters.maxTokens {
            parameters.maxTokens = min(configured, 32_768)
        }

        let messages: [Chat.Message] = chat.messages.map { message in
            switch message.role {
            case "system", "developer": return .system(message.text)
            case "assistant":
                return .assistant(message.text, toolCalls: message.decodedToolCalls)
            case "tool": return .tool(message.text, id: message.toolCallID)
            default: return .user(message.text)
            }
        }

        // Stateless API: fresh session per request. Split out system instructions and prior
        // turns into the session history; the final user turn is the one we reply to. (An
        // earlier version built a history-less session and streamed only `messages.last`,
        // silently dropping the whole conversation and the system prompt.)
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let settings = defaultSettings()

        let responseIDForEntry = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let createdForEntry = Int(Date().timeIntervalSince1970)

        // GGUF (llama.cpp) models serve through the same OpenAI surface as MLX.
        if let gguf = entry.gguf {
            await ggufChat(
                gguf, messages: messages, systemText: systemText,
                temperature: chat.temperature, topP: chat.top_p,
                maxOutputTokens: parameters.maxTokens ?? 8_192,
                stream: chat.stream == true, model: chat.model,
                responseID: responseIDForEntry, created: createdForEntry,
                on: connection, allowOrigin: allowOrigin)
            engine?.refreshMemory()
            return
        }

        guard let container = entry.container else {
            await HTTPResponse.sendError(
                on: connection, status: "503 Service Unavailable",
                message: "Model backend is not available.", allowOrigin: allowOrigin)
            return
        }
        let session = ChatSession(
            container,
            instructions: systemText.isEmpty ? nil : systemText,
            generateParameters: parameters,
            additionalContext: InferenceEngine.thinkingAdditionalContext(
                for: entry, enabled: settings.localThinkingEnabled,
                effort: settings.localReasoningEffort),
            tools: chat.toolSpecs)
        let responseID = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date().timeIntervalSince1970)

        if chat.stream == true {
            await streamChat(
                session: session, messages: messages, model: chat.model,
                responseID: responseID, created: created, on: connection, allowOrigin: allowOrigin)
        } else {
            await completeChat(
                session: session, messages: messages, model: chat.model,
                responseID: responseID, created: created, on: connection, allowOrigin: allowOrigin)
        }
        engine?.refreshMemory()
    }

    private func handleMCPTools(on connection: NWConnection, allowOrigin: String?) async {
        guard allowOrigin != nil else {
            await HTTPResponse.sendError(
                on: connection, status: "403 Forbidden",
                message: "The MCP bridge is available only to the embedded graph workbench.",
                allowOrigin: nil)
            return
        }
        guard let mcp else {
            await HTTPResponse.sendError(
                on: connection, status: "503 Service Unavailable",
                message: "MCP manager unavailable.", allowOrigin: allowOrigin)
            return
        }
        let tools = await mcp.prepareToolCatalogForPrompt().map { binding -> [String: Any] in
            [
                "server": binding.serverID,
                "name": binding.tool.name,
                "description": binding.tool.description,
                "inputSchema": binding.inputSchemaObject,
            ]
        }
        await HTTPResponse.sendJSON(
            on: connection, object: ["tools": tools], allowOrigin: allowOrigin)
    }

    private func handleMCPCall(
        _ request: HTTPRequest, on connection: NWConnection, allowOrigin: String?
    ) async {
        guard allowOrigin != nil else {
            await HTTPResponse.sendError(
                on: connection, status: "403 Forbidden",
                message: "The MCP bridge is available only to the embedded graph workbench.",
                allowOrigin: nil)
            return
        }
        guard let mcp,
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let rawServer = object["server"] as? String,
            let tool = object["tool"] as? String,
            let arguments = object["arguments"] as? [String: Any]
        else {
            await HTTPResponse.sendError(
                on: connection, status: "400 Bad Request",
                message: "Expected server, tool, and arguments.", allowOrigin: allowOrigin)
            return
        }
        let server = mcp.resolveEntryID(rawServer)
        guard mcp.effectiveSelectedTools(for: server).contains(tool) else {
            await HTTPResponse.sendError(
                on: connection, status: "403 Forbidden",
                message: "The requested MCP tool is not enabled.", allowOrigin: allowOrigin)
            return
        }
        do {
            let result = try await mcp.callTool(
                entryID: server, name: tool, arguments: arguments)
            await HTTPResponse.send(
                on: connection, status: "200 OK", contentType: "application/json",
                body: result, allowOrigin: allowOrigin)
        } catch {
            await HTTPResponse.sendError(
                on: connection, status: "502 Bad Gateway",
                message: error.localizedDescription, allowOrigin: allowOrigin)
        }
    }

    private func resolveModel(named name: String) async throws -> InferenceEngine.Loaded {
        guard let engine, let store else { throw ForgeError.modelNotFound(name) }
        if let loaded = engine.loadedModel(named: name) { return loaded }
        if let local = store.localModels.first(where: {
            $0.name == name || $0.shortName == name
        }) {
            return try await engine.load(local)
        }
        throw ForgeError.modelNotFound(name)
    }

    private func streamChat(
        session: ChatSession, messages: [Chat.Message], model: String,
        responseID: String, created: Int, on connection: NWConnection, allowOrigin: String?
    ) async {
        await HTTPResponse.sendHead(
            on: connection, status: "200 OK", contentType: "text/event-stream",
            allowOrigin: allowOrigin)
        await HTTPResponse.sendRaw(
            on: connection,
            "data: \(Self.chunkJSON(responseID: responseID, created: created, model: model, delta: ["role": "assistant"], finish: nil))\n\n")
        guard let gate = engine?.gate else {
            // Engine was torn down after we already sent the 200 head — terminate the SSE
            // stream explicitly so the client doesn't wait on a socket that never closes.
            await HTTPResponse.sendRaw(
                on: connection,
                "data: {\"error\":{\"message\":\"Model engine unavailable.\"}}\n\n")
            await HTTPResponse.sendRaw(on: connection, "data: [DONE]\n\n")
            return
        }
        // Generation runs OFF the main actor (withTurnDetached) so a long MLX
        // turn serving an API request doesn't freeze the app UI. The gate still
        // serializes GPU work — only one turn runs at a time.
        let sessionBox = SendableBox(value: session)
        let messagesBox = SendableBox(value: messages)
        _ = try? await gate.withTurnDetached { [sessionBox, messagesBox] in
            let session = sessionBox.value
            let messages = messagesBox.value
            let promptCapture = RenderedPromptCapture()
            session.onPromptPrepared = { prepared in
                promptCapture.set(
                    RenderedPromptSnapshot(
                        tokenIDs: prepared.tokenIDs,
                        thinkingMarkers: prepared.thinkingMarkers,
                        promptTailText: prepared.promptTailText))
            }
            defer { session.onPromptPrepared = nil }
            do {
                var finishReason = "stop"
                var toolIndex = 0
                var classifier: ReasoningStreamClassifier?
                for try await item in session.streamDetails(
                    to: messages.filter { $0.role != .system })
                {
                    if Task.isCancelled { break }
                    switch item {
                    case .chunk(let chunk):
                        if classifier == nil {
                            classifier = ReasoningStreamClassifier(
                                context: promptCapture.get()?.reasoningContext ?? .taggedThink)
                        }
                        for delta in classifier!.ingest(chunk) {
                            guard let payload = Self.apiPayload(for: delta) else { continue }
                            let delivered = await HTTPResponse.sendRaw(
                                on: connection,
                                "data: \(Self.chunkJSON(responseID: responseID, created: created, model: model, delta: payload, finish: nil))\n\n")
                            // Client hung up — stop generating instead of burning GPU to
                            // completion into a dead socket (ending iteration cancels the
                            // underlying generation).
                            guard delivered else { return }
                        }
                    case .info(let info):
                        // Report length-truncation honestly so clients can retry/extend.
                        if info.stopReason == .length { finishReason = "length" }
                    case .toolCall(let call):
                        finishReason = "tool_calls"
                        let delta: [String: Any] = [
                            "tool_calls": [[
                                "index": toolIndex,
                                "id": call.id ?? "call-\(UUID().uuidString)",
                                "type": "function",
                                "function": [
                                    "name": call.function.name,
                                    "arguments": Self.toolArgumentsJSON(call),
                                ],
                            ]]
                        ]
                        toolIndex += 1
                        let delivered = await HTTPResponse.sendRaw(
                            on: connection,
                            "data: \(Self.chunkJSON(responseID: responseID, created: created, model: model, delta: delta, finish: nil))\n\n")
                        guard delivered else { return }
                    }
                }
                if var classifier {
                    for delta in classifier.finalize() {
                        guard let payload = Self.apiPayload(for: delta) else { continue }
                        let delivered = await HTTPResponse.sendRaw(
                            on: connection,
                            "data: \(Self.chunkJSON(responseID: responseID, created: created, model: model, delta: payload, finish: nil))\n\n")
                        guard delivered else { return }
                    }
                }
                await HTTPResponse.sendRaw(
                    on: connection, "data: \(Self.chunkJSON(responseID: responseID, created: created, model: model, delta: [:], finish: finishReason))\n\n")
                await HTTPResponse.sendRaw(on: connection, "data: [DONE]\n\n")
            } catch {
                FileHandle.standardError.write(
                    Data("[forge-server] stream error: \(error)\n".utf8))
                let payload = ["error": ["message": "Generation failed."]]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                await HTTPResponse.sendRaw(
                    on: connection, "data: \(String(decoding: data, as: UTF8.self))\n\n")
                // The SSE protocol requires [DONE] to terminate the stream — some SDKs
                // only finalize their iterator when they see it.
                await HTTPResponse.sendRaw(on: connection, "data: [DONE]\n\n")
            }
        }
    }

    /// Builds an OpenAI-compatible `chat.completion.chunk` SSE payload. Static
    /// and nonisolated so it is callable from the off-main generation task.
    nonisolated private static func chunkJSON(
        responseID: String, created: Int, model: String,
        delta: [String: Any], finish: String?
    ) -> String {
        let object: [String: Any] = [
            "id": responseID, "object": "chat.completion.chunk",
            "created": created, "model": model,
            "choices": [
                ["index": 0, "delta": delta, "finish_reason": finish as Any]
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func apiPayload(
        for delta: InferenceStreamDelta
    ) -> [String: Any]? {
        switch delta {
        case .reasoning(let text): return ["reasoning": text]
        case .content(let text): return ["content": text]
        case .invalidReasoningStructure: return nil
        }
    }

    nonisolated private static func toolArgumentsJSON(_ call: ToolCall) -> String {
        let object = call.function.arguments.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func completeChat(
        session: ChatSession, messages: [Chat.Message], model: String,
        responseID: String, created: Int, on connection: NWConnection, allowOrigin: String?
    ) async {
        guard let gate = engine?.gate else {
            await HTTPResponse.sendError(
                on: connection, status: "503 Service Unavailable",
                message: "Engine not available.", allowOrigin: allowOrigin)
            return
        }
        do {
            // Generation runs OFF the main actor (withTurnDetached) so a long MLX
            // turn serving an API request doesn't freeze the app UI.
            let sessionBox = SendableBox(value: session)
            let messagesBox = SendableBox(value: messages)
            let (output, reasoning, info, toolCalls) = try await gate.withTurnDetached {
                [sessionBox, messagesBox] in
                let session = sessionBox.value
                let messages = messagesBox.value
                let promptCapture = RenderedPromptCapture()
                session.onPromptPrepared = { prepared in
                    promptCapture.set(
                        RenderedPromptSnapshot(
                            tokenIDs: prepared.tokenIDs,
                            thinkingMarkers: prepared.thinkingMarkers,
                            promptTailText: prepared.promptTailText))
                }
                defer { session.onPromptPrepared = nil }
                var output = ""
                var reasoning = ""
                var info: GenerateCompletionInfo?
                var toolCalls: [ToolCall] = []
                var classifier: ReasoningStreamClassifier?
                for try await item in session.streamDetails(
                    to: messages.filter { $0.role != .system }
                ) {
                    switch item {
                    case .chunk(let text):
                        if classifier == nil {
                            classifier = ReasoningStreamClassifier(
                                context: promptCapture.get()?.reasoningContext ?? .taggedThink)
                        }
                        for delta in classifier!.ingest(text) {
                            switch delta {
                            case .reasoning(let text): reasoning += text
                            case .content(let text): output += text
                            case .invalidReasoningStructure: break
                            }
                        }
                    case .info(let i): info = i
                    case .toolCall(let call): toolCalls.append(call)
                    }
                }
                if var classifier {
                    for delta in classifier.finalize() {
                        switch delta {
                        case .reasoning(let text): reasoning += text
                        case .content(let text): output += text
                        case .invalidReasoningStructure: break
                        }
                    }
                }
                return (output, reasoning, info, toolCalls)
            }
            let finishReason = !toolCalls.isEmpty
                ? "tool_calls" : (info?.stopReason == .length ? "length" : "stop")
            var responseMessage: [String: Any] = ["role": "assistant", "content": output]
            if !reasoning.isEmpty { responseMessage["reasoning"] = reasoning }
            if !toolCalls.isEmpty {
                responseMessage["tool_calls"] = toolCalls.enumerated().map { index, call in
                    [
                        "index": index,
                        "id": call.id ?? "call-\(UUID().uuidString)",
                        "type": "function",
                        "function": [
                            "name": call.function.name,
                            "arguments": Self.toolArgumentsJSON(call),
                        ],
                    ] as [String: Any]
                }
            }
            let body: [String: Any] = [
                "id": responseID, "object": "chat.completion",
                "created": created, "model": model,
                "choices": [
                    [
                        "index": 0,
                        "message": responseMessage,
                        "finish_reason": finishReason,
                    ]
                ],
                "usage": [
                    "prompt_tokens": info?.promptTokenCount ?? 0,
                    "completion_tokens": info?.generationTokenCount ?? 0,
                    "total_tokens": (info?.promptTokenCount ?? 0)
                        + (info?.generationTokenCount ?? 0),
                ],
            ]
            await HTTPResponse.sendJSON(on: connection, object: body, allowOrigin: allowOrigin)
        } catch {
            FileHandle.standardError.write(
                Data("[forge-server] completion error: \(error)\n".utf8))
            await HTTPResponse.sendError(
                on: connection, status: "500 Internal Server Error",
                message: "Inference failed.", allowOrigin: allowOrigin)
        }
    }

    /// Serves a GGUF (llama.cpp) model over the OpenAI surface. Same gate discipline
    /// as MLX — llama.cpp competes for the same GPU.
    private func ggufChat(
        _ gguf: GGUFRuntime,
        messages: [Chat.Message],
        systemText: String,
        temperature: Double?, topP: Double?,
        maxOutputTokens: Int,
        stream: Bool,
        model: String, responseID: String, created: Int,
        on connection: NWConnection, allowOrigin: String?
    ) async {
        guard let gate = engine?.gate else {
            await HTTPResponse.sendError(
                on: connection, status: "503 Service Unavailable",
                message: "Engine not available.", allowOrigin: allowOrigin)
            return
        }
        let settings = defaultSettings()
        let priorTurns = Array(messages.filter { $0.role != .system }.dropLast())
        let history: [(role: GGUFRuntime.HistoryRole, content: String)] = priorTurns.compactMap {
            message in
            switch message.role {
            case .user: return (.user, message.content)
            case .assistant: return (.assistant, message.content)
            default: return nil
            }
        }
        let prompt = messages.last(where: { $0.role != .system })?.content ?? ""

        @Sendable func chunkJSON(delta: [String: Any], finish: String?) -> String {
            let object: [String: Any] = [
                "id": responseID, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [
                    ["index": 0, "delta": delta, "finish_reason": finish as Any]
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        if stream {
            await HTTPResponse.sendHead(
                on: connection, status: "200 OK", contentType: "text/event-stream",
                allowOrigin: allowOrigin)
            await HTTPResponse.sendRaw(
                on: connection,
                "data: \(chunkJSON(delta: ["role": "assistant"], finish: nil))\n\n")
            _ = try? await gate.withTurn {
                gguf.configure(
                    temperature: temperature ?? settings.temperature,
                    topP: topP ?? settings.topP,
                    topK: settings.topK,
                    system: systemText.isEmpty ? nil : systemText,
                    history: history)
                _ = await gguf.respond(to: prompt, maxOutputTokens: maxOutputTokens) { delta in
                    guard let payload = Self.apiPayload(for: delta) else { return }
                    let delivered = await HTTPResponse.sendRaw(
                        on: connection,
                        "data: \(chunkJSON(delta: payload, finish: nil))\n\n")
                    // Client hung up — stop llama.cpp instead of generating into a dead socket.
                    if !delivered { gguf.stop() }
                }
                await HTTPResponse.sendRaw(
                    on: connection, "data: \(chunkJSON(delta: [:], finish: "stop"))\n\n")
                await HTTPResponse.sendRaw(on: connection, "data: [DONE]\n\n")
            }
        } else {
            let output = (try? await gate.withTurn {
                gguf.configure(
                    temperature: temperature ?? settings.temperature,
                    topP: topP ?? settings.topP,
                    topK: settings.topK,
                    system: systemText.isEmpty ? nil : systemText,
                    history: history)
                return await gguf.respond(to: prompt, maxOutputTokens: maxOutputTokens) { _ in }
            }) ?? ""
            // llama.cpp's wrapper doesn't expose token counts — report zeros rather than guesses.
            let body: [String: Any] = [
                "id": responseID, "object": "chat.completion",
                "created": created, "model": model,
                "choices": [
                    [
                        "index": 0,
                        "message": ["role": "assistant", "content": output],
                        "finish_reason": "stop",
                    ]
                ],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
            ]
            await HTTPResponse.sendJSON(on: connection, object: body, allowOrigin: allowOrigin)
        }
    }
}

// MARK: - Local network identity

/// Enumerates the machine's LAN identities (IPv4 addresses of active non-loopback
/// interfaces + the .local hostname) for display and Host-header validation when
/// the server is exposed to the network.
enum LocalNetwork {
    static func lanHosts() -> [String] {
        var hosts: [String] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0 {
            var cursor = addresses
            while let current = cursor {
                defer { cursor = current.pointee.ifa_next }
                let flags = Int32(current.pointee.ifa_flags)
                guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                    let addr = current.pointee.ifa_addr,
                    addr.pointee.sa_family == sa_family_t(AF_INET)
                else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                    nil, 0, NI_NUMERICHOST) == 0
                {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    let host = String(decoding: bytes, as: UTF8.self)
                    if !host.isEmpty, !hosts.contains(host) { hosts.append(host) }
                }
            }
            freeifaddrs(addresses)
        }
        // `Host.current().names` performs synchronous reverse-DNS/mDNS resolution.
        // This function is read from SwiftUI's body on the main actor, so a slow
        // resolver freezes the whole app (and endpoint requests can hit the same
        // path through `localIdentity()`). The SystemConfiguration value is the
        // machine's configured Bonjour name and does not perform network lookup.
        if let localHostName = configuredBonjourHostName(), !hosts.contains(localHostName) {
            hosts.append(localHostName)
        }
        return hosts
    }

    private static func configuredBonjourHostName() -> String? {
        guard let configured = SCDynamicStoreCopyLocalHostName(nil) as String? else {
            return nil
        }
        let name = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return name.hasSuffix(".local") ? name : "\(name).local"
    }
}

// MARK: - OpenAI request shapes

private struct ChatCompletionRequest: Decodable {
    var model: String
    var messages: [Message]
    var stream: Bool?
    var temperature: Double?
    var top_p: Double?
    var max_tokens: Int?
    var max_completion_tokens: Int?
    var tools: [JSONValue]?

    var toolSpecs: [ToolSpec]? {
        let converted = tools?.compactMap { value -> ToolSpec? in
            guard case .object(let object) = value else { return nil }
            return object.mapValues(Self.sendableValue)
        } ?? []
        return converted.isEmpty ? nil : converted
    }

    private static func sendableValue(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(sendableValue)
        case .object(let values): return values.mapValues(sendableValue)
        }
    }

    struct Message: Decodable {
        var role: String
        var text: String
        var toolCalls: [ToolCallPayload]?
        var toolCallID: String?

        var decodedToolCalls: [ToolCall]? {
            let calls = toolCalls?.compactMap { payload -> ToolCall? in
                guard payload.type == nil || payload.type == "function" else { return nil }
                let arguments: [String: JSONValue]
                if let data = payload.function.arguments.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
                {
                    arguments = decoded
                } else {
                    arguments = [:]
                }
                return ToolCall(
                    function: .init(name: payload.function.name, arguments: arguments),
                    id: payload.id)
            } ?? []
            return calls.isEmpty ? nil : calls
        }

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            toolCalls = try container.decodeIfPresent([ToolCallPayload].self, forKey: .toolCalls)
            toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
            // content can be a string or an array of typed parts.
            if let string = try? container.decode(String.self, forKey: .content) {
                text = string
            } else if let parts = try? container.decode([Part].self, forKey: .content) {
                text = parts.compactMap(\.text).joined(separator: "\n")
            } else {
                text = ""
            }
        }

        struct Part: Decodable {
            var type: String?
            var text: String?
        }

        struct ToolCallPayload: Decodable {
            var id: String?
            var type: String?
            var function: Function

            struct Function: Decodable {
                var name: String
                var arguments: String
            }
        }
    }
}

// MARK: - Minimal HTTP over NWConnection

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Reads one HTTP/1.1 request (headers + Content-Length body).
    static func read(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        // Headers
        while buffer.range(of: separator) == nil {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 1_048_576 { throw URLError(.dataLengthExceedsMaximum) }
        }
        guard let headerEnd = buffer.range(of: separator) else {
            throw URLError(.badServerResponse)
        }

        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { throw URLError(.badServerResponse) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = Data(buffer[headerEnd.upperBound...])
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        // Chat JSON is small; cap the buffered body to keep a single request from
        // pinning hundreds of MB of memory.
        if contentLength > 16 * 1_048_576 { throw URLError(.dataLengthExceedsMaximum) }
        while body.count < contentLength {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { break }
            body.append(chunk)
        }

        return HTTPRequest(
            method: requestLine[0], path: requestLine[1], headers: headers, body: body)
    }

    /// Per-read deadline. A client that opens a socket and then stalls (slowloris)
    /// would otherwise pin this request task indefinitely, since `receive` blocks
    /// with no timeout. Bound each read so a stalled connection is dropped.
    private static let readTimeoutNanos: UInt64 = 15_000_000_000  // 15s

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
                        data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: readTimeoutNanos)
                // The receive child is parked on a continuation that only the
                // NWConnection callback resumes — and the group must await it
                // before the timeout can propagate. Cancel the transport so
                // that callback fires (with an error) and the group can drain;
                // without this, an idle socket leaks the task + connection
                // forever.
                connection.cancel()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            // First task to finish wins; the timeout throws and drops the connection.
            let result = try await group.next() ?? nil
            return result
        }
    }
}

private enum HTTPResponse {
    /// CORS headers. `allowOrigin` is nil unless the request carried a validated
    /// local Origin — we never emit a wildcard, so a random website cannot read
    /// responses from this server.
    static func corsHeaders(_ allowOrigin: String?) -> String {
        guard let allowOrigin else { return "" }
        return "Access-Control-Allow-Origin: \(allowOrigin)\r\n"
            + "Vary: Origin\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
    }

    static func send(
        on connection: NWConnection, status: String, contentType: String?, body: Data,
        allowOrigin: String?
    ) async {
        var head = "HTTP/1.1 \(status)\r\n" + corsHeaders(allowOrigin) + "Connection: close\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        await sendData(on: connection, payload)
    }

    static func sendJSON(on connection: NWConnection, object: Any, allowOrigin: String?) async {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        await send(
            on: connection, status: "200 OK", contentType: "application/json", body: data,
            allowOrigin: allowOrigin)
    }

    static func sendError(
        on connection: NWConnection, status: String, message: String, allowOrigin: String?
    ) async {
        let body: [String: Any] = ["error": ["message": message, "type": "invalid_request_error"]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        await send(
            on: connection, status: status, contentType: "application/json", body: data,
            allowOrigin: allowOrigin)
    }

    /// SSE: status + headers only; body follows via `sendRaw`.
    static func sendHead(
        on connection: NWConnection, status: String, contentType: String, allowOrigin: String?
    ) async {
        let head =
            "HTTP/1.1 \(status)\r\n" + corsHeaders(allowOrigin)
            + "Content-Type: \(contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        await sendData(on: connection, Data(head.utf8))
    }

    /// Returns false when the connection is gone (client disconnected) so
    /// streaming callers can stop generating into a dead socket.
    @discardableResult
    static func sendRaw(on connection: NWConnection, _ text: String) async -> Bool {
        await sendData(on: connection, Data(text.utf8))
    }

    @discardableResult
    private static func sendData(on connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
        }
    }
}
