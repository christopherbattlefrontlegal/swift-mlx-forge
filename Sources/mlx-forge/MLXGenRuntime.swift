// Forge — local reference-conditioned video on Apple Silicon through mlx-gen.
//
// Two routes from the mlx-gen runtime (PyPI `mlx-gen`, Python module `mflux`):
//   - Bernini-R 1.3B reference-to-video: one to eight ordered reference photos
//     plus a prompt produce a new clip of those subjects. No audio.
//   - MiniMax-H3 first-frame image-to-video with synchronized stereo audio: the
//     clip starts from the keyframe; dialogue in the prompt animates the mouth.
// Both run `mlxgen generate --json-events` as a subprocess. The JSONL event
// stream becomes status text. Weights live in the Hugging Face cache under the
// configured HF home; generation never downloads. Developer build only.

import Foundation

enum MLXGenRoute: String, CaseIterable, Sendable {
    case berniniReference
    case h3FirstFrame

    /// The mlx-gen model alias passed to `--model`.
    var modelAlias: String {
        switch self {
        case .berniniReference: return "bernini-r-1.3b"
        case .h3FirstFrame: return "minimax-h3-turbo-544p"
        }
    }

    /// Shown in the Media Studio model picker.
    var displayModel: String {
        switch self {
        case .berniniReference: return "ByteDance/Bernini-R-1.3B (mlx-gen)"
        case .h3FirstFrame: return "MiniMaxAI/MiniMax-H3 Turbo 544p (mlx-gen)"
        }
    }

    var title: String {
        switch self {
        case .berniniReference: return "Bernini-R reference-to-video"
        case .h3FirstFrame: return "H3 image-to-video with audio"
        }
    }

    /// WIDTHxHEIGHT choices. Bernini renders 480x272 at 49 frames and 20 steps
    /// in three minutes on an M3 Ultra with the reference likeness intact; its
    /// official 848x480, 81-frame, 40-step profile ran past 30 minutes here
    /// without finishing, so it is not offered. H3 needs multiples of 32 and
    /// validates at 960x544.
    var sizes: [String] {
        switch self {
        case .berniniReference: return ["480x272", "272x480"]
        case .h3FirstFrame: return ["960x544", "544x960"]
        }
    }

    /// Clip length and denoise steps for the route.
    func profile(width: Int, height: Int) -> (frames: Int, steps: Int) {
        switch self {
        case .berniniReference: return (49, 20)
        case .h3FirstFrame: return (124, 8)
        }
    }

    var referenceImageRange: ClosedRange<Int> {
        switch self {
        case .berniniReference: return 1...8
        case .h3FirstFrame: return 1...1
        }
    }

    var generatesAudio: Bool { self == .h3FirstFrame }

    /// Hugging Face repos that must be in the cache before a render can start.
    var requiredRepos: [String] {
        switch self {
        case .berniniReference:
            // mlx-gen 0.38 routes generation only through the pinned FP32 source
            // package; its smaller bf16 repack downloads but cannot be selected.
            return ["ByteDance/Bernini-R-1.3B-Diffusers"]
        case .h3FirstFrame:
            return ["MiniMaxAI/MiniMax-H3"]
        }
    }

    /// Adapter files mlx-gen keeps in its own LoRA cache, relative to that cache.
    var requiredLoRAs: [String] {
        switch self {
        case .berniniReference: return []
        case .h3FirstFrame: return ["minimax_h3_fl2v_turbo_8step_v1.0_bf16.safetensors"]
        }
    }

    var downloadCommand: String { "mlxgen download --model \(modelAlias)" }
}

struct MLXGenPaths: Equatable, Sendable {
    static let executableKey = "media.mlxgen.executable"
    static let hfHomeKey = "media.mlxgen.hfHome"

    static let defaultExecutable = NSHomeDirectory() + "/mlxgen/bin/mlxgen"

    /// HF_HOME from the environment when the app inherits one, else this
    /// machine's model volume, else the Hugging Face default.
    static var defaultHFHome: String {
        if let env = ProcessInfo.processInfo.environment["HF_HOME"], !env.isEmpty {
            return env
        }
        let vault = "/Volumes/VAULT/_machine_/hf"
        if FileManager.default.fileExists(atPath: vault + "/hub") { return vault }
        return NSHomeDirectory() + "/.cache/huggingface"
    }

