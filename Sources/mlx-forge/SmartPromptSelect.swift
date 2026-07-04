// Forge — Smart Select for the prompt library.
//
// Flow: a mechanical form (no LLM) collects task/goals/notes, a keyword search
// over the awesome-prompts prompt_database index ranks candidates, and the
// active model is asked to pick — or combine and redraft — the best prompt(s).
// The model returns the final system prompt between FORGE_PROMPT_BEGIN/END
// markers; AppState installs it automatically when the reply finishes.

import Foundation
import SwiftUI

struct SmartPromptCandidate: Identifiable {
    let id: String
    let title: String
    let description: String
    let body: String
}

enum SmartPromptDB {

    /// The prompt_database folder that ships next to the user's prompts
    /// directory (awesome-prompts layout: <root>/prompts + <root>/prompt_database).
    static func databaseDirectory(promptDirectories: [URL]) -> URL? {
        let fm = FileManager.default
        for dir in promptDirectories {
            let sibling = dir.deletingLastPathComponent()
                .appendingPathComponent("prompt_database", isDirectory: true)
            if fm.fileExists(atPath: sibling.appendingPathComponent("search.py").path) {
                return sibling
            }
        }
        return nil
    }

    /// Keyword search over the SQLite index; returns candidates with full bodies.
    static func search(
        query: String, database: URL, limit: Int = 5, bodyClip: Int = 3000
    ) async -> [SmartPromptCandidate] {
        let hits = await runScript(
            in: database, script: "search.py", arguments: [query, "-n", "\(limit)", "--json"])
        // search.py --json wraps hits in {"query":…,"count":…,"results":[…]}.
        guard let hits,
            let envelope = decodeJSONObject(hits),
            let rows = envelope["results"] as? [[String: Any]]
        else { return [] }

        var results: [SmartPromptCandidate] = []
        for row in rows.prefix(limit) {
            guard let id = row["id"] as? String else { continue }
            var body = row["body"] as? String ?? ""
            if body.isEmpty {
                if let full = await runScript(
                    in: database, script: "get.py", arguments: [id, "--json"]),
                    let record = decodeJSONObject(full)
                {
                    body = record["body"] as? String ?? ""
                }
            }
            results.append(
                SmartPromptCandidate(
                    id: id,
                    title: (row["title"] as? String) ?? id,
                    description: (row["description"] as? String) ?? "",
                    body: String(body.prefix(bodyClip))))
        }
        return results
    }

    private static func runScript(
        in database: URL, script: String, arguments: [String]
    ) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", database.appendingPathComponent(script).path]
                + arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private static func decodeJSONObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}

/// Mechanical intake form — computed, no model involved.
struct SmartPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var goals = ""
    @State private var notes = ""

    let onSubmit: (_ task: String, _ goals: String, _ notes: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Label("Smart Prompt Select", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))
            Text(
                "Describe the work; Forge searches the prompt library and asks the active model to pick — or combine and redraft — the best prompt, then installs it as the system prompt."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Task").font(.callout.weight(.semibold))
                TextField("What should the model do?", text: $task)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Goals").font(.callout.weight(.semibold))
                TextField("What does a great outcome look like?", text: $goals)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Context / notes (optional)").font(.callout.weight(.semibold))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Find Best Prompt") {
                    onSubmit(task, goals, notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.s5)
        .frame(width: 460)
    }
}
