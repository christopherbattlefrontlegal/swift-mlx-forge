// Forge — the shared directory an agent graph can actually write to.
//
// Every graph gets its own folder under Application Support. File nodes and any
// agent granted workspace access are confined to it: paths are resolved against
// the root and then re-checked after symlink resolution, so neither a "../"
// path nor a symlink planted inside the workspace can reach outside it.
//
// This is deliberately not the user's project directory. An agent that can
// write files is useful; an agent that can write files anywhere is a liability.
// Point real work at it by opening the folder in Finder.

import Foundation

struct AgentWorkspace: Sendable {
    let root: URL

    enum WorkspaceError: LocalizedError {
        case escapesRoot(String)
        case notFound(String)
        case notReadableText(String)
        case tooLarge(String, Int)

        var errorDescription: String? {
            switch self {
            case .escapesRoot(let path):
                return "“\(path)” is outside the graph workspace."
            case .notFound(let path):
                return "No file at “\(path)” in the workspace."
            case .notReadableText(let path):
                return "“\(path)” is not readable as UTF-8 text."
            case .tooLarge(let path, let limit):
                return "“\(path)” is larger than the \(limit / 1024) KB read limit."
            }
        }
    }

    /// Hard ceiling on a single read, so one runaway file cannot fill a prompt.
    static let maxReadBytes = 512 * 1024
    /// Hard ceiling on a single write.
    static let maxWriteBytes = 4 * 1024 * 1024

    static var containerRoot: URL {
        let dir = ForgePaths.appSupport.appendingPathComponent("AgentWorkspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The workspace belonging to one graph. Created on first use.
    static func forGraph(_ graphID: UUID) -> AgentWorkspace {
        let dir = containerRoot.appendingPathComponent(graphID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AgentWorkspace(root: dir.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Deletes everything in the workspace but keeps the folder itself.
    func clear() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Path safety

    /// Resolves a workspace-relative path, refusing anything that lands outside
    /// the root. Checked twice: once on the literal path, once after resolving
    /// symlinks on the deepest existing ancestor.
    func resolve(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        guard !cleaned.isEmpty else { return root }

        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        guard isInside(candidate) else { throw WorkspaceError.escapesRoot(relativePath) }

        // A symlink planted inside the workspace could still point out of it.
        // Resolve the deepest existing ancestor and re-check.
        var probe = candidate
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != root.path {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        let resolved = probe.resolvingSymlinksInPath()
        guard isInside(resolved) || resolved.path == root.path else {
            throw WorkspaceError.escapesRoot(relativePath)
        }
        return candidate
    }

    private func isInside(_ url: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    /// Path as the agent should see it — relative to the workspace root.
    func displayPath(_ url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootPath.count))
    }

    // MARK: - Operations

    func read(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceError.notFound(relativePath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxReadBytes else {
            throw WorkspaceError.tooLarge(relativePath, Self.maxReadBytes)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.notReadableText(relativePath)
        }
        return text
    }

    @discardableResult
    func write(_ relativePath: String, contents: String) throws -> URL {
        let url = try resolve(relativePath)
        let clipped = String(contents.prefix(Self.maxWriteBytes))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(clipped.utf8).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    func append(_ relativePath: String, contents: String) throws -> URL {
        let existing = (try? read(relativePath)) ?? ""
        let joined = existing.isEmpty ? contents : existing + "\n" + contents
        return try write(relativePath, contents: joined)
    }

    /// Recursive listing as "path — size" lines, bounded so a large tree cannot
    /// blow out a prompt.
    func list(limit: Int = 200) -> [String] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var lines: [String] = []
        for case let url as URL in walker {
            if lines.count >= limit { break }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            let size = values?.fileSize ?? 0
            lines.append("\(displayPath(url)) — \(Format.bytes(Int64(size)))")
        }
        return lines.sorted()
    }

    /// Files in the workspace, for the UI panel.
    func entries(limit: Int = 200) -> [Entry] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var result: [Entry] = []
        for case let url as URL in walker {
            if result.count >= limit { break }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true { continue }
            result.append(
                Entry(
                    path: displayPath(url),
                    url: url,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result.sorted { $0.path < $1.path }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        let url: URL
        let sizeBytes: Int64
        let modifiedAt: Date
    }
}
