// Forge — multi-agent coding loop via OpenRouter.
//
// Runs planner → coder → auditor → fixer → tester in rounds until the tester
// signs off or max rounds is hit. One OpenRouter model slug drives every role.

import Foundation

struct CodingOrchestratorConfig: Codable, Equatable {
    var modelID: String = "qwen/qwen3-coder"
    var maxRounds: Int = 3
}

enum CodingOrchestrator {
    enum Phase: String, CaseIterable {
        case planner
        case coder
        case auditor
        case fixer
        case tester
        case orchestrator

        var title: String {
            switch self {
            case .planner: "Planner"
            case .coder: "Coder"
            case .auditor: "Auditor"
            case .fixer: "Fixer"
            case .tester: "Tester"
            case .orchestrator: "Orchestrator"
            }
        }

        var systemPrompt: String {
            switch self {
            case .planner:
                return """
                You are the planner in a coding agent loop. Break the user's task into \
                concrete steps, files to touch, risks, and acceptance criteria. Be concise. \
                Output markdown with numbered steps.
                """
            case .coder:
                return """
                You are the coder. Using the plan and any prior audit notes, write or revise \
                the implementation. Output complete, copy-pasteable code blocks with paths in \
                comments. Do not hand-wave — ship real code.
                """
            case .auditor:
                return """
                You are the auditor. Review the latest code for correctness, security, edge \
                cases, and style. List issues as bullets with severity (blocker/major/minor). \
                If clean, say PASS with one line why.
                """
            case .fixer:
                return """
                You are the fixer. Apply the auditor's findings. Output corrected code blocks \
                only where changes are needed; explain each fix briefly.
                """
            case .tester:
                return """
                You are the tester. Given the task and latest code, describe tests to run and \
                whether you expect them to pass. End with a line exactly: \
                VERDICT: PASS or VERDICT: FAIL and one sentence why.
                """
            case .orchestrator:
                return """
                You are the orchestrator debugger. Classify what kind of problem blocked \
                progress (architecture, API contract, logic bug, syntax, missing context, etc.) \
                and give the next agent one paragraph of steering. Be specific.
                """
            }
        }
    }

    static func run(
        task: String,
        config: CodingOrchestratorConfig,
        client: OpenRouterClient,
        onPhaseStart: @escaping @MainActor (Int, Phase) -> Void,
        onPhaseComplete: @escaping @MainActor (Int, Phase, String) -> Void,
        onAppend: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var artifact = ""
        var lastTester = ""

        for round in 1...max(1, config.maxRounds) {
            try Task.checkCancellation()

            for phase in [Phase.planner, .coder, .auditor, .fixer, .tester] {
                try Task.checkCancellation()
                await onPhaseStart(round, phase)

                let user = buildUserPrompt(
                    task: task, phase: phase, round: round, artifact: artifact, lastTester: lastTester)
                let reply = try await client.complete(
                    model: config.modelID,
                    system: phase.systemPrompt,
                    messages: [.init(role: "user", text: user)],
                    config: OpenRouterStreamConfig(
                        reasoningEnabled: false, maxTokens: 8192))

                if phase == .coder || phase == .fixer {
                    artifact = reply
                }
                if phase == .tester {
                    lastTester = reply
                }

                await onPhaseComplete(round, phase, reply)
                await onAppend(
                    """

                    ## Round \(round) · \(phase.title)

                    \(reply)
                    """)
            }

            if lastTester.uppercased().contains("VERDICT: PASS") {
                await onAppend("\n\n✅ **Code loop finished** — tester signed off in round \(round).\n")
                return artifact
            }

            if round < config.maxRounds {
                await onPhaseStart(round, .orchestrator)
                let steer = try await client.complete(
                    model: config.modelID,
                    system: Phase.orchestrator.systemPrompt,
                    messages: [
                        .init(
                            role: "user",
                            text:
                                "Task:\n\(task)\n\nLatest code:\n\(artifact)\n\nTester said:\n\(lastTester)\n\nSteer the next round.")
                    ],
                    config: OpenRouterStreamConfig(
                        reasoningEnabled: false, maxTokens: 2048))
                await onPhaseComplete(round, .orchestrator, steer)
                await onAppend("\n\n## Round \(round) · Orchestrator\n\n\(steer)\n")
                artifact = artifact + "\n\n[Orchestrator steering]\n" + steer
            }
        }

        await onAppend(
            "\n\n⚠️ **Code loop stopped** — reached max rounds (\(config.maxRounds)) without VERDICT: PASS.\n")
        return artifact
    }

    private static func buildUserPrompt(
        task: String, phase: Phase, round: Int, artifact: String, lastTester: String
    ) -> String {
        var parts = ["User task:\n\(task)", "Round: \(round)"]
        if !artifact.isEmpty {
            parts.append("Current implementation / context:\n\(artifact)")
        }
        if phase != .planner, !lastTester.isEmpty {
            parts.append("Previous tester output:\n\(lastTester)")
        }
        parts.append("Your role: \(phase.title). Respond in markdown.")
        return parts.joined(separator: "\n\n")
    }
}