    /// Where `mlxgen download` puts Turbo adapters (mflux's LoRA cache).
    static let defaultLoRACache = NSHomeDirectory() + "/Library/Caches/mflux/loras"

    var executable: String
    var hfHome: String
    var loraCache: String = MLXGenPaths.defaultLoRACache

    static func load(defaults: UserDefaults = .standard) -> MLXGenPaths {
        func value(_ key: String, _ fallback: String) -> String {
            let stored = defaults.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? fallback : stored
        }
        return MLXGenPaths(
            executable: value(executableKey, defaultExecutable),
            hfHome: value(hfHomeKey, defaultHFHome))
    }

    var hubDirectory: String { hfHome + "/hub" }

    /// The cache folder name for a repo id: `models--Org--Name`.
    static func cacheFolder(for repo: String) -> String {
        "models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    /// True when the repo has a snapshot on disk and no download is still in
    /// flight (hf_hub leaves `*.incomplete` blobs until each file finishes).
    func isDownloaded(_ repo: String, fileManager: FileManager = .default) -> Bool {
        let folder = hubDirectory + "/" + Self.cacheFolder(for: repo)
        let snapshots = folder + "/snapshots"
        guard let revisions = try? fileManager.contentsOfDirectory(atPath: snapshots),
            revisions.contains(where: { !$0.hasPrefix(".") })
        else { return false }
        let populated = revisions.contains { revision in
            let entries = (try? fileManager.contentsOfDirectory(atPath: snapshots + "/" + revision)) ?? []
            return entries.contains { !$0.hasPrefix(".") }
        }
        guard populated else { return false }
        let blobs = (try? fileManager.contentsOfDirectory(atPath: folder + "/blobs")) ?? []
        return !blobs.contains { $0.hasSuffix(".incomplete") }
    }

    /// What stops `route` from running, in the order to fix it. Empty when ready.
    func missing(for route: MLXGenRoute, fileManager: FileManager = .default) -> [String] {
        var items: [String] = []
        if !fileManager.isExecutableFile(atPath: executable) {
            items.append("\(executable) (install: uv venv ~/mlxgen && uv pip install --python ~/mlxgen/bin/python mlx-gen)")
        }
        for repo in route.requiredRepos where !isDownloaded(repo, fileManager: fileManager) {
            items.append("\(hubDirectory)/\(Self.cacheFolder(for: repo)) (run: \(route.downloadCommand))")
        }
        for lora in route.requiredLoRAs where !fileManager.fileExists(atPath: loraCache + "/" + lora) {
            items.append("\(loraCache)/\(lora) (run: \(route.downloadCommand))")
        }
        return items
    }
}

enum MLXGenError: LocalizedError {
    case notConfigured(route: MLXGenRoute, missing: [String])
    case badSize(String)
    case badReferences(expected: ClosedRange<Int>, got: Int)
    case failed(status: Int32, message: String)
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let route, let missing):
            return "\(route.title) is not set up. Missing: " + missing.joined(separator: "; ")
                + ". Fix the paths in Settings, Local Video."
        case .badSize(let size):
            return "Unsupported size \(size); use WIDTHxHEIGHT."
        case .badReferences(let expected, let got):
            return expected.upperBound == 1
                ? "Add one keyframe image."
                : "Add \(expected.lowerBound) to \(expected.upperBound) reference photos (got \(got))."
        case .failed(let status, let message):
            return "mlx-gen exited with status \(status).\n" + message
        case .noOutput(let path):
            return "mlx-gen finished but wrote no video at \(path)."
        }
    }
}

