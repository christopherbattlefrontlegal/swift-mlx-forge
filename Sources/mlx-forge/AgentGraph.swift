// Forge — agent graph model.
//
// A graph is a dataflow program: typed nodes with named input/output ports,
// connected by wires. Values travelling the wires are plain text — every node
// consumes text and emits text — which keeps the whole thing inspectable in the
// canvas and avoids a type system the user has to reason about.
//
// Several wires may land on one input port; their values are concatenated in
// wire order, each labelled with its source node. That is what makes an "agent
// team" fall out of the primitive: wire three agents into one agent's `context`
// port and it sees all three, attributed.
//
// Cycles are legal and are how review loops are expressed (coder → auditor →
// coder). `maxIterations` is the only backstop.

import Foundation
import SwiftUI

// MARK: - Backends

/// Which inference path an agent node speaks through. Local models are
/// referenced by resident model ID so a graph survives reordering of slots.
enum AgentBackend: Codable, Hashable, Sendable {
    case local(modelID: String)
    case anthropic(model: String)
    case openRouter(model: String)
    case openAI(model: String)

    var providerName: String {
        switch self {
        case .local: "Local"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        }
    }

    var isCloud: Bool {
        if case .local = self { return false }
        return true
    }

    /// Raw model identifier, for display when nothing better is available.
    var modelIdentifier: String {
        switch self {
        case .local(let id): id
        case .anthropic(let model): model
        case .openRouter(let model): model
        case .openAI(let model): model
        }
    }

    var symbolName: String {
        switch self {
        case .local: "cpu"
        case .anthropic: "sparkle"
        case .openRouter: "point.3.connected.trianglepath.dotted"
        case .openAI: "circle.hexagongrid"
        }
    }
}

// MARK: - Ports

/// A named connection point on a node. `id` is stable per node kind and is what
/// wires reference, so renaming a node never breaks its wiring.
struct AgentPort: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Optional ports let a node fire without them; required ports gate it.
    let isRequired: Bool

    init(_ id: String, _ title: String, required: Bool = true) {
        self.id = id
        self.title = title
        self.isRequired = required
    }
}

// MARK: - Node kinds

/// What a node does when it fires. The associated configuration for each kind
/// lives on `AgentNode` itself (flat storage) so the whole graph stays trivially
/// Codable and tolerant of new fields.
enum AgentNodeKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case input
    case agent
    case text
    case branch
    case extract
    case tool
    case file
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: "Task"
        case .agent: "Agent"
        case .text: "Text"
        case .branch: "Fork"
        case .extract: "Extract"
        case .tool: "Tool"
        case .file: "File"
        case .output: "Result"
        }
    }

    var symbolName: String {
        switch self {
        case .input: "arrow.right.to.line"
        case .agent: "brain.head.profile"
        case .text: "text.alignleft"
        case .branch: "arrow.triangle.branch"
        case .extract: "scissors"
        case .tool: "wrench.and.screwdriver"
        case .file: "doc.text"
        case .output: "arrow.left.to.line"
        }
    }

    var summary: String {
        switch self {
        case .input:
            "What you type when you hit Run lands here. Wire it into whatever should go first."
        case .agent:
            "One model doing one job. Give it a role in plain English and pick which model runs it."
        case .text:
            "Glue text together. Anything you put in {{double braces}} turns into a socket you can wire into."
        case .branch:
            "Looks at what came in and sends it down the Yes wire or the No wire. This is how you loop."
        case .extract:
            "Grabs just the part you want out of a long answer — the code, the JSON, the last line."
        case .tool:
            "Runs one of your MCP tools and passes the result along."
        case .file:
            "Reads or writes a file in this graph's own folder."
        case .output:
            "Whatever lands here is the run's answer."
        }
    }

    var accent: Color {
        switch self {
        case .input: Theme.steel
        case .agent: Theme.ember
        case .text: Theme.steel
        case .branch: Theme.emberGlow
        case .extract: Theme.steel
        case .tool: Theme.emberGlow
        case .file: Theme.steel
        case .output: Theme.okGreen
        }
    }
}

// MARK: - Node configuration enums

