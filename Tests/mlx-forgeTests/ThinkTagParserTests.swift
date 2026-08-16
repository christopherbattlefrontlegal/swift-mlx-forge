import XCTest

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
