// Forge — detect chat-template capabilities from on-disk tokenizer files at load time.

import Foundation

enum ChatTemplateSniffer {

    struct Capabilities: Equatable, Hashable, Sendable {
        var hasChatTemplate = false
        /// Template reads `enable_thinking` from kwargs (Qwen3 README-style).
        var supportsThinkingToggle = false
        /// No off-branch in template — thinking cannot be disabled via kwargs.
        var thinkingOnly = false
        /// `add_generation_prompt` opens a `` block (always-on reasoning).
        var thinkingBuiltIntoTemplate = false
    }

    /// Reads `tokenizer_config.json` / `chat_template.jinja` under the model folder.
    nonisolated static func sniff(modelDirectory: URL) -> Capabilities {
        guard let template = loadChatTemplateText(from: modelDirectory) else {
            return Capabilities()
        }
        var caps = Capabilities(hasChatTemplate: true)
        let lower = template.lowercased()
        if template.contains("enable_thinking") {
            caps.supportsThinkingToggle = true
            let hasOffBranch =
                lower.contains("not enable_thinking")
                || lower.contains("enable_thinking=false")
                || lower.contains("enable_thinking = false")
                || lower.contains("enable_thinking==false")
            caps.thinkingOnly = !hasOffBranch
        }
        if detectsBuiltInThinkingPrompt(in: template) {
            caps.thinkingBuiltIntoTemplate = true
        }
        return caps
    }

    /// True when the model is likely to emit `` blocks (toggle, built-in prompt, or reasoning fields).
    nonisolated static func expectsReasoningOutput(_ caps: Capabilities) -> Bool {
        caps.supportsThinkingToggle || caps.thinkingBuiltIntoTemplate
    }

    nonisolated private static func loadChatTemplateText(from directory: URL) -> String? {
        for root in searchRoots(in: directory) {
            if let jinja = readUTF8(root.appendingPathComponent("chat_template.jinja")) {
                return jinja
            }
            if let config = readTokenizerConfig(at: root.appendingPathComponent("tokenizer_config.json")) {
                return config
            }
        }
        return nil
    }

    nonisolated private static func searchRoots(in directory: URL) -> [URL] {
        var roots = [directory]
        collectSubdirectories(under: directory, depth: 0, maxDepth: 3, into: &roots)
        return roots
    }

    nonisolated private static func collectSubdirectories(
        under directory: URL, depth: Int, maxDepth: Int, into roots: inout [URL]
    ) {
        guard depth < maxDepth,
            let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true else { continue }
            roots.append(child)
            collectSubdirectories(under: child, depth: depth + 1, maxDepth: maxDepth, into: &roots)
        }
    }

    /// Qwen3 stock templates end generation with `<|im_start|>assistant` + an opening think tag.
    nonisolated private static func detectsBuiltInThinkingPrompt(in template: String) -> Bool {
        guard template.contains("add_generation_prompt") else { return false }
        let markers = [
            "<think>\\n",
            "<think>\\n\\n",
            "'<think>'",
            "\"<think>\"",
        ]
        return markers.contains { template.contains($0) }
    }

    nonisolated private static func readTokenizerConfig(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let template = json["chat_template"] as? String, !template.isEmpty {
            return template
        }
        return nil
    }

    nonisolated private static func readUTF8(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}