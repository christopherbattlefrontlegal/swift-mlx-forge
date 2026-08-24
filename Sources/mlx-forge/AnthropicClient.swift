// Forge — Anthropic (Claude API) streaming client.
//
// Pure-Swift, raw HTTPS against POST /v1/messages — there is no official
// Anthropic Swift SDK, so this speaks the wire protocol directly via URLSession.
// App-Store-safe: it's just an outbound TLS request (network.client entitlement).
//
// Reasoning uses adaptive thinking + effort (not deprecated budget_tokens).
// See: https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking
//      https://platform.claude.com/docs/en/build-with-claude/effort

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

enum AnthropicEffort: String, CaseIterable, Identifiable, Codable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High (default)"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

struct AnthropicStreamConfig: Equatable {
    var reasoningEnabled: Bool = true
    var effort: AnthropicEffort = .high
    /// Opus 4.8+ default to omitted thinking text — set true to show summarized reasoning.
    var thinkingSummarized: Bool = true
    var maxTokens: Int = 8192
}

struct AnthropicClient {
    struct Message {
        let role: String  // "user" | "assistant"
        let text: String
        var images: [Data] = []
    }

    /// Sniffs PNG/JPEG/GIF/WebP magic bytes (Claude's accepted image types).
    static func imageMediaType(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count > 11, data[8...11].elementsEqual("WEBP".utf8) { return "image/webp" }
        return "image/png"
    }

    /// Text-only messages stay plain strings; image turns become content blocks.
    static func messagePayload(_ message: Message) -> [String: Any] {
        guard !message.images.isEmpty else {
            return ["role": message.role, "content": message.text]
        }
        var blocks: [[String: Any]] = message.images.map { data in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageMediaType(data),
                    "data": data.base64EncodedString(),
                ] as [String: Any],
            ]
        }
        blocks.append(["type": "text", "text": message.text])
        return ["role": message.role, "content": blocks]
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

    /// Models that accept `thinking: {type: "adaptive"}` and `output_config.effort`.
    static func supportsAdaptiveThinking(model: String) -> Bool {
        model.contains("opus-4-")
            || model.contains("sonnet-4-6")
            || model.contains("fable-5")
    }

    /// Models where thinking text is omitted unless `display: "summarized"` is set.
    static func thinkingTextOptInRequired(model: String) -> Bool {
        model.contains("opus-4-8")
            || model.contains("opus-4-7")
            || model.contains("fable-5")
    }

    static func supportsEffort(_ effort: AnthropicEffort, model: String) -> Bool {
        switch effort {
        case .max:
            return model.contains("opus-4-") || model.contains("sonnet-4-6")
                || model.contains("fable-5")
        case .xhigh:
            return model.contains("opus-4-") || model.contains("fable-5")
        case .low, .medium, .high:
            return supportsAdaptiveThinking(model: model)
        }
    }

    var apiKey: String

    /// Streams a chat completion with provider-native reasoning and content channels.
    func stream(
        model: String,
        system: String?,
        messages: [Message],
        config: AnthropicStreamConfig = AnthropicStreamConfig(),
        tools: [MCPToolBinding] = [],
        onChunk: @escaping @MainActor (InferenceStreamDelta) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicError.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        // Long adaptive-thinking turns can go quiet between SSE events; the 60s
        // URLSession default aborts them mid-reasoning.
        request.timeoutInterval = 1800
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": config.maxTokens,
            "stream": true,
            "messages": messages.map(Self.messagePayload),
        ]
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { binding in
                [
                    "name": binding.nativeToolName,
                    "description": binding.tool.description,
                    "input_schema": binding.inputSchemaObject,
                ] as [String: Any]
            }
        }

        if config.reasoningEnabled && Self.supportsAdaptiveThinking(model: model) {
            var thinking: [String: Any] = ["type": "adaptive"]
            if config.thinkingSummarized || Self.thinkingTextOptInRequired(model: model) {
                thinking["display"] = "summarized"
            }
            body["thinking"] = thinking
            let effort = config.effort
            if Self.supportsEffort(effort, model: model) {
                body["output_config"] = ["effort": effort.rawValue]
            }
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
            throw AnthropicError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        // Native tool_use accumulation: index → (nativeName, partial JSON input).
        var toolCalls: [Int: (name: String, json: String)] = [:]
        var stopReason: String?

        func sentinelTail() -> String? {
            // Bridge the first native tool call into the FORGE_MCP_CALL sentinel the
            // existing MCP round-trip machinery parses out of the message text.
            guard let call = toolCalls.sorted(by: { $0.key < $1.key }).first?.value,
                let binding = tools.first(where: { $0.nativeToolName == call.name })
            else {
                if stopReason == "max_tokens" {
                    return
                        "\n\n⚠️ Output hit the max-token limit (\(config.maxTokens)) — raise Max Tokens in Tuning so reasoning can finish."
                }
                return nil
            }
            let arguments = call.json.isEmpty ? "{}" : call.json
            return
                "\nFORGE_MCP_CALL {\"server\":\"\(binding.serverID)\",\"tool\":\"\(binding.tool.name)\",\"arguments\":\(arguments)}"
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
            case "content_block_start":
                if let block = obj["content_block"] as? [String: Any] {
                    if block["type"] as? String == "tool_use",
                        let name = block["name"] as? String,
                        let index = obj["index"] as? Int {
                        toolCalls[index] = (name: name, json: "")
                    }
                }
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                    let deltaType = delta["type"] as? String {
                    if deltaType == "thinking_delta",
                        let text = delta["thinking"] as? String, !text.isEmpty {
                        await onChunk(.reasoning(text))
                    } else if deltaType == "text_delta",
                        let text = delta["text"] as? String, !text.isEmpty {
                        await onChunk(.content(text))
                    } else if deltaType == "input_json_delta",
                        let fragment = delta["partial_json"] as? String,
                        let index = obj["index"] as? Int,
                        var call = toolCalls[index] {
                        call.json += fragment
                        toolCalls[index] = call
                    }
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                    let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "error":
                let message =
                    (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw AnthropicError.stream(message)
            case "message_stop":
                if let tail = sentinelTail() {
                    await onChunk(.content(tail))
                }
                return
            default:
                break
            }
        }
        if let tail = sentinelTail() {
            await onChunk(.content(tail))
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