/// How a `.branch` node decides which way to send its input.
enum AgentBranchTest: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case contains
    case notContains
    case matchesRegex
    case isEmpty
    case isNotEmpty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .matchesRegex: "matches regex"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }

    var needsOperand: Bool {
        switch self {
        case .contains, .notContains, .matchesRegex: true
        case .isEmpty, .isNotEmpty: false
        }
    }

    func evaluate(_ text: String, operand: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .contains:
            return text.range(of: operand, options: .caseInsensitive) != nil
        case .notContains:
            return text.range(of: operand, options: .caseInsensitive) == nil
        case .matchesRegex:
            return text.range(of: operand, options: .regularExpression) != nil
        case .isEmpty:
            return trimmed.isEmpty
        case .isNotEmpty:
            return !trimmed.isEmpty
        }
    }
}

/// What a `.extract` node pulls out of its input.
enum AgentExtractMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codeFence
    case json
    case regex
    case firstLine
    case lastLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeFence: "First code fence"
        case .json: "First JSON object"
        case .regex: "Regex match"
        case .firstLine: "First line"
        case .lastLine: "Last line"
        }
    }

    var needsPattern: Bool { self == .regex }
}

/// Whether a `.file` node reads or writes.
enum AgentFileMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case read
    case write
    case append
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Read file"
        case .write: "Write file"
        case .append: "Append to file"
        case .list: "List workspace"
        }
    }

    var needsContent: Bool { self == .write || self == .append }
}

// MARK: - Node

struct AgentNode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: AgentNodeKind
    var name: String
    var position: CGPoint

    // MARK: Agent configuration
    /// System prompt / role description. Only meaningful for `.agent`.
    var role: String = ""
    var backend: AgentBackend = .local(modelID: "")
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    var reasoningEnabled: Bool = false
    /// MCP tool grants as "serverID.toolName". Empty means this agent gets no
    /// tools — grants are per-node on purpose, so a planner can't write files.
    var toolGrants: [String] = []
    /// Grants the built-in workspace file tools (scoped to the run directory).
    var workspaceAccess: Bool = false

    // MARK: Text configuration
    var template: String = ""

    // MARK: Branch configuration
    var branchTest: AgentBranchTest = .contains
    var branchOperand: String = ""

    // MARK: Extract configuration
    var extractMode: AgentExtractMode = .codeFence
    var extractPattern: String = ""

    // MARK: Tool configuration
    /// "serverID.toolName" for the single tool this node calls.
    var toolBinding: String = ""
    /// JSON object template for the call arguments; supports {{input}}.
    var toolArguments: String = "{}"

    // MARK: File configuration
    var fileMode: AgentFileMode = .read
    /// Workspace-relative path. Supports {{input}} interpolation.
    var filePath: String = ""

    init(kind: AgentNodeKind, name: String? = nil, position: CGPoint = .zero) {
        self.kind = kind
        self.name = name ?? kind.title
        self.position = position
        switch kind {
        case .agent:
            self.role = "You are a helpful agent. Answer the task directly and concisely."
        case .text:
            self.template = "{{input}}"
        case .branch:
            self.branchOperand = "VERDICT: PASS"
        case .file:
            self.filePath = "notes.md"
        default:
            break
        }
    }

    // Tolerant decoding: an older saved graph must never fail to open because a
    // field was added. Every configuration key falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(AgentNodeKind.self, forKey: .kind) ?? .agent
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.title
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position) ?? .zero
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        backend = try c.decodeIfPresent(AgentBackend.self, forKey: .backend) ?? .local(modelID: "")
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4096
        reasoningEnabled = try c.decodeIfPresent(Bool.self, forKey: .reasoningEnabled) ?? false
        toolGrants = try c.decodeIfPresent([String].self, forKey: .toolGrants) ?? []
        workspaceAccess = try c.decodeIfPresent(Bool.self, forKey: .workspaceAccess) ?? false
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        branchTest = try c.decodeIfPresent(AgentBranchTest.self, forKey: .branchTest) ?? .contains
        branchOperand = try c.decodeIfPresent(String.self, forKey: .branchOperand) ?? ""
        extractMode = try c.decodeIfPresent(AgentExtractMode.self, forKey: .extractMode) ?? .codeFence
        extractPattern = try c.decodeIfPresent(String.self, forKey: .extractPattern) ?? ""
        toolBinding = try c.decodeIfPresent(String.self, forKey: .toolBinding) ?? ""
        toolArguments = try c.decodeIfPresent(String.self, forKey: .toolArguments) ?? "{}"
        fileMode = try c.decodeIfPresent(AgentFileMode.self, forKey: .fileMode) ?? .read
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
    }

    // MARK: Ports

    /// Placeholders written as {{name}} in a template, in first-appearance order.
    static func templateVariables(in template: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        var rest = Substring(template)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let raw = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = raw.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty, seen.insert(name).inserted {
                found.append(name)
            }
            rest = rest[close.upperBound...]
        }
        return found
    }

    var inputPorts: [AgentPort] {
        switch kind {
        case .input:
            return []
        case .agent:
            return [
                AgentPort("prompt", "Prompt"),
                AgentPort("context", "Context", required: false),
            ]
        case .text:
            let variables = Self.templateVariables(in: template)
            // A template with no placeholders is a constant; give it one optional
            // port anyway so it can still be triggered by an upstream node.
            guard !variables.isEmpty else {
                return [AgentPort("trigger", "Trigger", required: false)]
            }
            return variables.map { AgentPort($0, $0) }
        case .branch:
            return [AgentPort("value", "Value")]
        case .extract:
            return [AgentPort("text", "Text")]
        case .tool:
            return [AgentPort("input", "Input", required: false)]
        case .file:
            switch fileMode {
            case .read, .list:
                return [AgentPort("trigger", "Trigger", required: false)]
            case .write, .append:
                return [AgentPort("content", "Content")]
            }
        case .output:
            return [AgentPort("value", "Value")]
        }
    }

    var outputPorts: [AgentPort] {
        switch kind {
        case .input:
            return [AgentPort("task", "Task")]
        case .agent:
            return [AgentPort("output", "Output")]
        case .text:
            return [AgentPort("text", "Text")]
        case .branch:
            return [AgentPort("true", "Yes"), AgentPort("false", "No")]
        case .extract:
            return [AgentPort("match", "Match")]
        case .tool:
            return [AgentPort("result", "Result")]
        case .file:
            return [AgentPort("content", "Content")]
        case .output:
            return []
        }
    }

    /// One-line description of the node's current configuration, for the canvas.
    var configSummary: String {
        switch kind {
        case .input:
            return "run task"
        case .agent:
            return backend.modelIdentifier.isEmpty
                ? "no model selected" : AgentBackendLabels.short(backend)
        case .text:
            let firstLine = template.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "empty template" : String(firstLine.prefix(48))
        case .branch:
            return branchTest.needsOperand
                ? "\(branchTest.title) “\(String(branchOperand.prefix(24)))”"
                : branchTest.title
        case .extract:
            return extractMode == .regex
                ? "regex \(String(extractPattern.prefix(24)))" : extractMode.title
        case .tool:
            return toolBinding.isEmpty ? "no tool selected" : toolBinding
        case .file:
            return "\(fileMode.title) · \(filePath.isEmpty ? "no path" : filePath)"
        case .output:
            return "run result"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, position
        case role, backend, temperature, maxTokens, reasoningEnabled, toolGrants, workspaceAccess
        case template
        case branchTest, branchOperand
        case extractMode, extractPattern
        case toolBinding, toolArguments
        case fileMode, filePath
    }
}

