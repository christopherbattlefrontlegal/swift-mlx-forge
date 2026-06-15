// Forge — OpenRouter streaming client.
//
// Uses OpenRouter's OpenAI-compatible chat completions endpoint:
// https://openrouter.ai/api/v1/chat/completions

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

struct OpenRouterClient {
    struct Message {
        let role: String
        let text: String
    }

    static let defaultModelID = "openrouter/auto"

    static let models: [(id: String, label: String)] = [
        ("openrouter/auto", "OpenRouter Auto"),
        ("openrouter/fusion", "OpenRouter Fusion"),
        ("~openai/gpt-latest", "OpenAI Latest"),
        ("~anthropic/claude-sonnet-latest", "Claude Sonnet Latest"),
        ("~google/gemini-pro-latest", "Gemini Pro Latest"),
        ("moonshotai/kimi-k2.7-code", "Kimi K2.7 Code"),
        ("qwen/qwen3.7-plus", "Qwen3.7 Plus"),
        ("minimax/minimax-m3", "MiniMax M3"),
        ("nvidia/nemotron-3-ultra-550b-a55b:free", "Nemotron 3 Ultra Free"),
    ]

    static func label(for id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }

    var apiKey: String
    var maxTokens: Int = 8192

    func stream(
        model: String,
        system: String?,
        messages: [Message],
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

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": payloadMessages,
        ]
        if model != "openrouter/fusion" {
            body["max_tokens"] = maxTokens
        }
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
                let delta = first["delta"] as? [String: Any],
                let text = delta["content"] as? String,
                !text.isEmpty
            else { continue }
            await onChunk(text)
        }
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
