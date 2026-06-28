// Forge — model discovery, downloads, and local library management.
//
// Local models come from:
//   1. Forge's managed download cache (~/Library/Application Support/Forge/Models, HubCache layout)
//   2. Any extra directories the user adds (plain folders containing config.json + *.safetensors,
//      or HubCache-layout roots)
//
// Remote discovery hits the public Hugging Face REST API directly (no SDK needed),
// downloads go through the same HubClient/Downloader stack the runtime loads with,
// so a finished download is immediately loadable from cache with no re-fetch.

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Observation

@MainActor
@Observable
final class ModelStore {

    // MARK: Library

    private(set) var localModels: [LocalModel] = []
    var extraDirectories: [URL] = [] {
        didSet { refreshLocal() }
    }

    // MARK: Discovery

    var searchQuery: String = ""
    private(set) var searchResults: [RemoteModel] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?

    /// Hand-picked starting points shown before the user searches.
    static let featured: [RemoteModel] = [
        .init(id: "mlx-community/Qwen3-4B-4bit"),
        .init(id: "mlx-community/Qwen3-8B-4bit"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        .init(id: "mlx-community/gemma-3-4b-it-4bit"),
        .init(id: "mlx-community/Phi-4-mini-instruct-4bit"),
        .init(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit"),
        .init(id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit"),
        .init(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"),
    ]

    // MARK: Downloads

    @MainActor
    @Observable
    final class DownloadTask: Identifiable {
        let id: String  // repo id
        var fraction: Double = 0
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var failed: String?
        var finished = false
        fileprivate var task: Task<Void, Never>?

        init(id: String) { self.id = id }
    }

    private(set) var downloads: [DownloadTask] = []

    /// The shared downloader writing into Forge's managed cache.
    /// Uses the Keychain token when set; otherwise falls back to the
    /// environment/HF-CLI token auto-detection built into HubClient.
    nonisolated static func makeDownloader() -> any Downloader {
        let cache = HubCache(cacheDirectory: ForgePaths.modelsRoot)
        let client: HubClient
        if let token = SecretsStore.huggingFaceToken {
            client = HubClient(host: HubClient.defaultHost, bearerToken: token, cache: cache)
        } else {
            client = HubClient(cache: cache)
        }
        return #hubDownloader(client)
    }

    /// Whether a Hugging Face token is stored in the Keychain.
    private(set) var hasToken = false

    func setToken(_ token: String?) {
        SecretsStore.huggingFaceToken = token
        hasToken = SecretsStore.hasHuggingFaceToken
    }

    init() {
        hasToken = SecretsStore.hasHuggingFaceToken
        refreshLocal()
    }

    // MARK: - Local scanning

    /// Called once after the first scan completes (used to auto-reload the last model).
    var onFirstScan: (() -> Void)?
    private(set) var isScanning = false
    private var scanGeneration = 0
    private var hasScannedOnce = false

    /// Scans all roots off the main thread; directory walks over large model
    /// trees on external volumes can block for seconds and must never stall app
    /// startup or the UI.
    func refreshLocal() {
        var roots = [ForgePaths.modelsRoot]
        roots.append(contentsOf: extraDirectories)
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true

        Task.detached(priority: .userInitiated) {
            var found: [LocalModel] = []
            for root in roots {
                found.append(
                    contentsOf: Self.scan(root: root, managed: root == ForgePaths.modelsRoot))
            }
            // Deduplicate by resolved directory.
            var seen = Set<String>()
            let models = found.filter { seen.insert($0.id).inserted }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            await MainActor.run {
                guard generation == self.scanGeneration else { return }  // superseded
                self.localModels = models
                self.isScanning = false
                if !self.hasScannedOnce {
                    self.hasScannedOnce = true
                    self.onFirstScan?()
                    self.onFirstScan = nil
                }
            }
        }
    }

    /// True if a repo id (org/name) is already present locally.
    func isDownloaded(_ repoID: String) -> Bool {
        localModels.contains { $0.name == repoID }
    }

    func activeDownload(for repoID: String) -> DownloadTask? {
        downloads.first { $0.id == repoID && !$0.finished && $0.failed == nil }
    }

    private nonisolated static func scan(root: URL, managed: Bool) -> [LocalModel] {
        let fm = FileManager.default

        // The root may itself be a model folder (the user picked the model dir
        // directly, not its parent). Register it as one model and stop.
        if fm.fileExists(atPath: root.appendingPathComponent("config.json").path),
            hasWeights(root)
        {
            return [
                makeLocalModel(
                    name: root.lastPathComponent,
                    directory: root,
                    sizeBytes: directorySize(root),
                    architecture: architecture(of: root),
                    quantization: quantization(of: root),
                    isManaged: false,
                    deletableRoot: nil)
            ]
        }

        guard
            let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var models: [LocalModel] = []
        for entry in entries {
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

            if !isDirectory {
                // Loose GGUF file at the top level (llama.cpp backend).
                if entry.pathExtension.lowercased() == "gguf" {
                    models.append(ggufModel(file: entry))
                }
                continue
            }

            if entry.lastPathComponent.hasPrefix("models--") {
                // HubCache layout: models--org--name/snapshots/<revision>/
                if let model = scanHubCacheEntry(entry, managed: managed) {
                    models.append(model)
                }
            } else if fm.fileExists(atPath: entry.appendingPathComponent("config.json").path) {
                // Plain model folder.
                if hasWeights(entry) {
                    models.append(
                        makeLocalModel(
                            name: entry.lastPathComponent,
                            directory: entry,
                            sizeBytes: directorySize(entry),
                            architecture: architecture(of: entry),
                            quantization: quantization(of: entry),
                            isManaged: false,
                            deletableRoot: nil))
                }
            } else {
                // Folder of GGUF files (e.g. <model>-gguf/), possibly one level
                // deeper (org/<model>-gguf/): one model per file.
                models.append(contentsOf: ggufModels(in: entry))
            }
        }
        return models
    }

    /// GGUF files in `dir`, descending one extra directory level (covers the
    /// common org/<model>-gguf/ layout).
    private nonisolated static func ggufModels(in dir: URL, depth: Int = 0) -> [LocalModel] {
        guard depth <= 4,
            let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var found: [LocalModel] = []
        for item in items {
            let isDirectory =
                (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                found.append(contentsOf: ggufModels(in: item, depth: depth + 1))
            } else if item.pathExtension.lowercased() == "gguf" {
                found.append(ggufModel(file: item))
            }
        }
        return found
    }

    /// A GGUF file as a model entry — runs on the llama.cpp backend.
    private nonisolated static func ggufModel(file: URL) -> LocalModel {
        let size =
            (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return makeLocalModel(
            name: file.deletingPathExtension().lastPathComponent,
            directory: file,
            sizeBytes: size,
            architecture: "gguf · llama.cpp",
            quantization: ggufQuantization(from: file.lastPathComponent),
            isManaged: false,
            deletableRoot: nil,
            isGGUF: true)
    }

    /// Pull "Q4_K_M" / "Q8_0" / "IQ2_XS" / "TQ1_0" / "F16" out of a filename.
    private nonisolated static func ggufQuantization(from name: String) -> String? {
        let pattern = "(?i)(i?q[0-9]_[0-9a-z_]+|tq[0-9]_[0-9]|f16|bf16|f32)"
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range]).uppercased()
    }

    private nonisolated static func scanHubCacheEntry(_ entry: URL, managed: Bool) -> LocalModel? {
        let fm = FileManager.default
        let name = entry.lastPathComponent
            .replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
        let snapshots = entry.appendingPathComponent("snapshots")
        guard
            let revisions = try? fm.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        // Prefer the revision pointed at by refs/main, fall back to newest.
        var snapshot: URL?
        let mainRef = entry.appendingPathComponent("refs/main")
        if let rev = try? String(contentsOf: mainRef, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            // `rev` is file content from a user-writable cache dir; treat it as a
            // single path component and reject traversal so it can't escape
            // `snapshots/` into an arbitrary directory.
            !rev.isEmpty, !rev.contains("/"), !rev.contains("\\"), !rev.contains(".."),
            fm.fileExists(atPath: snapshots.appendingPathComponent(rev).path)
        {
            snapshot = snapshots.appendingPathComponent(rev)
        } else {
            snapshot = revisions.max {
                let a =
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                let b =
                    (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                return a < b
            }
        }
        guard let snapshot,
            fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path),
            hasWeights(snapshot)
        else { return nil }

        return makeLocalModel(
            name: name,
            directory: snapshot,
            sizeBytes: directorySize(entry.appendingPathComponent("blobs")),
            architecture: architecture(of: snapshot),
            quantization: quantization(of: snapshot),
            isManaged: managed,
            deletableRoot: entry)
    }

    private nonisolated static func hasWeights(_ dir: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return names.contains { $0.hasSuffix(".safetensors") }
    }

    private nonisolated static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileSizeKey,
            ])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private nonisolated static func configJSON(of dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private nonisolated static func architecture(of dir: URL) -> String? {
        configJSON(of: dir)?["model_type"] as? String
    }

    private nonisolated static func quantization(of dir: URL) -> String? {
        guard let q = configJSON(of: dir)?["quantization"] as? [String: Any],
            let bits = q["bits"] as? Int
        else { return nil }
        return "\(bits)-bit"
    }

    private nonisolated static func sniffTemplateCaps(
        directory: URL, isGGUF: Bool
    ) -> ChatTemplateSniffer.Capabilities? {
        if isGGUF { return nil }
        return ChatTemplateSniffer.sniff(modelDirectory: directory)
    }

    private nonisolated static func makeLocalModel(
        name: String,
        directory: URL,
        sizeBytes: Int64,
        architecture: String?,
        quantization: String?,
        isManaged: Bool,
        deletableRoot: URL?,
        isGGUF: Bool = false
    ) -> LocalModel {
        LocalModel(
            name: name,
            directory: directory,
            sizeBytes: sizeBytes,
            architecture: architecture,
            quantization: quantization,
            isManaged: isManaged,
            deletableRoot: deletableRoot,
            chatTemplateCaps: sniffTemplateCaps(directory: directory, isGGUF: isGGUF))
    }

    // MARK: - Hugging Face discovery

    func search() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))  // debounce
                var components = URLComponents(string: "https://huggingface.co/api/models")!
                components.queryItems = [
                    .init(name: "search", value: query),
                    .init(name: "filter", value: "mlx"),
                    .init(name: "sort", value: "downloads"),
                    .init(name: "direction", value: "-1"),
                    .init(name: "limit", value: "40"),
                ]
                var request = URLRequest(url: components.url!)
                if let token = SecretsStore.huggingFaceToken {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let results = try JSONDecoder().decode([RemoteModel].self, from: data)
                guard !Task.isCancelled else { return }
                self?.searchResults = results
                self?.isSearching = false
            } catch is CancellationError {
                // superseded by a newer search
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchError = error.localizedDescription
                self?.isSearching = false
            }
        }
    }

    // MARK: - Downloads

    func download(_ repoID: String) {
        guard activeDownload(for: repoID) == nil else { return }
        let tracker = DownloadTask(id: repoID)
        downloads.append(tracker)

        tracker.task = Task {
            do {
                let downloader = Self.makeDownloader()
                _ = try await downloader.download(
                    id: repoID,
                    revision: nil,
                    matching: ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model"],
                    useLatest: false
                ) { progress in
                    Task { @MainActor in
                        tracker.fraction = progress.fractionCompleted
                        tracker.completedBytes = progress.completedUnitCount
                        tracker.totalBytes = progress.totalUnitCount
                    }
                }
                tracker.fraction = 1
                tracker.finished = true
                self.refreshLocal()
            } catch {
                tracker.failed = error.localizedDescription
            }
        }
    }

    func cancelDownload(_ tracker: DownloadTask) {
        tracker.task?.cancel()
        downloads.removeAll { $0.id == tracker.id }
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.finished || $0.failed != nil }
    }

    // MARK: - Deletion

    func delete(_ model: LocalModel) {
        // Only ever remove trees inside Forge's managed cache, and do the multi-GB
        // filesystem walk off the main actor so the UI doesn't beachball.
        guard model.isManaged, let root = model.deletableRoot else { return }
        Task.detached(priority: .utility) { [weak self] in
            try? FileManager.default.removeItem(at: root)
            await MainActor.run { self?.refreshLocal() }
        }
    }
}
