// Forge — the graph canvas.
//
// Drag blocks around, drag a wire from any output dot to any input dot, click a
// wire to read the exact text that last travelled it. While a run is going the
// blocks light up and stream their answer in place, so you watch the work move
// through the graph rather than reading a log and imagining it.

import SwiftUI

// MARK: - Layout

/// Where everything sits. Kept as pure functions so the canvas, the wires, and
/// hit-testing all agree on geometry without passing view state around.
enum AgentGraphGeometry {
    static let nodeWidth: CGFloat = 236
    static let headerHeight: CGFloat = 44
    static let portRowHeight: CGFloat = 24
    static let portInset: CGFloat = 14
    static let footerHeight: CGFloat = 30
    static let portHitRadius: CGFloat = 22

    static func nodeHeight(_ node: AgentNode) -> CGFloat {
        let rows = max(node.inputPorts.count, node.outputPorts.count, 1)
        return headerHeight + CGFloat(rows) * portRowHeight + footerHeight
    }

    static func nodeRect(_ node: AgentNode) -> CGRect {
        CGRect(
            x: node.position.x, y: node.position.y,
            width: nodeWidth, height: nodeHeight(node))
    }

    static func inputPortPoint(_ node: AgentNode, index: Int) -> CGPoint {
        CGPoint(
            x: node.position.x,
            y: node.position.y + headerHeight + portInset + CGFloat(index) * portRowHeight)
    }

    static func outputPortPoint(_ node: AgentNode, index: Int) -> CGPoint {
        CGPoint(
            x: node.position.x + nodeWidth,
            y: node.position.y + headerHeight + portInset + CGFloat(index) * portRowHeight)
    }

    static func point(for node: AgentNode, port: String, isOutput: Bool) -> CGPoint? {
        let ports = isOutput ? node.outputPorts : node.inputPorts
        guard let index = ports.firstIndex(where: { $0.id == port }) else { return nil }
        return isOutput
            ? outputPortPoint(node, index: index) : inputPortPoint(node, index: index)
    }

    /// Left-to-right bezier with horizontal shoulders, so wires read as flow
    /// even when they double back for a loop.
    static func wirePath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        let distance = max(60, min(180, abs(end.x - start.x) * 0.6))
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + distance, y: start.y),
            control2: CGPoint(x: end.x - distance, y: end.y))
        return path
    }

    /// Bounding box of every block, for zoom-to-fit.
    static func bounds(of graph: AgentGraph) -> CGRect? {
        guard !graph.nodes.isEmpty else { return nil }
        var rect = nodeRect(graph.nodes[0])
        for node in graph.nodes.dropFirst() {
            rect = rect.union(nodeRect(node))
        }
        return rect
    }
}

// MARK: - Canvas

struct AgentGraphCanvas: View {
    @Binding var graph: AgentGraph
    @Binding var selectedNodeID: UUID?
    @Binding var selectedWireID: UUID?
    let runtime: AgentGraphRuntime
    /// Bumped by the Fit button in the top bar; each change re-frames the view.
    var fitTrigger: Int = 0

    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var wireDrag: WireDrag?
    @State private var hoveredWireID: UUID?
    /// Where each block sat when its drag began. Without this the drag reads
    /// back the position it just wrote and compounds it every frame, which
    /// throws the block off the canvas after a few pixels of movement.
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var viewportSize: CGSize = .zero

