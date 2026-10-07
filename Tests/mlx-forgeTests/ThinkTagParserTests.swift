import XCTest
import MLXLMCommon

@testable import mlx_forge

final class ThinkTagParserTests: XCTestCase {
    func testPlainAnswerText() {
        var parser = ThinkTagParser()

        let split = parser.addContent("Final answer")
        XCTAssertEqual(split.reasoning, "")
        XCTAssertEqual(split.content, "Final answer")
        XCTAssertTrue(parser.isStructurallyValid)

        let tail = parser.finalize()
        XCTAssertEqual(tail.reasoning, "")
        XCTAssertEqual(tail.content, "")
    }

    func testOneBalancedThinkBlock() {
        var parser = ThinkTagParser()

        let prefix = parser.addContent("Here ")
        let split = parser.addContent("<think>private reasoning</think>result")
        let tail = parser.finalize()

        XCTAssertEqual(prefix.reasoning, "")
        XCTAssertEqual(prefix.content, "Here ")
        XCTAssertEqual(split.reasoning, "private reasoning")
        XCTAssertEqual(split.content, "result")
        XCTAssertEqual(tail.reasoning, "")
        XCTAssertEqual(tail.content, "")
        XCTAssertTrue(parser.isStructurallyValid)
    }

    func testSplitOpenAndCloseTagsAtEveryBoundary() {
        let full = "Hi <think>reasoning payload</think> there"
        let expected = parseOnce(full)

        for i in 0...full.count {
            let idx = full.index(full.startIndex, offsetBy: i)
            let firstChunk = String(full[..<idx])
            let secondChunk = String(full[idx...])

            var parser = ThinkTagParser()
            let chunkOne = parser.addContent(firstChunk)
            let chunkTwo = parser.addContent(secondChunk)
            let tail = parser.finalize()

            let reasoning = chunkOne.reasoning + chunkTwo.reasoning + tail.reasoning
            let content = chunkOne.content + chunkTwo.content + tail.content

            XCTAssertEqual(
                parser.isStructurallyValid,
                true,
                "structural validity should stay true for boundary \(i)")
            XCTAssertEqual(
                reasoning,
                expected.reasoning,
                "reasoning mismatch at boundary \(i)")
            XCTAssertEqual(
                content,
                expected.content,
                "content mismatch at boundary \(i)")
        }
    }

    func testTwoReopenedThinkBlocks() {
        var parser = ThinkTagParser()

        let prefix = parser.addContent("Start ")
        let split1 = parser.addContent("<think>first</think> middle ")
        let split2 = parser.addContent("<think>second</think> end")
        let tail = parser.finalize()

        let split1Content = prefix.content + split1.content
        XCTAssertEqual(split1.reasoning, "first")
        XCTAssertEqual(split1Content, "Start  middle ")
        XCTAssertEqual(split2.reasoning, "second")
        XCTAssertEqual(split2.content, " end")
        XCTAssertEqual(tail.reasoning, "")
        XCTAssertEqual(tail.content, "")
    }

    func testUnexpectedExtraCloseTagIsInvalid() {
        var parser = ThinkTagParser()

        let split = parser.addContent("Answer <think>ok</think> leaked </think> tail")
        let tail = parser.finalize()

        XCTAssertFalse(parser.isStructurallyValid)
        let reasoning = split.reasoning + tail.reasoning
        let content = split.content + tail.content
        XCTAssertEqual(reasoning, "ok")
        XCTAssertEqual(content, "Answer  leaked  tail")
        XCTAssertFalse(reasoning.contains("<think>") || reasoning.contains("</think>"))
        XCTAssertFalse(content.contains("<think>") || content.contains("</think>"))
    }

    func testCloseBeforeLaterOpenIsInvalid() {
        var parser = ThinkTagParser()

        let split = parser.addContent(
            "answer </think> then <think>secret</think> tail")
        let tail = parser.finalize()

        XCTAssertFalse(parser.isStructurallyValid)
        XCTAssertEqual(split.reasoning + tail.reasoning, "secret")
        XCTAssertEqual(split.content + tail.content, "answer  then  tail")
    }

