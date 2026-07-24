// Forge — the graph inspector.
//
// Shows whatever you last clicked: a block's settings, or the exact text that
// last travelled a wire. Every control is plain-language and every block also
// shows what it actually produced on the last run, so you can see where a graph
// went wrong without reading a log.

import SwiftUI

struct AgentInspectorPanel: View {
    @Environment(AppState.self) private var app
    @Binding var selectedNodeID: UUID?
    @Binding var selectedWireID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if let wireID = selectedWireID, let wire = app.selectedGraph?.wires.first(where: { $0.id == wireID }) {
                    wireInspector(wire)
                } else if let nodeID = selectedNodeID, let index = app.nodeIndex(nodeID) {
                    nodeInspector(graphIndex: index.graph, nodeIndex: index.node)
                } else {
                    emptyState
                }
            }
            .padding(Theme.s4)
        }
        .background(.black.opacity(0.18))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Nothing selected")
                .font(.headline)
            Text("Click a block to change what it does, or click a wire to read what last went through it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Wire

    @ViewBuilder
    private func wireInspector(_ wire: AgentWire) -> some View {
        let fromName = app.selectedGraph?.node(wire.fromNode)?.name ?? "?"
        let toName = app.selectedGraph?.node(wire.toNode)?.name ?? "?"
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack {
                Label("Wire", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    app.removeWire(wire.id)
                    selectedWireID = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this wire")
            }

            Text("**\(fromName)** · \(wire.fromPort)  →  **\(toName)** · \(wire.toPort)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let value = app.graphRuntime.wireValues[wire.id] {
                HStack {
                    Text("What went through, last run")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    CopyClipButton(text: value.text)
                }
                ScrollView {
                    Text(value.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.s2)
                }
                .frame(maxHeight: 360)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Nothing has travelled this wire yet. Run the graph and come back.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Node

    @ViewBuilder
    private func nodeInspector(graphIndex: Int, nodeIndex: Int) -> some View {
        @Bindable var app = app
        let node = app.agentGraphs[graphIndex].nodes[nodeIndex]
        let binding = $app.agentGraphs[graphIndex].nodes[nodeIndex]

        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                Image(systemName: node.kind.symbolName)
                    .foregroundStyle(node.kind.accent)
                Text(node.kind.title)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    app.agentGraphs[graphIndex].removeNode(node.id)
                    selectedNodeID = nil
                    app.scheduleGraphSave()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this block")
            }

            Text(node.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labelled("Name") {
                TextField("Name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
            }

            switch node.kind {
            case .agent: agentSettings(binding, node: node)
            case .text: textSettings(binding, node: node)
            case .branch: branchSettings(binding)
            case .extract: extractSettings(binding, node: node)
            case .tool: toolSettings(binding, node: node)
            case .file: fileSettings(binding, node: node)
            case .input, .output: EmptyView()
            }

            lastRunSection(node)
        }
        .onChange(of: node) { _, _ in app.scheduleGraphSave() }
    }

    // MARK: Agent

    @ViewBuilder
    private func agentSettings(_ binding: Binding<AgentNode>, node: AgentNode) -> some View {
        labelled("Which model runs this") {
            Menu {
                let locals = app.engine.loadedModels
                if locals.isEmpty {
                    Text("No local models loaded")
                } else {
                    Section("Loaded locally") {
                        ForEach(locals) { entry in
                            Button(entry.model.shortName) {
                                binding.wrappedValue.backend = .local(modelID: entry.id)
                            }
                        }
                    }
                }
                if app.hasAnthropicKey {
                    Section("Anthropic") {
                        ForEach(AppState.anthropicGraphModels, id: \.0) { id, label in
                            Button(label) { binding.wrappedValue.backend = .anthropic(model: id) }
                        }
                    }
                }
                if app.hasOpenAIKey {
                    Section("OpenAI") {
                        ForEach(AppState.openAIGraphModels, id: \.0) { id, label in
                            Button(label) { binding.wrappedValue.backend = .openAI(model: id) }
                        }
                    }
                }
                if app.hasOpenRouterKey {
                    Section("OpenRouter") {
                        ForEach(app.openRouterGraphModelChoices, id: \.0) { id, label in
                            Button(label) { binding.wrappedValue.backend = .openRouter(model: id) }
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: node.backend.symbolName)
                        .foregroundStyle(.secondary)
                    Text(AgentBackendLabels.full(node.backend, engine: app.engine))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
        }

        labelled("Its job, in your words") {
            TextEditor(text: binding.role)
                .font(.callout)
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(Theme.s1)
                .background(Theme.composerBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        }

        DisclosureGroup("Fine tuning") {
            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack {
                    Text("Creativity")
                        .font(.caption)
                    Slider(value: binding.temperature, in: 0...1.5)
                    Text(node.temperature, format: .number.precision(.fractionLength(2)))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36)
                }
                HStack {
                    Text("Answer length cap")
                        .font(.caption)
                    Spacer()
                    TextField(
                        "Tokens",
                        value: binding.maxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Toggle("Let it think out loud first", isOn: binding.reasoningEnabled)
                    .font(.caption)
                    .help("Slower and more expensive, but better on hard reasoning")
            }
            .padding(.top, Theme.s1)
        }
        .font(.caption.weight(.semibold))

        DisclosureGroup("What it's allowed to do") {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Toggle("Read and write files in this graph's folder", isOn: binding.workspaceAccess)
                    .font(.caption)
                Text(
                    "Off by default. Turn it on only for blocks that should actually produce files — a planner shouldn't be able to overwrite the coder's work."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                let bindings = app.mcp.selectedConnectedTools()
                if bindings.isEmpty {
                    Text("No MCP tools are connected. Add servers in Settings to grant them here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("MCP tools")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(bindings) { toolBinding in
                        Toggle(
                            isOn: Binding(
                                get: { node.toolGrants.contains(toolBinding.id) },
                                set: { granted in
                                    var grants = Set(binding.wrappedValue.toolGrants)
                                    if granted {
                                        grants.insert(toolBinding.id)
                                    } else {
                                        grants.remove(toolBinding.id)
                                    }
                                    binding.wrappedValue.toolGrants = grants.sorted()
                                })
                        ) {
                            Text(toolBinding.id)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.top, Theme.s1)
        }
        .font(.caption.weight(.semibold))
    }

    // MARK: Other kinds

    @ViewBuilder
    private func textSettings(_ binding: Binding<AgentNode>, node: AgentNode) -> some View {
        labelled("Text") {
            TextEditor(text: binding.template)
                .font(.callout.monospaced())
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .padding(Theme.s1)
                .background(Theme.composerBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        }
        let variables = AgentNode.templateVariables(in: node.template)
        Text(
            variables.isEmpty
                ? "Put a word in {{double braces}} to turn it into a socket you can wire into."
                : "Sockets on this block: \(variables.map { "{{\($0)}}" }.joined(separator: ", "))"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func branchSettings(_ binding: Binding<AgentNode>) -> some View {
        labelled("Send it down Yes when the text…") {
            Picker("", selection: binding.branchTest) {
                ForEach(AgentBranchTest.allCases) { test in
                    Text(test.title).tag(test)
                }
            }
            .labelsHidden()
        }
        if binding.wrappedValue.branchTest.needsOperand {
            labelled("…this") {
                TextField("Text to look for", text: binding.branchOperand)
                    .textFieldStyle(.roundedBorder)
            }
        }
        Text("Anything else goes down the No wire. Wire No back to an earlier block to make a loop.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func extractSettings(_ binding: Binding<AgentNode>, node: AgentNode) -> some View {
        labelled("Pull out") {
            Picker("", selection: binding.extractMode) {
                ForEach(AgentExtractMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
        }
        if node.extractMode.needsPattern {
            labelled("Pattern") {
                TextField("Regular expression", text: binding.extractPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
        }
    }

    @ViewBuilder
    private func toolSettings(_ binding: Binding<AgentNode>, node: AgentNode) -> some View {
        labelled("Tool to run") {
            Menu {
                let bindings = app.mcp.selectedConnectedTools()
                if bindings.isEmpty {
                    Text("No MCP tools connected")
                } else {
                    ForEach(bindings) { toolBinding in
                        Button(toolBinding.id) {
                            binding.wrappedValue.toolBinding = toolBinding.id
                        }
                    }
                }
            } label: {
                Text(node.toolBinding.isEmpty ? "Pick a tool" : node.toolBinding)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
        }
        labelled("Arguments") {
            TextEditor(text: binding.toolArguments)
                .font(.caption.monospaced())
                .frame(height: 100)
                .scrollContentBackground(.hidden)
                .padding(Theme.s1)
                .background(Theme.composerBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        }
        Text("JSON. Write {{input}} anywhere to drop in whatever arrives on the Input socket.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func fileSettings(_ binding: Binding<AgentNode>, node: AgentNode) -> some View {
        labelled("Do what") {
            Picker("", selection: binding.fileMode) {
                ForEach(AgentFileMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
        }
        if node.fileMode != .list {
            labelled("File name") {
                TextField("notes.md", text: binding.filePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            Text("Relative to this graph's own folder — it can't reach anywhere else on your Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Last run

    @ViewBuilder
    private func lastRunSection(_ node: AgentNode) -> some View {
        let state = app.graphRuntime.nodeStates[node.id]
        if let state, !state.primaryOutput.isEmpty || state.error != nil {
            Divider()
            HStack {
                Text("Last run")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                if state.iterations > 1 {
                    Text("fired \(state.iterations)×")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !state.primaryOutput.isEmpty {
                    CopyClipButton(text: state.primaryOutput)
                }
            }
            if let error = state.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.primaryOutput.isEmpty {
                ScrollView {
                    Text(state.primaryOutput)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.s2)
                }
                .frame(maxHeight: 300)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Helper

    @ViewBuilder
    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