enum MLXGenRuntime {
    /// Why Generate is unavailable right now, or nil when a render can start.
    static func unavailableReason(for route: MLXGenRoute) -> String? {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return "\(route.title) runs in the local developer build; the Mac App Store sandbox cannot launch it."
        }
        let missing = MLXGenPaths.load().missing(for: route)
        guard let first = missing.first else { return nil }
        return "\(route.title) is not set up: \(first). See Settings, Local Video."
    }

    /// Arguments after the `mlxgen` executable.
    static func arguments(
        route: MLXGenRoute, prompt: String, width: Int, height: Int, frames: Int, steps: Int,
        seed: Int, images: [String], outputPath: String
    ) -> [String] {
        var args = ["generate", "--model", route.modelAlias]
        switch route {
        case .berniniReference:
            for image in images { args += ["--reference-image", image] }
            args += ["--prompt", prompt, "--reference-guidance", "6.0"]
            args += ["--width", String(width), "--height", String(height)]
            args += ["--frames", String(frames), "--fps", "16", "--steps", String(steps)]
        case .h3FirstFrame:
            args += ["--image-path", images[0], "--prompt", prompt]
            args += ["--width", String(width), "--height", String(height)]
            args += ["--frames", String(frames), "--steps", String(steps), "--quantize", "8"]
        }
        args += ["--seed", String(seed), "--output", outputPath, "--json-events", "--no-progress"]
        return args
    }

    /// Parses one `--json-events` line (or a plain log line) into status text,
    /// or nil when the line carries no progress.
    static func status(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let event = runtimeEvent(fromLine: trimmed) {
            let phase = (event["phase"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
            switch phase {
            case "complete", "generated": return "finishing"
            case "save", "saved", "saving": return "writing video"
            case "failed", "": return nil
            default:
                let step = event["step"] as? Int ?? 0
                let total = event["total_steps"] as? Int ?? 0
                if total > 0 {
                    return step >= total ? "decoding video" : "\(phase) step \(step) of \(total)"
                }
                return phase
            }
        }
        if trimmed.contains("Saving video to") { return "writing video" }
        if trimmed.hasPrefix("Loading") || trimmed.contains("Quantizing") { return "loading model" }
        return nil
    }

    /// The error text of a `failed` event, if the log tail has one.
    static func failureMessage(fromLogTail tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() {
            if let event = runtimeEvent(fromLine: String(line)),
                event["phase"] as? String == "failed",
                let error = event["error"] as? String, !error.isEmpty
            {
                return error
            }
        }
        return nil
    }

    private static func runtimeEvent(fromLine line: String) -> [String: Any]? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "runtime"
        else { return nil }
        return object
    }

    /// Renders `prompt` conditioned on `images` and returns MP4 bytes. `frames`
    /// and `steps` override the route's defaults (the end-to-end test renders a
    /// short smoke clip; mlx-gen allows under 25 frames only at 12 steps or fewer).
    static func generate(
        route: MLXGenRoute, prompt: String, size: String, seed: Int, images: [URL],
        frames: Int? = nil, steps: Int? = nil,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        let paths = MLXGenPaths.load()
        let missing = paths.missing(for: route)
        guard missing.isEmpty else {
            throw MLXGenError.notConfigured(route: route, missing: missing)
        }
        guard route.referenceImageRange.contains(images.count) else {
            throw MLXGenError.badReferences(expected: route.referenceImageRange, got: images.count)
        }
        guard let dims = FastH3Runtime.dimensions(from: size) else { throw MLXGenError.badSize(size) }
        let profile = route.profile(width: dims.width, height: dims.height)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Forge-MLXGen", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let environment = LocalProcessRunner.environment(adding: [
            "HF_HOME": paths.hfHome,
            "HUGGINGFACE_HUB_CACHE": paths.hubDirectory,
            "HF_HUB_OFFLINE": "1",
        ])
        onStatus("starting mlx-gen (seed \(seed))")
        let result: LocalProcessRunner.Result
        do {
            result = try await LocalProcessRunner.run(
                executable: paths.executable,
                arguments: arguments(
                    route: route, prompt: prompt, width: dims.width, height: dims.height,
                    frames: frames ?? profile.frames, steps: steps ?? profile.steps, seed: seed,
                    images: images.map(\.path), outputPath: outputURL.path),
                currentDirectory: outputDir.path,
                environment: environment
            ) { line in
                if let status = status(fromLine: line) { onStatus(status) }
            }
        } catch let error as LocalProcessError {
            throw MLXGenError.failed(status: -1, message: error.localizedDescription)
        }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw MLXGenError.failed(
                status: result.status,
                message: failureMessage(fromLogTail: result.logTail) ?? result.logTail)
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            throw MLXGenError.noOutput(outputURL.path)
        }
        return data
    }
}