    func testNestedOpenIsInvalidAndNeverEmitted() {
        var parser = ThinkTagParser()

        let split = parser.addContent(
            "<think>outer <think> inner</think> answer")
        let tail = parser.finalize()
        let reasoning = split.reasoning + tail.reasoning
        let content = split.content + tail.content

        XCTAssertFalse(parser.isStructurallyValid)
        XCTAssertEqual(reasoning, "outer  inner")
        XCTAssertEqual(content, " answer")
        XCTAssertFalse(reasoning.contains("<think>") || reasoning.contains("</think>"))
        XCTAssertFalse(content.contains("<think>") || content.contains("</think>"))
    }

    func testPartialTagPrefixesArePreservedAtEndOfStream() {
        for tag in ["<think>", "</think>"] {
            for length in 1..<tag.count {
                var parser = ThinkTagParser()
                let prefix = String(tag.prefix(length))
                let split = parser.addContent("answer " + prefix)
                let tail = parser.finalize()

                XCTAssertEqual(
                    split.content + tail.content,
                    "answer " + prefix,
                    "lost ordinary suffix \(prefix.debugDescription)")
                XCTAssertEqual(split.reasoning + tail.reasoning, "")
                XCTAssertTrue(parser.isStructurallyValid)
            }
        }
    }

    func testUnterminatedThinkBlockSetsInvalidOnFinalize() {
        var parser = ThinkTagParser()

        let split = parser.addContent("prefix <think>half reasoning")
        let tail = parser.finalize()

        XCTAssertEqual(split.reasoning, "half reasoning")
        XCTAssertEqual(split.content, "prefix ")
        XCTAssertEqual(tail.reasoning, "")
        XCTAssertEqual(tail.content, "")
        XCTAssertFalse(parser.isStructurallyValid)
    }

    func testPreparedPromptTokenStateRoutesFirstGeneratedTokenToReasoning() {
        let context = ReasoningStreamContext.fromPromptTokenSequence(
            [100, 101, 10],
            format: .think,
            startTokenIDs: [10],
            endTokenIDs: [11])
        XCTAssertTrue(context.startsInReasoning)
        XCTAssertEqual(context.format, .think)

        var classifier = ReasoningStreamClassifier(context: context)
        let first = classifier.ingest("private reasoning")
        let second = classifier.ingest("</think>Final answer")
        let tail = classifier.finalize()

        XCTAssertEqual(first, [.reasoning("private reasoning")])
        XCTAssertEqual(second, [.content("Final answer")])
        XCTAssertEqual(tail, [])
    }

    func testPreparedEmptyThinkPrefillStartsInContent() {
        let context = ReasoningStreamContext.fromPromptTokenSequence(
            [100, 10, 11],
            format: .think,
            startTokenIDs: [10],
            endTokenIDs: [11])

        XCTAssertFalse(context.startsInReasoning)
        XCTAssertEqual(context.format, .think)

        var classifier = ReasoningStreamClassifier(context: context)
        XCTAssertEqual(classifier.ingest("Final answer"), [.content("Final answer")])
        XCTAssertEqual(classifier.finalize(), [])
    }

    func testLatestPreparedMarkerSequenceWinsAcrossHistory() {
        let context = ReasoningStreamContext.fromPromptTokenSequence(
            [10, 90, 11, 91, 10],
            format: .longcatThink,
            startTokenIDs: [10],
            endTokenIDs: [11])

        XCTAssertEqual(context.format, .longcatThink)
        XCTAssertTrue(context.startsInReasoning)
    }

    func testPreparedPromptSupportsMultiTokenThoughtChannelMarkers() {
        let context = ReasoningStreamContext.fromPromptTokenSequence(
            [100, 20, 21],
            format: .thoughtChannel,
            startTokenIDs: [20, 21],
            endTokenIDs: [22])

        XCTAssertEqual(context.format, .thoughtChannel)
        XCTAssertTrue(context.startsInReasoning)

        var classifier = ReasoningStreamClassifier(context: context)
        var deltas = classifier.ingest("private reasoning<channel|>Final answer")
        deltas += classifier.finalize()
        XCTAssertEqual(deltas, [.reasoning("private reasoning"), .content("Final answer")])
    }

