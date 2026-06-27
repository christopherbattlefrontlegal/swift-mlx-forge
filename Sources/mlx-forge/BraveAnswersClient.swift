// Forge — Brave Search Answers API (web-grounded research chat).
// https://api.search.brave.com/res/v1/chat/completions

import Foundation

enum BraveAnswersError: LocalizedError {
    case noKey
    case emptyQuery
    case http(Int, String)
    case stream(String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Brave Search API key set — add one in Settings (Cloud APIs)."
        case .emptyQuery:
            return "empty query"
        case .http(let code, let message):
            return "Brave Answers API error \(code): \(message)"
        case .stream(let message):
            return "Brave Answers stream error: \(message)"
        case .emptyAnswer:
            return "empty answer response"
        }
    }
}

struct BraveSearchConfig: Codable, Equatable {
    var country: String = "us"
    var language: String = "en"
    var enableCitations: Bool = true
    var enableEntities: Bool = false
    var enableResearch: Bool = false
}

struct BraveCitation: Codable, Equatable {
    let startIndex: Int
    let endIndex: Int
    let number: Int
    let url: String
    let favicon: String?
    let snippet: String?
}

struct BraveSearchUsage: Codable, Equatable {
    var requests: Int?
    var queries: Int?
    var tokensIn: Int?
    var tokensOut: Int?
    var totalCost: Double?
}

struct BraveAnswersClient {
    var apiKey: String
    var config: BraveSearchConfig = BraveSearchConfig()

    func stream(
        query: String,
        onChunk: @escaping @MainActor (String) -> Void,
        onCitation: (@MainActor (BraveCitation) -> Void)? = nil,
        onUsage: (@MainActor (BraveSearchUsage) -> Void)? = nil
    ) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw BraveAnswersError.noKey }
        guard !trimmed.isEmpty else { throw BraveAnswersError.emptyQuery }

        var request = URLRequest(url: URL(string: "https://api.search.brave.com/res/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-subscription-token")

        let body: [String: Any] = [
            "model": "brave",
            "stream": true,
            "messages": [
                ["role": "user", "content": trimmed]
            ],
            "country": config.country,
            "language": config.language,
            "enable_citations": config.enableCitations,
            "enable_entities": config.enableEntities,
            "enable_research": config.enableResearch,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw BraveAnswersError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        var deliveredText = false
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
                throw BraveAnswersError.stream((error["message"] as? String) ?? "stream error")
            }
            guard
                let choices = obj["choices"] as? [[String: Any]],
                let first = choices.first,
                let delta = first["delta"] as? [String: Any],
                let text = delta["content"] as? String,
                !text.isEmpty
            else { continue }

            if let citation = Self.parseCitationTag(text) {
                await onCitation?(citation)
                continue
            }
            if let usage = Self.parseUsageTag(text) {
                await onUsage?(usage)
                continue
            }
            if text.hasPrefix("<enum_item>") { continue }

            deliveredText = true
            await onChunk(text)
        }

        if !deliveredText {
            throw BraveAnswersError.emptyAnswer
        }
    }

    private static func parseCitationTag(_ text: String) -> BraveCitation? {
        guard text.hasPrefix("<citation>"), text.hasSuffix("</citation>") else { return nil }
        let json = text.dropFirst("<citation>".count).dropLast("</citation>".count)
        guard let data = String(json).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BraveCitation.self, from: data)
    }

    private static func parseUsageTag(_ text: String) -> BraveSearchUsage? {
        guard text.hasPrefix("<usage>"), text.hasSuffix("</usage>") else { return nil }
        let json = text.dropFirst("<usage>".count).dropLast("</usage>".count)
        guard
            let data = String(json).data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return BraveSearchUsage(
            requests: raw["X-Request-Requests"] as? Int,
            queries: raw["X-Request-Queries"] as? Int,
            tokensIn: raw["X-Request-Tokens-In"] as? Int,
            tokensOut: raw["X-Request-Tokens-Out"] as? Int,
            totalCost: raw["X-Request-Total-Cost"] as? Double)
    }

    private static func extractError(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(decoding: data, as: UTF8.self) }
        if let error = obj["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        return (obj["message"] as? String) ?? String(decoding: data, as: UTF8.self)
    }
}