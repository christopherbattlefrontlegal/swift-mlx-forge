// Copyright © 2024 Apple Inc.

import Foundation

/// A protocol for tokenizing text into token IDs and decoding token IDs into text.
public protocol Tokenizer: Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?

    var bosToken: String? { get }
    var eosToken: String? { get }
    var unknownToken: String? { get }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
}

/// Tokenizer-owned control sequences for models with a private thinking phase.
///
/// This mirrors MLX LM's tokenizer inference: prefer single-token think or
/// longcat-think markers, then the multi-token channel format.
public struct ThinkingMarkers: Equatable, Sendable {
    public let start: String
    public let end: String
    public let startTokenIDs: [Int]
    public let endTokenIDs: [Int]

    public init(
        start: String, end: String,
        startTokenIDs: [Int], endTokenIDs: [Int]
    ) {
        self.start = start
        self.end = end
        self.startTokenIDs = startTokenIDs
        self.endTokenIDs = endTokenIDs
    }

    /// Determines whether generation starts inside thinking by comparing the
    /// last start/end marker occurrences in the prepared prompt token sequence.
    public func startsInThinking(promptTokenIDs: [Int]) -> Bool {
        guard !startTokenIDs.isEmpty, !endTokenIDs.isEmpty else { return false }
        return promptTokenIDs.lastIndex(of: startTokenIDs)
            > promptTokenIDs.lastIndex(of: endTokenIDs)
    }
}

extension Tokenizer {
    public func encode(text: String) -> [Int] {
        encode(text: text, addSpecialTokens: true)
    }

    public func decode(tokenIds: [Int]) -> String {
        decode(tokenIds: tokenIds, skipSpecialTokens: false)
    }

    public var eosTokenId: Int? {
        guard let eosToken else { return nil }
        return convertTokenToId(eosToken)
    }

    public var unknownTokenId: Int? {
        guard let unknownToken else { return nil }
        return convertTokenToId(unknownToken)
    }

    /// Infers the model's thinking protocol from tokenizer vocabulary, matching
    /// the marker families supported by MLX LM's TokenizerWrapper.
    public var thinkingMarkers: ThinkingMarkers? {
        let singleTokenMarkers = [
            ("<think>", "</think>"),
            ("<longcat_think>", "</longcat_think>"),
        ]
        for (start, end) in singleTokenMarkers {
            if let startTokenID = convertTokenToId(start),
                let endTokenID = convertTokenToId(end)
            {
                return ThinkingMarkers(
                    start: start, end: end,
                    startTokenIDs: [startTokenID], endTokenIDs: [endTokenID])
            }
        }

        if convertTokenToId("<|channel>") != nil,
            convertTokenToId("<channel|>") != nil
        {
            let start = "<|channel>thought"
            let end = "<channel|>"
            let startTokenIDs = encode(text: start, addSpecialTokens: false)
            let endTokenIDs = encode(text: end, addSpecialTokens: false)
            guard !startTokenIDs.isEmpty, !endTokenIDs.isEmpty else { return nil }
            return ThinkingMarkers(
                start: start, end: end,
                startTokenIDs: startTokenIDs, endTokenIDs: endTokenIDs)
        }

        return nil
    }

    public func applyChatTemplate(
        messages: [[String: any Sendable]]
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
    }

    public func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: tools, additionalContext: nil)
    }
}

private extension Array where Element: Equatable {
    func lastIndex(of sequence: [Element]) -> Int {
        guard !sequence.isEmpty, sequence.count <= count else { return -1 }
        for start in stride(from: count - sequence.count, through: 0, by: -1) {
            if self[start..<(start + sequence.count)].elementsEqual(sequence) {
                return start
            }
        }
        return -1
    }
}

public enum TokenizerError: LocalizedError {
    case missingChatTemplate

    public var errorDescription: String? {
        switch self {
        case .missingChatTemplate:
            "This tokenizer does not have a chat template."
        }
    }
}

public protocol StreamingDetokenizer: IteratorProtocol<String> {
    mutating func append(token: Int)
}

public struct NaiveStreamingDetokenizer: StreamingDetokenizer {
    let tokenizer: any Tokenizer

    var segmentTokens = [Int]()
    var segment = ""

    public init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
    }

    public mutating func append(token: Int) {
        segmentTokens.append(token)
    }

    mutating func startNewSegment() {
        let lastToken = segmentTokens.last
        segmentTokens.removeAll()
        if let lastToken {
            segmentTokens.append(lastToken)
            segment = tokenizer.decode(tokenIds: segmentTokens)
        } else {
            segment = ""
        }
    }

    public mutating func next() -> String? {
        let newSegment = tokenizer.decode(tokenIds: segmentTokens)
        let new = newSegment.suffix(newSegment.count - segment.count)

        // if the new segment ends with REPLACEMENT CHARACTER this means
        // that the token didn't produce a complete unicode character
        if new.last == "\u{fffd}" {
            return nil
        }

        if new.hasSuffix("\n") {
            startNewSegment()
        } else {
            self.segment = newSegment
        }

        return String(new)
    }
}
