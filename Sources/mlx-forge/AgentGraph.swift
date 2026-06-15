// Forge — agent graph model.
//
// A simple node-and-edge graph: each node is an agent (a model + a prompt), each
// edge is a handoff ("this agent talks to that agent"). The point is to stay
// dead-simple to use — drop agents, connect them, set each one's prompt. Layers
// and live execution build on top of this later.

import Foundation

struct AgentNode: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "Agent"
    var role: String = ""          // optional free label ("RAG", "reviewer"…)
    var x: Double                   // canvas position (node center)
    var y: Double
    var isClaude: Bool = true       // true → Claude API model; false → local model
    var modelID: String = "claude-opus-4-8"  // Claude model id, or local model name
    var prompt: String = ""         // the agent's instruction / system prompt

    var modelLabel: String {
        isClaude ? AnthropicClient.label(for: modelID) : modelID
    }
}

struct AgentEdge: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var from: UUID
    var to: UUID
}

struct AgentGraph: Codable, Equatable {
    var nodes: [AgentNode] = []
    var edges: [AgentEdge] = []

    // MARK: Mutations

    mutating func addNode(at position: CGPoint? = nil) {
        // Stagger or use provided world position for canvas tap-to-add.
        if let pos = position {
            nodes.append(
                AgentNode(
                    title: "Agent \(nodes.count + 1)",
                    x: pos.x,
                    y: pos.y))
            return
        }
        let n = Double(nodes.count)
        nodes.append(
            AgentNode(
                title: "Agent \(nodes.count + 1)",
                x: 320 + n.truncatingRemainder(dividingBy: 4) * 60,
                y: 220 + n.truncatingRemainder(dividingBy: 3) * 60))
    }

    mutating func connect(from: UUID, to: UUID) {
        guard from != to else { return }
        guard !edges.contains(where: { $0.from == from && $0.to == to }) else { return }
        edges.append(AgentEdge(from: from, to: to))
    }

    mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
    }

    func node(_ id: UUID) -> AgentNode? { nodes.first { $0.id == id } }

    // MARK: Persistence (small — stored as JSON in UserDefaults)

    private static let key = "agent.graph"

    static func load() -> AgentGraph {
        guard let data = UserDefaults.standard.data(forKey: key),
            let graph = try? JSONDecoder().decode(AgentGraph.self, from: data)
        else { return AgentGraph() }
        return graph
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AgentGraph.key)
        }
    }
}
