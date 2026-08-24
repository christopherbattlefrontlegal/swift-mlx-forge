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
        onChunk: @escaping @MainActor (InferenceStreamDelta) -> Void,
        onCitation: (@MainActor (BraveCitation) -> Void)? = nil,
        onUsage: (@MainActor (BraveSearchUsage) -> Void)? = nil
    ) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw BraveAnswersError.noKey }
        guard !trimmed.isEmpty else { throw BraveAnswersError.emptyQuery }

        var request = URLRequest(url: URL(string: "https://api.search.brave.com/res/v1/chat/completions")!)
        request.httpMethod = "POST"
        // Brave Research can spend more than URLRequest's default timeout
        // gathering sources before it emits the next SSE event. Match Forge's
        // other long-running cloud streams so a normal research pause is not
        // reported as a failed request.
        request.timeoutInterval = 1800
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-subscription-token")

        // Research mode rejects enable_citations (Brave API validation 422).
        var body: [String: Any] = [
            "model": "brave",
            "stream": true,
            "messages": [
                ["role": "user", "content": trimmed]
            ],
            "country": config.country,
            "language": config.language,
            "enable_entities": config.enableEntities,
            "enable_research": config.enableResearch,
        ]
        if !config.enableResearch {
            body["enable_citations"] = config.enableCitations
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
            await onChunk(.content(text))
        }

        if !deliveredText {
            throw BraveAnswersError.emptyAnswer
        }
    }

    /// Research mode may emit an intermediate writer draft, then repeat or
    /// revise that draft before the final answer. Unlike ordinary Answers
    /// mode, Forge buffers Research output and runs it through this cleanup so
    /// internal drafting notes and superseded answers never become the saved
    /// assistant response.
    static func cleanedResearchAnswer(_ raw: String) -> String {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [String] = []
        var lines: [String] = []

        func flushLines() {
            let block = lines
                .filter { !isResearchPlanningLeak($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { blocks.append(block) }
            lines.removeAll(keepingCapacity: true)
        }

        var sawDraftSignal = false
        for line in normalizedNewlines.components(separatedBy: "\n") {
            if isResearchPlanningLeak(line) {
                sawDraftSignal = true
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushLines()
            } else {
                lines.append(line)
            }
        }
        flushLines()

        var result: [String] = []
        for block in blocks {
            let canonical = canonicalResearchBlock(block)
            if let exact = result.firstIndex(where: {
                canonicalResearchBlock($0) == canonical
            }) {
                // A byte-for-byte repeated answer is a strong signal that the
                // Research writer is emitting candidates rather than sections.
                sawDraftSignal = true
                result[exact] = block
                continue
            }

            let threshold = sawDraftSignal ? 0.45 : 0.82
            if researchWordSet(block).count >= 20,
               let revision = result.indices.last(where: { index in
                   researchWordSet(result[index]).count >= 20
                       && researchSimilarity(result[index], block) >= threshold
               })
            {
                result[revision] = block
            } else {
                result.append(block)
            }
        }
        return result.joined(separator: "\n\n")
    }

    private static func isResearchPlanningLeak(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        return value.contains("i will output")
            || value.contains("i'll output")
            || value.contains("i will now write")
            || value.contains("i'll now write")
            || value.contains("this covers all bases")
            || value.contains(".writer")
    }

    private static func canonicalResearchBlock(_ block: String) -> String {
        block.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func researchWordSet(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "and", "are", "but", "for", "from", "has", "have", "into", "its",
            "not", "that", "the", "their", "these", "this", "through", "using",
            "was", "were", "while", "with"
        ]
        return Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    private static func researchSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = researchWordSet(lhs)
        let right = researchWordSet(rhs)
        let denominator = min(left.count, right.count)
        guard denominator > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(denominator)
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
