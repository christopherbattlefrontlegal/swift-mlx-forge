// Forge — inference runtime update checker.
//
// The runtimes (mlx-swift-lm for MLX, LLM.swift for GGUF/llama.cpp) are compiled
// into the app by SwiftPM — they cannot be hot-swapped at runtime the way LM
// Studio downloads runtime packs. What Forge does instead: check the upstream
// GitHub releases once a day (and on demand), surface "update available" in the
// Tuning panel, and ship `scripts/update-runtimes.sh` which bumps the pins,
// rebuilds, and repackages Forge.app in one step.

import Foundation
import Observation

@MainActor
@Observable
final class RuntimeUpdateChecker {

    /// Pinned runtime versions. `scripts/update-runtimes.sh` rewrites these in
    /// lock-step with Package.swift — keep the literal formatting intact.
    static let pinnedRuntimes: [(id: String, label: String, repo: String, version: String)] = [
        ("mlx", "MLX runtime (mlx-swift-lm)", "ml-explore/mlx-swift-lm", "3.31.4"),
        ("gguf", "GGUF runtime (LLM.swift · llama.cpp)", "eastriverlee/LLM.swift", "2.1.0"),
    ]

    struct RuntimeStatus: Identifiable {
        let id: String
        let label: String
        let repo: String
        let current: String
        var latest: String?

        var updateAvailable: Bool {
            guard let latest else { return false }
            return RuntimeUpdateChecker.isVersion(latest, newerThan: current)
        }
    }

    private(set) var statuses: [RuntimeStatus]
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var lastError: String?

    private static let lastCheckedKey = "runtimeUpdates.lastChecked"

    init() {
        statuses = Self.pinnedRuntimes.map {
            RuntimeStatus(id: $0.id, label: $0.label, repo: $0.repo, current: $0.version)
        }
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    var updatesAvailable: Bool {
        statuses.contains(where: \.updateAvailable)
    }

    /// Checks at most once a day; call at app start.
    func checkDailyIfNeeded() {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 86_400 { return }
        checkNow()
    }

    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        Task {
            defer { isChecking = false }
            for index in statuses.indices {
                let repo = statuses[index].repo
                do {
                    statuses[index].latest = try await Self.latestReleaseTag(repo: repo)
                } catch {
                    lastError = "Update check failed for \(repo): \(error.localizedDescription)"
                }
            }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
        }
    }

    private static func latestReleaseTag(repo: String) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else {
            throw URLError(.cannotParseResponse)
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric component comparison ("3.31.4" vs "3.31.10"); non-numeric parts compare as 0.
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
