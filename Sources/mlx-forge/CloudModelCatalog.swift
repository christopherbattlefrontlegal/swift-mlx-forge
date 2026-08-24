// Forge — live model catalogs for cloud providers.
//
// One home for the per-provider model lists the pickers show. Each provider
// has three layers: a curated fallback (used before the first fetch), the
// live catalog fetched from the provider's /v1/models endpoint (persisted in
// UserDefaults), and user-added custom ids. Fetches are cheap GETs, so the
// app refreshes stale catalogs automatically at launch.

import Foundation

enum CloudProvider: String, CaseIterable, Hashable {
    case openAI
    case anthropic
    case xAI

    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .xAI: return "xAI"
        }
    }

    var apiKey: String? {
        switch self {
        case .openAI: return SecretsStore.openAIAPIKey
        case .anthropic: return SecretsStore.anthropicAPIKey
        case .xAI: return SecretsStore.xaiAPIKey
        }
    }
}

enum CloudModelCatalog {

    // MARK: - Reads

    /// Chat-capable models for the provider's pickers: live catalog when one
    /// has been fetched (falling back to the curated list), plus custom ids.
    static func chatModels(_ provider: CloudProvider) -> [(id: String, label: String)] {
        let base = fetched(provider).filter { isChatModel(provider, id: $0.id) }
        var models = base.isEmpty ? defaults(provider) : base
        for custom in customModels(provider) where !models.contains(where: { $0.id == custom }) {
            models.append((custom, custom))
        }
        return models
    }

    /// Image-generation model ids for the Media Studio.
    static func imageModels(_ provider: CloudProvider) -> [String] {
        let live = fetched(provider).map(\.id).filter { isImageModel(provider, id: $0) }
        if !live.isEmpty { return live }
        switch provider {
        case .openAI: return ["gpt-image-1"]
        case .xAI: return ["grok-2-image"]
        case .anthropic: return []
        }
    }

    /// Video-generation model ids (OpenAI Sora family).
    static func videoModels() -> [String] {
        let live = fetched(.openAI).map(\.id)
            .filter { $0.hasPrefix("sora") }
            .sorted(by: >)
        return live.isEmpty ? ["sora-2"] : live
    }

