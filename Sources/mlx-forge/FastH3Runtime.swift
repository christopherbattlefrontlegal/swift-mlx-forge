// Forge — local FastH3 8-Step V2 text-to-video-with-audio on Apple Silicon.
//
// Runs FastVideo's maintained MLX recipe, examples/inference/basic/mlx_fasth3_8step.py,
// from a FastVideo clone as a subprocess, turns its progress log into status text,
// and returns the finished MP4 bytes. The three paths come from Settings, Local Video,
// and default to this machine's layout. Developer build only: the Mac App Store
// sandbox must not spawn external commands.

import Foundation

struct FastH3Paths: Equatable {
    static let fastVideoRootKey = "media.fasth3.fastVideoRoot"
    static let checkpointRootKey = "media.fasth3.checkpointRoot"
    static let mlxCheckpointKey = "media.fasth3.mlxCheckpoint"

    static let defaultFastVideoRoot = NSHomeDirectory() + "/FastVideo"
    static let defaultCheckpointRoot =
        "/Volumes/VAULT/machine/models/FastH3-8-Step-V2/checkpoint"
    static let defaultMLXCheckpoint =
        "/Volumes/VAULT/machine/models/FastH3-8-Step-V2/mlx-vsa-int8/int8"

    var fastVideoRoot: String
    var checkpointRoot: String
    var mlxCheckpoint: String

    /// Stored paths, falling back to the defaults for blank or unset keys.
    static func load(defaults: UserDefaults = .standard) -> FastH3Paths {
        func value(_ key: String, _ fallback: String) -> String {
            let stored = defaults.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? fallback : stored
        }
        return FastH3Paths(
            fastVideoRoot: value(fastVideoRootKey, defaultFastVideoRoot),
            checkpointRoot: value(checkpointRootKey, defaultCheckpointRoot),
            mlxCheckpoint: value(mlxCheckpointKey, defaultMLXCheckpoint))
    }

    var python: String { fastVideoRoot + "/.venv/bin/python" }
    var script: String { fastVideoRoot + "/examples/inference/basic/mlx_fasth3_8step.py" }
    var inferenceContract: String { checkpointRoot + "/fastvideo_inference.json" }
    var ditWeights: String { mlxCheckpoint + "/mlx_h3_dit.safetensors" }

    /// Required files that are not on disk, in the order to fix them.
    func missing(fileManager: FileManager = .default) -> [String] {
        [python, script, inferenceContract, ditWeights]
            .filter { !fileManager.fileExists(atPath: $0) }
    }
}

enum FastH3Error: LocalizedError {
    case notConfigured(missing: [String])
    case badSize(String)
    case launchFailed(String)
    case failed(status: Int32, log: String)
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let missing):
            return "FastH3 is not set up. Missing: " + missing.joined(separator: ", ")
                + ". Fix the paths in Settings, Local Video."
        case .badSize(let size):
            return "Unsupported FastH3 size \(size); use WIDTHxHEIGHT."
        case .launchFailed(let reason):
            return "Could not start the FastVideo runtime: \(reason)"
        case .failed(let status, let log):
            return "FastH3 exited with status \(status).\n" + log
        case .noOutput(let path):
            return "FastH3 finished but wrote no video at \(path)."
        }
    }
}

enum FastH3Runtime {
    static let modelName = "FastVideo/FastVideo-FastH3-8-Step-V2"
    /// The recipe's clip: 124 frames at 24 fps, about five seconds, with speech.
    static let numFrames = 124
    static let fps = 24
    static let sizes = ["832x480", "1280x720"]

    /// Why Generate is unavailable right now, or nil when a render can start.
    static func unavailableReason() -> String? {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return "FastH3 runs in the local developer build; the Mac App Store sandbox cannot launch it."
        }
        let missing = FastH3Paths.load().missing()
        guard let first = missing.first else { return nil }
        return "FastH3 is not set up: \(first) is missing. Fix the paths in Settings, Local Video."
    }

    static func dimensions(from size: String) -> (width: Int, height: Int)? {
        let parts = size.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// Arguments after the interpreter, in the maintained recipe's order.
    static func arguments(
        paths: FastH3Paths, prompt: String, width: Int, height: Int, seed: Int,
        outputPath: String
    ) -> [String] {
        [
            paths.script,
            "--model-root", paths.checkpointRoot,
            "--mlx-checkpoint", paths.mlxCheckpoint,
            "--prompt", prompt,
            "--height", String(height),
            "--width", String(width),
            "--num-frames", String(numFrames),
            "--seed", String(seed),
            "--output-path", outputPath,
        ]
    }

    /// Status text for one FastVideo log line, or nil when the line carries no progress.
    static func status(fromLogLine line: String) -> String? {
        if let marker = line.range(of: "H3 denoise step ") {
            let rest = line[marker.upperBound...]
            let token = rest.prefix { $0.isNumber || $0 == "/" }
            let parts = token.split(separator: "/").compactMap { Int($0) }
            if parts.count == 2 {
                return parts[0] >= parts[1]
                    ? "decoding video and audio"
                    : "denoising step \(parts[0]) of \(parts[1])"
            }
        }
        if line.contains("Geometry:") { return "encoding prompt" }
        if line.contains("Loaded MLX H3 DiT") { return "loading DiT" }
        if line.contains("Generation complete") { return "muxing" }
        return nil
    }

    /// Renders `prompt` at `size` ("832x480" or "1280x720") and returns MP4 bytes.
    /// `onStatus` receives phase text as the runtime logs it.
    static func generate(
        prompt: String, size: String, seed: Int,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        let paths = FastH3Paths.load()
        let missing = paths.missing()
        guard missing.isEmpty else { throw FastH3Error.notConfigured(missing: missing) }
        guard let dims = dimensions(from: size) else { throw FastH3Error.badSize(size) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Forge-FastH3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        onStatus("starting FastVideo (seed \(seed))")
        let result: LocalProcessRunner.Result
        do {
            result = try await LocalProcessRunner.run(
                executable: paths.python,
                arguments: arguments(
                    paths: paths, prompt: prompt, width: dims.width, height: dims.height,
                    seed: seed, outputPath: outputURL.path),
                currentDirectory: paths.fastVideoRoot,
                environment: LocalProcessRunner.environment()
            ) { line in
                if let status = status(fromLogLine: line) { onStatus(status) }
            }
        } catch LocalProcessError.launchFailed(let reason) {
            throw FastH3Error.launchFailed(reason)
        }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw FastH3Error.failed(status: result.status, log: result.logTail)
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            throw FastH3Error.noOutput(outputURL.path)
        }
        return data
    }
}
