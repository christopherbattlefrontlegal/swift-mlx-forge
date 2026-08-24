// Forge — cloud media generation clients and the on-disk media library.
//
// One home for every generation API the Media Studio speaks: OpenAI images
// (gpt-image-1), xAI Grok images, and OpenAI Sora video jobs. Video is an
// async job API; the client polls until the render completes and returns the
// MP4 bytes. Generated assets land in Application Support/Forge/Media.

import Foundation
import Observation

enum MediaGenError: LocalizedError {
    case noKey(String)
    case http(Int, String)
    case badResponse(String)
    case videoFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noKey(let provider):
            return "No \(provider) API key set. Add one in Settings."
        case .http(let code, let message):
            return "API error \(code): \(message)"
        case .badResponse(let detail):
            return "Unexpected API response: \(detail)"
        case .videoFailed(let reason):
            return "Video generation failed: \(reason)"
        case .timeout:
            return "Timed out waiting for the render to finish."
        }
    }
}

enum MediaProvider: String, CaseIterable, Identifiable, Codable {
    case openAIImage
    case grokImage
    case openAIVideo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIImage: return "GPT Image"
        case .grokImage: return "Grok Image"
        case .openAIVideo: return "Sora Video"
        }
    }

    var systemImage: String {
        switch self {
        case .openAIImage, .grokImage: return "photo"
        case .openAIVideo: return "video"
        }
    }

    var isVideo: Bool { self == .openAIVideo }

    var hasKey: Bool {
        switch self {
        case .openAIImage, .openAIVideo: return SecretsStore.hasOpenAIKey
        case .grokImage: return SecretsStore.hasXAIKey
        }
    }

    var keyHint: String {
        switch self {
        case .openAIImage, .openAIVideo: return "OpenAI"
        case .grokImage: return "xAI"
        }
    }

    var imageSizes: [String] {
        switch self {
        case .openAIImage: return ["1024x1024", "1536x1024", "1024x1536"]
        case .grokImage: return ["default"]
        case .openAIVideo: return ["1280x720", "720x1280"]
        }
    }
}

enum MediaGenClient {

    // MARK: - Images

    static func generateImage(
        provider: MediaProvider, prompt: String, size: String
    ) async throws -> Data {
        switch provider {
        case .openAIImage:
            guard let key = SecretsStore.openAIAPIKey else {
                throw MediaGenError.noKey("OpenAI")
            }
            var body: [String: Any] = ["model": "gpt-image-1", "prompt": prompt, "n": 1]
            if size != "default" { body["size"] = size }
            let json = try await postJSON(
                url: "https://api.openai.com/v1/images/generations", key: key, body: body)
            return try await imageData(fromGenerationResponse: json)
        case .grokImage:
            guard let key = SecretsStore.xaiAPIKey else {
                throw MediaGenError.noKey("xAI")
            }
            let body: [String: Any] = [
                "model": "grok-2-image", "prompt": prompt,
                "response_format": "b64_json", "n": 1,
            ]
            let json = try await postJSON(
                url: "https://api.x.ai/v1/images/generations", key: key, body: body)
            return try await imageData(fromGenerationResponse: json)
        case .openAIVideo:
            throw MediaGenError.badResponse("Video uses generateVideo().")
        }
    }

    /// Both providers speak the OpenAI images shape: `{"data":[{"b64_json"|"url"}]}`.
    private static func imageData(
        fromGenerationResponse json: [String: Any]
    ) async throws -> Data {
        guard let first = (json["data"] as? [[String: Any]])?.first else {
            throw MediaGenError.badResponse("no data array")
        }
        if let b64 = first["b64_json"] as? String, let data = Data(base64Encoded: b64) {
            return data
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        throw MediaGenError.badResponse("no b64_json or url in data[0]")
    }

    // MARK: - Video (async job API)

    /// Creates a Sora render job, polls until it finishes, and returns MP4 bytes.
    /// `onStatus` receives human-readable progress ("rendering 42%").
    static func generateVideo(
        prompt: String, seconds: Int, size: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        guard let key = SecretsStore.openAIAPIKey else {
            throw MediaGenError.noKey("OpenAI")
        }
        let body: [String: Any] = [
            "model": "sora-2", "prompt": prompt,
            "seconds": String(seconds), "size": size,
        ]
        let created = try await postJSON(
            url: "https://api.openai.com/v1/videos", key: key, body: body)
        guard let jobID = created["id"] as? String else {
            throw MediaGenError.badResponse("video job has no id")
        }

        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(5))
            let job = try await getJSON(
                url: "https://api.openai.com/v1/videos/\(jobID)", key: key)
            let status = (job["status"] as? String) ?? "unknown"
            switch status {
            case "completed":
                onStatus("downloading")
                return try await getData(
                    url: "https://api.openai.com/v1/videos/\(jobID)/content", key: key)
            case "failed":
                let reason =
                    ((job["error"] as? [String: Any])?["message"] as? String)
                    ?? "no reason given"
                throw MediaGenError.videoFailed(reason)
            default:
                if let progress = job["progress"] as? Int {
                    onStatus("rendering \(progress)%")
                } else {
                    onStatus(status.replacingOccurrences(of: "_", with: " "))
                }
            }
        }
        throw MediaGenError.timeout
    }

    // MARK: - HTTP primitives

    private static func postJSON(
        url: String, key: String, body: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeJSON(data: data, response: response)
    }

    private static func getJSON(url: String, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeJSON(data: data, response: response)
    }

    private static func getData(url: String, key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw MediaGenError.http(
                http.statusCode, String(data: data.prefix(400), encoding: .utf8) ?? "")
        }
        return data
    }

    private static func decodeJSON(
        data: Data, response: URLResponse
    ) throws -> [String: Any] {
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            let message =
                ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String })
                ?? (String(data: data.prefix(400), encoding: .utf8) ?? "")
            throw MediaGenError.http(http.statusCode, message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaGenError.badResponse("not a JSON object")
        }
        return json
    }
}

// MARK: - Library

struct MediaAsset: Identifiable, Equatable {
    let url: URL
    let createdAt: Date

    var id: URL { url }
    var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }
    var filename: String { url.lastPathComponent }
}

/// Generated assets on disk. One writer (the main actor) appends; the grid
/// re-reads the folder so externally deleted files fall out naturally.
@MainActor
@Observable
final class MediaLibrary {
    private(set) var assets: [MediaAsset] = []

    let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Forge/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "mp4"]

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        assets = files
            .filter { Self.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let created =
                    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                return MediaAsset(url: url, createdAt: created)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ data: Data, fileExtension: String, provider: MediaProvider) -> MediaAsset? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "gen-\(formatter.string(from: Date()))-\(provider.rawValue).\(fileExtension)"
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url)) != nil else { return nil }
        refresh()
        return assets.first { $0.url == url }
    }

    func delete(_ asset: MediaAsset) {
        try? FileManager.default.removeItem(at: asset.url)
        refresh()
    }
}
