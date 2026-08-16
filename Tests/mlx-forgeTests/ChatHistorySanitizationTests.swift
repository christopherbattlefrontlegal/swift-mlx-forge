import XCTest

@testable import mlx_forge

final class ChatHistorySanitizationTests: XCTestCase {
    func testNewFormatAssistantMessageUsesModelVisibleContent() {
        let message = ChatMessage(
            role: .assistant,
            content: "Final answer",
            reasoning: "Private reasoning for audit")

        XCTAssertEqual(message.modelVisibleContent, "Final answer")
        XCTAssertEqual(message.isModelReplayable, true)
        XCTAssertEqual(message.copyableText, "Final answer")
    }

    func testBalancedLegacyInlineThinkBlockIsAnswerOnlyReplayable() {
        let message = ChatMessage(
            role: .assistant,
            content: "Context <think>legacy reasoning</think>Final answer")

        XCTAssertEqual(message.modelVisibleContent, "Context Final answer")
        XCTAssertEqual(message.copyableText, "Context Final answer")
        XCTAssertEqual(message.isModelReplayable, true)
    }

    func testUnbalancedLegacyReasoningIsNotReplayable() {
        let message = ChatMessage(
            role: .assistant,
            content: "<think>open</think> leaked </think> multiply")

        XCTAssertEqual(message.modelVisibleContent, "")
        XCTAssertEqual(message.isModelReplayable, false)
    }

    func testMultiplyClosedLegacyReasoningIsNotReplayable() {
        let message = ChatMessage(
            role: .assistant,
            content: "<think>a</think> b </think> c</think>")

        XCTAssertEqual(message.modelVisibleContent, "")
        XCTAssertEqual(message.isModelReplayable, false)
    }

    func testMisorderedLegacyReasoningIsNotReplayable() {
        let message = ChatMessage(
            role: .assistant,
            content: "</think>visible before <think>unterminated")

        XCTAssertEqual(message.modelVisibleContent, "")
        XCTAssertEqual(message.copyableText, "visible before ")
        XCTAssertFalse(message.isModelReplayable)
    }

    func testErrorMessageIsNotReplayable() {
        let message = ChatMessage(
            role: .assistant,
            content: "⚠️ interrupted",
            isError: true)

        XCTAssertEqual(message.modelVisibleContent, "")
        XCTAssertEqual(message.isModelReplayable, false)
    }

    func testGeneratedModelHistoryOmitsSystemAndThinkTags() {
        let history = Conversation(messages: [
            ChatMessage(role: .user, content: "How many moons?"),
            ChatMessage(role: .system, content: "MCP status: listing"),
            ChatMessage(role: .assistant, content: "<think>hidden reasoning</think>Answer one"),
            ChatMessage(role: .system, content: "MCP result: done"),
            {
                ChatMessage(
                    role: .assistant,
                    content: "partial answer",
                    reasoning: "unfinished",
                    reasoningStructureValid: false)
            }()
        ])

        let turns = history.modelReplayTurns
        XCTAssertEqual(
            turns.map(\.role),
            [.user, .assistant])
        XCTAssertEqual(turns, [
            ModelReplayTurn(role: .user, content: "How many moons?"),
            ModelReplayTurn(role: .assistant, content: "Answer one"),
        ])
        XCTAssertTrue(
            turns.allSatisfy { !$0.content.contains("<think") && !$0.content.contains("</think>") })
    }

    func testMalformedConversationRegressionWithoutReplay() {
        let history = Conversation(messages: [
            ChatMessage(role: .user, content: "first turn"),
            {
                ChatMessage(
                    role: .assistant,
                    content: "partial",
                    reasoning: "bad",
                    reasoningStructureValid: false)
            }(),
            ChatMessage(role: .system, content: "MCP status: started"),
            ChatMessage(role: .assistant, content: "Follow up response"),
            ChatMessage(role: .system, content: "MCP status: done"),
            ChatMessage(role: .assistant, content: "<think>open</think> tail </think>")
        ])

        let turns = history.modelReplayTurns
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertTrue(
            turns.contains(where: {
                $0.role == .assistant && $0.content == "Follow up response"
            }))
        XCTAssertTrue(
            turns.filter { $0.role == .assistant }.allSatisfy {
                !$0.content.contains("<think")
            })
    }

    func testReasoningPersistenceAndBackwardCompatibility() throws {
        let oldJSON = Data(#"{"role":"assistant","content":"old answer"}"#.utf8)
        let oldMessage = try JSONDecoder().decode(ChatMessage.self, from: oldJSON)
        XCTAssertEqual(oldMessage.reasoning, "")
        XCTAssertTrue(oldMessage.reasoningStructureValid)

        let newMessage = ChatMessage(
            role: .assistant,
            content: "new answer",
            reasoning: "private",
            reasoningStructureValid: false)
        let encoded = try JSONEncoder().encode(newMessage)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        XCTAssertEqual(decoded, newMessage)
        XCTAssertEqual(decoded.reasoning, "private")
        XCTAssertFalse(decoded.reasoningStructureValid)
    }
}