    func testTokenizerInfersDocumentedSingleTokenThinkingMarkers() {
        let tokenizer = ThinkingMarkerTestTokenizer(
            vocabulary: [
                "<think>": 10,
                "</think>": 11,
                "<longcat_think>": 12,
                "</longcat_think>": 13,
            ])

        XCTAssertEqual(
            tokenizer.thinkingMarkers,
            ThinkingMarkers(
                start: "<think>", end: "</think>",
                startTokenIDs: [10], endTokenIDs: [11]))
    }

    func testTokenizerInfersDocumentedLongcatThinkingMarkers() {
        let tokenizer = ThinkingMarkerTestTokenizer(
            vocabulary: [
                "<longcat_think>": 12,
                "</longcat_think>": 13,
            ])

        XCTAssertEqual(
            tokenizer.thinkingMarkers,
            ThinkingMarkers(
                start: "<longcat_think>", end: "</longcat_think>",
                startTokenIDs: [12], endTokenIDs: [13]))
    }

    func testTokenizerInfersDocumentedMultiTokenThoughtChannel() {
        let tokenizer = ThinkingMarkerTestTokenizer(
            vocabulary: ["<|channel>": 20, "<channel|>": 22],
            encodings: [
                "<|channel>thought": [20, 21],
                "<channel|>": [22],
            ])

        let markers = tokenizer.thinkingMarkers
        XCTAssertEqual(
            markers,
            ThinkingMarkers(
                start: "<|channel>thought", end: "<channel|>",
                startTokenIDs: [20, 21], endTokenIDs: [22]))
        XCTAssertTrue(markers?.startsInThinking(promptTokenIDs: [99, 22, 20, 21]) == true)
        XCTAssertFalse(markers?.startsInThinking(promptTokenIDs: [99, 20, 21, 22]) == true)
    }

    func testPreopenedMarkerSplitCloseAtEveryBoundary() {
        let closeTag = "</think>"
        for index in 0...closeTag.count {
            var classifier = ReasoningStreamClassifier(
                context: ReasoningStreamContext(format: .think, startsInReasoning: true))
            let split = closeTag.index(closeTag.startIndex, offsetBy: index)
            var deltas = classifier.ingest("secret" + closeTag[..<split])
            deltas += classifier.ingest(String(closeTag[split...]) + "answer")
            deltas += classifier.finalize()

            XCTAssertEqual(
                deltas,
                [.reasoning("secret"), .content("answer")],
                "close-tag boundary \(index)")
        }
    }

    func testClassifierReportsUnterminatedReasoning() {
        var classifier = ReasoningStreamClassifier(
            context: ReasoningStreamContext(format: .think, startsInReasoning: true))

        XCTAssertEqual(classifier.ingest("unfinished"), [.reasoning("unfinished")])
        XCTAssertEqual(classifier.finalize(), [.invalidReasoningStructure])
    }

    func testParserNeverSurfacesControlTags() {
        var parser = ThinkTagParser()
        let first = parser.addContent("plain </think> with partial ")
        let second = parser.addContent("<thi")
        let third = parser.addContent("nk> and trailing </think>")
        let tail = parser.finalize()

        let output = first.reasoning + second.reasoning + third.reasoning + tail.reasoning
        let content = first.content + second.content + third.content + tail.content
        XCTAssertEqual(output, " and trailing ")
        XCTAssertEqual(content, "plain  with partial ")
        XCTAssertFalse(parser.isStructurallyValid)
        XCTAssertFalse(content.contains("<think"))
        XCTAssertFalse(content.contains("</think>"))
        XCTAssertFalse(output.contains("<think"))
        XCTAssertFalse(output.contains("</think>"))
    }

    private func parseOnce(_ text: String) -> (reasoning: String, content: String) {
        var parser = ThinkTagParser()
        let split = parser.addContent(text)
        let tail = parser.finalize()
        return (split.reasoning + tail.reasoning, split.content + tail.content)
    }
}

private struct ThinkingMarkerTestTokenizer: Tokenizer {
    let vocabulary: [String: Int]
    let encodings: [String: [Int]]

    init(vocabulary: [String: Int], encodings: [String: [Int]] = [:]) {
        self.vocabulary = vocabulary
        self.encodings = encodings
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        encodings[text] ?? vocabulary[text].map { [$0] } ?? []
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { vocabulary[token] }
    func convertIdToToken(_ id: Int) -> String? {
        vocabulary.first(where: { $0.value == id })?.key
    }

    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
