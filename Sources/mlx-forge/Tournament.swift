// Forge — model tournament: frontier models compete on one task through a
// judged single-elimination bracket, all via OpenRouter.
//
// Every contestant answers the task once, in parallel. The bracket then
// compares answers pairwise: the judge sees anonymized answers twice with
// positions swapped (position bias is real); a split verdict gets a tiebreak
// vote. Answers are reused across rounds, so each model is asked exactly once.

import Foundation
import Observation
import SwiftUI

struct TournamentMatch: Identifiable {
    enum State: Equatable {
        case pending
        case judging
        case decided
        case bye
    }

    let id = UUID()
    let round: Int
    let modelA: String
    let modelB: String?
    var state: State = .pending
    var winner: String?
    var rationale: String = ""
}

@MainActor
@Observable
final class TournamentRun {
    enum Phase: Equatable {
        case idle
        case answering
        case bracket
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var answers: [String: String] = [:]
    private(set) var forfeits: [String: String] = [:]
    private(set) var rounds: [[TournamentMatch]] = []
    private(set) var champion: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .answering || phase == .bracket }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { phase = .idle }
    }

    func start(contestants: [String], judge: String, taskPrompt: String, maxTokens: Int) {
        guard !isRunning else { return }
        answers = [:]
        forfeits = [:]
        rounds = []
        champion = nil
        phase = .answering
        task = Task { @MainActor in
            do {
                try await collectAnswers(contestants: contestants, prompt: taskPrompt, maxTokens: maxTokens)
                try await runBracket(judge: judge, taskPrompt: taskPrompt)
                phase = .finished
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Phase 1: every contestant answers once, in parallel

    private func collectAnswers(
        contestants: [String], prompt: String, maxTokens: Int
    ) async throws {
        try await withThrowingTaskGroup(of: (String, Result<String, Error>).self) { group in
            for model in contestants {
                group.addTask {
                    do {
                        let answer = try await TournamentRun.complete(
                            model: model,
                            messages: [["role": "user", "content": prompt]],
                            maxTokens: maxTokens)
                        return (model, .success(answer))
                    } catch {
                        return (model, .failure(error))
                    }
                }
            }
            for try await (model, result) in group {
                switch result {
                case .success(let answer):
                    answers[model] = answer
                case .failure(let error):
                    forfeits[model] = error.localizedDescription
                }
            }
        }
        guard answers.count >= 2 else {
            throw TournamentError.notEnoughAnswers(answers.count, forfeits)
        }
    }

    // MARK: - Phase 2: judged single-elimination bracket

    private func runBracket(judge: String, taskPrompt: String) async throws {
        phase = .bracket
        var field = answers.keys.shuffled()
        var roundIndex = 0
        while field.count > 1 {
            var thisRound: [TournamentMatch] = []
            var pairs: [(String, String)] = []
            var byes: [String] = []
            var iterator = field.makeIterator()
            while let a = iterator.next() {
                if let b = iterator.next() {
                    pairs.append((a, b))
                    thisRound.append(TournamentMatch(round: roundIndex, modelA: a, modelB: b))
                } else {
                    byes.append(a)
                    var bye = TournamentMatch(round: roundIndex, modelA: a, modelB: nil)
                    bye.state = .bye
                    bye.winner = a
                    thisRound.append(bye)
                }
            }
            rounds.append(thisRound)
            let currentRound = rounds.count - 1

            var winners: [String] = byes
            try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
                for (matchOffset, pair) in pairs.enumerated() {
                    let answerA = answers[pair.0] ?? ""
                    let answerB = answers[pair.1] ?? ""
                    rounds[currentRound][matchIndex(in: currentRound, offset: matchOffset)]
                        .state = .judging
                    group.addTask {
                        let verdict = try await TournamentRun.judgePair(
                            judge: judge, taskPrompt: taskPrompt,
                            modelA: pair.0, answerA: answerA,
                            modelB: pair.1, answerB: answerB)
                        return (matchOffset, verdict.winner, verdict.reason)
                    }
                }
                for try await (matchOffset, winner, reason) in group {
                    let index = matchIndex(in: currentRound, offset: matchOffset)
                    rounds[currentRound][index].winner = winner
                    rounds[currentRound][index].rationale = reason
                    rounds[currentRound][index].state = .decided
                    winners.append(winner)
                }
            }
            field = winners.shuffled()
            roundIndex += 1
        }
        champion = field.first
    }

    /// Judged matches occupy the same order as `pairs`; byes are appended after
    /// pair construction order, so map a pair offset to its match slot.
    private func matchIndex(in round: Int, offset: Int) -> Int {
        var seen = 0
        for (index, match) in rounds[round].enumerated() where match.modelB != nil {
            if seen == offset { return index }
            seen += 1
        }
        return 0
    }

    // MARK: - Judging

    private struct Verdict {
        let winner: String
        let reason: String
    }

    private static func judgePair(
        judge: String, taskPrompt: String,
        modelA: String, answerA: String,
        modelB: String, answerB: String
    ) async throws -> Verdict {
        let first = try await judgeOnce(
            judge: judge, taskPrompt: taskPrompt, answerA: answerA, answerB: answerB)
        let second = try await judgeOnce(
            judge: judge, taskPrompt: taskPrompt, answerA: answerB, answerB: answerA)
        // Second call had swapped positions, so its "A" means the real B.
        let secondNormalized = (winner: second.winner == "A" ? "B" : "A", reason: second.reason)

        let agreed: (winner: String, reason: String)
        if first.winner == secondNormalized.winner {
            agreed = first
        } else {
            let tiebreak = try await judgeOnce(
                judge: judge, taskPrompt: taskPrompt, answerA: answerA, answerB: answerB)
            agreed = tiebreak
        }
        return Verdict(
            winner: agreed.winner == "A" ? modelA : modelB,
            reason: agreed.reason)
    }

    private static func judgeOnce(
        judge: String, taskPrompt: String, answerA: String, answerB: String
    ) async throws -> (winner: String, reason: String) {
        let prompt = """
            You are the judge of a head-to-head model competition. Two anonymous \
            answers to the same task are below. Pick the better one on correctness, \
            completeness, and clarity, in that order.

            TASK:
            \(taskPrompt)

            ANSWER A:
            \(answerA)

            ANSWER B:
            \(answerB)

            Respond with ONLY this JSON, nothing else:
            {"winner": "A" or "B", "reason": "one or two sentences"}
            """
        let raw = try await complete(
            model: judge,
            messages: [["role": "user", "content": prompt]],
            maxTokens: 400)
        return parseVerdict(raw)
    }

    private static func parseVerdict(_ raw: String) -> (winner: String, reason: String) {
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
            let data = String(raw[start...end]).data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let winner = (json["winner"] as? String)?.uppercased(),
            winner == "A" || winner == "B"
        {
            return (winner, (json["reason"] as? String) ?? "")
        }
        // Fallback for judges that ignore the JSON instruction.
        let upper = raw.uppercased()
        if upper.contains("WINNER: B") || upper.contains("\"B\"") { return ("B", raw) }
        return ("A", raw)
    }

    // MARK: - OpenRouter non-streaming completion

    static func complete(
        model: String, messages: [[String: Any]], maxTokens: Int
    ) async throws -> String {
        guard let apiKey = SecretsStore.openRouterAPIKey else {
            throw OpenRouterError.noKey
        }
        var request = URLRequest(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Forge", forHTTPHeaderField: "X-OpenRouter-Title")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw OpenRouterError.http(
                http.statusCode, String(data: data.prefix(400), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenRouterError.stream("no message content in completion response")
        }
        return content
    }
}

enum TournamentError: LocalizedError {
    case notEnoughAnswers(Int, [String: String])

    var errorDescription: String? {
        switch self {
        case .notEnoughAnswers(let count, let forfeits):
            let details = forfeits.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return "Only \(count) contestant(s) answered. Forfeits: \(details)"
        }
    }
}

// MARK: - View

struct TournamentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var run = TournamentRun()
    @State private var taskPrompt = ""
    @State private var judge = "anthropic/claude-sonnet-4.5"
    @State private var maxTokens = 2048
    @State private var customSlug = ""
    @State private var selectedModels: Set<String> = [
        "anthropic/claude-sonnet-4.5",
        "openai/gpt-5",
        "google/gemini-2.5-pro",
        "x-ai/grok-4.3",
    ]
    @State private var availableModels: [String] = [
        "anthropic/claude-sonnet-4.5",
        "openai/gpt-5",
        "google/gemini-2.5-pro",
        "x-ai/grok-4.3",
        "deepseek/deepseek-v3.2",
        "moonshotai/kimi-k3",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Label("Model Tournament", systemImage: "trophy")
                    .font(.title3.weight(.semibold))
                Spacer()
                if run.isRunning {
                    Button("Stop") { run.cancel() }
                }
                Button("Close") {
                    run.cancel()
                    dismiss()
                }
            }

            if run.phase == .idle || isFailed {
                configForm
            } else {
                bracketView
            }
        }
        .padding(Theme.s5)
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.backgroundGradient)
    }

    private var isFailed: Bool {
        if case .failed = run.phase { return true }
        return false
    }

    // MARK: Config

    private var configForm: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if !app.hasOpenRouterKey {
                Label(
                    "Tournaments run through OpenRouter. Add a key in Settings first.",
                    systemImage: "key.slash")
                .foregroundStyle(Theme.emberGlow)
            }
            if case .failed(let message) = run.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Task").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $taskPrompt)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(Theme.s2)
                .background(Theme.composerBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            Text("Contestants (\(selectedModels.count) selected)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(availableModels, id: \.self) { slug in
                        Toggle(
                            slug,
                            isOn: Binding(
                                get: { selectedModels.contains(slug) },
                                set: { on in
                                    if on { selectedModels.insert(slug) } else {
                                        selectedModels.remove(slug)
                                    }
                                }))
                    }
                }
            }
            .frame(maxHeight: 140)

            HStack(spacing: Theme.s2) {
                TextField("add model slug (e.g. mistralai/mistral-large)", text: $customSlug)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let slug = customSlug.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !slug.isEmpty, !availableModels.contains(slug) else { return }
                    availableModels.append(slug)
                    selectedModels.insert(slug)
                    customSlug = ""
                }
                .disabled(customSlug.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: Theme.s4) {
                Picker("Judge", selection: $judge) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 340)
                Stepper("Max answer tokens \(maxTokens)", value: $maxTokens, in: 512...16384, step: 512)
            }
            if selectedModels.contains(judge) {
                Text("The judge is also competing. That works, but a neutral judge is fairer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                run.start(
                    contestants: Array(selectedModels), judge: judge,
                    taskPrompt: taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxTokens: maxTokens)
            } label: {
                Label("Run Tournament", systemImage: "flag.checkered")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ember)
            .disabled(
                !app.hasOpenRouterKey || selectedModels.count < 2
                    || taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Bracket

    private var bracketView: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if run.phase == .answering {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Contestants are answering (\(run.answers.count) in)…")
                        .font(.callout)
                }
            }
            if let champion = run.champion {
                championBanner(champion)
            }
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: Theme.s5) {
                    ForEach(Array(run.rounds.enumerated()), id: \.offset) { index, round in
                        VStack(alignment: .leading, spacing: Theme.s3) {
                            Text(roundTitle(index, totalContestants: run.answers.count))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(round) { match in
                                matchCard(match)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.s2)
            }
            if !run.forfeits.isEmpty {
                Text(
                    "Forfeits: "
                        + run.forfeits.keys.sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func roundTitle(_ index: Int, totalContestants: Int) -> String {
        let remaining = run.rounds[index].count
        if remaining == 1 { return "Final" }
        if remaining == 2 { return "Semifinals" }
        return "Round \(index + 1)"
    }

    private func matchCard(_ match: TournamentMatch) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            entrantRow(match.modelA, match: match)
            if let modelB = match.modelB {
                entrantRow(modelB, match: match)
            } else {
                Text("bye").font(.caption2).foregroundStyle(.secondary)
            }
            if match.state == .judging {
                HStack(spacing: Theme.s1) {
                    ProgressView().controlSize(.mini)
                    Text("judging").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !match.rationale.isEmpty {
                DisclosureGroup("judge's reason") {
                    Text(match.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .font(.caption2)
            }
        }
        .padding(Theme.s2)
        .frame(width: 290, alignment: .leading)
        .background(Theme.assistantBubble)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func entrantRow(_ model: String, match: TournamentMatch) -> some View {
        HStack(spacing: Theme.s1) {
            Image(
                systemName: match.winner == nil
                    ? "circle" : (match.winner == model ? "crown.fill" : "xmark"))
                .font(.caption2)
                .foregroundStyle(match.winner == model ? Theme.ember : Theme.steel)
            Text(model)
                .font(.caption.monospaced())
                .lineLimit(1)
                .foregroundStyle(
                    match.winner == nil || match.winner == model ? .primary : .secondary)
        }
    }

    private func championBanner(_ champion: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label("\(champion) wins", systemImage: "crown.fill")
                .font(.headline)
                .foregroundStyle(Theme.ember)
            if let answer = run.answers[champion] {
                ScrollView {
                    Text(answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack {
                    Button("Copy winning answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                    .controlSize(.small)
                    Button("New tournament") {
                        run = TournamentRun()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(Theme.s3)
        .background(Theme.userBubble)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
    }
}
