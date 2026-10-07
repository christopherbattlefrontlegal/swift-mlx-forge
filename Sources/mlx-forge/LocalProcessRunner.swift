// Forge — runs a local command-line renderer as a subprocess.
//
// Shared by the local video runtimes (FastH3, mlx-gen). Merges stdout and
// stderr into one line stream for the caller's status parser, keeps a short
// tail of the log for error reports, and terminates the child on task
// cancellation. Developer build only: the Mac App Store sandbox must not spawn
// external commands.

import Foundation

enum LocalProcessError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not start the local runtime: \(reason)"
        }
    }
}

enum LocalProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let logTail: String
    }

    /// Splits the merged stdout/stderr stream into lines and keeps the tail for errors.
    final class LineLog: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = ""
        private var lines: [String] = []
        private let limit: Int

        init(limit: Int = 60) { self.limit = limit }

        func ingest(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            partial += String(decoding: data, as: UTF8.self)
            var completed: [String] = []
            while let newline = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(partial[..<newline])
                partial = String(partial[partial.index(after: newline)...])
                if !line.isEmpty { completed.append(line) }
            }
            lines.append(contentsOf: completed)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
            return completed
        }

        var tail: String {
            lock.lock()
            defer { lock.unlock() }
            let all = partial.isEmpty ? lines : lines + [partial]
            return all.joined(separator: "\n")
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    /// A Finder-launched app has a minimal PATH; local renderers need Homebrew's ffmpeg.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] =
            "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["PYTHONUNBUFFERED"] = "1"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Runs `executable` and calls `onLine` for every complete output line.
    /// Returns when the process exits; throws `LocalProcessError.launchFailed`
    /// when it cannot start. Cancelling the task terminates the process.
    static func run(
        executable: String, arguments: [String], currentDirectory: String?,
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Result {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(
                fileURLWithPath: currentDirectory, isDirectory: true)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let log = LineLog()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in log.ingest(data) { onLine(line) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    for line in log.ingest(pipe.fileHandleForReading.readDataToEndOfFile()) {
                        onLine(line)
                    }
                    continuation.resume(
                        returning: Result(
                            status: finished.terminationStatus, logTail: log.tail))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        throwing: LocalProcessError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
