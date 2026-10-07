// Forge — opens the Music Video Studio: a Claude Code session in a terminal,
// started from a launcher script inside a workspace folder whose CLAUDE.md
// briefs the session on the band, the song, and every local video tool on this
// Mac. The Media tab button calls this. Developer build only.

import AppKit
import Foundation

enum StudioLauncherError: LocalizedError {
    case missingLauncher(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLauncher(let path):
            return "No studio launcher at \(path). Set the path in Settings, Local Video."
        case .openFailed(let reason):
            return "Could not open the studio: \(reason)"
        }
    }
}

enum StudioLauncher {
    static let launcherKey = "media.studio.launcher"
    static let defaultLauncher = NSHomeDirectory() + "/MusicVideoStudio/launch.command"

    /// The launcher script path from Settings, or the default workspace.
    static func launcherPath(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: launcherKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultLauncher : stored
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: launcherPath())
    }

    /// Opens the launcher in iTerm2 when it is installed, else in the default
    /// handler for `.command` files (Terminal). No scripting permissions needed.
    @MainActor
    static func open() throws {
        let path = launcherPath()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw StudioLauncherError.missingLauncher(path)
        }
        let script = URL(fileURLWithPath: path)
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if FileManager.default.fileExists(atPath: iterm.path) {
            NSWorkspace.shared.open([script], withApplicationAt: iterm, configuration: configuration) {
                _, error in
                guard let error else { return }
                NSLog("StudioLauncher: iTerm open failed (\(error.localizedDescription)); using default handler")
                DispatchQueue.main.async { NSWorkspace.shared.open(script) }
            }
        } else {
            NSWorkspace.shared.open(script)
        }
    }
}
