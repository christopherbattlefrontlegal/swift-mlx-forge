// Forge — OpenAI Responses API streaming client.
//
// Reasoning models use POST /v1/responses with reasoning.effort + reasoning.summary.
// https://developers.openai.com/api/docs/guides/reasoning

import Foundation

enum OpenAIError: LocalizedError {
    case noKey
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No OpenAI API key set — add one in Settings (⌘,)."
        case .http(let code, let message):
            return "OpenAI API error \(code): \(message)"
        case .stream(let message):
            return "OpenAI stream error: \(message)"
        }
    }
}

/// OpenAI reasoning.effort values per https://developers.openai.com/api/docs/guides/reasoning
enum OpenAIReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case none, minimal, low, medium, high, xhigh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium (GPT-5.5 default)"
        case .high: return "High"
        case .xhigh: return "Extra high"
        }
    }
}

struct OpenAIStreamConfig: Equatable {
    var reasoningEnabled: Bool = true
    var effort: OpenAIReasoningEffort = .medium
    /// Request reasoning summaries in the stream (reasoning.summary: auto).
    var reasoningSummary: Bool = true
    var maxOutputTokens: Int = 16384
}

struct OpenAIClient {
    struct Turn {
        let role: String  // "user" | "assistant"
        let text: String
    }

    static let models: [(id: String, label: String)] = [
        ("gpt-5.5", "GPT-5.5"),
        ("gpt-5.5-pro", "GPT-5.5 Pro"),
        ("gpt-5.4", "GPT-5.4"),
        ("gpt-5.4-mini", "GPT-5.4 Mini"),
        ("o4-mini", "o4-mini"),
        ("o3", "o3"),
    ]

    static func label(for id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }

    var apiKey: String

    /// Streams a Responses API turn. Reasoning summary deltas are wrapped in ``.
    func stream(
        model: String,
        system: String?,
        turns: [Turn],
        config: OpenAIStreamConfig = OpenAIStreamConfig(),
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw OpenAIError.noKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input: [[String: Any]] = turns.map {
            ["role": $0.role, "content": $0.text]
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
            "max_output_tokens": config.maxOutputTokens,
        ]
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = system
        }
        if config.reasoningEnabled && config.effort != .none {
            var reasoning: [String: Any] = ["effort": config.effort.rawValue]
            if config.reasoningSummary {
                reasoning["summary"] = "auto"
            }
            body["reasoning"] = reasoning
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 64_000 { break }
            }
            throw OpenAIError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        var assembler = OpenAIReasoningStreamAssembler()

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

            if type == "error" {
                let message = (obj["message"] as? String) ?? "stream error"
                throw OpenAIError.stream(message)
            }

            if let chunk = assembler.ingest(eventType: type, payload: obj) {
                await onChunk(chunk)
            }
            if type == "response.completed" || type == "response.failed" {
                if let tail = assembler.finish() {
                    await onChunk(tail)
                }
                return
            }
        }
        if let tail = assembler.finish() {
            await onChunk(tail)
        }
    }

    private static func extractError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        return (obj["message"] as? String) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Maps OpenAI Responses SSE events into `` + answer text for the chat UI.
private struct OpenAIReasoningStreamAssembler {
    private var thinkingOpen = false
    private var thinkingClosed = false

    mutating func ingest(eventType: String, payload: [String: Any]) -> String? {
        switch eventType {
        case "response.reasoning_summary_part.added",
            "response.reasoning_summary_text.delta",
            "response.reasoning.delta":
            if let delta = payload["delta"] as? String, !delta.isEmpty {
                return appendThinking(delta)
            }
            if let summary = payload["summary"] as? String, !summary.isEmpty {
                return appendThinking(summary)
            }
            if let part = payload["part"] as? [String: Any],
                let text = part["text"] as? String, !text.isEmpty {
                return appendThinking(text)
            }
        case "response.output_text.delta", "response.content_part.delta":
            if let delta = payload["delta"] as? String, !delta.isEmpty {
                var out = closeThinkingIfNeeded() ?? ""
                out += delta
                return out.isEmpty ? nil : out
            }
            if let part = payload["part"] as? [String: Any],
                part["type"] as? String == "output_text",
                let text = part["text"] as? String, !text.isEmpty {
                var out = closeThinkingIfNeeded() ?? ""
                out += text
                return out.isEmpty ? nil : out
            }
        default:
            break
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