import SwiftUI
import AppKit

struct GraphExplorerView: View {
    @Bindable var store: LibraryStore
    @State private var zoom: CGFloat = 1
    @State private var panX: CGFloat = 0
    @State private var panY: CGFloat = 0
    @State private var selectedSlug: String?
    @State private var hoveredSlug: String?
    @State private var selectedEdgeID: String?
    @State private var hoveredEdgeID: String?
    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var connectedSlugsByNode: [String: Set<String>] = [:]
    @State private var lastDragTranslation: CGSize = .zero
    @State private var layoutRotation: Double = 0
    @State private var didRecordOpenTelemetry = false

    private let maxLayoutIterations = 96
    private var graph: VaultGraph { store.vaultSnapshot.graph }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.white

                Canvas { ctx, _ in
                    for edge in graph.edges {
                        guard let from = nodePositions[edge.source], let to = nodePositions[edge.target] else { continue }
                        let active = selectedSlug == edge.source || selectedSlug == edge.target || selectedEdgeID == edge.id || hoveredEdgeID == edge.id
                        let fromPoint = screenPoint(for: from, in: size)
                        let toPoint = screenPoint(for: to, in: size)
                        drawEdge(ctx: ctx, from: fromPoint, to: toPoint, relation: edge.relation, active: active)
                    }
                }
                .accessibilityLabel("Knowledge graph: \(graph.nodes.count) nodes, \(graph.edges.count) connections")
                .accessibilityHint("Node details are available in the list views")