    static func customModels(_ provider: CloudProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: customKey(provider)) ?? []
    }

    static func lastRefresh(_ provider: CloudProvider) -> Date? {
        UserDefaults.standard.object(forKey: refreshKey(provider)) as? Date
    }

    static func fetchedCount(_ provider: CloudProvider) -> Int {
        fetched(provider).count
    }

    // MARK: - Mutations

    static func addCustomModel(_ provider: CloudProvider, id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var customs = customModels(provider)
        guard !customs.contains(trimmed) else { return }
        customs.append(trimmed)
        UserDefaults.standard.set(customs, forKey: customKey(provider))
    }

    static func removeCustomModel(_ provider: CloudProvider, id: String) {
        let customs = customModels(provider).filter { $0 != id }
        UserDefaults.standard.set(customs, forKey: customKey(provider))
    }

    // MARK: - Live fetch

    /// Fetches the provider's full model list and persists it. Filtering
    /// happens at read time, so improving a filter never needs a refetch.
    static func refresh(_ provider: CloudProvider) async throws {
        guard let key = provider.apiKey else {
            throw MediaGenError.noKey(provider.label)
        }
        let entries: [(String, String)]
        switch provider {
        case .openAI:
            entries = try await fetchModelList(
                url: "https://api.openai.com/v1/models",
                headers: ["Authorization": "Bearer \(key)"]
            ).map { ($0.id, prettifyOpenAI($0.id)) }
        case .xAI:
            entries = try await fetchModelList(
                url: "https://api.x.ai/v1/models",
                headers: ["Authorization": "Bearer \(key)"]
            ).map { ($0.id, prettifyXAI($0.id)) }
        case .anthropic:
            entries = try await fetchModelList(
                url: "https://api.anthropic.com/v1/models?limit=100",
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"]
            ).map { ($0.id, $0.displayName ?? $0.id) }
        }
        // Anthropic already lists newest first. Others sort newest-looking first
        // within the GPT family, then everything else (o-series and friends).
        let sorted: [(String, String)]
        if provider == .anthropic {
            sorted = entries
        } else {
            let gpt = entries.filter { $0.0.hasPrefix("gpt-") }.sorted { $0.0 > $1.0 }
            let rest = entries.filter { !$0.0.hasPrefix("gpt-") }.sorted { $0.0 > $1.0 }
            sorted = gpt + rest
        }
        persist(provider, entries: sorted)
    }

    private struct ModelEntry {
        let id: String
        let displayName: String?
    }

    private static func fetchModelList(
        url: String, headers: [String: String]
    ) async throws -> [ModelEntry] {
        var request = URLRequest(url: URL(string: url)!)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw MediaGenError.http(
                http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]]
        else {
            throw MediaGenError.badResponse("model list has no data array")
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ModelEntry(id: id, displayName: item["display_name"] as? String)
        }
    }

    // MARK: - Filters

    private static func isChatModel(_ provider: CloudProvider, id: String) -> Bool {
        let lower = id.lowercased()
        let excluded = [
            "image", "sora", "audio", "tts", "whisper", "embedding", "moderation",
            "dall-e", "realtime", "transcribe", "davinci", "babbage", "instruct",
            "search", "computer-use", "vision-preview",
        ]
        if excluded.contains(where: { lower.contains($0) }) { return false }
        switch provider {
        case .openAI:
            if lower.hasPrefix("gpt-") { return true }
            if lower.first == "o", lower.dropFirst().first?.isNumber == true { return true }
            return false
        case .xAI:
            return lower.hasPrefix("grok")
        case .anthropic:
            return lower.hasPrefix("claude")
        }
    }

    private static func isImageModel(_ provider: CloudProvider, id: String) -> Bool {
        let lower = id.lowercased()
        switch provider {
        case .openAI: return lower.hasPrefix("gpt-image") || lower.hasPrefix("dall-e")
        case .xAI: return lower.contains("image")
        case .anthropic: return false
        }
    }

    // MARK: - Labels

    private static func prettifyOpenAI(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        let rest = id.dropFirst(4)
            .split(separator: "-")
            .map { part -> String in
                part.first?.isNumber == true ? String(part) : part.capitalized
            }
            .joined(separator: " ")
        return "GPT-" + rest
    }

    private static func prettifyXAI(_ id: String) -> String {
        id.split(separator: "-")
            .map { part -> String in
                part.first?.isNumber == true ? String(part) : part.capitalized
            }
            .joined(separator: " ")
    }

    // MARK: - Defaults + persistence

    private static func defaults(_ provider: CloudProvider) -> [(id: String, label: String)] {
        switch provider {
        case .openAI: return OpenAIClient.defaultModels
        case .anthropic: return AnthropicClient.defaultModels
        case .xAI: return [("grok-4.3", "Grok 4.3"), ("grok-2-image", "Grok 2 Image")]
        }
    }

    private static func fetched(_ provider: CloudProvider) -> [(id: String, label: String)] {
        guard let pairs = UserDefaults.standard.array(forKey: catalogKey(provider))
                as? [[String]]
        else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
    }

    private static func persist(_ provider: CloudProvider, entries: [(String, String)]) {
        UserDefaults.standard.set(
            entries.map { [$0.0, $0.1] }, forKey: catalogKey(provider))
        UserDefaults.standard.set(Date(), forKey: refreshKey(provider))
    }

    private static func catalogKey(_ p: CloudProvider) -> String { "catalog.fetched.\(p.rawValue)" }
    private static func customKey(_ p: CloudProvider) -> String { "catalog.custom.\(p.rawValue)" }
    private static func refreshKey(_ p: CloudProvider) -> String { "catalog.refreshed.\(p.rawValue)" }
}
