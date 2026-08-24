import XCTest
import MLXLMCommon

@testable import mlx_forge

/// Covers the text-based prompt-state fallback used when a model's tokenizer
/// exposes no dedicated `<think>` marker tokens (common in community
/// conversions whose templates open the tag as plain text).
final class ReasoningStreamContextTests: XCTestCase {

    func testTailWithOpenThinkTagStartsInReasoning() {
        let context = ReasoningStreamContext.fromPromptTailText(
            "<|im_start|>assistant\n<think>\n")
        XCTAssertEqual(context?.format, .think)
        XCTAssertEqual(context?.startsInReasoning, true)
    }

    func testTailWithClosedEmptyThinkBlockStartsInContent() {
        let context = ReasoningStreamContext.fromPromptTailText(
            "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        XCTAssertEqual(context?.format, .think)
        XCTAssertEqual(context?.startsInReasoning, false)
    }

    func testTailWithoutThinkTagsHasNoContext() {
        XCTAssertNil(
            ReasoningStreamContext.fromPromptTailText("<|im_start|>assistant\n"))
    }

    func testLongcatTailDetected() {
        let context = ReasoningStreamContext.fromPromptTailText(
            "assistant\n<longcat_think>\n")
        XCTAssertEqual(context?.format, .longcatThink)
        XCTAssertEqual(context?.startsInReasoning, true)
    }

    func testSnapshotFallsBackToTailTextWhenMarkersMissing() {
        let snapshot = RenderedPromptSnapshot(
            tokenIDs: [1, 2, 3], thinkingMarkers: nil,
            promptTailText: "<|im_start|>assistant\n<think>\n")
        XCTAssertEqual(snapshot.reasoningContext.format, .think)
        XCTAssertTrue(snapshot.reasoningContext.startsInReasoning)
    }

    func testSnapshotPrefersTokenMarkersWhenPresent() {
        // Marker IDs present but absent from the prompt: token rule applies
        // (not in reasoning) and the tail text must not override it.
        let markers = ThinkingMarkers(
            start: "<think>", end: "</think>",
            startTokenIDs: [100], endTokenIDs: [101])
        let snapshot = RenderedPromptSnapshot(
            tokenIDs: [1, 2, 3], thinkingMarkers: markers,
            promptTailText: "<think>\n")
        XCTAssertFalse(snapshot.reasoningContext.startsInReasoning)
    }

    func testSnapshotWithoutTailDefaultsToTaggedThink() {
        let snapshot = RenderedPromptSnapshot(tokenIDs: [], thinkingMarkers: nil)
        XCTAssertEqual(snapshot.reasoningContext, .taggedThink)
    }
}
