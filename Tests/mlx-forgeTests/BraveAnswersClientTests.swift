import XCTest

@testable import mlx_forge

final class BraveAnswersClientTests: XCTestCase {
    func testResearchCleanupKeepsLatestRevisionAndDropsWriterLeakage() {
        let draft = """
            Government investigators use graph databases to connect people, vehicles, locations, events, records, evidence, calls, organizations, firearms, and related activity. The graph exposes relationships across otherwise separate data sources and helps analysts inspect timelines, common locations, communication patterns, custody links, and recurring methods during complex investigations.
            """
        let final = """
            Government and law-enforcement investigators use graph databases to connect people, vehicles, locations, events, records, evidence, calls, organizations, firearms, and related activity. This structure exposes relationships across separate data sources and helps analysts inspect timelines, shared locations, communication patterns, custody links, and recurring methods during complex investigations.
            """
        let streamed = """
            \(draft)

            This covers all bases. I will output this.writer

            \(draft)

            \(final)
            """

        XCTAssertEqual(BraveAnswersClient.cleanedResearchAnswer(streamed), final)
    }

    func testResearchCleanupPreservesDistinctAnswerSections() {
        let first = "The first section explains the governing rule and its required elements."
        let second = "The second section applies that rule to a separate factual record."

        XCTAssertEqual(
            BraveAnswersClient.cleanedResearchAnswer("\(first)\n\n\(second)"),
            "\(first)\n\n\(second)")
    }
}