/// Display labels for a backend. Kept out of `AgentBackend` so the model layer
/// does not depend on the provider clients.
enum AgentBackendLabels {
    @MainActor
    static func full(_ backend: AgentBackend, engine: InferenceEngine?) -> String {
        switch backend {
        case .local(let modelID):
            if let entry = engine?.loadedModels.first(where: { $0.id == modelID }) {
                return entry.model.shortName
            }
            if modelID.isEmpty { return "No model" }
            return URL(filePath: modelID).lastPathComponent + " (not loaded)"
        case .anthropic(let model):
            return AnthropicClient.label(for: model)
        case .openRouter(let model):
            return OpenRouterClient.label(for: model)
        case .openAI(let model):
            return OpenAIClient.label(for: model)
        }
    }

    /// Backend label without engine context — safe from any isolation domain.
    static func short(_ backend: AgentBackend) -> String {
        switch backend {
        case .local(let modelID):
            return modelID.isEmpty ? "No model" : URL(filePath: modelID).lastPathComponent
        case .anthropic(let model):
            return AnthropicClient.label(for: model)
        case .openRouter(let model):
            return OpenRouterClient.label(for: model)
        case .openAI(let model):
            return OpenAIClient.label(for: model)
        }
    }
}

// MARK: - Wire

struct AgentWire: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var fromNode: UUID
    var fromPort: String
    var toNode: UUID
    var toPort: String

    init(
        id: UUID = UUID(), fromNode: UUID, fromPort: String, toNode: UUID, toPort: String
    ) {
        self.id = id
        self.fromNode = fromNode
        self.fromPort = fromPort
        self.toNode = toNode
        self.toPort = toPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fromNode = try c.decode(UUID.self, forKey: .fromNode)
        fromPort = try c.decode(String.self, forKey: .fromPort)
        toNode = try c.decode(UUID.self, forKey: .toNode)
        toPort = try c.decode(String.self, forKey: .toPort)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromNode, fromPort, toNode, toPort
    }
}

