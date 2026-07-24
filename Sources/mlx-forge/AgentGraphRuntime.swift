// Forge — agent graph execution.
//
// The scheduler is a dataflow loop, not a topological sort, because review
// loops (coder → auditor → coder) are the point and a DAG cannot express them.
//
// Each input port retains the last value it received. A block fires when every
// required, wired port holds a value AND at least one port received something
// new since it last fired. That single rule is what makes loops behave the way
// people expect: the coder keeps the plan it was given and re-fires when fresh
// audit feedback arrives, without the plan having to be re-sent.
//
// Runaway loops are bounded by `graph.maxIterations` per block.

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentGraphRuntime {

    // MARK: - Observable run state

    enum NodeStatus: Equatable, Sendable {
        case idle
        case waiting
        case running
        case done
        case failed
        case blocked
    }

    struct NodeState: Equatable {
        var status: NodeStatus = .idle
        /// Last completed output, per output port.
        var outputs: [String: String] = [:]
        /// Live text while a model streams.
        var streaming: String = ""
        var iterations: Int = 0
        var error: String?
        var tokensPerSecond: Double?
        var lastFinishedAt: Date?

        var primaryOutput: String {
            outputs["output"] ?? outputs["text"] ?? outputs["match"] ?? outputs["result"]
                ?? outputs["content"] ?? outputs["task"] ?? outputs.values.first ?? ""
        }
    }

    struct LogEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case info
            case fired
            case finished
            case tool
            case failure
        }
        let id = UUID()
        let time: Date
        let nodeID: UUID?
        let nodeName: String
        let kind: Kind
        let text: String
    }

    /// One value in flight on a wire, kept for the inspector so the user can
    /// click any wire and read exactly what went through it.
    struct WireValue: Equatable {
        var text: String
        var fromName: String
        var at: Date
    }

    private(set) var isRunning = false
    private(set) var nodeStates: [UUID: NodeState] = [:]
    private(set) var log: [LogEntry] = []
    private(set) var wireValues: [UUID: WireValue] = [:]
    /// Blocks that fired in the current tick, for the canvas pulse.
    private(set) var activeNodeIDs: Set<UUID> = []
    private(set) var results: [String] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var stopReason: String?
    private(set) var tick = 0

    /// Per-block conversation memory, so an agent that fires twice remembers
    /// what it said the first time. Cleared at the start of every run.
    private var memory: [UUID: [ChatMessage]] = [:]

    private var runTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    // MARK: - Injected dependencies

    private unowned let engine: InferenceEngine
    private unowned let mcp: MCPManager
    private let baseSettings: () -> GenerationSettings

    init(
        engine: InferenceEngine, mcp: MCPManager,
        baseSettings: @escaping () -> GenerationSettings
    ) {
        self.engine = engine
        self.mcp = mcp
        self.baseSettings = baseSettings
    }

    // MARK: - Lifecycle

    func run(graph: AgentGraph, task: String) {
        guard !isRunning else { return }
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { return }

        generation &+= 1
        let runGeneration = generation

        nodeStates = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, NodeState()) })
        log = []
        wireValues = [:]
        activeNodeIDs = []
        results = []
        memory = [:]
        stopReason = nil
        finishedAt = nil
        startedAt = Date()
        tick = 0
        isRunning = true

        append(.info, node: nil, name: "Run", "Started — “\(clip(trimmedTask, 120))”")

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(graph: graph, task: trimmedTask, generation: runGeneration)
            guard self.generation == runGeneration else { return }
            self.isRunning = false
            self.finishedAt = Date()
            self.activeNodeIDs = []
            self.runTask = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        finishedAt = Date()
        activeNodeIDs = []
        stopReason = "Stopped by you."
        for id in nodeStates.keys where nodeStates[id]?.status == .running {
            nodeStates[id]?.status = .idle
            nodeStates[id]?.streaming = ""
        }
        append(.info, node: nil, name: "Run", "Stopped.")
    }

    /// Clears run state without touching the graph, so the canvas goes quiet.
    func reset() {
        guard !isRunning else { return }
        nodeStates = [:]
        log = []
        wireValues = [:]
        results = []
        startedAt = nil
        finishedAt = nil
        stopReason = nil
        tick = 0
        memory = [:]
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    // MARK: - Scheduler

    /// A value sitting on one input port, tagged with where it came from.
    private struct PortValue {
        var text: String
        var fromName: String
    }

    private func execute(graph: AgentGraph, task: String, generation runGeneration: UInt64) async {
        let workspace = AgentWorkspace.forGraph(graph.id)

        // Retained values per (node, port) — the "last value sticks" rule.
        var retained: [UUID: [String: [PortValue]]] = [:]
        // Ports that received something new since their block last fired.
        var freshPorts: [UUID: Set<String>] = [:]
        var fireCounts: [UUID: Int] = [:]

        func deliver(to nodeID: UUID, port: String, value: PortValue) {
            // Fan-in on one port accumulates; a repeat from the same source
            // replaces its earlier value so a loop does not grow without bound.
            var portValues = retained[nodeID]?[port] ?? []
            if let existing = portValues.firstIndex(where: { $0.fromName == value.fromName }) {
                portValues[existing] = value
            } else {
                portValues.append(value)
            }
            retained[nodeID, default: [:]][port] = portValues
            freshPorts[nodeID, default: []].insert(port)
        }

        // Seed: Task blocks emit the run's task. Blocks with nothing wired into
        // them at all are sources too (a constant Text block, a File read), so
        // they fire once at the start.
        for node in graph.nodes {
            switch node.kind {
            case .input:
                for wire in graph.wires(from: node.id, port: "task") {
                    deliver(
                        to: wire.toNode, port: wire.toPort,
                        value: PortValue(text: task, fromName: node.name))
                    wireValues[wire.id] = WireValue(text: task, fromName: node.name, at: Date())
                }
                nodeStates[node.id]?.status = .done
                nodeStates[node.id]?.outputs["task"] = task
            default:
                if graph.wires(into: node.id).isEmpty, node.kind != .output {
                    freshPorts[node.id, default: []].insert("__source__")
                }
            }
        }

        while !Task.isCancelled, generation == runGeneration {
            // Ready = has something new, every required wired port is satisfied,
            // and it has not burned through its iteration budget.
            let ready = graph.nodes.filter { node in
                guard node.kind != .input else { return false }
                guard !(freshPorts[node.id] ?? []).isEmpty else { return false }
                guard (fireCounts[node.id] ?? 0) < graph.maxIterations else { return false }
                for port in node.inputPorts where port.isRequired {
                    guard !graph.wires(into: node.id, port: port.id).isEmpty else { return false }
                    guard let values = retained[node.id]?[port.id], !values.isEmpty else {
                        return false
                    }
                }
                return true
            }

            guard !ready.isEmpty else {
                if stopReason == nil {
                    let exhausted = graph.nodes.filter {
                        (fireCounts[$0.id] ?? 0) >= graph.maxIterations
                    }
                    if !exhausted.isEmpty {
                        stopReason =
                            "Hit the \(graph.maxIterations)-turn limit on \(exhausted.map(\.name).joined(separator: ", ")). Raise the limit in the run bar if the loop needs longer."
                        append(.info, node: nil, name: "Run", stopReason ?? "")
                    }
                }
                break
            }

            tick += 1
            activeNodeIDs = Set(ready.map(\.id))

            // Snapshot each ready block's inputs, then clear its fresh flags so
            // it will not re-fire until genuinely new data arrives.
            var batch: [(node: AgentNode, inputs: [String: [PortValue]])] = []
            for node in ready {
                batch.append((node, retained[node.id] ?? [:]))
                freshPorts[node.id] = []
                fireCounts[node.id, default: 0] += 1
                nodeStates[node.id]?.status = .running
                nodeStates[node.id]?.iterations = fireCounts[node.id] ?? 0
                nodeStates[node.id]?.streaming = ""
                nodeStates[node.id]?.error = nil
            }

            // Fire the batch concurrently. Cloud calls genuinely overlap;
            // local generations interleave and are serialised by MLXGate.
            var running: [(UUID, Task<NodeOutcome, Never>)] = []
            for entry in batch {
                let node = entry.node
                let inputs = entry.inputs
                let child = Task { @MainActor [weak self] in
                    guard let self else { return NodeOutcome.failure("Runtime went away.") }
                    return await self.fire(
                        node: node, inputs: inputs, graph: graph, workspace: workspace,
                        generation: runGeneration)
                }
                running.append((node.id, child))
            }

            var produced: [(node: AgentNode, outcome: NodeOutcome)] = []
            for (nodeID, child) in running {
                let outcome = await child.value
                guard let node = graph.node(nodeID) else { continue }
                produced.append((node, outcome))
            }

            guard !Task.isCancelled, generation == runGeneration else { break }
            activeNodeIDs = []

            // Route this tick's outputs onto the wires.
            for entry in produced {
                let node = entry.node
                switch entry.outcome {
                case .failure(let message):
                    nodeStates[node.id]?.status = .failed
                    nodeStates[node.id]?.error = message
                    nodeStates[node.id]?.streaming = ""
                    append(.failure, node: node.id, name: node.name, message)
                case .emit(let portValues):
                    nodeStates[node.id]?.status = .done
                    nodeStates[node.id]?.streaming = ""
                    nodeStates[node.id]?.lastFinishedAt = Date()
                    nodeStates[node.id]?.outputs = portValues
                    for (port, text) in portValues {
                        for wire in graph.wires(from: node.id, port: port) {
                            deliver(
                                to: wire.toNode, port: wire.toPort,
                                value: PortValue(text: text, fromName: node.name))
                            wireValues[wire.id] = WireValue(
                                text: text, fromName: node.name, at: Date())
                        }
                    }
                case .collected(let text):
                    nodeStates[node.id]?.status = .done
                    nodeStates[node.id]?.lastFinishedAt = Date()
                    nodeStates[node.id]?.outputs["value"] = text
                    results.append(text)
                    append(.finished, node: node.id, name: node.name, "Result collected.")
                }
            }
        }

        if Task.isCancelled { return }
        guard generation == runGeneration else { return }
        if stopReason == nil {
            stopReason = results.isEmpty ? "Finished — no Result block was reached." : "Finished."
        }
        append(.info, node: nil, name: "Run", stopReason ?? "Finished.")
    }

    private enum NodeOutcome {
        /// Values keyed by output port.
        case emit([String: String])
        /// A Result block collected a final answer.
        case collected(String)
        case failure(String)
    }

    // MARK: - Block execution

    private func fire(
        node: AgentNode, inputs: [String: [PortValue]], graph: AgentGraph,
        workspace: AgentWorkspace, generation runGeneration: UInt64
    ) async -> NodeOutcome {
        append(.fired, node: node.id, name: node.name, "Running…")
        switch node.kind {
        case .input:
            return .emit(["task": ""])
        case .agent:
            return await fireAgent(
                node: node, inputs: inputs, workspace: workspace, generation: runGeneration)
        case .text:
            return fireText(node: node, inputs: inputs)
        case .branch:
            return fireBranch(node: node, inputs: inputs)
        case .extract:
            return fireExtract(node: node, inputs: inputs)
        case .tool:
            return await fireTool(node: node, inputs: inputs)
        case .file:
            return fireFile(node: node, inputs: inputs, workspace: workspace)
        case .output:
            return .collected(joined(inputs["value"] ?? [], labelled: false))
        }
    }

    // MARK: Agent

    private func fireAgent(
        node: AgentNode, inputs: [String: [PortValue]], workspace: AgentWorkspace,
        generation runGeneration: UInt64
    ) async -> NodeOutcome {
        let prompt = joined(inputs["prompt"] ?? [], labelled: false)
        let context = joined(inputs["context"] ?? [], labelled: true)

        var message = prompt
        if !context.isEmpty {
            message += """


                ── What the other blocks sent you ──
                \(context)
                """
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure("\(node.name) had nothing to work with — no text arrived on its inputs.")
        }

        let system = agentSystemPrompt(for: node, workspace: workspace)
        var history = memory[node.id] ?? []

        var toolRounds = 0
        let toolLimit = max(1, baseSettings().mcpMaxIterations <= 0 ? 8 : baseSettings().mcpMaxIterations)
        var currentMessage = message

        while true {
            guard generation == runGeneration, !Task.isCancelled else {
                return .failure("Cancelled.")
            }
            let call = await callModel(
                node: node, system: system, history: history, message: currentMessage)

            if let error = call.error, call.text.isEmpty {
                return .failure(error)
            }
            history.append(ChatMessage(role: .user, content: currentMessage))
            history.append(ChatMessage(role: .assistant, content: call.text))

            // Did it ask for a tool?
            guard let request = Self.parseToolCall(in: call.text) else {
                memory[node.id] = Self.trimmedMemory(history)
                var answer = call.text
                if let error = call.error {
                    answer += "\n\n⚠️ \(error)"
                }
                return .emit(["output": answer])
            }

            toolRounds += 1
            guard toolRounds <= toolLimit else {
                memory[node.id] = Self.trimmedMemory(history)
                return .emit([
                    "output": call.text
                        + "\n\n⚠️ Stopped after \(toolLimit) tool calls in one turn."
                ])
            }

            let resultText = await runToolCall(request, node: node, workspace: workspace)
            append(
                .tool, node: node.id, name: node.name,
                "Called \(request.displayName) — \(clip(resultText, 100))")
            nodeStates[node.id]?.streaming = ""
            currentMessage = """
                Tool result for \(request.displayName):

                \(clip(resultText, 20_000))

                Continue. If you have what you need, give your final answer now.
                """
        }
    }

    private func agentSystemPrompt(for node: AgentNode, workspace: AgentWorkspace) -> String {
        var parts: [String] = []
        let role = node.role.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(role.isEmpty ? "You are a helpful agent." : role)
        parts.append(
            """
            You are one block named “\(node.name)” in a Forge agent graph. Text arrives on your \
            inputs and your answer is passed straight to whatever is wired to your output. \
            Answer as yourself only — never write another block's reply, and never prefix your \
            answer with your own name.
            """)

        var toolLines: [String] = []
        if node.workspaceAccess {
            toolLines.append(
                "- \"workspace_list\" — list the files in this graph's folder. arguments: {}")
            toolLines.append(
                "- \"workspace_read\" — read a file. arguments: {\"path\":\"notes.md\"}")
            toolLines.append(
                "- \"workspace_write\" — write a file. arguments: {\"path\":\"a.swift\",\"content\":\"…\"}")
            toolLines.append(
                "- \"workspace_append\" — add to the end of a file. arguments: {\"path\":\"log.md\",\"content\":\"…\"}")
        }
        for grant in node.toolGrants {
            let parts = grant.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let description = mcp.tools(for: parts[0]).first { $0.name == parts[1] }?.description ?? ""
            toolLines.append(
                "- server \"\(parts[0])\", tool \"\(parts[1])\"\(description.isEmpty ? "" : ": \(clip(description, 140))")"
            )
        }

        if !toolLines.isEmpty {
            parts.append(
                """
                Tools you may use. To call one, reply with ONLY this single line and nothing else:
                FORGE_TOOL {"tool":"<name>","arguments":{…}}
                For an MCP server tool, include its server: \
                FORGE_TOOL {"server":"<server-id>","tool":"<name>","arguments":{…}}

                Available to you:
                \(toolLines.joined(separator: "\n"))

                Forge runs the tool and hands you the result, then you continue. \
                When you have what you need, answer normally in prose — do not echo raw JSON.
                """)
            if node.workspaceAccess {
                parts.append(
                    "Your workspace folder is \(workspace.root.path). Use plain relative paths like \"src/main.swift\" — you cannot reach outside this folder."
                )
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Keeps a block's memory bounded — the last few exchanges are what matter
    /// for a loop; the full history would grow without limit across iterations.
    private static func trimmedMemory(_ history: [ChatMessage]) -> [ChatMessage] {
        let maxMessages = 8
        guard history.count > maxMessages else { return history }
        return Array(history.suffix(maxMessages))
    }

    // MARK: Model dispatch

    private struct ModelReply {
        var text: String
        var error: String?
    }

    private func callModel(
        node: AgentNode, system: String, history: [ChatMessage], message: String
    ) async -> ModelReply {
        switch node.backend {
        case .local(let modelID):
            return await callLocal(
                node: node, modelID: modelID, system: system, history: history, message: message)
        case .anthropic(let model):
            return await callAnthropic(
                node: node, model: model, system: system, history: history, message: message)
        case .openRouter(let model):
            return await callOpenRouter(
                node: node, model: model, system: system, history: history, message: message)
        case .openAI(let model):
            return await callOpenAI(
                node: node, model: model, system: system, history: history, message: message)
        }
    }

    private func nodeSettings(_ node: AgentNode) -> GenerationSettings {
        var settings = baseSettings()
        settings.temperature = node.temperature
        settings.maxTokens = node.maxTokens
        settings.reasoningEnabled = node.reasoningEnabled
        settings.localThinkingEnabled = node.reasoningEnabled
        return settings
    }

    private func callLocal(
        node: AgentNode, modelID: String, system: String, history: [ChatMessage], message: String
    ) async -> ModelReply {
        guard engine.isLoaded(modelID) else {
            return ModelReply(
                text: "",
                error:
                    "\(node.name) can't run — its local model isn't loaded. Load it into a slot and run again."
            )
        }
        var conversation = Conversation()
        conversation.messages = history
        let settings = nodeSettings(node)

        return await withCheckedContinuation { continuation in
            var collected = ""
            engine.generate(
                conversation: conversation,
                prompt: message,
                images: [],
                settings: settings,
                systemInstructions: system,
                targetModelID: modelID,
                onChunk: { [weak self] delta in
                    collected += delta
                    self?.nodeStates[node.id]?.streaming = collected
                },
                onComplete: { [weak self] info, errorMessage in
                    if let info {
                        self?.nodeStates[node.id]?.tokensPerSecond = info.tokensPerSecond
                    }
                    continuation.resume(
                        returning: ModelReply(
                            text: Self.stripThinking(collected), error: errorMessage))
                })
        }
    }

    private func callAnthropic(
        node: AgentNode, model: String, system: String, history: [ChatMessage], message: String
    ) async -> ModelReply {
        guard let key = SecretsStore.anthropicAPIKey else {
            return ModelReply(
                text: "", error: "\(node.name) needs an Anthropic API key — add one in Settings.")
        }
        var config = AnthropicStreamConfig()
        config.reasoningEnabled = node.reasoningEnabled
        config.maxTokens = max(node.maxTokens, 2048)
        var messages = history.compactMap { entry -> AnthropicClient.Message? in
            guard entry.role != .system, !entry.content.isEmpty else { return nil }
            return AnthropicClient.Message(
                role: entry.role == .user ? "user" : "assistant", text: entry.content)
        }
        messages.append(AnthropicClient.Message(role: "user", text: message))

        var collected = ""
        do {
            try await AnthropicClient(apiKey: key).stream(
                model: model, system: system, messages: messages, config: config,
                onChunk: { [weak self] delta in
                    collected += delta
                    self?.nodeStates[node.id]?.streaming = collected
                })
            return ModelReply(text: Self.stripThinking(collected), error: nil)
        } catch {
            return ModelReply(
                text: Self.stripThinking(collected), error: friendlyError(error, node: node))
        }
    }

    private func callOpenRouter(
        node: AgentNode, model: String, system: String, history: [ChatMessage], message: String
    ) async -> ModelReply {
        guard let key = SecretsStore.openRouterAPIKey else {
            return ModelReply(
                text: "", error: "\(node.name) needs an OpenRouter API key — add one in Settings.")
        }
        var config = OpenRouterStreamConfig()
        config.reasoningEnabled = node.reasoningEnabled
        config.maxTokens = max(node.maxTokens, 1024)
        var messages = history.compactMap { entry -> OpenRouterClient.Message? in
            guard entry.role != .system, !entry.content.isEmpty else { return nil }
            return OpenRouterClient.Message(
                role: entry.role == .user ? "user" : "assistant", text: entry.content)
        }
        messages.append(OpenRouterClient.Message(role: "user", text: message))

        var collected = ""
        do {
            try await OpenRouterClient(apiKey: key).stream(
                model: model, system: system, messages: messages, config: config,
                onChunk: { [weak self] delta in
                    collected += delta
                    self?.nodeStates[node.id]?.streaming = collected
                })
            return ModelReply(text: Self.stripThinking(collected), error: nil)
        } catch {
            return ModelReply(
                text: Self.stripThinking(collected), error: friendlyError(error, node: node))
        }
    }

    private func callOpenAI(
        node: AgentNode, model: String, system: String, history: [ChatMessage], message: String
    ) async -> ModelReply {
        guard let key = SecretsStore.openAIAPIKey else {
            return ModelReply(
                text: "", error: "\(node.name) needs an OpenAI API key — add one in Settings.")
        }
        var config = OpenAIStreamConfig()
        config.reasoningEnabled = node.reasoningEnabled
        config.maxOutputTokens = max(node.maxTokens, 2048)
        var turns = history.compactMap { entry -> OpenAIClient.Turn? in
            guard entry.role != .system, !entry.content.isEmpty else { return nil }
            return OpenAIClient.Turn(
                role: entry.role == .user ? "user" : "assistant", text: entry.content)
        }
        turns.append(OpenAIClient.Turn(role: "user", text: message))

        var collected = ""
        do {
            try await OpenAIClient(apiKey: key).stream(
                model: model, system: system, turns: turns, config: config,
                onChunk: { [weak self] delta in
                    collected += delta
                    self?.nodeStates[node.id]?.streaming = collected
                })
            return ModelReply(text: Self.stripThinking(collected), error: nil)
        } catch {
            return ModelReply(
                text: Self.stripThinking(collected), error: friendlyError(error, node: node))
        }
    }

    private func friendlyError(_ error: Error, node: AgentNode) -> String {
        if error is CancellationError { return "\(node.name) was cancelled." }
        return "\(node.name) failed: \(error.localizedDescription)"
    }

    /// Reasoning arrives wrapped in <think> tags for the chat UI. Downstream
    /// blocks want the answer, not the deliberation.
    private static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            guard let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex)
            else {
                result = String(result[..<open.lowerBound])
                break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Text

    private func fireText(node: AgentNode, inputs: [String: [PortValue]]) -> NodeOutcome {
        var rendered = node.template
        for variable in AgentNode.templateVariables(in: node.template) {
            let value = joined(inputs[variable] ?? [], labelled: false)
            rendered = rendered.replacingOccurrences(of: "{{\(variable)}}", with: value)
            // Tolerate whitespace inside the braces the user typed.
            rendered = rendered.replacingOccurrences(of: "{{ \(variable) }}", with: value)
        }
        return .emit(["text": rendered])
    }

    // MARK: Fork

    private func fireBranch(node: AgentNode, inputs: [String: [PortValue]]) -> NodeOutcome {
        let value = joined(inputs["value"] ?? [], labelled: false)
        let passed = node.branchTest.evaluate(value, operand: node.branchOperand)
        append(
            .finished, node: node.id, name: node.name,
            passed ? "Yes — went down the Yes wire." : "No — went down the No wire.")
        // Only the taken side emits, so the untaken path stays quiet.
        return .emit([passed ? "true" : "false": value])
    }

    // MARK: Extract

    private func fireExtract(node: AgentNode, inputs: [String: [PortValue]]) -> NodeOutcome {
        let text = joined(inputs["text"] ?? [], labelled: false)
        let extracted: String?
        switch node.extractMode {
        case .codeFence:
            extracted = Self.firstCodeFence(in: text)
        case .json:
            extracted = Self.firstJSONObject(in: text)
        case .regex:
            extracted = text.range(of: node.extractPattern, options: .regularExpression)
                .map { String(text[$0]) }
        case .firstLine:
            extracted = text.split(whereSeparator: \.isNewline).first.map(String.init)
        case .lastLine:
            extracted = text.split(whereSeparator: \.isNewline).last.map(String.init)
        }
        guard let extracted, !extracted.isEmpty else {
            return .failure(
                "\(node.name) found no \(node.extractMode.title.lowercased()) in what it was given. Check what the block before it is producing."
            )
        }
        return .emit(["match": extracted])
    }

    private static func firstCodeFence(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // Skip the language tag on the opening fence line.
        let afterOpen = text[open.upperBound...]
        guard let newline = afterOpen.firstIndex(where: \.isNewline) else { return nil }
        let bodyStart = afterOpen.index(after: newline)
        guard let close = text.range(of: "```", range: bodyStart..<text.endIndex) else {
            return String(text[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[bodyStart..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opener = text[start]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == opener { depth += 1 }
            if character == closer {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Tool block

    private func fireTool(node: AgentNode, inputs: [String: [PortValue]]) async -> NodeOutcome {
        let input = joined(inputs["input"] ?? [], labelled: false)
        let parts = node.toolBinding.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .failure("\(node.name) has no tool picked. Click it and choose one.")
        }
        let rendered = node.toolArguments
            .replacingOccurrences(of: "{{input}}", with: Self.jsonEscaped(input))
        guard let data = rendered.data(using: .utf8),
            let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(
                "\(node.name)'s arguments aren't valid JSON. Click it and check the arguments box.")
        }
        do {
            try await mcp.ensureConnected(entryID: parts[0])
            let result = try await mcp.callTool(
                entryID: parts[0], name: parts[1], arguments: arguments)
            return .emit(["result": Self.readableToolResult(result)])
        } catch {
            return .failure("\(node.name) couldn't run \(node.toolBinding): \(error.localizedDescription)")
        }
    }

    // MARK: File block

    private func fireFile(
        node: AgentNode, inputs: [String: [PortValue]], workspace: AgentWorkspace
    ) -> NodeOutcome {
        let content = joined(inputs["content"] ?? [], labelled: false)
        let path = node.filePath.replacingOccurrences(
            of: "{{input}}", with: content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
        do {
            switch node.fileMode {
            case .read:
                return .emit(["content": try workspace.read(path)])
            case .write:
                let url = try workspace.write(path, contents: content)
                append(
                    .finished, node: node.id, name: node.name,
                    "Wrote \(workspace.displayPath(url)) (\(Format.bytes(content.utf8.count)))")
                return .emit(["content": content])
            case .append:
                let url = try workspace.append(path, contents: content)
                append(
                    .finished, node: node.id, name: node.name,
                    "Added to \(workspace.displayPath(url))")
                return .emit(["content": content])
            case .list:
                let listing = workspace.list()
                return .emit([
                    "content": listing.isEmpty
                        ? "The workspace is empty." : listing.joined(separator: "\n")
                ])
            }
        } catch {
            return .failure("\(node.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Tool calls from agents

    struct ToolCallRequest: Equatable {
        var serverID: String?
        var toolName: String
        var arguments: [String: String]
        /// Raw arguments as JSON, for MCP servers that want richer shapes.
        var argumentsJSON: String

        var displayName: String {
            serverID.map { "\($0).\(toolName)" } ?? toolName
        }
    }

    /// Finds a `FORGE_TOOL {json}` line anywhere in the reply. Kept independent
    /// of the chat path's parser so a change here cannot regress chat.
    static func parseToolCall(in text: String) -> ToolCallRequest? {
        guard let marker = text.range(of: "FORGE_TOOL") else { return nil }
        let after = text[marker.upperBound...]
        guard let braceStart = after.firstIndex(of: "{") else { return nil }
        // Walk to the matching brace so embedded objects survive.
        var depth = 0
        var index = braceStart
        var end: Substring.Index?
        var inString = false
        var escaped = false
        while index < after.endIndex {
            let character = after[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = after.index(after: index)
                        break
                    }
                }
            }
            index = after.index(after: index)
        }
        guard let end else { return nil }
        let json = String(after[braceStart..<end])
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let toolName = object["tool"] as? String, !toolName.isEmpty
        else { return nil }

        let rawArguments = object["arguments"] as? [String: Any] ?? [:]
        var flattened: [String: String] = [:]
        for (key, value) in rawArguments {
            if let string = value as? String {
                flattened[key] = string
            } else if let number = value as? NSNumber {
                flattened[key] = number.stringValue
            }
        }
        let argumentsJSON =
            (try? JSONSerialization.data(withJSONObject: rawArguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return ToolCallRequest(
            serverID: (object["server"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            toolName: toolName,
            arguments: flattened,
            argumentsJSON: argumentsJSON)
    }

    /// Runs a tool an agent asked for, refusing anything that block was not
    /// granted. Grants are per-block so a planner cannot quietly write files.
    private func runToolCall(
        _ request: ToolCallRequest, node: AgentNode, workspace: AgentWorkspace
    ) async -> String {
        // Built-in workspace tools.
        if request.serverID == nil, request.toolName.hasPrefix("workspace_") {
            guard node.workspaceAccess else {
                return
                    "Refused: \(node.name) does not have workspace access. Turn it on for this block if it should be able to touch files."
            }
            do {
                switch request.toolName {
                case "workspace_list":
                    let listing = workspace.list()
                    return listing.isEmpty ? "The workspace is empty." : listing.joined(separator: "\n")
                case "workspace_read":
                    guard let path = request.arguments["path"] else { return "Missing \"path\"." }
                    return try workspace.read(path)
                case "workspace_write":
                    guard let path = request.arguments["path"] else { return "Missing \"path\"." }
                    let url = try workspace.write(path, contents: request.arguments["content"] ?? "")
                    return "Wrote \(workspace.displayPath(url))."
                case "workspace_append":
                    guard let path = request.arguments["path"] else { return "Missing \"path\"." }
                    let url = try workspace.append(
                        path, contents: request.arguments["content"] ?? "")
                    return "Added to \(workspace.displayPath(url))."
                default:
                    return "No built-in tool named \(request.toolName)."
                }
            } catch {
                return "Failed: \(error.localizedDescription)"
            }
        }

        guard let serverID = request.serverID else {
            return
                "That tool needs a server id. Call it as FORGE_TOOL {\"server\":\"…\",\"tool\":\"\(request.toolName)\",\"arguments\":{…}}."
        }
        let binding = "\(serverID).\(request.toolName)"
        guard node.toolGrants.contains(binding) else {
            let granted = node.toolGrants.isEmpty ? "none" : node.toolGrants.joined(separator: ", ")
            return
                "Refused: \(node.name) is not allowed to call \(binding). Tools it can use: \(granted)."
        }
        do {
            try await mcp.ensureConnected(entryID: serverID)
            let arguments =
                (try? JSONSerialization.jsonObject(
                    with: Data(request.argumentsJSON.utf8))) as? [String: Any] ?? [:]
            let data = try await mcp.callTool(
                entryID: serverID, name: request.toolName, arguments: arguments)
            return Self.readableToolResult(data)
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    /// MCP results arrive as a content-block envelope; pull out the text.
    static func readableToolResult(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "(binary result)"
        }
        if let content = object["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let text = object["text"] as? String { return text }
        return
            (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "(no readable result)"
    }

    private static func jsonEscaped(_ text: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data()
        guard let string = String(data: data, encoding: .utf8), string.count > 2 else {
            return text
        }
        // Strip the array brackets JSONSerialization insists on.
        return String(string.dropFirst().dropLast())
    }

    // MARK: - Helpers

    /// Joins the values sitting on one port. Labelled joins attribute each
    /// chunk to the block it came from — that attribution is what lets an agent
    /// answer "what did the others say" without guessing.
    private func joined(_ values: [PortValue], labelled: Bool) -> String {
        let usable = values.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return "" }
        if !labelled || usable.count == 1 && !labelled {
            return usable.map(\.text).joined(separator: "\n\n")
        }
        return usable.map { "[\($0.fromName)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    private func append(_ kind: LogEntry.Kind, node: UUID?, name: String, _ text: String) {
        log.append(
            LogEntry(time: Date(), nodeID: node, nodeName: name, kind: kind, text: text))
        // The log is a live view, not an archive; keep it bounded.
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
