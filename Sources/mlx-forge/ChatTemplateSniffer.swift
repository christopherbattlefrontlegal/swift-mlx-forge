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
            // Stock Qwen3 writes `enable_thinking is false`; GLM writes
            // `not enable_thinking`. Any of these means the template has a
            // real off-branch and the toggle works both ways.
            let hasOffBranch =
                lower.contains("not enable_thinking")
                || lower.contains("enable_thinking=false")
                || lower.contains("enable_thinking = false")
                || lower.contains("enable_thinking==false")
                || lower.contains("enable_thinking == false")
                || lower.contains("enable_thinking is false")
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
    ///
    /// An open tag immediately followed by `</think>` is the OPPOSITE signal: that's the
    /// empty-block *no-think prefill* (`<think>\n\n</think>`) hybrid templates emit when
    /// `enable_thinking=false`. Counting it as always-on reasoning made Forge treat plain
    /// answers as thinking — mislabeling the UI and burning the thinking budget on them.
    nonisolated private static func detectsBuiltInThinkingPrompt(in template: String) -> Bool {
        guard template.contains("add_generation_prompt") else { return false }
        var searchRange = template.startIndex..<template.endIndex
        while let open = template.range(of: "<think>", range: searchRange) {
            // The empty prefill is at most `\n\n</think>` away (escaped `\n` in the
            // template source is two characters, so a short window covers both forms).
            let window = template[open.upperBound...].prefix(12)
            if !window.contains("</think>") { return true }
            searchRange = open.upperBound..<template.endIndex
        }
        return false
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