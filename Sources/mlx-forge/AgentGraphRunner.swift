// Forge — agent graph execution.
//
// Runs the graph as a pipeline: start agents (no incoming arrows) receive the
// user's task; every other agent receives the outputs of the agents that hand
// off to it. Nodes run one at a time in dependency order — the single MLX gate
// serializes GPU work anyway, and sequential keeps the output readable.

import Foundation
import MLXLMCommon
import Observation

@MainActor
@Observable
final class AgentGraphRunner {

    enum NodeState: Equatable {
        case waiting
        case running
        case done
        case failed(String)
    }

    private(set) var states: [UUID: NodeState] = [:]
    private(set) var outputs: [UUID: String] = [:]
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?

    var hasResults: Bool { !outputs.isEmpty || isRunning || errorMessage != nil }

    func clear() {
        stop()
        states = [:]
        outputs = [:]
        errorMessage = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func run(graph: AgentGraph, taskText: String, app: AppState) {
        guard !isRunning, !graph.nodes.isEmpty else { return }
        guard let order = Self.topologicalOrder(graph) else {
            errorMessage = "The graph has a cycle — handoffs must flow one direction."
            return
        }
        errorMessage = nil
        outputs = [:]
        states = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, .waiting) })
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            for nodeID in order {
                guard !Task.isCancelled, let node = graph.node(nodeID) else { break }
                self.states[nodeID] = .running
                let input = self.input(for: nodeID, in: graph, taskText: taskText)
                do {
                    try await self.runNode(node, input: input, app: app)
                    self.states[nodeID] = .done
                } catch is CancellationError {
                    self.states[nodeID] = .failed("stopped")
                    break
                } catch {
                    self.states[nodeID] = .failed(error.localizedDescription)
                    // Downstream agents would get empty input — stop the run
                    // instead of cascading garbage.
                    break
                }
            }
            self.isRunning = false
        }
    }

    /// Start agents get the task verbatim; downstream agents get each upstream
    /// agent's output under a header naming who it came from.
    private func input(for id: UUID, in graph: AgentGraph, taskText: String) -> String {
        let upstream = graph.edges
            .filter { $0.to == id }
            .compactMap { edge -> (String, String)? in
                guard let text = outputs[edge.from] else { return nil }
                return (graph.node(edge.from)?.title ?? "Agent", text)
            }
        guard !upstream.isEmpty else { return taskText }
        return upstream
            .map { "## From \($0.0)\n\($0.1)" }
            .joined(separator: "\n\n")
    }

    private func runNode(_ node: AgentNode, input: String, app: AppState) async throws {
        outputs[node.id] = ""
        if node.isClaude {
            try await runClaude(node, input: input)
        } else {
            try await runLocal(node, input: input, app: app)
        }
    }

    private func runClaude(_ node: AgentNode, input: String) async throws {
        guard let key = SecretsStore.anthropicAPIKey, !key.isEmpty else {
            throw RunError.message("No Anthropic API key — add one in Settings (⌘,).")
        }
        let client = AnthropicClient(apiKey: key)
        try await client.stream(
            model: node.modelID,
            system: node.prompt,
            messages: [.init(role: "user", text: input)]
        ) { [weak self] delta in
            self?.outputs[node.id, default: ""].append(delta)
        }
    }

    private func runLocal(_ node: AgentNode, input: String, app: AppState) async throws {
        guard
            let entry = app.engine.loadedModels.first(where: {
                $0.model.name == node.modelID || $0.model.shortName == node.modelID
            })
        else {
            throw RunError.message(
                "Local model “\(node.modelID)” is not loaded — load it first (⌘M).")
        }
        guard let container = entry.container else {
            throw RunError.message(
                "“\(node.modelID)” is a GGUF model — not supported in the graph yet, use an MLX model.")
        }
        let session = ChatSession(
            container,
            instructions: node.prompt.isEmpty ? nil : node.prompt,
            history: [],
            generateParameters: InferenceEngine.parameters(from: app.settings))

        try await app.engine.gate.withTurn { [weak self] in
            for try await item in session.streamDetails(
                to: input, role: .user, images: [], videos: [])
            {
                if Task.isCancelled { break }
                if case .chunk(let text) = item {
                    self?.outputs[node.id, default: ""].append(text)
                }
            }
        }
    }

    /// Kahn's algorithm; nil when the graph has a cycle.
    static func topologicalOrder(_ graph: AgentGraph) -> [UUID]? {
        var incoming = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { node in
                (node.id, graph.edges.filter { $0.to == node.id }.count)
            })
        var queue = graph.nodes.map(\.id).filter { incoming[$0] == 0 }
        var order: [UUID] = []
        while let id = queue.first {
            queue.removeFirst()
            order.append(id)
            for edge in graph.edges where edge.from == id {
                incoming[edge.to, default: 0] -= 1
                if incoming[edge.to] == 0 { queue.append(edge.to) }
            }
        }
        return order.count == graph.nodes.count ? order : nil
    }

    enum RunError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