    private struct WireDrag {
        let fromNode: UUID
        let fromPort: String
        var current: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                dotGrid
                content
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: pan.width, y: pan.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .coordinateSpace(name: "canvasViewport")
            // Background drag pans; clicking empty space clears the selection.
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        pan = CGSize(
                            width: panStart.width + value.translation.width,
                            height: panStart.height + value.translation.height)
                    }
                    .onEnded { _ in panStart = pan }
            )
            .onTapGesture {
                selectedNodeID = nil
                selectedWireID = nil
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls(viewport: proxy.size)
            }
            .overlay(alignment: .topLeading) {
                if graph.nodes.isEmpty { emptyHint }
            }
            .onAppear {
                viewportSize = proxy.size
                // Open framed on the work rather than on empty grid.
                fit(in: proxy.size)
            }
            .onChange(of: proxy.size) { _, size in viewportSize = size }
            .onChange(of: fitTrigger) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { fit(in: viewportSize) }
            }
        }
    }

    // MARK: Layers

    private var content: some View {
        ZStack(alignment: .topLeading) {
            wireLayer
            nodeLayer
        }
        // A large fixed canvas so blocks placed far apart stay reachable.
        .frame(
            width: AgentGraph.canvasSize.width, height: AgentGraph.canvasSize.height,
            alignment: .topLeading)
        // Port drags report positions in this space, which is untransformed
        // graph coordinates — the same space node positions live in.
        .coordinateSpace(name: "graphSpace")
    }

    private var wireLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(graph.wires) { wire in
                if let start = endpoint(wire, isOutput: true),
                    let end = endpoint(wire, isOutput: false)
                {
                    let isLive = runtime.wireValues[wire.id] != nil
                    let isSelected = selectedWireID == wire.id
                    AgentGraphGeometry.wirePath(from: start, to: end)
                        .stroke(
                            wireStyle(isSelected: isSelected, isLive: isLive),
                            style: StrokeStyle(
                                lineWidth: isSelected ? 3 : (isLive ? 2.5 : 1.6),
                                lineCap: .round))
                        .shadow(
                            color: isLive ? Theme.ember.opacity(0.5) : .clear,
                            radius: isLive ? 4 : 0)
                    // Fat invisible stroke so a 2pt wire is still clickable.
                    AgentGraphGeometry.wirePath(from: start, to: end)
                        .stroke(.clear, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .contentShape(.rect)
                        .onTapGesture {
                            selectedWireID = wire.id
                            selectedNodeID = nil
                        }
                        .onHover { hoveredWireID = $0 ? wire.id : nil }
                        .contextMenu {
                            Button("Delete wire", role: .destructive) {
                                graph.removeWire(wire.id)
                                if selectedWireID == wire.id { selectedWireID = nil }
                            }
                        }
                }
            }
            if let drag = wireDrag, let node = graph.node(drag.fromNode),
                let start = AgentGraphGeometry.point(
                    for: node, port: drag.fromPort, isOutput: true)
            {
                AgentGraphGeometry.wirePath(from: start, to: drag.current)
                    .stroke(
                        Theme.emberGlow,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
            }
        }
        .allowsHitTesting(true)
    }

    private func wireStyle(isSelected: Bool, isLive: Bool) -> Color {
        if isSelected { return Theme.emberGlow }
        if isLive { return Theme.ember.opacity(0.85) }
        return .white.opacity(hoveredWireID == nil ? 0.22 : 0.3)
    }

    private var nodeLayer: some View {
        ForEach(graph.nodes) { node in
            AgentNodeCard(
                node: node,
                state: runtime.nodeStates[node.id],
                isActive: runtime.activeNodeIDs.contains(node.id),
                isSelected: selectedNodeID == node.id,
                onStartWire: { port, point in
                    wireDrag = WireDrag(fromNode: node.id, fromPort: port, current: point)
                },
                onDragWire: { point in
                    wireDrag?.current = point
                },
                onEndWire: { point in
                    finishWire(at: point)
                },
                onDeletePort: { port in
                    graph.wires.removeAll { $0.toNode == node.id && $0.toPort == port }
                }
            )
            .frame(
                width: AgentGraphGeometry.nodeWidth,
                height: AgentGraphGeometry.nodeHeight(node))
            .position(
                x: node.position.x + AgentGraphGeometry.nodeWidth / 2,
                y: node.position.y + AgentGraphGeometry.nodeHeight(node) / 2)
            .onTapGesture {
                selectedNodeID = node.id
                selectedWireID = nil
            }
            .gesture(
                // Reported in "graphSpace", which sits inside the scaleEffect,
                // so the translation is already in graph units — no zoom math.
                DragGesture(minimumDistance: 3, coordinateSpace: .named("graphSpace"))
                    .onChanged { value in
                        guard let index = graph.index(of: node.id) else { return }
                        // Anchor to where the block was when the drag started,
                        // not to where it is now — `node` updates as we write.
                        let origin = dragOrigins[node.id] ?? node.position
                        if dragOrigins[node.id] == nil { dragOrigins[node.id] = origin }
                        graph.nodes[index].position = clamped(
                            CGPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y + value.translation.height),
                            for: node)
                    }
                    .onEnded { _ in
                        dragOrigins[node.id] = nil
                        graph.updatedAt = Date()
                    }
            )
            .contextMenu {
                Button("Duplicate") { duplicate(node) }
                Button("Disconnect everything") {
                    graph.wires.removeAll { $0.fromNode == node.id || $0.toNode == node.id }
                }
                Divider()
                Button("Delete block", role: .destructive) {
                    graph.removeNode(node.id)
                    if selectedNodeID == node.id { selectedNodeID = nil }
                }
            }
        }
    }

    private var dotGrid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28 * zoom
            guard spacing > 8 else { return }
            let offsetX = pan.width.truncatingRemainder(dividingBy: spacing)
            let offsetY = pan.height.truncatingRemainder(dividingBy: spacing)
            var y = offsetY
            while y < size.height {
                var x = offsetX
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(.white.opacity(0.10)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Nothing here yet")
                .font(.headline)
            Text(
                "Pick a starting shape from **Start from…** above, or drag blocks in from the palette on the left and wire them together."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 340, alignment: .leading)
        }
        .padding(Theme.s4)
        .padding(.top, Theme.s5)
        .padding(.leading, Theme.s5)
    }

    // MARK: Controls

    private func zoomControls(viewport: CGSize) -> some View {
        HStack(spacing: Theme.s1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { zoom = max(0.35, zoom - 0.15) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 38)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { fit(in: viewport) }
            } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
            .help("Bring every block back into view")

            Button {
                withAnimation(.easeOut(duration: 0.15)) { zoom = min(2, zoom + 0.15) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, Theme.s1)
        .background(.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .padding(Theme.s3)
    }

    private func fit(in viewport: CGSize) {
        guard let bounds = AgentGraphGeometry.bounds(of: graph), viewport.width > 0 else {
            zoom = 1
            pan = .zero
            panStart = .zero
            return
        }
        let margin: CGFloat = 60
        let scaleX = (viewport.width - margin * 2) / max(bounds.width, 1)
        let scaleY = (viewport.height - margin * 2) / max(bounds.height, 1)
        zoom = max(0.35, min(1.4, min(scaleX, scaleY)))
        pan = CGSize(
            width: margin - bounds.minX * zoom,
            height: margin - bounds.minY * zoom)
        panStart = pan
    }

    // MARK: Wiring

    private func endpoint(_ wire: AgentWire, isOutput: Bool) -> CGPoint? {
        let nodeID = isOutput ? wire.fromNode : wire.toNode
        let port = isOutput ? wire.fromPort : wire.toPort
        guard let node = graph.node(nodeID) else { return nil }
        return AgentGraphGeometry.point(for: node, port: port, isOutput: isOutput)
    }

    /// Drops a dragged wire on the nearest input dot, if one is close enough.
    private func finishWire(at point: CGPoint) {
        defer { wireDrag = nil }
        guard let drag = wireDrag else { return }
        var best: (nodeID: UUID, port: String, distance: CGFloat)?
        for node in graph.nodes where node.id != drag.fromNode {
            for (index, port) in node.inputPorts.enumerated() {
                let target = AgentGraphGeometry.inputPortPoint(node, index: index)
                let distance = hypot(target.x - point.x, target.y - point.y)
                if distance <= AgentGraphGeometry.portHitRadius,
                    best == nil || distance < best!.distance
                {
                    best = (node.id, port.id, distance)
                }
            }
        }
        guard let best else { return }
        graph.connect(
            fromNode: drag.fromNode, fromPort: drag.fromPort, toNode: best.nodeID,
            toPort: best.port)
    }

    /// Keeps a block inside the canvas so it can never be dragged somewhere you
    /// cannot scroll back to.
    private func clamped(_ point: CGPoint, for node: AgentNode) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), AgentGraph.canvasSize.width - AgentGraphGeometry.nodeWidth),
            y: min(
                max(0, point.y),
                AgentGraph.canvasSize.height - AgentGraphGeometry.nodeHeight(node)))
    }

    private func duplicate(_ node: AgentNode) {
        var copy = node
        copy.id = UUID()
        copy.name = node.name + " copy"
        copy.position = CGPoint(x: node.position.x + 40, y: node.position.y + 40)
        graph.addNode(copy)
        selectedNodeID = copy.id
    }
}

