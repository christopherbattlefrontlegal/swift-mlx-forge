import XCTest

@testable import mlx_forge

final class ChatTemplateSnifferTests: XCTestCase {
    /// The reasoning-control section of the stock Qwen3.8 chat template.
    private static let qwen38Template = """
        {%- if enable_thinking is undefined or enable_thinking is true %}
            {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
            {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
                {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. Supported types are xhigh (default), medium, and low.') }}
            {%- endif %}
        {%- endif %}
        {%- if add_generation_prompt %}
            {{- '<|im_start|>assistant\\n' }}
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\\n\\n</think>\\n\\n' }}
            {%- else %}
                {{- '<think>\\n' }}
            {%- endif %}
        {%- endif %}
        """

    private func writeTemplate(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-sniffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(
            to: dir.appendingPathComponent("chat_template.jinja"), atomically: true,
            encoding: .utf8)
        return dir
    }

    func testQwen38TemplateExposesItsReasoningEffortLevels() throws {
        let dir = try writeTemplate(Self.qwen38Template)
        defer { try? FileManager.default.removeItem(at: dir) }

        let caps = ChatTemplateSniffer.sniff(modelDirectory: dir)

        XCTAssertTrue(caps.supportsReasoningEffort)
        XCTAssertEqual(caps.reasoningEffortLevels, ["xhigh", "medium", "low"])
        XCTAssertEqual(caps.reasoningEffortDefault, "xhigh")
        XCTAssertTrue(caps.supportsThinkingToggle)
        XCTAssertFalse(caps.thinkingOnly)
    }

    func testInklingStyleTemplateHasNoEnumeratedLevels() throws {
        let dir = try writeTemplate(
            "{{ reasoning_effort }} {% if add_generation_prompt %}x{% endif %}")
        defer { try? FileManager.default.removeItem(at: dir) }

        let caps = ChatTemplateSniffer.sniff(modelDirectory: dir)

        XCTAssertTrue(caps.supportsReasoningEffort)
        XCTAssertEqual(caps.reasoningEffortLevels, [])
        XCTAssertNil(caps.reasoningEffortDefault)
    }

    @MainActor
    func testQwen38ContextClampsToTemplateLevelsAndUsesEnableThinking() {
        var caps = ChatTemplateSniffer.Capabilities(hasChatTemplate: true)
        caps.supportsThinkingToggle = true
        caps.supportsReasoningEffort = true
        caps.reasoningEffortLevels = ["xhigh", "medium", "low"]
        caps.reasoningEffortDefault = "xhigh"
        let entry = Self.entry(caps: caps)

        // Forge's stored default "high" is not a Qwen level: the template's default wins.
        let defaulted = InferenceEngine.thinkingAdditionalContext(
            for: entry, enabled: true, effort: "high")
        XCTAssertEqual(defaulted?["reasoning_effort"] as? String, "xhigh")
        XCTAssertEqual(defaulted?["enable_thinking"] as? Bool, true)

        let low = InferenceEngine.thinkingAdditionalContext(
            for: entry, enabled: true, effort: "low")
        XCTAssertEqual(low?["reasoning_effort"] as? String, "low")

        // Off goes through enable_thinking, never through a value the template rejects.
        let off = InferenceEngine.thinkingAdditionalContext(
            for: entry, enabled: false, effort: "low")
        XCTAssertEqual(off?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(off?["reasoning_effort"] as? String, "low")
    }

    @MainActor
    func testInklingContextIsUnchanged() {
        var caps = ChatTemplateSniffer.Capabilities(hasChatTemplate: true)
        caps.supportsReasoningEffort = true
        let entry = Self.entry(caps: caps)

        let on = InferenceEngine.thinkingAdditionalContext(
            for: entry, enabled: true, effort: "medium")
        XCTAssertEqual(on?["reasoning_effort"] as? String, "medium")
        XCTAssertNil(on?["enable_thinking"])

        let off = InferenceEngine.thinkingAdditionalContext(
            for: entry, enabled: false, effort: "medium")
        XCTAssertEqual(off?["reasoning_effort"] as? String, "none")
    }

    @MainActor
    private static func entry(caps: ChatTemplateSniffer.Capabilities) -> InferenceEngine.Loaded {
        let model = LocalModel(
            name: "test", directory: URL(fileURLWithPath: "/dev/null/test"), sizeBytes: 0,
            isManaged: false)
        return InferenceEngine.Loaded(model: model, container: nil, templateCaps: caps)
    }
}
