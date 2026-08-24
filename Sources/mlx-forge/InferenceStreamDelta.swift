// Forge — typed inference stream boundary.
//
// Backends classify private reasoning before emitting a delta. Tagged text is
// retained only as an explicit compatibility path for legacy/untyped streams.

import Foundation
import MLXLMCommon

enum InferenceStreamDelta: Equatable, Sendable {
    case reasoning(String)
    case content(String)
    case invalidReasoningStructure
}

struct ReasoningTagFormat: Equatable, Hashable, Sendable {
    let openTag: String
    let closeTag: String

    static let think = ReasoningTagFormat(openTag: "<think>", closeTag: "</think>")
    static let longcatThink = ReasoningTagFormat(
        openTag: "<longcat_think>", closeTag: "</longcat_think>")
    static let thoughtChannel = ReasoningTagFormat(
        openTag: "<|channel>thought", closeTag: "<channel|>")
}

struct ReasoningStreamContext: Equatable, Hashable, Sendable {
    let format: ReasoningTagFormat
    let startsInReasoning: Bool

    static let taggedThink = ReasoningStreamContext(
        format: .think, startsInReasoning: false)

    /// Mirrors MLX LM's prompt-state rule using the actually prepared tokens:
    /// the last start-marker sequence wins only when it follows the last end.
    static func fromPromptTokenSequence(
        _ promptTokenIDs: [Int],
        format: ReasoningTagFormat,
        startTokenIDs: [Int],
        endTokenIDs: [Int]
    ) -> ReasoningStreamContext {
        let markers = ThinkingMarkers(
            start: format.openTag,
            end: format.closeTag,
            startTokenIDs: startTokenIDs,
            endTokenIDs: endTokenIDs)
        return ReasoningStreamContext(
            format: format,
            startsInReasoning: markers.startsInThinking(promptTokenIDs: promptTokenIDs))
    }

    static func fromPromptTokenSequence(
        _ promptTokenIDs: [Int],
        markers: ThinkingMarkers?
    ) -> ReasoningStreamContext {
        guard let markers else { return .taggedThink }
        return fromPromptTokenSequence(
            promptTokenIDs,
            format: ReasoningTagFormat(
                openTag: markers.start, closeTag: markers.end),
            startTokenIDs: markers.startTokenIDs,
            endTokenIDs: markers.endTokenIDs)
    }
}

/// Converts a model's tagged compatibility stream into typed deltas before it
/// reaches AppState. Structured provider APIs bypass this classifier entirely.
struct ReasoningStreamClassifier: Sendable {
    private var parser: ThinkTagParser
    private var reportedInvalidStructure = false

    init(context: ReasoningStreamContext) {
        parser = ThinkTagParser(
            openTag: context.format.openTag,
            closeTag: context.format.closeTag,
            initialState: context.startsInReasoning ? .reasoning : .content)
    }

    mutating func ingest(_ text: String) -> [InferenceStreamDelta] {
        deltas(from: parser.addContent(text))
    }

    mutating func finalize() -> [InferenceStreamDelta] {
        deltas(from: parser.finalize())
    }

    private mutating func deltas(
        from split: (reasoning: String, content: String)
    ) -> [InferenceStreamDelta] {
        var result: [InferenceStreamDelta] = []
        if !split.reasoning.isEmpty { result.append(.reasoning(split.reasoning)) }
        if !split.content.isEmpty { result.append(.content(split.content)) }
        if !parser.isStructurallyValid, !reportedInvalidStructure {
            reportedInvalidStructure = true
            result.append(.invalidReasoningStructure)
        }
        return result
    }
}

struct RenderedPromptSnapshot: Sendable {
    let tokenIDs: [Int]
    let thinkingMarkers: ThinkingMarkers?

    var reasoningContext: ReasoningStreamContext {
        .fromPromptTokenSequence(tokenIDs, markers: thinkingMarkers)
    }
}

final class RenderedPromptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: RenderedPromptSnapshot?

    func set(_ value: RenderedPromptSnapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func get() -> RenderedPromptSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
