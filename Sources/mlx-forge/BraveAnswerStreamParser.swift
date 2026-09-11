// Brave wraps research answers and metadata in tagged JSON inside SSE content.
import Foundation

enum BraveAnswerEvent: Equatable, Sendable {
    case content(String)
    case status(String)
    case citation(BraveCitation)
    case usage(BraveSearchUsage)
}

struct BraveAnswerStreamParser {
    let research: Bool
    private var pending = ""
    private var plainResearchText = ""
    private var latestAnswer: String?
    private var sourceURLs: [String] = []
    private var sawResearchEvent = false
    private var deliveredText = false
    private var receivedFinish = false
    private(set) var isDone = false

    private static let researchTags = [
        "queries", "analyzing", "thinking", "blindspots", "progress", "answer",
    ]
    private static let tags = researchTags + ["citation", "usage", "enum_item"]

    mutating func ingest(line: String) throws -> [BraveAnswerEvent] {
        guard !isDone, line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" {
            isDone = true
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
            as? [String: Any]
        else { throw BraveAnswersError.stream("Invalid JSON in the response stream.") }
        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String
                ?? (error as? String) ?? "Request failed."
            throw BraveAnswersError.stream(message)
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else {
                throw BraveAnswersError.stream("Answer interrupted (\(reason)).")
            }
            receivedFinish = true
        }
        guard let delta = choice["delta"] as? [String: Any],
            let text = delta["content"] as? String
        else { return [] }
        return try ingest(content: text)
    }

    mutating func finish() throws -> [BraveAnswerEvent] {
        guard isDone || receivedFinish else {
            throw BraveAnswersError.stream("Connection closed before the answer finished.")
        }
        return try finishContent()
    }

    // Also used to decode tagged answers saved by older Forge versions.
    mutating func ingest(content: String) throws -> [BraveAnswerEvent] {
        pending += content
        var events: [BraveAnswerEvent] = []
        while !pending.isEmpty {
            guard let start = pending.firstIndex(of: "<") else {
                emitText(pending, into: &events)
                pending = ""
                break
            }
            if start != pending.startIndex {
                emitText(String(pending[..<start]), into: &events)
                pending = String(pending[start...])
            }
            guard let tag = Self.tags.first(where: { pending.hasPrefix("<\($0)>") }) else {
                // An opening tag can straddle any number of SSE chunks. Ordinary
                // HTML and comparisons remain answer text.
                if Self.tags.contains(where: { "<\($0)>".hasPrefix(pending) }) { break }
                emitText("<", into: &events)
                pending.removeFirst()
                continue
            }
            let bodyStart = pending.index(pending.startIndex, offsetBy: tag.count + 2)
            guard let close = Self.closingTag(tag, in: pending, from: bodyStart) else { break }
            let body = String(pending[bodyStart..<close.lowerBound])
            events += try decode(tag: tag, body: body)
            pending = String(pending[close.upperBound...])
        }
        return events
    }

    mutating func finishContent() throws -> [BraveAnswerEvent] {
        var events: [BraveAnswerEvent] = []
        if pending == "<" {
            emitText(pending, into: &events)
            pending = ""
        }
        guard pending.isEmpty else {
            throw BraveAnswersError.stream("Incomplete tagged response from Brave.")
        }
        if research {
            // A structured answer is authoritative. Progress, planning events,
            // and superseded drafts cannot stand in for a completed answer.
            let answer = latestAnswer ?? (sawResearchEvent ? ""
                : BraveAnswersClient.cleanedPlainResearchAnswer(plainResearchText))
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BraveAnswersError.emptyAnswer
            }
            // Research mode does not support inline citation events. Its source
            // selections still belong with the answer when the writer omits
            // links. Label these as reviewed sources, not claim-level citations.
            let sources = sourceURLs.filter { !answer.contains($0) }
            let footer = sources.isEmpty ? "" : "\n\n**Sources reviewed**\n"
                + sources.map { "- <\($0)>" }.joined(separator: "\n")
            return [.content(answer + footer)]
        }
        guard deliveredText else { throw BraveAnswersError.emptyAnswer }
        return events
    }

    private mutating func emitText(_ text: String, into events: inout [BraveAnswerEvent]) {
        if research {
            plainResearchText += text
        } else if !text.isEmpty {
            deliveredText = deliveredText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            events.append(.content(text))
        }
    }

    private mutating func decode(tag: String, body: String) throws -> [BraveAnswerEvent] {
        if tag == "enum_item" { return [] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            throw BraveAnswersError.stream("Invalid \(tag) event from Brave.")
        }
        let object = value as? [String: Any] ?? [:]
        if Self.researchTags.contains(tag) { sawResearchEvent = true }
        switch tag {
        case "answer":
            guard let answer = object["answer"] as? String,
                !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw BraveAnswersError.emptyAnswer }
            if research {
                latestAnswer = answer
                return [.status("Brave has finished the answer…")]
            }
            deliveredText = true
            return [.content(answer)]
        case "queries":
            return [.status("Brave is searching the web…")]
        case "analyzing":
            return [.status("Brave is reading sources…")]
        case "thinking":
            for rawURL in object["urls_selected"] as? [String] ?? [] {
                guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
                    ["https", "http"].contains(scheme), url.host != nil
                else { continue }
                let value = url.absoluteString
                if !sourceURLs.contains(value) { sourceURLs.append(value) }
            }
            return [.status("Brave is evaluating sources…")]
        case "blindspots":
            return [.status("Brave is checking gaps in the research…")]
        case "progress":
            guard latestAnswer == nil else { return [] }
            if let queries = object["number_of_queries"] as? Int,
                let sources = object["number_of_urls_analyzed"] as? Int
            {
                return [.status("Brave is researching… \(queries) searches · \(sources) sources reviewed")]
            }
            return [.status("Brave is researching…")]
        case "citation":
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let citation = try? decoder.decode(BraveCitation.self, from: Data(body.utf8)) else {
                throw BraveAnswersError.stream("Invalid citation from Brave.")
            }
            return [.citation(citation)]
        case "usage":
            return [.usage(BraveSearchUsage(
                requests: object["X-Request-Requests"] as? Int,
                queries: object["X-Request-Queries"] as? Int,
                tokensIn: object["X-Request-Tokens-In"] as? Int,
                tokensOut: object["X-Request-Tokens-Out"] as? Int,
                totalCost: object["X-Request-Total-Cost"] as? Double))]
        default:
            return []
        }
    }

    /// A literal closing tag inside a JSON string is part of the answer, not
    /// the end of the event. Respect escaped quotes and backslashes too.
    private static func closingTag(
        _ tag: String, in text: String, from start: String.Index
    ) -> Range<String.Index>? {
        var quoted = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "<", text[index...].hasPrefix("</\(tag)>") {
                return index..<text.index(index, offsetBy: tag.count + 3)
            }
            index = text.index(after: index)
        }
        return nil
    }
}
