// Forge — Anthropic (Claude API) streaming client.
//
// Pure-Swift, raw HTTPS against POST /v1/messages — there is no official
// Anthropic Swift SDK, so this speaks the wire protocol directly via URLSession.
// App-Store-safe: it's just an outbound TLS request (network.client entitlement).
//
// Request stays MINIMAL on purpose: model + max_tokens + system + messages +
// stream. We do NOT send temperature / top_p / top_k / thinking.budget_tokens —
// the latest models (Fable 5, Opus 4.8) return 400 for those. Keeping the body
// minimal means the same code works across every Claude model.

import Foundation

enum AnthropicError: LocalizedError {
    case noKey
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Anthropic API key set — add one in the Tuning panel."
        case .http(let code, let message):
            return "Claude API error \(code): \(message)"
        case .stream(let message):
            return "Claude stream error: \(message)"
        }
    }
}

struct AnthropicClient {
    struct Message {
        let role: String  // "user" | "assistant"
        let text: String
    }

    /// Selectable Claude models. Default to Opus 4.8 (most capable GA model).
    static let models: [(id: String, label: String)] = [
        ("claude-opus-4-8", "Claude Opus 4.8"),
        ("claude-fable-5", "Claude Fable 5"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    ]

    static func label(for id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }

    var apiKey: String
    var maxTokens: Int = 8192

    /// Streams a chat completion, delivering text deltas to `onChunk` on the main
    /// actor. Throws on network/HTTP/stream error; honors task cancellation.
    func stream(
        model: String,
        system: String?,
        messages: [Message],
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicError.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.text] },
        ]
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            // Drain a bounded amount of the error body for a useful message.
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 64_000 { break }
            }
            throw AnthropicError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any],
                let type = obj["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                    delta["type"] as? String == "text_delta",
                    let text = delta["text"] as? String, !text.isEmpty {
                    await onChunk(text)
                }
            case "error":
                // Mid-stream errors arrive over a 200 response — don't mislabel them
                // as "Claude API error 200".
                let message =
                    (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw AnthropicError.stream(message)
            case "message_stop":
                return
            default:
                break
            }
        }
    }

    /// Pulls `error.message` out of a JSON or SSE error body.
    private static func extractError(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.components(separatedBy: "\n") {
            let chunk = raw.hasPrefix("data:") ? String(raw.dropFirst(5)) : raw
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8))
                as? [String: Any],
                let err = obj["error"] as? [String: Any],
                let message = err["message"] as? String {
                return message
            }
        }
        return nil
    }
}
