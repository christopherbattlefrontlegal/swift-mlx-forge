// Forge — incremental <think> tag parser for streaming reasoning.
//
// Every backend (local MLX, GGUF, Anthropic, OpenAI, OpenRouter) funnels
// reasoning through the same onChunk text stream wrapped in <think>…</think>.
// This stateful parser splits each incoming delta into (reasoning, content)
// *as it arrives*, so the UI can render a live reasoning block the moment the
// first reasoning token lands — instead of re-parsing one growing blob and
// waiting for </think> before anything classifies.
//
// Ported from AgentRunKit's ThinkTagParser (swift_mlx_research). Handles a
// tag that is split across two deltas (e.g. "<thi" then "nk>") via overlap
// buffering, and trims the whitespace bookending the tag.

import Foundation

struct ThinkTagParser: Sendable {
    private enum State {
        case lookingForOpen
        case eatingOpenWhitespace
        case thinking
        case eatingCloseWhitespace
        case content
    }

    private let openTag: String
    private let closeTag: String

    private var state: State = .lookingForOpen
    private var accumulator: String = ""

    init(openTag: String = "<think>", closeTag: String = "</think>") {
        self.openTag = openTag
        self.closeTag = closeTag
    }

    /// Feed a streaming delta; returns the reasoning/content produced by this
    /// delta (either or both may be empty). Call once per chunk.
    mutating func addContent(_ text: String) -> (reasoning: String, content: String) {
        accumulator += text
        var reasoning = ""
        var content = ""
        while eat(&reasoning, &content) {}
        return (reasoning, content)
    }

    /// Flush whatever remains at end-of-stream.
    mutating func finalize() -> (reasoning: String, content: String) {
        switch state {
        case .lookingForOpen:
            let content = accumulator
            accumulator = ""
            return ("", content)
        case .eatingOpenWhitespace:
            accumulator = ""
            return ("", "")
        case .thinking:
            let reasoning = accumulator
            accumulator = ""
            return (reasoning, "")
        case .eatingCloseWhitespace:
            accumulator = ""
            return ("", "")
        case .content:
            return ("", "")
        }
    }

    private mutating func eat(_ reasoning: inout String, _ content: inout String) -> Bool {
        switch state {
        case .lookingForOpen:
            return eatLookingForOpen(&content)
        case .eatingOpenWhitespace:
            return eatOpenWhitespace()
        case .thinking:
            return eatThinking(&reasoning)
        case .eatingCloseWhitespace:
            return eatCloseWhitespace()
        case .content:
            content += accumulator
            accumulator = ""
            return false
        }
    }

    private mutating func eatLookingForOpen(_ content: inout String) -> Bool {
        let trimmed = accumulator.drop(while: { $0.isWhitespace })
        if trimmed.isEmpty {
            return false
        }
        if trimmed.hasPrefix(openTag) {
            let afterTag = trimmed.dropFirst(openTag.count)
            accumulator = String(afterTag)
            state = .eatingOpenWhitespace
            return true
        }
        // Partial open tag split across deltas (e.g. "<thi") — wait for more.
        if openTag.hasPrefix(trimmed) {
            return false
        }
        content += accumulator
        accumulator = ""
        state = .content
        return true
    }

    private mutating func eatOpenWhitespace() -> Bool {
        guard let firstNonWS = accumulator.firstIndex(where: { !$0.isWhitespace }) else {
            accumulator = ""
            return false
        }
        accumulator = String(accumulator[firstNonWS...])
        state = .thinking
        return true
    }

    private mutating func eatThinking(_ reasoning: inout String) -> Bool {
        guard let closeRange = accumulator.range(of: closeTag) else {
            // Hold back any suffix that could be the start of a split close tag.
            let overlapLen = Self.overlap(accumulator, closeTag)
            if overlapLen > 0 {
                let splitIndex = accumulator.index(accumulator.endIndex, offsetBy: -overlapLen)
                reasoning += accumulator[..<splitIndex]
                accumulator = String(accumulator[splitIndex...])
            } else {
                reasoning += accumulator
                accumulator = ""
            }
            return false
        }
        reasoning += accumulator[..<closeRange.lowerBound]
        accumulator = String(accumulator[closeRange.upperBound...])
        state = .eatingCloseWhitespace
        return true
    }

    private mutating func eatCloseWhitespace() -> Bool {
        guard let firstNonWS = accumulator.firstIndex(where: { !$0.isWhitespace }) else {
            accumulator = ""
            return false
        }
        accumulator = String(accumulator[firstNonWS...])
        state = .content
        return true
    }

    /// Longest suffix of `buffer` that is also a prefix of `tag` (split-tag guard).
    private static func overlap(_ buffer: String, _ tag: String) -> Int {
        let bufChars = Array(buffer)
        let tagChars = Array(tag)
        let maxPossible = min(bufChars.count, tagChars.count)
        for length in stride(from: maxPossible, through: 1, by: -1) {
            let suffix = bufChars[(bufChars.count - length)...]
            let prefix = tagChars[..<length]
            if suffix.elementsEqual(prefix) {
                return length
            }
        }
        return 0
    }
}