// MARK: - Node card

private struct AgentNodeCard: View {
    let node: AgentNode
    let state: AgentGraphRuntime.NodeState?
    let isActive: Bool
    let isSelected: Bool
    var onStartWire: (String, CGPoint) -> Void
    var onDragWire: (CGPoint) -> Void
    var onEndWire: (CGPoint) -> Void
    var onDeletePort: (String) -> Void

    private var status: AgentGraphRuntime.NodeStatus { state?.status ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ports
            footer
        }
        .frame(
            width: AgentGraphGeometry.nodeWidth,
            height: AgentGraphGeometry.nodeHeight(node), alignment: .top)
        .background(Theme.assistantBubble, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                .strokeBorder(borderColor, lineWidth: isSelected || isActive ? 2 : 1)
        )
        .shadow(color: isActive ? node.kind.accent.opacity(0.55) : .black.opacity(0.35),
                radius: isActive ? 14 : 6, y: 2)
    }

    private var borderColor: Color {
        if isActive { return node.kind.accent }
        switch status {
        case .failed: return .red.opacity(0.8)
        case .done: return Theme.okGreen.opacity(0.55)
        default: return isSelected ? Theme.emberGlow : .white.opacity(0.10)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: node.kind.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(node.kind.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.configSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(.horizontal, Theme.s3)
        .frame(height: AgentGraphGeometry.headerHeight)
        .background(node.kind.accent.opacity(0.10))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            HStack(spacing: 2) {
                if let iterations = state?.iterations, iterations > 1 {
                    Text("×\(iterations)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.okGreen)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle, .waiting, .blocked:
            EmptyView()
        }
    }

    private var ports: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(node.inputPorts.enumerated()), id: \.element.id) { index, port in
                    portRow(port, index: index, isOutput: false)
                }
            }
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(node.outputPorts.enumerated()), id: \.element.id) { index, port in
                    portRow(port, index: index, isOutput: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(
            height: CGFloat(max(node.inputPorts.count, node.outputPorts.count, 1))
                * AgentGraphGeometry.portRowHeight,
            alignment: .top)
        .padding(.top, AgentGraphGeometry.portInset - AgentGraphGeometry.portRowHeight / 2)
    }

    private func portRow(_ port: AgentPort, index: Int, isOutput: Bool) -> some View {
        HStack(spacing: Theme.s1) {
            if isOutput {
                Text(port.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            portDot(port, isOutput: isOutput)
            if !isOutput {
                Text(port.title)
                    .font(.caption2)
                    .foregroundStyle(port.isRequired ? .secondary : .tertiary)
            }
        }
        .frame(height: AgentGraphGeometry.portRowHeight)
        .padding(isOutput ? .trailing : .leading, 0)
        .offset(x: isOutput ? 7 : -7)
    }

    private func portDot(_ port: AgentPort, isOutput: Bool) -> some View {
        Circle()
            .fill(isOutput ? AnyShapeStyle(node.kind.accent) : AnyShapeStyle(.white.opacity(0.28)))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
            .contentShape(Circle().inset(by: -9))
            .help(
                isOutput
                    ? "Drag from here to another block's input"
                    : (port.isRequired
                        ? "\(port.title) — required" : "\(port.title) — optional"))
            .gesture(
                isOutput
                    ? DragGesture(coordinateSpace: .named("graphSpace"))
                        .onChanged { value in
                            onStartWire(port.id, value.location)
                            onDragWire(value.location)
                        }
                        .onEnded { value in onEndWire(value.location) }
                    : nil
            )
            .onTapGesture(count: 2) {
                if !isOutput { onDeletePort(port.id) }
            }
    }

    private var footer: some View {
        Group {
            if status == .running, let streaming = state?.streaming, !streaming.isEmpty {
                Text(streaming.suffix(120))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            } else if status == .failed, let error = state?.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            } else if let output = state?.primaryOutput, !output.isEmpty {
                Text(output.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else {
                Text(" ")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.s3)
        .frame(height: AgentGraphGeometry.footerHeight, alignment: .center)
    }
}