// MARK: - Graph

struct AgentGraph: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Graph"
    var nodes: [AgentNode] = []
    var wires: [AgentWire] = []
    /// Backstop for cyclic graphs: how many times any single node may fire in
    /// one run. Every real loop (coder → auditor → coder) relies on this.
    var maxIterations: Int = 12
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(), name: String = "New Graph", nodes: [AgentNode] = [],
        wires: [AgentWire] = [], maxIterations: Int = 12
    ) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.wires = wires
        self.maxIterations = maxIterations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Graph"
        nodes = try c.decodeIfPresent([AgentNode].self, forKey: .nodes) ?? []
        wires = try c.decodeIfPresent([AgentWire].self, forKey: .wires) ?? []
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 12
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        // Drop wires whose endpoints no longer exist rather than crashing the
        // canvas later on a dangling reference.
        let ids = Set(nodes.map(\.id))
        wires.removeAll { !ids.contains($0.fromNode) || !ids.contains($0.toNode) }
        // Heal blocks that were saved outside the canvas — an earlier drag bug
        // could fling one somewhere you could not scroll back to, and a NaN
        // would make it vanish entirely.
        for index in nodes.indices {
            nodes[index].position = AgentGraph.sanitized(nodes[index].position)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nodes, wires, maxIterations, updatedAt
    }

    /// Canvas extent. Positions are kept inside it so every block stays
    /// reachable by scrolling.
    static let canvasSize = CGSize(width: 6000, height: 4000)

    /// Forces a position back onto the canvas, replacing NaN or infinity with
    /// a sane default rather than letting it poison layout.
    static func sanitized(_ point: CGPoint) -> CGPoint {
        let x = point.x.isFinite ? point.x : 100
        let y = point.y.isFinite ? point.y : 100
        return CGPoint(
            x: min(max(0, x), canvasSize.width - 300),
            y: min(max(0, y), canvasSize.height - 200))
    }

    // MARK: Queries

    func node(_ nodeID: UUID) -> AgentNode? {
        nodes.first { $0.id == nodeID }
    }

    func index(of nodeID: UUID) -> Int? {
        nodes.firstIndex { $0.id == nodeID }
    }

    var inputNodes: [AgentNode] { nodes.filter { $0.kind == .input } }
    var outputNodes: [AgentNode] { nodes.filter { $0.kind == .output } }

    func wires(from nodeID: UUID, port: String) -> [AgentWire] {
        wires.filter { $0.fromNode == nodeID && $0.fromPort == port }
    }

    func wires(into nodeID: UUID) -> [AgentWire] {
        wires.filter { $0.toNode == nodeID }
    }

    func wires(into nodeID: UUID, port: String) -> [AgentWire] {
        wires.filter { $0.toNode == nodeID && $0.toPort == port }
    }

    /// True when adding this wire would duplicate one already present.
    func hasWire(fromNode: UUID, fromPort: String, toNode: UUID, toPort: String) -> Bool {
        wires.contains {
            $0.fromNode == fromNode && $0.fromPort == fromPort
                && $0.toNode == toNode && $0.toPort == toPort
        }
    }

    // MARK: Mutation

    mutating func addNode(_ node: AgentNode) {
        nodes.append(node)
        updatedAt = Date()
    }

    mutating func removeNode(_ nodeID: UUID) {
        nodes.removeAll { $0.id == nodeID }
        wires.removeAll { $0.fromNode == nodeID || $0.toNode == nodeID }
        updatedAt = Date()
    }

    mutating func removeWire(_ wireID: UUID) {
        wires.removeAll { $0.id == wireID }
        updatedAt = Date()
    }

    /// Connects two ports, rejecting self-loops on a single node and duplicates.
    /// Fan-in is allowed: several wires may land on one input port.
    @discardableResult
    mutating func connect(
        fromNode: UUID, fromPort: String, toNode: UUID, toPort: String
    ) -> Bool {
        guard fromNode != toNode else { return false }
        guard !hasWire(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort)
        else { return false }
        wires.append(
            AgentWire(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort))
        updatedAt = Date()
        return true
    }

    /// Drops wires that point at ports a node no longer has. Text nodes change
    /// their port set as the template is edited, so this runs after every edit.
    mutating func pruneOrphanWires() {
        let inputs = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, Set($0.inputPorts.map(\.id))) })
        let outputs = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, Set($0.outputPorts.map(\.id))) })
        wires.removeAll { wire in
            guard let out = outputs[wire.fromNode], let into = inputs[wire.toNode] else {
                return true
            }
            return !out.contains(wire.fromPort) || !into.contains(wire.toPort)
        }
    }

    // MARK: Validation

    struct Issue: Identifiable, Hashable {
        enum Severity: Hashable {
            case error
            case warning
        }
        var id: String { "\(nodeID?.uuidString ?? "graph")-\(message)" }
        var nodeID: UUID?
        var severity: Severity
        var message: String
    }

    /// Problems that would make a run fail or produce nothing. Errors block the
    /// run; warnings are shown but do not.
    func issues(loadedModelIDs: Set<String>) -> [Issue] {
        // Every message says what is wrong AND what to do about it. A validation
        // list you have to decode is worse than no validation list.
        var result: [Issue] = []
        if nodes.isEmpty {
            result.append(
                .init(
                    nodeID: nil, severity: .error,
                    message: "This graph is empty. Drag a block in from the palette to start."))
            return result
        }
        if inputNodes.isEmpty {
            result.append(
                .init(
                    nodeID: nil, severity: .error,
                    message:
                        "There's no Task block, so nothing would receive what you type. Add one and wire it into your first step."
                ))
        }
        if outputNodes.isEmpty {
            result.append(
                .init(
                    nodeID: nil, severity: .warning,
                    message:
                        "There's no Result block, so the run won't collect an answer. Add one and wire your last step into it."
                ))
        }
        for node in nodes {
            for port in node.inputPorts where port.isRequired {
                if wires(into: node.id, port: port.id).isEmpty {
                    result.append(
                        .init(
                            nodeID: node.id, severity: .error,
                            message:
                                "\(node.name) has nothing plugged into “\(port.title)”. Drag a wire from another block's output into it."
                        ))
                }
            }
            switch node.kind {
            case .agent:
                switch node.backend {
                case .local(let modelID):
                    if modelID.isEmpty {
                        result.append(
                            .init(
                                nodeID: node.id, severity: .error,
                                message: "\(node.name) has no model picked. Click it and choose one."
                            ))
                    } else if !loadedModelIDs.contains(modelID) {
                        result.append(
                            .init(
                                nodeID: node.id, severity: .error,
                                message:
                                    "\(node.name) wants a local model that isn't loaded. Load it into a slot, or pick a different model."
                            ))
                    }
                case .anthropic(let model), .openRouter(let model), .openAI(let model):
                    if model.isEmpty {
                        result.append(
                            .init(
                                nodeID: node.id, severity: .error,
                                message: "\(node.name) has no model picked. Click it and choose one."
                            ))
                    }
                }
            case .tool:
                if node.toolBinding.isEmpty {
                    result.append(
                        .init(
                            nodeID: node.id, severity: .error,
                            message:
                                "\(node.name) has no tool picked. Click it and choose one of your MCP tools."
                        ))
                }
            case .file:
                if node.filePath.isEmpty && node.fileMode != .list {
                    result.append(
                        .init(
                            nodeID: node.id, severity: .error,
                            message: "\(node.name) needs a file name. Click it and type one."))
                }
            case .branch:
                if node.branchTest.needsOperand && node.branchOperand.isEmpty {
                    result.append(
                        .init(
                            nodeID: node.id, severity: .error,
                            message:
                                "\(node.name) has nothing to compare against. Click it and type the text to look for."
                        ))
                }
            case .extract:
                if node.extractMode.needsPattern && node.extractPattern.isEmpty {
                    result.append(
                        .init(
                            nodeID: node.id, severity: .error,
                            message:
                                "\(node.name) needs a pattern to search for. Click it and type one."
                        ))
                }
            case .input, .text, .output:
                break
            }
            // A block whose answer goes nowhere still costs a model call and is
            // then thrown away — worth saying out loud, but not fatal.
            if node.kind != .output, !node.outputPorts.isEmpty,
                !wires.contains(where: { $0.fromNode == node.id })
            {
                result.append(
                    .init(
                        nodeID: node.id, severity: .warning,
                        message:
                            "\(node.name)'s answer isn't wired anywhere, so it'll be thrown away."))
            }
        }
        return result
    }

    var hasBlockingIssue: Bool {
        // Model residency is checked at run time; this is the cheap structural read.
        issues(loadedModelIDs: []).contains { $0.severity == .error && $0.nodeID == nil }
    }
}
