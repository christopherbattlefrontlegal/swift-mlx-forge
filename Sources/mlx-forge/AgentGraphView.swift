// Forge — the agent graph workbench.
//
// Left: a palette of blocks you drag or click to add. Middle: the canvas.
// Right: whatever you have selected — a block's settings, or the text that last
// went down a wire. Bottom: the run bar and a plain-language activity log.

import AppKit
import SwiftUI

struct AgentGraphView: View {
    @Environment(AppState.self) private var app
    @State private var selectedNodeID: UUID?
    @State private var selectedWireID: UUID?
    @State private var showPresets = false
    @State private var showIssues = false
    @State private var showWorkspace = false
    @State private var fitTrigger = 0

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                AgentBlockPalette(onAdd: addBlock)
                    .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)

                VStack(spacing: 0) {
                    if let index = app.selectedGraphIndex {
                        AgentGraphCanvas(
                            graph: $app.agentGraphs[index],
                            selectedNodeID: $selectedNodeID,
                            selectedWireID: $selectedWireID,
                            runtime: app.graphRuntime,
                            fitTrigger: fitTrigger)
                        .background(Theme.backgroundGradient)
                        .onChange(of: app.agentGraphs[index].nodes) { _, _ in
                            // Text blocks grow and lose sockets as their template
                            // is edited; drop wires that now point at nothing.
                            app.agentGraphs[index].pruneOrphanWires()
                            app.scheduleGraphSave()
                        }
                        .onChange(of: app.agentGraphs[index].wires) { _, _ in
                            app.scheduleGraphSave()
                        }
                    } else {
                        noGraphPlaceholder
                    }
                    Divider()
                    AgentRunBar(
                        selectedNodeID: $selectedNodeID,
                        showWorkspace: $showWorkspace)
                    .frame(height: 210)
                }
                .frame(minWidth: 420)

                AgentInspectorPanel(
                    selectedNodeID: $selectedNodeID,
                    selectedWireID: $selectedWireID)
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
            }
        }
        .background(Theme.backgroundGradient)
        .onAppear {
            // First visit lands on something runnable rather than a blank grid.
            if app.agentGraphs.isEmpty {
                app.applyPreset(.solo)
            }
        }
        .sheet(isPresented: $showWorkspace) {
            AgentWorkspaceSheet(isPresented: $showWorkspace)
                .environment(app)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        @Bindable var app = app
        return HStack(spacing: Theme.s3) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(Theme.emberGradient)

            if app.selectedGraphIndex != nil {
                TextField(
                    "Graph name",
                    text: Binding(
                        get: { app.selectedGraph?.name ?? "" },
                        set: { app.renameSelectedGraph($0) })
                )
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 260)
            }

            Menu {
                ForEach(app.agentGraphs) { graph in
                    Button {
                        app.selectedGraphID = graph.id
                        selectedNodeID = nil
                        selectedWireID = nil
                    } label: {
                        Label(
                            graph.name,
                            systemImage: graph.id == app.selectedGraphID ? "checkmark" : "")
                    }
                }
                Divider()
                Button("New empty graph") { app.newGraph() }
                if app.selectedGraph != nil {
                    Button("Duplicate this graph") { app.duplicateSelectedGraph() }
                    Button("Delete this graph", role: .destructive) {
                        app.deleteSelectedGraph()
                        selectedNodeID = nil
                    }
                }
            } label: {
                Label("Graphs", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)

            Button {
                showPresets = true
            } label: {
                Label("Start from…", systemImage: "wand.and.stars")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.emberGlow)
            .help("Replace this graph with a ready-made shape you can then take apart")
            .popover(isPresented: $showPresets, arrowEdge: .bottom) {
                AgentPresetPicker(isPresented: $showPresets)
                    .environment(app)
            }

            Spacer(minLength: Theme.s3)

            Button {
                fitTrigger += 1
            } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Bring every block back into view")

            issuesButton

            Button {
                showWorkspace = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("The folder this graph's blocks can read and write")
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(.white.opacity(0.03))
    }

    private var issuesButton: some View {
        let issues = app.selectedGraphIssues
        let errors = issues.filter { $0.severity == .error }.count
        return Button {
            showIssues.toggle()
        } label: {
            Label(
                issues.isEmpty
                    ? "Ready to run"
                    : (errors > 0
                        ? "\(errors) thing\(errors == 1 ? "" : "s") to fix"
                        : "\(issues.count) note\(issues.count == 1 ? "" : "s")"),
                systemImage: issues.isEmpty
                    ? "checkmark.circle"
                    : (errors > 0 ? "exclamationmark.triangle.fill" : "info.circle"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    issues.isEmpty
                        ? AnyShapeStyle(Theme.okGreen)
                        : (errors > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)))
        }
        .buttonStyle(.plain)
        .disabled(issues.isEmpty)
        .popover(isPresented: $showIssues, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Before this runs")
                    .font(.headline)
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: Theme.s2) {
                        Image(
                            systemName: issue.severity == .error
                                ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(issue.severity == .error ? .orange : .secondary)
                            .font(.caption)
                        Text(issue.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if let nodeID = issue.nodeID {
                            selectedNodeID = nodeID
                            showIssues = false
                        }
                    }
                }
            }
            .padding(Theme.s4)
            .frame(width: 420)
        }
    }

    private var noGraphPlaceholder: some View {
        VStack(spacing: Theme.s3) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40))
                .foregroundStyle(Theme.emberGradient)
            Text("No graph open")
                .font(.title3.weight(.semibold))
            Text("Make a new one, or start from a ready-made shape.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("New graph") { app.newGraph() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addBlock(_ kind: AgentNodeKind) {
        guard let index = app.selectedGraphIndex else { return }
        // Drop new blocks in a readable column rather than all on one spot.
        let count = app.agentGraphs[index].nodes.count
        let position = CGPoint(
            x: 120 + CGFloat(count % 4) * 280,
            y: 120 + CGFloat(count / 4) * 200)
        var node = AgentNode(kind: kind, position: position)
        if kind == .agent {
            node.backend = app.defaultAgentBackend
            node.name = "Agent \(app.agentGraphs[index].nodes.filter { $0.kind == .agent }.count + 1)"
        }
        app.agentGraphs[index].addNode(node)
        selectedNodeID = node.id
        selectedWireID = nil
        app.scheduleGraphSave()
    }
}

