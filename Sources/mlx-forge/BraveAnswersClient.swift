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

struct BraveCitation: Codable, Equatable, Sendable {
    let startIndex: Int
    let endIndex: Int
    let number: Int
    let url: String
    let favicon: String?
    let snippet: String?
}

struct BraveSearchUsage: Codable, Equatable, Sendable {
    var requests: Int?
    var queries: Int?
    var tokensIn: Int?
    var tokensOut: Int?
    var totalCost: Double?
}

struct BraveAnswersClient {
    var apiKey: String
    var config: BraveSearchConfig = BraveSearchConfig()
    var session: URLSession = .shared

    func stream(
        query: String,
        history: [ChatMessage] = [],
        onChunk: @escaping @MainActor (InferenceStreamDelta) -> Void,
        onCitation: (@MainActor (BraveCitation) -> Void)? = nil,
        onUsage: (@MainActor (BraveSearchUsage) -> Void)? = nil,
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let request = try makeRequest(query: query, history: history)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw BraveAnswersError.http(status, Self.extractError(from: data) ?? "request failed")
        }

        @MainActor func deliver(_ events: [BraveAnswerEvent]) {
            for event in events {
                switch event {
                case .content(let text): onChunk(.content(text))
                case .status(let status): onStatus?(status)
                case .citation(let citation): onCitation?(citation)
                case .usage(let usage): onUsage?(usage)
                }
            }
        }

        var parser = BraveAnswerStreamParser(research: config.enableResearch)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            await deliver(try parser.ingest(line: line))
            if parser.isDone { break }
        }
        try Task.checkCancellation()
        await deliver(try parser.finish())
    }

    func makeRequest(query: String, history: [ChatMessage] = []) throws -> URLRequest {
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
                ["role": "user", "content": Self.contextualQuery(trimmed, history: history)]
            ],
            "country": config.country,
            "language": config.language,
            "enable_entities": config.enableEntities && !config.enableResearch,
            "enable_research": config.enableResearch,
        ]
        if !config.enableResearch {
            body["enable_citations"] = config.enableCitations
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Brave accepts exactly one user message. Include the conversation as
    /// context inside it so requests such as "give me that in paragraphs" keep
    /// their subject. Exclude reasoning, errors, and internal status messages.
    private static func contextualQuery(_ query: String, history: [ChatMessage]) -> String {
        let turns = history.compactMap { message -> String? in
            guard message.role != .system, message.isModelReplayable else { return nil }
            var text = message.modelVisibleContent
            if message.role == .assistant,
                message.modelName?.hasPrefix("Brave Search") == true,
                text.contains("<answer>") || text.contains("<queries>")
            {
                text = cleanedResearchAnswer(text)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "\(message.role == .user ? "User" : "Assistant"): \(text)"
        }
        guard !turns.isEmpty else { return query }
        return """
            Previous conversation for context:
            \(turns.joined(separator: "\n\n"))

            Answer the current request using the context above:
            \(query)
            """
    }

    /// Decode old saved Research responses with the same protocol parser used
    /// for live requests; keep the final answer and discard progress metadata.
    static func cleanedResearchAnswer(_ raw: String) -> String {
        var parser = BraveAnswerStreamParser(research: true)
        do {
            _ = try parser.ingest(content: raw)
            return try parser.finishContent().compactMap { event in
                if case .content(let text) = event { return text }
                return nil
            }.joined()
        } catch {
            return ""
        }
    }

    /// Compatibility with older responses that emitted untagged writer drafts.
    static func cleanedPlainResearchAnswer(_ raw: String) -> String {
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
