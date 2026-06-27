// Forge — data model layer.
// Pure value types; persistence lives in Persistence.swift.

import Foundation

// MARK: - Chat

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    var id: UUID = UUID()
    var role: Role
    var content: String
    var timestamp: Date = Date()

    /// Attached images for this message (primarily for user turns with photos).
    /// Stored as raw JPEG/PNG Data for simplicity and VLM/MCP compatibility.
    /// When sending via MCP for "photo review", we base64-encode into the tool arguments.
    var attachedImageData: [Data] = []

    // Filled in when an assistant message finishes generating.
    var modelName: String?
    var tokensPerSecond: Double?
    var generationTokenCount: Int?
    var promptTokenCount: Int?
    var promptTime: TimeInterval?

    /// True for locally-generated error notices ("⚠️ …") that were never real
    /// model output. Optional so conversations saved before this field decode
    /// cleanly. Excluded from the history replayed to any provider.
    var isError: Bool?
    var isErrorMessage: Bool { isError == true }

    /// Splits assistant content into reasoning ("<think>…</think>") and answer parts,
    /// in document order. Handles a still-streaming unterminated think block, and
    /// models whose chat template pre-opens the tag so output starts mid-reasoning
    /// and only a closing "</think>" appears.
    var segments: [Segment] {
        var result: [Segment] = []
        var normalized = content
        if let close = normalized.range(of: "</think>") {
            let head = normalized[..<close.lowerBound]
            if !head.contains("<think>") {
                normalized = "<think>" + normalized
            }
        }
        var remaining = Substring(normalized)
        // ids are positional (0,1,2…) so identity is STABLE across recomputes while
        // streaming — SwiftUI then updates each segment's text in place instead of
        // tearing down and rebuilding every bubble on every token (which also reset
        // the ThinkingBlock's expand state and thrashed the main thread).
        while let open = remaining.range(of: "<think>") {
            let before = remaining[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { result.append(Segment(id: result.count, kind: .answer, text: before)) }
            let afterOpen = remaining[open.upperBound...]
            if let close = afterOpen.range(of: "</think>") {
                let thought = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !thought.isEmpty {
                    result.append(Segment(id: result.count, kind: .thinking(done: true), text: thought))
                }
                remaining = afterOpen[close.upperBound...]
            } else {
                let thought = afterOpen.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(Segment(id: result.count, kind: .thinking(done: false), text: thought))
                remaining = Substring("")
            }
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(Segment(id: result.count, kind: .answer, text: tail)) }
        return result
    }

    struct Segment: Identifiable, Equatable {
        enum Kind: Equatable {
            case answer
            case thinking(done: Bool)
        }
        let id: Int
        var kind: Kind
        var text: String
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var messages: [ChatMessage] = []
    var systemPrompt: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Model id last used in this conversation (so reopening can suggest it).
    var lastModelID: String?

    var isEmpty: Bool { messages.isEmpty }

    /// Auto-title from the first user message.
    mutating func refreshTitle() {
        guard title == "New Chat",
            let first = messages.first(where: { $0.role == .user })
        else { return }
        let line = first.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)[0]
        title = String(line.prefix(48)) + (line.count > 48 ? "…" : "")
    }
}

// MARK: - Models on disk / on the hub

/// A model available locally on disk, ready to load.
struct LocalModel: Identifiable, Equatable, Hashable {
    /// Stable identity — the resolved model directory path.
    var id: String { directory.path }
    /// Display id, e.g. "mlx-community/Qwen3-4B-4bit" or a folder name.
    var name: String
    /// Directory that contains config.json + *.safetensors.
    var directory: URL
    /// Total size on disk in bytes (blobs).
    var sizeBytes: Int64
    /// "qwen3", "llama", … from config.json model_type, when readable.
    var architecture: String?
    /// Quantization summary, e.g. "4-bit", when readable from config.json.
    var quantization: String?
    /// True if this lives inside Forge's managed download cache (deletable in-app).
    var isManaged: Bool
    /// Root folder to remove when deleting (cache `models--…` dir, not the snapshot).
    var deletableRoot: URL?

    var shortName: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// GGUF single-file model (llama.cpp backend). `directory` is the .gguf
    /// file itself, not a folder.
    var isGGUF: Bool {
        directory.pathExtension.lowercased() == "gguf"
    }

    /// MoE / expert models must use mlx-swift-lm's standard factory loader.
    /// Forge's bounded/deferred weight path is for dense LLMs only and runs
    /// dramatically slower on architectures like Qwen3.5/3.6 A3B.
    var prefersStandardMLXLoad: Bool {
        if isGGUF { return true }
        let haystack =
            "\(architecture ?? "") \(name) \(shortName) \(directory.lastPathComponent)"
            .lowercased()
        let markers = [
            "moe", "mixtral", "a3b", "a22b", "a2b", "deepseek_v3", "kimi-k2",
        ]
        return markers.contains { haystack.contains($0) }
    }

    var backendLabel: String {
        isGGUF ? "GGUF" : "MLX"
    }

    var precisionLabel: String? {
        quantization ?? Self.precisionHint(in: "\(name) \(directory.lastPathComponent)")
    }

    /// True for checkpoints where deferred/lazy paths still imply very long first-use work.
    var isVeryLargeForDeferredLoad: Bool {
        Int64(sizeBytes) >= WeightLoadPolicy.largeModelBytes
    }

