// Forge — OpenRouter streaming client.
//
// Uses OpenRouter's OpenAI-compatible chat completions endpoint:
// https://openrouter.ai/api/v1/chat/completions
// Reasoning: https://openrouter.ai/docs/guides/best-practices/reasoning-tokens

import Foundation

enum OpenRouterError: LocalizedError {
    case noKey
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No OpenRouter API key set — add one in Settings."
        case .http(let code, let message):
            return "OpenRouter API error \(code): \(message)"
        case .stream(let message):
            return "OpenRouter stream error: \(message)"
        }
    }
}

/// OpenRouter unified `reasoning.effort` values.
enum OpenRouterReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case none, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

struct OpenRouterStreamConfig: Equatable {
    var reasoningEnabled: Bool = true
    var effort: OpenRouterReasoningEffort = .high
    var maxTokens: Int = 8192
}

struct OpenRouterClient {
    struct Message {
        let role: String
        let text: String
    }

    struct ModelInfo: Identifiable, Codable, Equatable, Hashable {
        var id: String
        var name: String
        var contextLength: Int?

        var label: String {
            if let contextLength, contextLength > 0 {
                let k = contextLength >= 1000 ? contextLength / 1000 : contextLength
                return "\(name) · \(k)k ctx"
            }
            return name
        }
    }

    static let defaultModelID = "openrouter/auto"

    static let models: [(id: String, label: String)] = [
        ("openrouter/auto", "OpenRouter Auto"),
        ("openrouter/fusion", "OpenRouter Fusion"),
        ("~openai/gpt-latest", "OpenAI Latest"),
        ("~anthropic/claude-sonnet-latest", "Claude Sonnet Latest"),
        ("~google/gemini-pro-latest", "Gemini Pro Latest"),
        ("openai/gpt-5.2-codex", "GPT-5.2 Codex"),
        ("openai/gpt-5.5", "GPT-5.5"),
        ("z-ai/glm-5.2", "GLM 5.2"),
        ("moonshotai/kimi-k2.7-code", "Kimi K2.7 Code"),
        ("arcee-ai/coder-large", "Arcee Coder Large"),
        ("kwaipilot/kat-coder-pro-v2", "Kat Coder Pro v2"),
        ("cohere/north-mini-code:free", "Cohere North Mini Code (free)"),
        ("qwen/qwen3-coder", "Qwen3 Coder"),
        ("qwen/qwen3.7-plus", "Qwen3.7 Plus"),
        ("deepseek/deepseek-v3.2", "DeepSeek V3.2"),
        ("minimax/minimax-m3", "MiniMax M3"),
        ("nvidia/nemotron-3-ultra-550b-a55b:free", "Nemotron 3 Ultra Free"),
    ]

    nonisolated(unsafe) private static var catalogLabels: [String: String] = [:]

    static func label(for id: String) -> String {
        if let preset = models.first(where: { $0.id == id }) {
            return preset.label
        }
        if let cached = catalogLabels[id] {
            return cached
        }
        return id
    }

    static func registerCatalog(_ entries: [ModelInfo]) {
        for entry in entries {
            catalogLabels[entry.id] = entry.label
        }
    }

    var apiKey: String

    func fetchModels() async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw OpenRouterError.noKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Forge", forHTTPHeaderField: "X-OpenRouter-Title")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OpenRouterError.http(status, Self.extractError(from: data) ?? "model list failed")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["data"] as? [[String: Any]]
        else { return [] }

        let mapped = rows.compactMap { row -> ModelInfo? in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String) ?? id
            let context = row["context_length"] as? Int
            return ModelInfo(id: id, name: name, contextLength: context)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Self.registerCatalog(mapped)
        return mapped
    }

    func complete(
        model: String,
        system: String?,
        messages: [Message],
        config: OpenRouterStreamConfig = OpenRouterStreamConfig()
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenRouterError.noKey }

        var payloadMessages = [[String: String]]()
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(["role": "system", "content": system])
        }
        payloadMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.text] })

        var request = URLRequest(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Forge", forHTTPHeaderField: "X-OpenRouter-Title")

        var body = Self.baseBody(
            model: model, messages: payloadMessages, config: config, stream: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OpenRouterError.http(status, Self.extractError(from: data) ?? "request failed")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw OpenRouterError.stream("empty completion response")
        }
        if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            return "``\n\n" + (message["content"] as? String ?? "")
        }
        guard let content = message["content"] as? String else {
            throw OpenRouterError.stream("empty completion response")
        }
        return content
    }

    func stream(
        model: String,
        system: String?,
        messages: [Message],
        config: OpenRouterStreamConfig = OpenRouterStreamConfig(),
        sessionID: String? = nil,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw OpenRouterError.noKey }

        var payloadMessages = [[String: String]]()
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(["role": "system", "content": system])
        }
        payloadMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.text] })

        var request = URLRequest(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Forge", forHTTPHeaderField: "X-OpenRouter-Title")

        var body = Self.baseBody(
            model: model, messages: payloadMessages, config: config, stream: true)
        if let sessionID, !sessionID.isEmpty {
            body["session_id"] = sessionID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw OpenRouterError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        var assembler = OpenRouterReasoningStreamAssembler()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any]
            else { continue }

            if let error = obj["error"] as? [String: Any] {
                throw OpenRouterError.stream((error["message"] as? String) ?? "stream error")
            }
            guard
                let choices = obj["choices"] as? [[String: Any]],
                let first = choices.first,
                let delta = first["delta"] as? [String: Any]
            else { continue }

            if let chunk = assembler.ingest(delta: delta) {
                await onChunk(chunk)
            }
        }
        if let tail = assembler.finish() {
            await onChunk(tail)
        }
    }

    private static func baseBody(
        model: String,
        messages: [[String: String]],
        config: OpenRouterStreamConfig,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages,
        ]
        if model != "openrouter/fusion" {
            body["max_tokens"] = config.maxTokens
        }
        if config.reasoningEnabled {
            body["reasoning"] = ["effort": config.effort.rawValue, "exclude": false]
        } else {
            body["reasoning"] = ["effort": OpenRouterReasoningEffort.none.rawValue]
        }
        return body
    }

    private static func extractError(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.components(separatedBy: "\n") {
            let chunk = raw.hasPrefix("data:") ? String(raw.dropFirst(5)) : raw
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8))
                as? [String: Any] {
                if let error = obj["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return message
                }
                if let message = obj["message"] as? String {
                    return message
                }
            }
        }
        return nil
    }
}

/// Wraps OpenRouter reasoning fields into `` markers for the chat UI.
private struct OpenRouterReasoningStreamAssembler {
    private var thinkingOpen = false
    private var thinkingClosed = false

    mutating func ingest(delta: [String: Any]) -> String? {
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            for detail in details {
                let kind = detail["type"] as? String ?? ""
                let text =
                    (detail["text"] as? String)
                    ?? (detail["summary"] as? String)
                    ?? ""
                if !text.isEmpty, kind.hasPrefix("reasoning") {
                    return appendThinking(text)
                }
            }
        }
        if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
            return appendThinking(reasoning)
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            var out = closeThinkingIfNeeded() ?? ""
            out += content
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private mutating func appendThinking(_ text: String) -> String {
        if !thinkingOpen {
            thinkingOpen = true
            return "``" + text
        }
        return text
    }

    private mutating func closeThinkingIfNeeded() -> String? {
        guard thinkingOpen, !thinkingClosed else { return nil }
        thinkingClosed = true
        return "``\n\n"
    }

    mutating func finish() -> String? {
        closeThinkingIfNeeded()
    }
}