// MARK: - Palette

private struct AgentBlockPalette: View {
    var onAdd: (AgentNodeKind) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Blocks")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.s3)
                ForEach(AgentNodeKind.allCases) { kind in
                    Button {
                        onAdd(kind)
                    } label: {
                        HStack(alignment: .top, spacing: Theme.s2) {
                            Image(systemName: kind.symbolName)
                                .foregroundStyle(kind.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .font(.callout.weight(.semibold))
                                Text(kind.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Theme.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Add a \(kind.title) block")
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.bottom, Theme.s4)
        }
        .background(.black.opacity(0.18))
    }
}

// MARK: - Preset picker

private struct AgentPresetPicker: View {
    @Environment(AppState.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Start from a shape")
                .font(.headline)
            Text("This replaces what's on the canvas. Every shape is just blocks and wires — take it apart however you like.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let available = app.availableAgentBackends
            ForEach(AgentGraphPreset.allCases) { preset in
                Button {
                    app.applyPreset(preset)
                    isPresented = false
                } label: {
                    HStack(alignment: .top, spacing: Theme.s3) {
                        Image(systemName: preset.symbolName)
                            .foregroundStyle(Theme.emberGlow)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(.callout.weight(.semibold))
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            if available.count < preset.agentCount, !available.isEmpty {
                                Text(
                                    "You have \(available.count) model\(available.count == 1 ? "" : "s") available, so some blocks will share one."
                                )
                                .font(.caption2)
                                .foregroundStyle(.orange.opacity(0.9))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if available.isEmpty {
                Label(
                    "No models available yet — load a local model into a slot, or add a cloud API key in Settings.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.s4)
        .frame(width: 460)
    }
}

// MARK: - Run bar + log

private struct AgentRunBar: View {
    @Environment(AppState.self) private var app
    @Binding var selectedNodeID: UUID?
    @Binding var showWorkspace: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: Theme.s3) {
                TextField(
                    "What should this graph do? (this text arrives at your Task block)",
                    text: $app.graphTaskText,
                    axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2)
                    .background(Theme.composerBackground, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { app.runSelectedGraph() }

                if app.graphRuntime.isRunning {
                    Button {
                        app.graphRuntime.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, Theme.s3)
                            .frame(height: 34)
                            .background(.red.opacity(0.8), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        app.runSelectedGraph()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, Theme.s4)
                            .frame(height: 34)
                            .background(Theme.emberGradient, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.canRunSelectedGraph)
                    .help(
                        app.canRunSelectedGraph
                            ? "Run the graph"
                            : "Fix the highlighted problems first, and type a task.")
                }

                Menu {
                    ForEach([4, 8, 12, 20, 40], id: \.self) { limit in
                        Button("\(limit) turns per block") { app.setGraphMaxIterations(limit) }
                    }
                } label: {
                    Text("\(app.selectedGraph?.maxIterations ?? 12) turns")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 88)
                .help("How many times any one block may fire in a run — the backstop for loops")
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)

            Divider()
            runLog
        }
        .background(.black.opacity(0.15))
    }

    private var runLog: some View {
        let runtime = app.graphRuntime
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if runtime.log.isEmpty {
                        Text(
                            "Type what you want done, hit Run, and you'll see each block light up here as it works."
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.s2)
                    }
                    ForEach(runtime.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                            Text(entry.time, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(entry.nodeName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(for: entry.kind))
                                .frame(minWidth: 74, alignment: .leading)
                            Text(entry.text)
                                .font(.caption2)
                                .foregroundStyle(
                                    entry.kind == .failure ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(entry.id)
                        .contentShape(.rect)
                        .onTapGesture {
                            if let nodeID = entry.nodeID { selectedNodeID = nodeID }
                        }
                    }
                    if !runtime.results.isEmpty {
                        Divider().padding(.vertical, Theme.s1)
                        ForEach(Array(runtime.results.enumerated()), id: \.offset) { _, result in
                            HStack(alignment: .top, spacing: Theme.s2) {
                                Text("RESULT")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.okGreen)
                                Text(result)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                CopyClipButton(text: result)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
            }
            .onChange(of: runtime.log.count) { _, _ in
                if let last = runtime.log.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        scroller.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for kind: AgentGraphRuntime.LogEntry.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .fired: Theme.emberGlow
        case .finished: Theme.okGreen
        case .tool: Theme.steel
        case .failure: .red
        }
    }
}

// MARK: - Workspace sheet

private struct AgentWorkspaceSheet: View {
    @Environment(AppState.self) private var app
    @Binding var isPresented: Bool
    @State private var entries: [AgentWorkspace.Entry] = []
    @State private var preview: String?
    @State private var previewTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This graph's folder")
                        .font(.headline)
                    Text(
                        "Blocks with file access can read and write here — and nowhere else. Anything they make shows up in this list."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: Theme.s2) {
                Button {
                    if let root = app.selectedGraphWorkspace?.root {
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button(role: .destructive) {
                    try? app.selectedGraphWorkspace?.clear()
                    reload()
                } label: {
                    Label("Empty the folder", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
            .buttonStyle(.bordered)

            if entries.isEmpty {
                Text("Nothing here yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.path)
                                .font(.callout)
                            Text(
                                "\(Format.bytes(entry.sizeBytes)) · \(entry.modifiedAt.formatted(.relative(presentation: .named)))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View") {
                            previewTitle = entry.path
                            preview = (try? String(contentsOf: entry.url, encoding: .utf8))
                                ?? "(not readable as text)"
                        }
                        .buttonStyle(.link)
                    }
                }
                .listStyle(.inset)
            }

            if let preview {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    HStack {
                        Text(previewTitle).font(.caption.weight(.bold))
                        Spacer()
                        CopyClipButton(text: preview)
                        Button("Close") { self.preview = nil }
                            .buttonStyle(.link)
                    }
                    ScrollView {
                        Text(preview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.s2)
                    }
                    .frame(height: 200)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(Theme.s4)
        .frame(width: 620, height: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = app.selectedGraphWorkspace?.entries() ?? []
    }
}