    var runtimeDetails: String {
        var parts = [backendLabel]
        if let precisionLabel, !parts.contains(precisionLabel) {
            parts.append(precisionLabel)
        }
        if let architecture {
            let normalized =
                architecture == "gguf · llama.cpp" ? "llama.cpp" : architecture
            if !normalized.isEmpty && !parts.contains(normalized) {
                parts.append(normalized)
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func precisionHint(in text: String) -> String? {
        let lower = text.lowercased()
        let patterns: [(String, String)] = [
            (#"(?i)\b(tq[0-9]_[0-9])\b"#, "$1"),
            (#"(?i)\b(i?q[0-9]_[0-9a-z_]+)\b"#, "$1"),
            (#"(?i)\b([2-8])-?bit\b"#, "$1-bit"),
            (#"(?i)\bbf16\b|\bbfloat16\b"#, "BF16"),
            (#"(?i)\bfp16\b|\bf16\b|\bfloat16\b"#, "FP16"),
            (#"(?i)\bfp32\b|\bf32\b|\bfloat32\b"#, "FP32"),
        ]
        for (pattern, template) in patterns {
            guard let range = lower.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let raw = String(lower[range])
            if template == "$1" {
                return raw.uppercased()
            }
            if template == "$1-bit",
               let digit = raw.first(where: { $0.isNumber }) {
                return "\(digit)-bit"
            }
            return template
        }
        return nil
    }
}

/// A model discovered via the Hugging Face search API.
struct RemoteModel: Identifiable, Codable, Equatable {
    var id: String
    var downloads: Int?
    var likes: Int?
    var tags: [String]?
    var pipeline_tag: String?

    var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
    var organization: String {
        id.split(separator: "/").first.map(String.init) ?? ""
    }
    var sizeHint: String? {
        // Pull "4bit" / "8bit" style hints out of the repo name.
        let lower = id.lowercased()
        for q in ["4bit", "4-bit", "8bit", "8-bit", "6bit", "6-bit", "3bit", "3-bit", "bf16", "fp16"] {
            if lower.contains(q) { return q.replacingOccurrences(of: "-", with: "") }
        }
        return nil
    }
}

// MARK: - Weight loading

/// How MLX safetensors weights are materialized during load.
enum WeightLoadPolicy: String, Codable, CaseIterable, Identifiable, Equatable {
    /// Upstream path: one whole-model `eval` after all shards merge.
    case eager
    /// Per-shard `eval` while loading — lowers transient peak RAM (recommended).
    case boundedEager
    /// Skip final `eval`; weights materialize on first forward pass.
    case deferred

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eager: "Standard (eager)"
        case .boundedEager: "Bounded eager"
        case .deferred: "Deferred (lazy)"
        }
    }

    var shortLabel: String {
        switch self {
        case .eager: "eager"
        case .boundedEager: "bounded"
        case .deferred: "deferred"
        }
    }

    var help: String {
        switch self {
        case .eager:
            "Default MLX behavior — all weights evaluated in one step at the end of load."
        case .boundedEager:
            "Evaluates each safetensors shard before loading the next — lowers peak RAM during load while staying ready after load completes."
        case .deferred:
            "Load returns quickly with lazy weights; the first token pays the materialization cost. Not labeled as fully ready for latency-sensitive use."
        }
    }

    /// Above this on-disk size, deferred load still reads every shard and the first
    /// send materializes the full model — often minutes of GPU work on huge checkpoints.
    static let largeModelBytes: Int64 = 50_000_000_000
}

// MARK: - Generation settings

struct GenerationSettings: Codable, Equatable {
    /// MLX safetensors materialization policy for API auto-load (UI Load picks per click).
    var weightLoadPolicy: WeightLoadPolicy = .eager
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 0
    var minP: Double = 0.0
    var maxTokens: Int = 4096
    var repetitionPenalty: Double = 1.0
    var systemPrompt: String = ""
    var maxKVSize: Int = 0  // 0 = unlimited

    init() {}

    // Tolerant decoding so new fields never invalidate an older settings file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weightLoadPolicy =
            (try? c.decodeIfPresent(WeightLoadPolicy.self, forKey: .weightLoadPolicy))
            .flatMap { $0 } ?? .eager
        temperature =
            (try? c.decodeIfPresent(Double.self, forKey: .temperature)).flatMap { $0 } ?? 0.7
        topP = (try? c.decodeIfPresent(Double.self, forKey: .topP)).flatMap { $0 } ?? 0.95
        topK = (try? c.decodeIfPresent(Int.self, forKey: .topK)).flatMap { $0 } ?? 0
        minP = (try? c.decodeIfPresent(Double.self, forKey: .minP)).flatMap { $0 } ?? 0.0
        maxTokens = (try? c.decodeIfPresent(Int.self, forKey: .maxTokens)).flatMap { $0 } ?? 4096
        repetitionPenalty =
            (try? c.decodeIfPresent(Double.self, forKey: .repetitionPenalty)).flatMap { $0 } ?? 1.0
        systemPrompt =
            (try? c.decodeIfPresent(String.self, forKey: .systemPrompt)).flatMap { $0 } ?? ""
        maxKVSize = (try? c.decodeIfPresent(Int.self, forKey: .maxKVSize)).flatMap { $0 } ?? 0
    }
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func bytes(_ value: Int) -> String { bytes(Int64(value)) }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000)
                .formatted(.number.precision(.fractionLength(1))) + "M"
        }
        if value >= 1_000 {
            return (Double(value) / 1_000)
                .formatted(.number.precision(.fractionLength(1))) + "K"
        }
        return "\(value)"
    }
}
