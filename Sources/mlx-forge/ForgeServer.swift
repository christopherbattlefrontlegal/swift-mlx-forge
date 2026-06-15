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
    /// Supplies default generation settings for requests that omit parameters.
    var defaultSettings: () -> GenerationSettings = { GenerationSettings() }

    private var listener: NWListener?
    private var startGeneration = 0
    /// The port we are actually bound to. Drives `localIdentity()` so Host/Origin
    /// enforcement is keyed off the real socket, not the observable `state` (which
    /// can briefly lag a stale listener's lifecycle events).
    private var boundPort: UInt16?

    var baseURL: String? {
        guard case .running(let port) = state else { return nil }
        return "http://127.0.0.1:\(port)/v1"
    }

    // MARK: - Lifecycle

    /// Stops any existing listener, then binds after a short grace period so
    /// the cancelled socket is fully released (immediate rebind can hit
    /// EADDRINUSE even with address reuse enabled).
    func start(port: UInt16) {
        startGeneration += 1
        let generation = startGeneration
        stop()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == self.startGeneration else { return }
            self.bind(port: port)
        }
    }

    private func bind(port: UInt16) {
        FileHandle.standardError.write(Data("[forge-server] bind(port: \(port))\n".utf8))
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only — never expose the firm's models to the network.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
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
        listener?.cancel()
        listener = nil
        boundPort = nil
        state = .stopped
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            do {
                let request = try await HTTPRequest.read(from: connection)
                await self?.route(request, on: connection)
            } catch {
                await HTTPResponse.sendError(
                    on: connection, status: "400 Bad Request",
                    message: "Bad request.", allowOrigin: nil)
            }
            connection.cancel()
        }
    }

    /// The Host/Origin values that are legitimately us. Anything else is either a
    /// DNS-rebinding attempt (attacker domain resolved to 127.0.0.1 → forged Host)
    /// or a drive-by request from a website the user happens to be visiting.
    private func localIdentity() -> (hosts: Set<String>, origins: Set<String>)? {
        guard let port = boundPort else { return nil }
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        let origins: Set<String> = [
            "http://127.0.0.1:\(port)", "http://localhost:\(port)", "http://[::1]:\(port)",
        ]
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
        switch (request.method, path) {
        case ("OPTIONS", _):
            await HTTPResponse.send(
                on: connection, status: "204 No Content", contentType: nil, body: Data(),
                allowOrigin: allowOrigin)
        case ("GET", "/health"), ("GET", "/"):
            await handleHealth(on: connection, allowOrigin: allowOrigin)
        case ("GET", "/v1/models"):
            await handleModels(on: connection, allowOrigin: allowOrigin)
        case ("POST", "/v1/chat/completions"):
            await handleChat(request, on: connection, allowOrigin: allowOrigin)
        default:
            await HTTPResponse.sendError(
                on: connection, status: "404 Not Found",
                message: "Unknown endpoint.", allowOrigin: allowOrigin)
        }
    }

    // MARK: - Endpoints

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
        let chat: ChatCompletionRequest
        do {
            chat = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)
        } catch {
            await HTTPResponse.sendError(
                on: connection, status: "400 Bad Request",
                message: "Invalid request body.", allowOrigin: allowOrigin)
            return
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
            parameters.maxTokens = maxTokens > 0 ? maxTokens : nil
        }

        let messages: [Chat.Message] = chat.messages.map { message in
            switch message.role {
            case "system", "developer": return .system(message.text)
            case "assistant": return .assistant(message.text)
            case "tool": return .tool(message.text)
            default: return .user(message.text)
            }
        }

        // GGUF (llama.cpp) models aren't wired into the API server yet.
        guard let container = entry.container else {
            await HTTPResponse.sendError(
                on: connection, status: "501 Not Implemented",
                message: "GGUF models are not yet available via the API server — use the chat UI.",
                allowOrigin: allowOrigin)
            return
        }

        // Stateless API: fresh session per request, full history each time.
        let session = ChatSession(container, generateParameters: parameters)
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

        func chunkJSON(delta: [String: Any], finish: String?) -> String {
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

        await HTTPResponse.sendRaw(
            on: connection,
            "data: \(chunkJSON(delta: ["role": "assistant"], finish: nil))\n\n")
        guard let gate = engine?.gate else { return }
        // Generation holds an exclusive MLX turn — it can never overlap the
        // chat UI's stream or another API request (concurrent MLX evals on
        // one Metal device are a GPU-fault, not a slowdown).
        await gate.withTurn {
            do {
                let prompt = messages.last?.content ?? ""
                let role = messages.last?.role ?? .user
                let images = messages.last?.images ?? []
                let videos = messages.last?.videos ?? []
                for try await chunk in session.streamResponse(
                    to: prompt, role: role, images: images, videos: videos)
                {
                    let delivered = await HTTPResponse.sendRaw(
                        on: connection,
                        "data: \(chunkJSON(delta: ["content": chunk], finish: nil))\n\n")
                    // Client hung up — stop generating instead of burning GPU
                    // to completion into a dead socket (ending iteration
                    // cancels the underlying generation).
                    guard delivered else { return }
                }
                await HTTPResponse.sendRaw(
                    on: connection, "data: \(chunkJSON(delta: [:], finish: "stop"))\n\n")
                await HTTPResponse.sendRaw(on: connection, "data: [DONE]\n\n")
            } catch {
                FileHandle.standardError.write(
                    Data("[forge-server] stream error: \(error)\n".utf8))
                let payload = ["error": ["message": "Generation failed."]]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                await HTTPResponse.sendRaw(
                    on: connection, "data: \(String(decoding: data, as: UTF8.self))\n\n")
            }
        }
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
            var output = ""
            var info: GenerateCompletionInfo?
            // Exclusive MLX turn — see streamChat for why.
            try await gate.withTurn {
                let prompt = messages.last?.content ?? ""
                let role = messages.last?.role ?? .user
                let images = messages.last?.images ?? []
                let videos = messages.last?.videos ?? []
                for try await item in session.streamDetails(
                    to: prompt, role: role, images: images, videos: videos
                ) {
                    switch item {
                    case .chunk(let text): output += text
                    case .info(let i): info = i
                    case .toolCall: break
                    }
                }
            }
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

    struct Message: Decodable {
        var role: String
        var text: String

        enum CodingKeys: String, CodingKey {
            case role, content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
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
    /// CORS headers. `allowOrigin` is nil unless the request carried a *validated
    /// loopback* Origin — we never emit a wildcard, so a random website cannot read
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
