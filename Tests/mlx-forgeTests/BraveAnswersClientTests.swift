import XCTest

@testable import mlx_forge

final class BraveAnswersClientTests: XCTestCase {
    private func event(_ content: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["content": content]]],
        ])
        return "data: " + String(decoding: data, as: UTF8.self)
    }

    private func text(in events: [BraveAnswerEvent]) -> String {
        events.compactMap {
            if case .content(let text) = $0 { return text }
            return nil
        }.joined()
    }

    private let researchResponse = #"<queries>{"queries":["example search"]}</queries><analyzing>{"query":"example search","urls":18,"new_urls":18}</analyzing><thinking>{"query":"example search","urls_analyzed":30,"urls_selected":["https://example.com"]}</thinking><blindspots>["check another source"]</blindspots><answer>{"answer":"The answer is **four**.\n\n[Source](https://example.com)"}</answer><progress>{"number_of_queries":1,"number_of_urls_analyzed":30}</progress>"#

    func testRecordedResearchEventShapeProducesOnlyDecodedAnswer() throws {
        var parser = BraveAnswerStreamParser(research: true)
        let progress = try parser.ingest(line: event(researchResponse))
        XCTAssertEqual(text(in: progress), "")
        XCTAssertTrue(progress.contains(.status("Brave is reading sources…")))
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertEqual(
            text(in: try parser.finish()),
            "The answer is **four**.\n\n[Source](https://example.com)")
        XCTAssertEqual(
            BraveAnswersClient.cleanedResearchAnswer(researchResponse),
            "The answer is **four**.\n\n[Source](https://example.com)")
    }

    func testTagsAndJSONCanBeSplitAtEveryCharacter() throws {
        var parser = BraveAnswerStreamParser(research: true)
        for character in researchResponse {
            let events = try parser.ingest(line: event(String(character)))
            XCTAssertEqual(text(in: events), "")
        }
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertEqual(
            text(in: try parser.finish()),
            "The answer is **four**.\n\n[Source](https://example.com)")
    }

    func testLatestStructuredAnswerReplacesDraftWithoutRewritingItsProse() throws {
        let answer = "I will output </answer> literally, with a quote: \" and a backslash: \\. Café."
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["answer": answer]), as: UTF8.self)
        var parser = BraveAnswerStreamParser(research: true)
        _ = try parser.ingest(line: event("Writer draft. <answer>{\"answer\":\"Earlier answer\"}</answer><answer>\(json)</answer>"))
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertEqual(text(in: try parser.finish()), answer)
    }

    func testResearchKeepsReviewedSourcesWhenTheWriterOmitsLinks() throws {
        var parser = BraveAnswerStreamParser(research: true)
        let raw = #"<thinking>{"urls_selected":["https://example.com/one","https://example.com/one","javascript:alert(1)","https://example.org/two"]}</thinking><answer>{"answer":"The completed research answer."}</answer>"#
        _ = try parser.ingest(line: event(raw))
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertEqual(text(in: try parser.finish()), """
            The completed research answer.

            **Sources reviewed**
            - <https://example.com/one>
            - <https://example.org/two>
            """)
    }

    func testProgressOnlyIsAnErrorNotAnAnswer() throws {
        var parser = BraveAnswerStreamParser(research: true)
        _ = try parser.ingest(line: event(#"<queries>{"queries":["example"]}</queries>"#))
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertThrowsError(try parser.finish())
    }

    func testTruncatedStreamAndIncompleteAnswerAreErrors() throws {
        var disconnected = BraveAnswerStreamParser(research: true)
        _ = try disconnected.ingest(line: event(researchResponse))
        XCTAssertThrowsError(try disconnected.finish())

        var truncated = BraveAnswerStreamParser(research: true)
        _ = try truncated.ingest(line: event(#"<answer>{"answer":"unfinished"#))
        _ = try truncated.ingest(line: "data: [DONE]")
        XCTAssertThrowsError(try truncated.finish())
    }

    func testMalformedEventsAndProviderErrorsAreReported() throws {
        for payload in [
            "data: {invalid",
            #"data: {"error":{"message":"quota exceeded"}}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            try event(#"<answer>{"answer":42}</answer>"#),
            try event("<answer>{invalid}</answer>"),
        ] {
            var parser = BraveAnswerStreamParser(research: true)
            XCTAssertThrowsError(try parser.ingest(line: payload), payload)
        }
    }

    func testAnswersTextAndSplitSnakeCaseCitationsAndUsage() throws {
        let raw = #"An <em>answer</em>, where 2 < 3.<citation>{"start_index":0,"end_index":9,"number":1,"url":"https://example.com"}</citation><usage>{"X-Request-Queries":2,"X-Request-Total-Cost":0.01}</usage><enum_item>{"name":"hidden entity"}</enum_item> Done."#
        var parser = BraveAnswerStreamParser(research: false)
        var events: [BraveAnswerEvent] = []
        for character in raw {
            events += try parser.ingest(line: event(String(character)))
        }
        _ = try parser.ingest(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        events += try parser.finish()
        XCTAssertEqual(text(in: events), "An <em>answer</em>, where 2 < 3. Done.")
        XCTAssertTrue(events.contains(.citation(BraveCitation(
            startIndex: 0, endIndex: 9, number: 1, url: "https://example.com", favicon: nil, snippet: nil))))
        XCTAssertTrue(events.contains(.usage(BraveSearchUsage(queries: 2, totalCost: 0.01))))
    }

    func testDoneTerminatesTheStreamAndIgnoresLaterEvents() throws {
        var parser = BraveAnswerStreamParser(research: false)
        XCTAssertEqual(try parser.ingest(line: ": heartbeat"), [])
        _ = try parser.ingest(line: event("Answer"))
        _ = try parser.ingest(line: "data: [DONE]")
        XCTAssertTrue(parser.isDone)
        XCTAssertEqual(try parser.ingest(line: event("must not appear")), [])
        XCTAssertNoThrow(try parser.finish())
    }

    func testPlainTextEndingWithLessThanSignIsPreserved() throws {
        var parser = BraveAnswerStreamParser(research: false)
        var events = try parser.ingest(line: event("The symbol is <"))
        _ = try parser.ingest(line: "data: [DONE]")
        events += try parser.finish()
        XCTAssertEqual(text(in: events), "The symbol is <")
    }

    func testFollowupPreservesAlreadyDecodedAnswerProse() throws {
        let answer = "I will output the results in the requested format."
        let history = [ChatMessage(role: .assistant, content: answer, modelName: "Brave Search · Answers")]
        let request = try BraveAnswersClient(apiKey: "test-key").makeRequest(query: "continue", history: history)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(try XCTUnwrap(messages.first?["content"]).contains(answer))
    }

    func testFollowupIncludesPriorQuestionAndDecodedAnswerInOneUserMessage() throws {
        var priorAnswer = ChatMessage(role: .assistant, content: researchResponse, reasoning: "hidden thoughts")
        priorAnswer.modelName = "Brave Search · Research"
        let history = [
            ChatMessage(role: .user, content: "Research a specific topic"),
            priorAnswer,
            ChatMessage(role: .system, content: "internal status"),
            ChatMessage(role: .assistant, content: "network error", isError: true),
        ]
        let client = BraveAnswersClient(apiKey: "test-key", config: BraveSearchConfig(
            enableCitations: true, enableEntities: true, enableResearch: true))
        let request = try client.makeRequest(query: "Give me that in paragraphs", history: history)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        let prompt = try XCTUnwrap(messages[0]["content"])
        XCTAssertTrue(prompt.contains("Research a specific topic"))
        XCTAssertTrue(prompt.contains("The answer is **four**."))
        XCTAssertTrue(prompt.hasSuffix("Give me that in paragraphs"))
        for excluded in ["<answer>", "<queries>", "hidden thoughts", "internal status", "network error"] {
            XCTAssertFalse(prompt.contains(excluded), excluded)
        }
        XCTAssertNil(body["enable_citations"])
        XCTAssertEqual(body["enable_entities"] as? Bool, false)
    }

    @MainActor
    func testClientStreamsDecodedResearchThroughURLSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BraveResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = BraveAnswersClient(
            apiKey: "fixture-key", config: BraveSearchConfig(enableResearch: true), session: session)
        var output = ""
        var statuses: [String] = []
        try await client.stream(query: "example", onChunk: { delta in
            if case .content(let text) = delta { output += text }
        }, onStatus: { statuses.append($0) })
        XCTAssertEqual(output, "A complete answer.\n\n[Source](https://example.com)")
        XCTAssertFalse(statuses.isEmpty)
    }

    /// Opt-in live verification uses the configured key without printing it.
    @MainActor
    func testLiveBraveAnswersAndResearchFollowup() async throws {
        guard ProcessInfo.processInfo.environment["FORGE_BRAVE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set FORGE_BRAVE_LIVE_TEST=1 for live Brave verification")
        }
        let key = try XCTUnwrap(SecretsStore.braveSearchAPIKey, "No configured Brave key")
        let question = "What is the capital of France? Answer in one short sentence."
        var history: [ChatMessage] = []
        for research in [false, true] {
            let client = BraveAnswersClient(apiKey: key, config: BraveSearchConfig(enableResearch: research))
            var answer = ""
            var statuses = 0
            let started = Date()
            try await client.stream(
                query: research ? "What country is that city in? Answer briefly with a source link." : question,
                history: history,
                onChunk: { if case .content(let text) = $0 { answer += text } },
                onStatus: { _ in statuses += 1 })
            XCTAssertTrue(answer.lowercased().contains(research ? "france" : "paris"), answer)
            XCTAssertFalse(answer.contains("<answer>"))
            XCTAssertFalse(answer.contains("<thinking>"))
            if research { XCTAssertGreaterThan(statuses, 0) }
            print("[brave-live] research=\(research) seconds=\(Date().timeIntervalSince(started)) chars=\(answer.count) progressEvents=\(statuses)")
            history = [ChatMessage(role: .user, content: question), ChatMessage(role: .assistant, content: answer)]
        }
    }

    @MainActor
    func testLiveResearchOnReportedQuery() async throws {
        guard ProcessInfo.processInfo.environment["FORGE_BRAVE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set FORGE_BRAVE_LIVE_TEST=1 for live Brave verification")
        }
        let key = try XCTUnwrap(SecretsStore.braveSearchAPIKey, "No configured Brave key")
        let client = BraveAnswersClient(apiKey: key, config: BraveSearchConfig(enableResearch: true))
        var answer = ""
        let started = Date()
        try await client.stream(
            query: "Verify you know what Claude Code CLI and Codex CLI are used for.",
            onChunk: { if case .content(let text) = $0 { answer += text } })
        XCTAssertTrue(answer.lowercased().contains("claude"), answer)
        XCTAssertTrue(answer.lowercased().contains("codex"), answer)
        XCTAssertGreaterThan(answer.count, 100)
        for tag in ["<answer>", "<thinking>", "<queries>", "<progress>"] {
            XCTAssertFalse(answer.contains(tag), tag)
        }
        print("[brave-live-reproduction] seconds=\(Date().timeIntervalSince(started)) chars=\(answer.count)")
    }

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

private final class BraveResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let fragments = [
            #"<queries>{"queries":["example"]}</queries><ans"#,
            #"wer>{"answer":"A complete answer.\n\n[Source](https://example.com)"}</answer>"#,
        ]
        for fragment in fragments {
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": fragment]]]])
            let line = "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
            client?.urlProtocol(self, didLoad: Data(line.utf8))
        }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
