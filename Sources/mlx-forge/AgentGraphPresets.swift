// Forge — starter graph shapes.
//
// Each preset is a plain `AgentGraph` value, so anything a preset builds the
// user can then take apart on the canvas. Presets distribute whatever backends
// they are given round-robin; with one backend available every agent uses it.

import Foundation

enum AgentGraphPreset: String, CaseIterable, Identifiable {
    case solo
    case codeLoop
    case debate
    case supervisor
    case roundTable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solo: "Single agent"
        case .codeLoop: "Code loop"
        case .debate: "Debate + judge"
        case .supervisor: "Supervisor + workers"
        case .roundTable: "Round table"
        }
    }

    var summary: String {
        switch self {
        case .solo:
            "Task in, one model, result out. The smallest useful graph."
        case .codeLoop:
            "Planner → coder → auditor, looping until the auditor passes, then the code is written to the workspace."
        case .debate:
            "Two agents argue the same task, each seeing the other's last answer, and a third calls it."
        case .supervisor:
            "A supervisor splits the task across three workers and synthesises their replies."
        case .roundTable:
            "Every agent sees every other agent's reply — the old Room, as a graph."
        }
    }

    var symbolName: String {
        switch self {
        case .solo: "person"
        case .codeLoop: "arrow.triangle.2.circlepath"
        case .debate: "person.2"
        case .supervisor: "person.3"
        case .roundTable: "circle.grid.cross"
        }
    }

    /// Number of agent nodes the preset creates, so the picker can warn when
    /// fewer models are available than the shape wants.
    var agentCount: Int {
        switch self {
        case .solo: 1
        case .codeLoop: 3
        case .debate: 3
        case .supervisor: 4
        case .roundTable: 3
        }
    }

    func build(backends: [AgentBackend]) -> AgentGraph {
        // Round-robin so a preset still works with a single available model.
        let pool = backends.isEmpty ? [AgentBackend.local(modelID: "")] : backends
        func backend(_ index: Int) -> AgentBackend { pool[index % pool.count] }

        switch self {
        case .solo: return Self.buildSolo(backend: backend)
        case .codeLoop: return Self.buildCodeLoop(backend: backend)
        case .debate: return Self.buildDebate(backend: backend)
        case .supervisor: return Self.buildSupervisor(backend: backend)
        case .roundTable: return Self.buildRoundTable(backend: backend)
        }
    }

    // MARK: - Shapes

    private static func buildSolo(backend: (Int) -> AgentBackend) -> AgentGraph {
        var input = AgentNode(kind: .input, name: "Task", position: CGPoint(x: 80, y: 220))
        var agent = AgentNode(kind: .agent, name: "Agent", position: CGPoint(x: 380, y: 200))
        agent.backend = backend(0)
        agent.role = "You are a capable generalist. Answer the task directly and completely."
        var output = AgentNode(kind: .output, name: "Result", position: CGPoint(x: 700, y: 220))

        input.name = "Task"
        output.name = "Result"

        var graph = AgentGraph(name: "Single agent", nodes: [input, agent, output])
        graph.connect(fromNode: input.id, fromPort: "task", toNode: agent.id, toPort: "prompt")
        graph.connect(fromNode: agent.id, fromPort: "output", toNode: output.id, toPort: "value")
        return graph
    }

    private static func buildCodeLoop(backend: (Int) -> AgentBackend) -> AgentGraph {
        let input = AgentNode(kind: .input, name: "Task", position: CGPoint(x: 60, y: 300))

        var planner = AgentNode(kind: .agent, name: "Planner", position: CGPoint(x: 320, y: 120))
        planner.backend = backend(0)
        planner.maxTokens = 4096
        planner.role = """
            You are the planner in a coding loop. Break the task into concrete steps, name the \
            files to touch, call out risks, and state acceptance criteria. Be concise. Output \
            markdown with numbered steps. Do not write the implementation.
            """

        var coder = AgentNode(kind: .agent, name: "Coder", position: CGPoint(x: 620, y: 300))
        coder.backend = backend(1)
        coder.maxTokens = 8192
        coder.role = """
            You are the coder. Using the plan, and any audit feedback you are given, write the \
            full implementation. Output complete, copy-pasteable code in a single fenced code \
            block, with the file path in a leading comment. Ship real code — no placeholders, \
            no "rest of the implementation here".
            """

        var auditor = AgentNode(kind: .agent, name: "Auditor", position: CGPoint(x: 940, y: 300))
        auditor.backend = backend(2)
        auditor.maxTokens = 4096
        auditor.role = """
            You are the auditor. Review the code you are given for correctness, security, edge \
            cases, and clarity. List concrete issues as bullets with a severity of blocker, \
            major, or minor. If and only if the code has no blocker or major issues, make the \
            final line exactly: VERDICT: PASS
            """

        var gate = AgentNode(kind: .branch, name: "Passed?", position: CGPoint(x: 1240, y: 300))
        gate.branchTest = .contains
        gate.branchOperand = "VERDICT: PASS"

        var extract = AgentNode(kind: .extract, name: "Take code", position: CGPoint(x: 940, y: 560))
        extract.extractMode = .codeFence

        var write = AgentNode(kind: .file, name: "Write file", position: CGPoint(x: 1240, y: 560))
        write.fileMode = .write
        write.filePath = "implementation.txt"

        let output = AgentNode(kind: .output, name: "Result", position: CGPoint(x: 1540, y: 420))

        var graph = AgentGraph(
            name: "Code loop",
            nodes: [input, planner, coder, auditor, gate, extract, write, output],
            maxIterations: 12)

        graph.connect(fromNode: input.id, fromPort: "task", toNode: planner.id, toPort: "prompt")
        graph.connect(fromNode: planner.id, fromPort: "output", toNode: coder.id, toPort: "prompt")
        graph.connect(fromNode: coder.id, fromPort: "output", toNode: auditor.id, toPort: "prompt")
        graph.connect(fromNode: auditor.id, fromPort: "output", toNode: gate.id, toPort: "value")
        // Fail → the auditor's notes go back to the coder as context, which
        // re-fires it against the plan it already holds. This is the loop.
        graph.connect(fromNode: gate.id, fromPort: "false", toNode: coder.id, toPort: "context")
        // Pass → pull the code out of the last coder answer and write it down.
        graph.connect(fromNode: gate.id, fromPort: "true", toNode: extract.id, toPort: "text")
        graph.connect(fromNode: coder.id, fromPort: "output", toNode: extract.id, toPort: "text")
        graph.connect(fromNode: extract.id, fromPort: "match", toNode: write.id, toPort: "content")
        graph.connect(fromNode: write.id, fromPort: "content", toNode: output.id, toPort: "value")
        return graph
    }

    private static func buildDebate(backend: (Int) -> AgentBackend) -> AgentGraph {
        let input = AgentNode(kind: .input, name: "Question", position: CGPoint(x: 60, y: 300))

        var first = AgentNode(kind: .agent, name: "Advocate", position: CGPoint(x: 380, y: 140))
        first.backend = backend(0)
        first.role = """
            You are arguing a position on the question you are given. Make the strongest case \
            you honestly can. If you are shown an opposing argument, answer its strongest point \
            head-on rather than repeating yourself. Keep it under 300 words.
            """

        var second = AgentNode(kind: .agent, name: "Skeptic", position: CGPoint(x: 380, y: 460))
        second.backend = backend(1)
        second.role = """
            You are the skeptic. Attack the weakest link in the argument you are shown and in \
            the question's framing itself. Concede a point when it is genuinely correct. Keep \
            it under 300 words.
            """

        var judge = AgentNode(kind: .agent, name: "Judge", position: CGPoint(x: 760, y: 300))
        judge.backend = backend(2)
        judge.maxTokens = 4096
        judge.role = """
            You are the judge. You are shown a question and two opposing arguments, attributed \
            to their authors. Say which argument is stronger and exactly why, name any point \
            both sides missed, then give your own answer to the question.
            """

        let output = AgentNode(kind: .output, name: "Verdict", position: CGPoint(x: 1080, y: 300))

        var graph = AgentGraph(
            name: "Debate + judge", nodes: [input, first, second, judge, output], maxIterations: 8)

        graph.connect(fromNode: input.id, fromPort: "task", toNode: first.id, toPort: "prompt")
        graph.connect(fromNode: input.id, fromPort: "task", toNode: second.id, toPort: "prompt")
        // Each sees the other's last answer — a two-node cycle, bounded by maxIterations.
        graph.connect(fromNode: first.id, fromPort: "output", toNode: second.id, toPort: "context")
        graph.connect(fromNode: second.id, fromPort: "output", toNode: first.id, toPort: "context")
        graph.connect(fromNode: input.id, fromPort: "task", toNode: judge.id, toPort: "prompt")
        graph.connect(fromNode: first.id, fromPort: "output", toNode: judge.id, toPort: "context")
        graph.connect(fromNode: second.id, fromPort: "output", toNode: judge.id, toPort: "context")
        graph.connect(fromNode: judge.id, fromPort: "output", toNode: output.id, toPort: "value")
        return graph
    }

    private static func buildSupervisor(backend: (Int) -> AgentBackend) -> AgentGraph {
        let input = AgentNode(kind: .input, name: "Task", position: CGPoint(x: 60, y: 320))

        var supervisor = AgentNode(
            kind: .agent, name: "Supervisor", position: CGPoint(x: 340, y: 320))
        supervisor.backend = backend(0)
        supervisor.maxTokens = 4096
        supervisor.role = """
            You are the supervisor. Restate the task, then split it into three independent \
            sub-tasks that can be worked in parallel. Label them exactly "1.", "2." and "3.". \
            Every worker sees this whole message, so make each sub-task self-contained.
            """

        var workerOne = AgentNode(kind: .agent, name: "Worker 1", position: CGPoint(x: 700, y: 120))
        workerOne.backend = backend(1)
        workerOne.role =
            "You are worker 1. Do sub-task 1 from the plan you are shown, and only that one. Be thorough and concrete."

        var workerTwo = AgentNode(kind: .agent, name: "Worker 2", position: CGPoint(x: 700, y: 340))
        workerTwo.backend = backend(2)
        workerTwo.role =
            "You are worker 2. Do sub-task 2 from the plan you are shown, and only that one. Be thorough and concrete."

        var workerThree = AgentNode(
            kind: .agent, name: "Worker 3", position: CGPoint(x: 700, y: 560))
        workerThree.backend = backend(3)
        workerThree.role =
            "You are worker 3. Do sub-task 3 from the plan you are shown, and only that one. Be thorough and concrete."

        var synth = AgentNode(kind: .agent, name: "Synthesis", position: CGPoint(x: 1040, y: 320))
        synth.backend = backend(0)
        synth.maxTokens = 8192
        synth.role = """
            You are the synthesiser. You are given the original task and three workers' \
            results, attributed. Merge them into one coherent deliverable. Resolve any \
            contradictions explicitly rather than averaging them, and drop duplicated work.
            """

        let output = AgentNode(kind: .output, name: "Deliverable", position: CGPoint(x: 1380, y: 320))

        var graph = AgentGraph(
            name: "Supervisor + workers",
            nodes: [input, supervisor, workerOne, workerTwo, workerThree, synth, output],
            maxIterations: 8)

        graph.connect(fromNode: input.id, fromPort: "task", toNode: supervisor.id, toPort: "prompt")
        for worker in [workerOne, workerTwo, workerThree] {
            graph.connect(
                fromNode: supervisor.id, fromPort: "output", toNode: worker.id, toPort: "prompt")
            graph.connect(
                fromNode: worker.id, fromPort: "output", toNode: synth.id, toPort: "context")
        }
        graph.connect(fromNode: input.id, fromPort: "task", toNode: synth.id, toPort: "prompt")
        graph.connect(fromNode: synth.id, fromPort: "output", toNode: output.id, toPort: "value")
        return graph
    }

    private static func buildRoundTable(backend: (Int) -> AgentBackend) -> AgentGraph {
        let input = AgentNode(kind: .input, name: "Topic", position: CGPoint(x: 60, y: 320))

        var agents: [AgentNode] = []
        let positions = [CGPoint(x: 420, y: 100), CGPoint(x: 420, y: 320), CGPoint(x: 420, y: 540)]
        for index in 0..<3 {
            var agent = AgentNode(
                kind: .agent, name: "Seat \(index + 1)", position: positions[index])
            agent.backend = backend(index)
            agent.role = """
                You are seat \(index + 1) at a round table with two other agents. You are shown \
                the topic and the other seats' latest replies, attributed by name. Add something \
                of your own — a disagreement, a missing consideration, a concrete next step. \
                Never restate what another seat already said, and never speak for them. \
                Keep it under 250 words.
                """
            agents.append(agent)
        }

        var minutes = AgentNode(kind: .agent, name: "Minutes", position: CGPoint(x: 800, y: 320))
        minutes.backend = backend(0)
        minutes.maxTokens = 4096
        minutes.role = """
            You are the note-taker. Summarise where the table agreed, where it split, and what \
            it decided. Attribute the substantive positions to the seat that made them.
            """

        let output = AgentNode(kind: .output, name: "Minutes", position: CGPoint(x: 1140, y: 320))

        var graph = AgentGraph(
            name: "Round table", nodes: [input] + agents + [minutes, output], maxIterations: 9)

        for agent in agents {
            graph.connect(fromNode: input.id, fromPort: "task", toNode: agent.id, toPort: "prompt")
            graph.connect(
                fromNode: agent.id, fromPort: "output", toNode: minutes.id, toPort: "context")
            // All-to-all: every seat's reply lands on every other seat's context.
            for other in agents where other.id != agent.id {
                graph.connect(
                    fromNode: agent.id, fromPort: "output", toNode: other.id, toPort: "context")
            }
        }
        graph.connect(fromNode: input.id, fromPort: "task", toNode: minutes.id, toPort: "prompt")
        graph.connect(fromNode: minutes.id, fromPort: "output", toNode: output.id, toPort: "value")
        return graph
    }
}
