// Forge — app-level wiring for agent graphs: storage, selection, and running.

import Foundation
import SwiftUI

// MARK: - Persistence

enum AgentGraphPersistence {
    static var file: URL {
        ForgePaths.appSupport.appendingPathComponent("agent-graphs.json")
    }

    static func load() -> [AgentGraph] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        // A graph file that fails to decode must not take the app down with it.
        return (try? JSONDecoder().decode([AgentGraph].self, from: data)) ?? []
    }

    static func loadSelectedID() -> UUID? {
        UserDefaults.standard.string(forKey: "graph.selectedID").flatMap(UUID.init(uuidString:))
    }

    static func save(_ graphs: [AgentGraph]) {
        guard let data = try? JSONEncoder().encode(graphs) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - AppState

extension AppState {

    // Cloud model choices offered in a block's model menu. Kept short and
    // current rather than exhaustive — anything else can go through OpenRouter.
    static let anthropicGraphModels: [(String, String)] = [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-fable-5", "Fable 5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
    ]

    static let openAIGraphModels: [(String, String)] = [
        ("gpt-5", "GPT-5"),
        ("gpt-5-mini", "GPT-5 mini"),
        ("o4-mini", "o4-mini"),
    ]

    /// OpenRouter choices: whatever the user already selected for chat, plus the
    /// catalog if it has been fetched.
    var openRouterGraphModelChoices: [(String, String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for id in openRouterModelIDs where !id.isEmpty {
            if seen.insert(id).inserted {
                result.append((id, OpenRouterClient.label(for: id)))
            }
        }
        for id in openRouterCustomModels where !id.isEmpty {
            if seen.insert(id).inserted {
                result.append((id, OpenRouterClient.label(for: id)))
            }
        }
        for entry in openRouterCatalog.prefix(60) {
            if seen.insert(entry.id).inserted {
                result.append((entry.id, OpenRouterClient.label(for: entry.id)))
            }
        }
        if result.isEmpty {
            result.append(
                (OpenRouterClient.defaultModelID,
                 OpenRouterClient.label(for: OpenRouterClient.defaultModelID)))
        }
        return result
    }

    // MARK: Selection

    var selectedGraphIndex: Int? {
        guard let selectedGraphID else { return agentGraphs.isEmpty ? nil : 0 }
        return agentGraphs.firstIndex { $0.id == selectedGraphID }
            ?? (agentGraphs.isEmpty ? nil : 0)
    }

    var selectedGraph: AgentGraph? {
        selectedGraphIndex.map { agentGraphs[$0] }
    }

    /// Locates a block by id across the selected graph.
    func nodeIndex(_ nodeID: UUID) -> (graph: Int, node: Int)? {
        guard let graphIndex = selectedGraphIndex,
            let nodeIndex = agentGraphs[graphIndex].nodes.firstIndex(where: { $0.id == nodeID })
        else { return nil }
        return (graphIndex, nodeIndex)
    }

    var selectedGraphWorkspace: AgentWorkspace? {
        selectedGraph.map { AgentWorkspace.forGraph($0.id) }
    }

    // MARK: Graph management

    func newGraph() {
        var graph = AgentGraph(name: "Graph \(agentGraphs.count + 1)")
        graph.addNode(AgentNode(kind: .input, name: "Task", position: CGPoint(x: 100, y: 220)))
        agentGraphs.append(graph)
        selectedGraphID = graph.id
        saveGraphsNow()
    }

    func duplicateSelectedGraph() {
        guard var graph = selectedGraph else { return }
        graph.id = UUID()
        graph.name += " copy"
        // Fresh block ids, with the wiring remapped onto them.
        var remap: [UUID: UUID] = [:]
        graph.nodes = graph.nodes.map { node in
            var copy = node
            copy.id = UUID()
            remap[node.id] = copy.id
            return copy
        }
        graph.wires = graph.wires.compactMap { wire in
            guard let from = remap[wire.fromNode], let to = remap[wire.toNode] else { return nil }
            return AgentWire(
                fromNode: from, fromPort: wire.fromPort, toNode: to, toPort: wire.toPort)
        }
        agentGraphs.append(graph)
        selectedGraphID = graph.id
        saveGraphsNow()
    }

    func deleteSelectedGraph() {
        guard let index = selectedGraphIndex else { return }
        agentGraphs.remove(at: index)
        selectedGraphID = agentGraphs.first?.id
        saveGraphsNow()
    }

    func renameSelectedGraph(_ name: String) {
        guard let index = selectedGraphIndex else { return }
        agentGraphs[index].name = name
        scheduleGraphSave()
    }

    func removeWire(_ wireID: UUID) {
        guard let index = selectedGraphIndex else { return }
        agentGraphs[index].removeWire(wireID)
        scheduleGraphSave()
    }

    func setGraphMaxIterations(_ value: Int) {
        guard let index = selectedGraphIndex else { return }
        agentGraphs[index].maxIterations = max(1, value)
        scheduleGraphSave()
    }

    func applyPreset(_ preset: AgentGraphPreset) {
        let built = preset.build(backends: availableAgentBackends)
        if let index = selectedGraphIndex {
            // Keep the graph's identity (and therefore its workspace folder)
            // so replacing the shape does not orphan files already produced.
            let id = agentGraphs[index].id
            var replacement = built
            replacement.id = id
            agentGraphs[index] = replacement
        } else {
            agentGraphs.append(built)
            selectedGraphID = built.id
        }
        saveGraphsNow()
    }

    // MARK: Backends

    /// Every model a block could actually use right now: loaded locals first,
    /// then whichever cloud providers have a key.
    var availableAgentBackends: [AgentBackend] {
        var result: [AgentBackend] = engine.loadedModels.map { .local(modelID: $0.id) }
        if hasAnthropicKey, let first = Self.anthropicGraphModels.first {
            result.append(.anthropic(model: first.0))
        }
        if hasOpenAIKey, let first = Self.openAIGraphModels.first {
            result.append(.openAI(model: first.0))
        }
        if hasOpenRouterKey, let first = openRouterGraphModelChoices.first {
            result.append(.openRouter(model: first.0))
        }
        return result
    }

    var defaultAgentBackend: AgentBackend {
        availableAgentBackends.first ?? .local(modelID: "")
    }

    // MARK: Running

    var selectedGraphIssues: [AgentGraph.Issue] {
        guard let graph = selectedGraph else { return [] }
        return graph.issues(loadedModelIDs: Set(engine.loadedModels.map(\.id)))
    }

    var canRunSelectedGraph: Bool {
        guard selectedGraph != nil, !graphRuntime.isRunning else { return false }
        guard !graphTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !selectedGraphIssues.contains { $0.severity == .error }
    }

    func runSelectedGraph() {
        guard canRunSelectedGraph, let graph = selectedGraph else { return }
        graphRuntime.run(graph: graph, task: graphTaskText)
    }
}