                ForEach(graph.nodes) { node in
                    if let pos = nodePositions[node.slug] {
                        let isSel = selectedSlug == node.slug
                        let isConn = selectedSlug != nil && !isSel && isNode(node, connectedToSlug: selectedSlug)
                        let isHov = hoveredSlug == node.slug
                        let dim = selectedSlug != nil && !isSel && !isConn
                        let push = pushOffset(node: node, isSelected: isSel, isConnected: isConn)
                        let point = screenPoint(for: pos, in: size)
                        let r: CGFloat = isSel ? 20 : (isHov ? 17 : 14)
                        let col = nodeColor(for: node.group)

                        VStack(spacing: 0) {
                            ZStack {
                                if isSel { Circle().fill(col.opacity(0.10)).frame(width: r * 2 + 14, height: r * 2 + 14) }
                                Circle().fill(col.opacity(isSel ? 0.88 : 0.65)).frame(width: r * 2, height: r * 2)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5))
                                    .shadow(color: col.opacity(0.25), radius: isSel ? 6 : 2, y: 1)
                            }
                            Text(node.title).lociFont(size: 9.5, weight: isSel ? .semibold : .medium, relativeTo: .caption2)
                                .foregroundStyle(Color.black.opacity(isSel ? 0.82 : 0.55)).lineLimit(1).frame(width: 80)
                        }
                        .contentShape(Circle().size(width: 48, height: 48))
                        .position(x: point.x + push.width, y: point.y + push.height)
                        .zIndex(isSel ? 10 : 1)
                        .scaleEffect(isSel ? 1.15 : (dim ? 0.85 : 1.0))
                        .opacity(dim ? 0.08 : 1).blur(radius: dim ? 5 : 0)
                        .animation(AppMotion.quick, value: isSel)
                        .animation(AppMotion.instant, value: dim)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(node.title), \(node.group.rawValue)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            withAnimation(AppMotion.quick) {
                                selectedSlug = selectedSlug == node.slug ? nil : node.slug
                                selectedEdgeID = nil
                            }
                        }
                    }
                }

                if let slug = selectedSlug, let node = graph.nodes.first(where: { $0.slug == slug }),
                   let pos = nodePositions[slug] {
                    let point = screenPoint(for: pos, in: size)
                    card(node: node, x: point.x, y: point.y, in: size).zIndex(20)
                }

                if let edge = explainedEdge,
                   let from = nodePositions[edge.source],
                   let to = nodePositions[edge.target] {
                    let fromPoint = screenPoint(for: from, in: size)
                    let toPoint = screenPoint(for: to, in: size)
                    edgeReasonLabel(for: edge)
                        .position(edgeLabelPoint(from: fromPoint, to: toPoint, in: size))
                        .zIndex(18)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                graphOverlay(in: size)
            }
            .offset(x: 0, y: 0)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let nearest = nearestNodeSlug(to: location, within: 40, in: size)
                    let nearestEdge = nearest == nil ? nearestEdge(to: location, within: 14, in: size)?.id : nil
                    if hoveredSlug != nearest {
                    withAnimation(AppMotion.quick) {
                        hoveredSlug = nearest
                    }
                    }
                    if hoveredEdgeID != nearestEdge {
                    withAnimation(AppMotion.instant) {
                        hoveredEdgeID = nearestEdge
                    }
                    }
                case .ended:
                withAnimation(AppMotion.instant) {
                    hoveredSlug = nil
                    hoveredEdgeID = nil
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let dx = value.translation.width - lastDragTranslation.width
                        let dy = value.translation.height - lastDragTranslation.height
                        lastDragTranslation = value.translation

                        if abs(value.translation.width) + abs(value.translation.height) >= 5 {
                            panX += dx
                            panY += dy
                            hoveredSlug = nil
                            hoveredEdgeID = nil
                        } else {
                            let nearest = nearestNodeSlug(to: value.location, within: 40, in: size)
                            let nearestEdge = nearest == nil ? nearestEdge(to: value.location, within: 14, in: size)?.id : nil
                            if hoveredSlug != nearest {
                        withAnimation(AppMotion.quick) {
                            hoveredSlug = nearest
                        }
                            }
                            if hoveredEdgeID != nearestEdge {
                        withAnimation(AppMotion.instant) {
                            hoveredEdgeID = nearestEdge
                        }
                            }
                        }
                    }
                    .onEnded { value in
                        let dist = abs(value.translation.width) + abs(value.translation.height)
                        lastDragTranslation = .zero

                        if dist < 5 {
                            let bestSlug = nearestNodeSlug(to: value.location, within: 40, in: size)
                            let bestEdge = bestSlug == nil ? nearestEdge(to: value.location, within: 14, in: size) : nil
                withAnimation(AppMotion.quick) {
                                if let best = bestSlug {
                                    selectedSlug = selectedSlug == best ? nil : best
                                    selectedEdgeID = nil
                                } else {
                                    selectedSlug = nil
                                    selectedEdgeID = selectedEdgeID == bestEdge?.id ? nil : bestEdge?.id
                                }
                                hoveredSlug = bestSlug
                                hoveredEdgeID = bestEdge?.id
                            }
                            if bestSlug != nil || bestEdge != nil {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                        } else {
                            hoveredSlug = nil
                            hoveredEdgeID = nil
                        }
                    }
            )
            .gesture(MagnifyGesture().onChanged { z in zoom = min(4, max(0.25, zoom * z.magnification)) })
            .focusable().focusEffectDisabled()
            .onKeyPress(.rightArrow) { nav(1); return .handled }
            .onKeyPress(.leftArrow) { nav(-1); return .handled }
            .onKeyPress(.escape) { withAnimation { selectedSlug = nil; selectedEdgeID = nil }; return .handled }
            .onAppear {
                prepareLayout(in: size)
                if !didRecordOpenTelemetry {
                    didRecordOpenTelemetry = true
                    LociTelemetry.record(.graphOpened, properties: LociTelemetry.graphProperties(for: store))
                }
            }
            .onChange(of: graph.nodes.count) { _, _ in
                nodePositions = [:]
                prepareLayout(in: size)
            }
            .onChange(of: graph.edges.count) { _, _ in
                connectedSlugsByNode = adjacencyMap(for: graph.edges)
            }
        }
    }

    private func screenPoint(for point: CGPoint, in size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(
            x: center.x + (point.x - center.x) * zoom + panX,
            y: center.y + (point.y - center.y) * zoom + panY
        )
    }

    private func nearestNodeSlug(to point: CGPoint, within radius: CGFloat, in size: CGSize) -> String? {
        var bestSlug: String? = nil
        var bestDist = radius
        for node in graph.nodes {
            guard let pos = nodePositions[node.slug] else { continue }
            let nodePoint = screenPoint(for: pos, in: size)
            let nx = nodePoint.x
            let ny = nodePoint.y
            let dx = point.x - nx
            let dy = point.y - ny
            let d = sqrt(dx * dx + dy * dy)
            if d < bestDist {
                bestDist = d
                bestSlug = node.slug
            }
        }
        return bestSlug
    }

    private var explainedEdge: VaultGraphEdge? {
        guard let id = selectedEdgeID ?? hoveredEdgeID else { return nil }
        return graph.edges.first { $0.id == id }
    }

    private func nearestEdge(to point: CGPoint, within radius: CGFloat, in size: CGSize) -> VaultGraphEdge? {
        var bestEdge: VaultGraphEdge?
        var bestDistance = radius
        for edge in graph.edges {
            guard let from = nodePositions[edge.source],
                  let to = nodePositions[edge.target] else { continue }
            let fromPoint = screenPoint(for: from, in: size)
            let toPoint = screenPoint(for: to, in: size)
            let distance = distanceFrom(point, toSegmentFrom: fromPoint, to: toPoint)
            if distance < bestDistance {
                bestDistance = distance
                bestEdge = edge
            }
        }
        return bestEdge
    }

    private func distanceFrom(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func edgeLabelPoint(from: CGPoint, to: CGPoint, in size: CGSize) -> CGPoint {
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return CGPoint(
            x: min(max(midpoint.x, 92), size.width - 92),
            y: min(max(midpoint.y - 16, 72), size.height - 72)
        )
    }

    private func graphOverlay(in size: CGSize) -> some View {
        ZStack {
            graphLegend
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 2)
                .padding(.bottom, 2)

            graphControls(in: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 2)
        }
        .padding(16)
        .allowsHitTesting(true)
    }

    private var graphLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 7, alignment: .leading), count: 2), alignment: .leading, spacing: 6) {
                ForEach(ReferenceGroup.allCases) { group in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(nodeColor(for: group))
                            .frame(width: 5.5, height: 5.5)
                        Text(shortLabel(for: group))
                            .lociFont(size: 8.5, weight: .semibold, relativeTo: .caption2)
                            .foregroundStyle(Color.black.opacity(0.62))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(width: 102, height: 48, alignment: .center)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.045), radius: 7, y: 3)
    }

    private func edgeReasonLabel(for edge: VaultGraphEdge) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(relColor(for: edge.relation))
                .frame(width: 6, height: 6)
            Text(edgeReasonText(for: edge.relation))
                .lociFont(size: 9, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(Color.black.opacity(0.66))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
        .help(edgeReasonText(for: edge.relation))
    }

    private func graphControls(in size: CGSize) -> some View {
        VStack(spacing: 4) {
            controlButton(systemName: "minus", help: "Zoom out") {
                withAnimation(AppMotion.quick) {
                    zoom = max(0.25, zoom - 0.10)
                }
            }
            Text("\(Int((zoom * 100).rounded()))%")
                .lociFont(size: 8.5, weight: .bold, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(Color.black.opacity(0.56))
                .frame(width: 28, height: 15)
            controlButton(systemName: "plus", help: "Zoom in") {
                withAnimation(AppMotion.quick) {
                    zoom = min(4, zoom + 0.10)
                }
            }
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 18, height: 1)
                .padding(.vertical, 1)
            controlButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Rearrange graph") {
                withAnimation(AppMotion.quick) {
                    layoutRotation += .pi / 7
                    selectedSlug = nil
                    hoveredSlug = nil
                    computeLayout(in: size)
                }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.045), radius: 7, y: 3)
    }

    private func controlButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .lociFont(size: 11, weight: .bold, relativeTo: .caption)
                .foregroundStyle(Color.black.opacity(0.62))
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Card

    private func card(node: VaultGraphNode, x: CGFloat, y: CGFloat, in size: CGSize) -> some View {
        let conns = graph.edges.filter { $0.source == node.slug || $0.target == node.slug }
        let connSlugs = Set(conns.flatMap { [$0.source, $0.target] }).subtracting([node.slug])
        let connNodes = graph.nodes.filter { connSlugs.contains($0.slug) }
        let col = nodeColor(for: node.group)
        let cw: CGFloat = min(260, size.width * 0.30)
        let cx = min(max(cw / 2 + 16, x + 30), size.width - cw / 2 - 16)
        let cy = min(max(y, 80), size.height - 80)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack { Circle().fill(col.opacity(0.12)).frame(width: 32, height: 32); Circle().fill(col.gradient).frame(width: 14, height: 14) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).lociFont(size: 13, weight: .bold, relativeTo: .subheadline).foregroundStyle(Color.black.opacity(0.85)).lineLimit(2)
                    Text(node.subtitle ?? node.kind.title).lociFont(size: 9.5, weight: .semibold, relativeTo: .caption2).foregroundStyle(col)
                }
                Spacer()
            }
            Divider().padding(.vertical, 7)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(conns.count)").lociFont(size: 15, weight: .bold, design: .rounded, relativeTo: .headline).foregroundStyle(Color.black.opacity(0.72))
                    Text("relations").lociFont(size: 8.5, weight: .medium, relativeTo: .caption2).foregroundStyle(Color.black.opacity(0.38))
                }
            }
            if !connNodes.isEmpty {
                Divider().padding(.vertical, 7)
                ForEach(connNodes.prefix(5)) { cn in
                    let cc = nodeColor(for: cn.group)
                    let rel = conns.first(where: { ($0.source == node.slug && $0.target == cn.slug) || ($0.target == node.slug && $0.source == cn.slug) })?.relation ?? .related
                    HStack(spacing: 6) {
                        Circle().fill(cc).frame(width: 5, height: 5)
                        Text(cn.title).lociFont(size: 10.5, weight: .medium, relativeTo: .caption).foregroundStyle(Color.black.opacity(0.65)).lineLimit(1)
                        Spacer()
                        Text(rel.rawValue).lociFont(size: 8, weight: .semibold, relativeTo: .caption2).foregroundStyle(relColor(for: rel)).padding(.horizontal, 5).padding(.vertical, 2).background(relColor(for: rel).opacity(0.10), in: Capsule())
                    }.padding(.vertical, 3)
                }
                if connNodes.count > 5 { Text("+ \(connNodes.count - 5) more").lociFont(size: 9, weight: .medium, relativeTo: .caption2).foregroundStyle(Color.black.opacity(0.32)).padding(.top, 4) }
            }
        }
        .padding(14).frame(width: cw, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
        .position(x: cx, y: cy)
    }

    // MARK: - Push

    private func pushOffset(node: VaultGraphNode, isSelected: Bool, isConnected: Bool) -> CGSize {
        guard let slug = selectedSlug, let fp = nodePositions[slug] else { return .zero }
        guard !isSelected else { return .zero }
        let np = nodePositions[node.slug] ?? .zero
        let dx = np.x - fp.x, dy = np.y - fp.y, d = sqrt(dx * dx + dy * dy)
        guard d > 1 else { return .zero }
        let f: CGFloat = isConnected ? 30 : 55
        return CGSize(width: dx / d * f, height: dy / d * f)
    }

    // MARK: - Helpers

    private func adjacencyMap(for edges: [VaultGraphEdge]) -> [String: Set<String>] {
        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }
        return adjacency
    }

    private func isNode(_ node: VaultGraphNode, connectedToSlug slug: String?) -> Bool {
        guard let slug else { return false }
        return connectedSlugsByNode[slug]?.contains(node.slug) == true
    }

    private func nav(_ dir: Int) {
        let n = graph.nodes
        guard !n.isEmpty else { return }
        if let cur = selectedSlug, let idx = n.firstIndex(where: { $0.slug == cur }) {
            withAnimation(AppMotion.quick) { selectedSlug = n[(idx + dir + n.count) % n.count].slug }
        } else {
            withAnimation(AppMotion.quick) { selectedSlug = n[dir > 0 ? 0 : n.count - 1].slug }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func nodeColor(for g: ReferenceGroup) -> Color {
        switch g { case .file: Color(red: 0.22, green: 0.50, blue: 0.82); case .memory: Color(red: 0.88, green: 0.52, blue: 0.18); case .link: Color(red: 0.18, green: 0.66, blue: 0.42); case .website: Color(red: 0.78, green: 0.20, blue: 0.30) }
    }

    private func shortLabel(for group: ReferenceGroup) -> String {
        switch group {
        case .file: "File"
        case .memory: "Mem"
        case .link: "Link"
        case .website: "Web"
        }
    }

    private func relColor(for r: GraphRelation) -> Color {
        switch r {
        case .collection: Color(red: 0.20, green: 0.52, blue: 0.82)
        case .kind: Color(red: 0.55, green: 0.30, blue: 0.72)
        case .concept: Color(red: 0.18, green: 0.66, blue: 0.42)
        case .contradiction: Color(red: 0.82, green: 0.20, blue: 0.20)
        case .crossRef: Color(red: 0.88, green: 0.52, blue: 0.18)
        case .domain: Color(red: 0.15, green: 0.58, blue: 0.62)
        case .related: Color(red: 0.55, green: 0.55, blue: 0.55)
        case .group: Color(red: 0.18, green: 0.52, blue: 0.66)
        case .authoredBy: Color(red: 0.12, green: 0.48, blue: 0.92)
        case .containsMedia: Color(red: 0.66, green: 0.36, blue: 0.86)
        case .tagged: Color(red: 0.90, green: 0.48, blue: 0.12)
        }
    }

    private func edgeReasonText(for relation: GraphRelation) -> String {
        switch relation {
        case .collection: "Same collection"
        case .kind: "Same visual type"
        case .concept: "Shared concept"
        case .contradiction: "Contradiction"
        case .crossRef: "Wiki cross-reference"
        case .domain: "Same domain"
        case .related: "LLM related theme"
        case .group: "Same document group"
        case .authoredBy: "Authored by"
        case .containsMedia: "Contains media"
        case .tagged: "Tagged"
        }
    }

    // MARK: - Layout

    private func prepareLayout(in size: CGSize) {
        guard !graph.nodes.isEmpty else {
            nodePositions = [:]
            connectedSlugsByNode = [:]
            return
        }

        connectedSlugsByNode = adjacencyMap(for: graph.edges)

        let graphSlugs = Set(graph.nodes.map(\.slug))
        guard Set(nodePositions.keys) != graphSlugs else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            nodePositions = initialPositions(for: graph, in: size)
        }

        DispatchQueue.main.async {
            guard Set(nodePositions.keys) == graphSlugs else { return }
            computeLayout(in: size)
        }
    }

    private func initialPositions(for graph: VaultGraph, in size: CGSize) -> [String: CGPoint] {
        var pos: [String: CGPoint] = [:]
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let groups = Dictionary(grouping: graph.nodes, by: \.group)
        let angles: [ReferenceGroup: Double] = [.file: -.pi * 0.75, .website: -.pi * 0.25, .memory: .pi * 0.75, .link: .pi * 0.25]
        for (g, nodes) in groups {
            let a = (angles[g] ?? 0) + layoutRotation
            let cc = CGPoint(x: c.x + cos(a) * size.width * 0.25, y: c.y + sin(a) * size.height * 0.25)
            for (i, n) in nodes.enumerated() {
                let sa = Double(i) / Double(max(1, nodes.count)) * .pi * 2
                let r: CGFloat = 50 + CGFloat(nodes.count) * 6
                pos[n.slug] = CGPoint(x: cc.x + cos(sa) * r, y: cc.y + sin(sa) * r)
            }
        }
        return pos
    }

    private func computeLayout(in size: CGSize) {
        guard !graph.nodes.isEmpty else { return }
        var pos = initialPositions(for: graph, in: size)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        var temp: CGFloat = 1.0
        let iterations = layoutIterations(for: graph.nodes.count)
        let repulsionStride = layoutRepulsionStride(for: graph.nodes.count)
        for _ in 0..<iterations {
            var f: [String: CGSize] = [:]
            for n in graph.nodes { f[n.slug] = .zero }
            for i in graph.nodes.indices {
                for j in stride(from: i + 1, to: graph.nodes.count, by: repulsionStride) {
                    let (a, b) = (graph.nodes[i], graph.nodes[j])
                    guard let pa = pos[a.slug], let pb = pos[b.slug] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y, d = max(1, sqrt(dx * dx + dy * dy))
                    let force = 4000 / (d * d) * temp; let fx = dx / d * force, fy = dy / d * force
                    f[a.slug, default: .zero] = CGSize(width: (f[a.slug]?.width ?? 0) + fx, height: (f[a.slug]?.height ?? 0) + fy)
                    f[b.slug, default: .zero] = CGSize(width: (f[b.slug]?.width ?? 0) - fx, height: (f[b.slug]?.height ?? 0) - fy)
                }
            }
            for e in graph.edges {
                guard let pa = pos[e.source], let pb = pos[e.target] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y, d = max(1, sqrt(dx * dx + dy * dy))
                let force = 0.004 * (d - 160) * temp; let fx = dx / d * force, fy = dy / d * force
                f[e.source, default: .zero] = CGSize(width: (f[e.source]?.width ?? 0) + fx, height: (f[e.source]?.height ?? 0) + fy)
                f[e.target, default: .zero] = CGSize(width: (f[e.target]?.width ?? 0) - fx, height: (f[e.target]?.height ?? 0) - fy)
            }
            for n in graph.nodes {
                guard var p = pos[n.slug] else { continue }
                let fv = f[n.slug] ?? .zero; p.x += fv.width; p.y += fv.height
                let dx = p.x - c.x, dy = p.y - c.y, d = sqrt(dx * dx + dy * dy), mx = min(size.width, size.height) * 0.44
                if d > mx { p.x = c.x + dx / d * mx; p.y = c.y + dy / d * mx }
                pos[n.slug] = p
            }
            temp *= 0.90
        }
        nodePositions = pos
    }

    private func layoutIterations(for nodeCount: Int) -> Int {
        switch nodeCount {
        case 0...80:
            return maxLayoutIterations
        case 81...180:
            return 64
        case 181...420:
            return 38
        default:
            return 24
        }
    }

    private func layoutRepulsionStride(for nodeCount: Int) -> Int {
        switch nodeCount {
        case 0...160:
            return 1
        case 161...360:
            return 2
        case 361...720:
            return 3
        default:
            return 4
        }
    }

    // MARK: - Edge Drawing

    private func drawEdge(ctx: GraphicsContext, from: CGPoint, to: CGPoint, relation: GraphRelation, active: Bool) {
        let dx = to.x - from.x, dy = to.y - from.y, dist = sqrt(dx * dx + dy * dy)
        guard dist > 1 else { return }
        let curve = min(dist * 0.15, 50)
        let cp = CGPoint(x: (from.x + to.x) / 2 - dy / dist * curve, y: (from.y + to.y) / 2 + dx / dist * curve)
        var path = Path(); path.move(to: from); path.addQuadCurve(to: to, control: cp)
        let base = relColor(for: relation)
        let c: Color = active ? base.opacity(0.65) : base.opacity(0.18)
        let lw: CGFloat = active ? (relation == .contradiction ? 2.0 : 1.6) : (relation == .contradiction ? 1.2 : 0.7)
        ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: relation == .contradiction ? [6, 4] : []))
    }
}
