// Forge — incremental <think> tag parser for streaming reasoning.
//
// Used only by model-local/legacy streams that expose tagged text instead of a
// structured reasoning channel. It recognizes tags across arbitrary chunk
// boundaries, preserves ordinary bytes, and records malformed structure.

import Foundation

struct ThinkTagParser: Sendable {
    enum InitialState: Sendable {
        case content
        case reasoning
    }

    private enum State {
        case content
        case reasoning
    }

    private enum TagKind {
        case open
        case close
    }

    private let openTag: String
    private let closeTag: String
    private var state: State = .content
    private var buffer = ""

    private(set) var isStructurallyValid = true

    init(
        openTag: String = "<think>", closeTag: String = "</think>",
        initialState: InitialState = .content
    ) {
        precondition(!openTag.isEmpty && !closeTag.isEmpty)
        self.openTag = openTag
        self.closeTag = closeTag
        self.state = initialState == .reasoning ? .reasoning : .content
    }

    /// Feed one streaming delta and return only newly classified text.
    mutating func addContent(_ text: String) -> (reasoning: String, content: String) {
        var working = buffer + text
        buffer.removeAll(keepingCapacity: true)

        var reasoning = ""
        var content = ""
        var shouldContinue = true
        while shouldContinue {
            switch state {
            case .content:
                shouldContinue = scanContent(&working, into: &content)
            case .reasoning:
                shouldContinue = scanReasoning(&working, into: &reasoning)
            }
        }
        buffer = working
        return (reasoning, content)
    }

    /// Flush a possible partial-tag suffix at end of stream. A partial tag is
    /// ordinary text; only a complete parser control tag is stripped.
    mutating func finalize() -> (reasoning: String, content: String) {
        defer { buffer.removeAll(keepingCapacity: true) }
        switch state {
        case .content:
            return ("", buffer)
        case .reasoning:
            isStructurallyValid = false
            return (buffer, "")
        }
    }

    private mutating func scanContent(
        _ working: inout String,
        into content: inout String
    ) -> Bool {
        if let tag = firstCompleteTag(in: working) {
            content += String(working[..<tag.range.lowerBound])
            working = String(working[tag.range.upperBound...])
            switch tag.kind {
            case .open:
                state = .reasoning
            case .close:
                // An unmatched closer is malformed, but its surrounding prose
                // remains inspectable as visible content.
                isStructurallyValid = false
            }
            return true
        }

        emitStablePrefix(from: &working, into: &content)
        return false
    }

    private mutating func scanReasoning(
        _ working: inout String,
        into reasoning: inout String
    ) -> Bool {
        if let tag = firstCompleteTag(in: working) {
            reasoning += String(working[..<tag.range.lowerBound])
            working = String(working[tag.range.upperBound...])
            switch tag.kind {
            case .open:
                // Nested reasoning blocks are malformed. Strip the control tag
                // and continue collecting so it never reaches the UI literally.
                isStructurallyValid = false
            case .close:
                state = .content
            }
            return true
        }

        emitStablePrefix(from: &working, into: &reasoning)
        return false
    }

    private func firstCompleteTag(
        in text: String
    ) -> (kind: TagKind, range: Range<String.Index>)? {
        let openRange = text.range(of: openTag)
        let closeRange = text.range(of: closeTag)
        switch (openRange, closeRange) {
        case (.none, .none):
            return nil
        case (.some(let range), .none):
            return (.open, range)
        case (.none, .some(let range)):
            return (.close, range)
        case (.some(let openRange), .some(let closeRange)):
            return openRange.lowerBound <= closeRange.lowerBound
                ? (.open, openRange) : (.close, closeRange)
        }
    }

    /// Emit text that cannot become part of a control tag on the next chunk,
    /// retaining only the longest proper tag-prefix suffix in `working`.
    private func emitStablePrefix(
        from working: inout String,
        into output: inout String
    ) {
        let heldLength = max(
            trailingProperPrefixLength(in: working, of: openTag),
            trailingProperPrefixLength(in: working, of: closeTag))
        guard heldLength > 0 else {
            output += working
            working.removeAll(keepingCapacity: true)
            return
        }

        let split = working.index(working.endIndex, offsetBy: -heldLength)
        output += String(working[..<split])
        working = String(working[split...])
    }

    private func trailingProperPrefixLength(in text: String, of tag: String) -> Int {
        let maximum = min(text.count, tag.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            let suffixStart = text.index(text.endIndex, offsetBy: -length)
            let tagEnd = tag.index(tag.startIndex, offsetBy: length)
            if text[suffixStart...] == tag[..<tagEnd] {
                return length
            }
        }
        return 0
    }
}
