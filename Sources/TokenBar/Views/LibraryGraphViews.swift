import SwiftUI

// MARK: - View mode toggle (Graph | List)

enum LibraryViewMode: String {
    case graph
    case list
}

struct LibraryViewToggle: View {
    let mode: LibraryViewMode
    let onChange: (LibraryViewMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(
                icon: "circle.grid.cross",
                label: "Graph",
                isActive: mode == .graph
            ) { onChange(.graph) }
            toggleButton(
                icon: "line.3.horizontal",
                label: "List",
                isActive: mode == .list
            ) { onChange(.list) }
        }
        .padding(2)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func toggleButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? TokenBarStyle.foreground : TokenBarStyle.faint)
    }
}

// MARK: - Mode bar (title + subtitle + toggle)

struct LibraryModeBar: View {
    let title: String
    let subtitle: String
    let mode: LibraryViewMode
    let onChange: (LibraryViewMode) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(TokenBarStyle.faint)
            }
            Spacer()
            LibraryViewToggle(mode: mode, onChange: onChange)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Skills Constellation

private let scopeColors: [String: Color] = [
    "user": Color(red: 0.83, green: 0.97, blue: 0.42),
    "project": Color(red: 0.13, green: 0.78, blue: 0.78),
    "shared": Color(red: 1.0, green: 0.71, blue: 0.33),
]

private let scopeLabels: [String: String] = [
    "user": "User",
    "project": "Project",
    "shared": "Shared",
]

private struct SkillNode: Identifiable {
    let id: String
    let name: String
    let scope: String
    let dir: String
    var x: CGFloat
    var y: CGFloat
    let ctx: Double?
    let size: String
    let desc: String
    let isReal: Bool
    let broken: Bool
    let calls: Int
    var neighbours: Set<String> = []
}

private struct SkillLink: Identifiable {
    let id: String
    let fromId: String
    let toId: String
    let kind: String
}

private func buildSkillsGraph() -> (nodes: [SkillNode], links: [SkillLink]) {
    let dirs = skillDirs
    let clusters: [String: (cx: CGFloat, cy: CGFloat, baseR: CGFloat)] = [
        "user": (240, 280, 120),
        "project": (600, 280, 90),
        "shared": (940, 280, 130),
    ]

    var nodes: [SkillNode] = []
    for d in dirs {
        guard let c = clusters[d.scope.rawValue] else { continue }
        let n = d.items.count
        for (i, item) in d.items.enumerated() {
            let angle = CGFloat(i) / CGFloat(max(1, n)) * .pi * 2 - .pi / 2
            let r = c.baseR + CGFloat(item.contextK ?? 1) * 4
            let calls = item.broken ? 0 : Int((item.contextK ?? 0.5) * 8 + (item.isReal ? 6 : 2))
            nodes.append(SkillNode(
                id: "\(d.scope.rawValue)/\(item.name)",
                name: item.name,
                scope: d.scope.rawValue,
                dir: d.label,
                x: c.cx + cos(angle) * r,
                y: c.cy + sin(angle) * r,
                ctx: item.contextK,
                size: item.size,
                desc: item.desc,
                isReal: item.isReal,
                broken: item.broken,
                calls: calls
            ))
        }
    }

    let rels: [(from: String, to: String, kind: String)] = [
        ("user/frontend-design", "user/make-a-deck", "chain"),
        ("user/make-a-deck", "user/save-as-pdf", "chain"),
        ("user/make-a-deck", "user/animations", "chain"),
        ("user/interactive-prototype", "user/wireframe", "chain"),
        ("project/frontend-design", "user/frontend-design", "override"),
        ("shared/make-a-deck", "user/make-a-deck", "shadow"),
        ("shared/shadcn-recipes", "user/frontend-design", "augments"),
        ("project/tokenbar-style-guide", "user/frontend-design", "augments"),
        ("project/mock-fixtures", "shared/db-migrations", "chain"),
    ]

    let idSet = Set(nodes.map(\.id))
    var links: [SkillLink] = []
    for (idx, r) in rels.enumerated() {
        let hasFrom = idSet.contains(r.from)
        let hasTo = idSet.contains(r.to)
        guard hasFrom, hasTo else { continue }
        links.append(SkillLink(id: "link-\(idx)", fromId: r.from, toId: r.to, kind: r.kind))
    }

    for i in nodes.indices {
        var neighbours = Set<String>()
        for link in links {
            if link.fromId == nodes[i].id { neighbours.insert(link.toId) }
            if link.toId == nodes[i].id { neighbours.insert(link.fromId) }
        }
        nodes[i].neighbours = neighbours
    }

    return (nodes, links)
}

struct SkillsConstellationView: View {
    @State private var selectedId: String?
    @State private var hoveredId: String?

    private let graph = buildSkillsGraph()

    private var nodeMap: [String: SkillNode] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    }

    private var activeNode: SkillNode? {
        if let hid = hoveredId { return nodeMap[hid] }
        if let sid = selectedId { return nodeMap[sid] }
        return graph.nodes.max(by: { $0.neighbours.count < $1.neighbours.count })
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasArea
            if let node = activeNode {
                detailPanel(node)
                    .frame(width: 260)
            }
        }
        .frame(height: 520)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private var canvasArea: some View {
        Canvas { context, size in
            let sx = size.width / 1200
            let sy = size.height / 560

            context.opacity = 0.5
            for link in graph.links {
                guard let from = nodeMap[link.fromId], let to = nodeMap[link.toId] else { continue }
                let isActive = activeNode.map { $0.id == link.fromId || $0.id == link.toId } ?? false
                var path = Path()
                let mx = (from.x + to.x) / 2
                let my = (from.y + to.y) / 2 - 30
                path.move(to: CGPoint(x: from.x * sx, y: from.y * sy))
                path.addQuadCurve(
                    to: CGPoint(x: to.x * sx, y: to.y * sy),
                    control: CGPoint(x: mx * sx, y: my * sy)
                )
                let color = linkColor(link.kind)
                context.stroke(path, with: .color(color.opacity(isActive ? 0.7 : 0.25)), lineWidth: isActive ? 1.5 : 0.8)
            }

            context.opacity = 1.0
            for scope in ["user", "project", "shared"] {
                let cx: CGFloat = scope == "user" ? 240 : scope == "project" ? 600 : 940
                let label = scopeLabels[scope] ?? scope
                let textPos = CGPoint(x: cx * sx, y: 60 * sy)
                context.draw(
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(scopeColors[scope] ?? .white),
                    at: textPos
                )
            }

            for node in graph.nodes {
                let r = max(8, min(26, 9 + CGFloat(node.ctx ?? 1) * 3))
                let center = CGPoint(x: node.x * sx, y: node.y * sy)
                let isActive = activeNode?.id == node.id
                let isNeighbour = activeNode?.neighbours.contains(node.id) ?? false
                let isDimmed = activeNode != nil && !isActive && !isNeighbour
                let scopeColor = scopeColors[node.scope] ?? .white

                if isActive {
                    let haloPath = Path(ellipseIn: CGRect(x: center.x - r - 6, y: center.y - r - 6, width: (r + 6) * 2, height: (r + 6) * 2))
                    context.fill(haloPath, with: .color(scopeColor.opacity(0.12)))
                }

                let circlePath = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                let alpha: Double = isDimmed ? 0.15 : (node.broken ? 0.35 : 1.0)
                context.fill(circlePath, with: .color(scopeColor.opacity(alpha)))

                if !node.isReal && !node.broken {
                    context.stroke(
                        Path(ellipseIn: CGRect(x: center.x - r - 2, y: center.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)),
                        with: .color(scopeColor.opacity(isDimmed ? 0.08 : 0.35)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }

                let textAlpha = isDimmed ? 0.2 : 0.85
                context.draw(
                    Text(node.name)
                        .font(.system(size: 9.5, weight: isActive ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(textAlpha)),
                    at: CGPoint(x: center.x, y: center.y + r + 12)
                )
            }

            context.draw(
                Text("chain")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4)),
                at: CGPoint(x: 60 * sx, y: 510 * sy)
            )
            context.draw(
                Text("override")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4)),
                at: CGPoint(x: 140 * sx, y: 510 * sy)
            )
            context.draw(
                Text("shadow")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4)),
                at: CGPoint(x: 230 * sx, y: 510 * sy)
            )
            context.draw(
                Text("augments")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4)),
                at: CGPoint(x: 330 * sx, y: 510 * sy)
            )
        }
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    let sx = 1200.0 / max(1, value.location.x > 0 ? value.location.x * 1200 / value.location.x : 1200)
                    if let tapped = hitTest(at: value.location, canvasSize: CGSize(width: 800, height: 520)) {
                        selectedId = tapped.id
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if let hit = hitTest(at: location, canvasSize: CGSize(width: 800, height: 520)) {
                    hoveredId = hit.id
                } else {
                    hoveredId = nil
                }
            case .ended:
                hoveredId = nil
            }
        }
    }

    private func hitTest(at point: CGPoint, canvasSize: CGSize) -> SkillNode? {
        let sx = canvasSize.width / 1200
        let sy = canvasSize.height / 560
        for node in graph.nodes.reversed() {
            let r = max(8, min(26, 9 + CGFloat(node.ctx ?? 1) * 3)) + 6
            let center = CGPoint(x: node.x * sx, y: node.y * sy)
            let dist = hypot(point.x - center.x, point.y - center.y)
            if dist <= r { return node }
        }
        return nil
    }

    private func linkColor(_ kind: String) -> Color {
        switch kind {
        case "chain": Color(red: 0.83, green: 0.97, blue: 0.42)
        case "override": Color(red: 1.0, green: 0.71, blue: 0.33)
        case "shadow": Color(red: 0.77, green: 0.64, blue: 1.0)
        case "augments": Color(red: 0.13, green: 0.78, blue: 0.78)
        default: Color.white.opacity(0.3)
        }
    }

    private func detailPanel(_ node: SkillNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(scopeLabels[node.scope] ?? "")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((scopeColors[node.scope] ?? .white).opacity(0.12), in: Capsule())
                        .foregroundStyle(scopeColors[node.scope] ?? .white)
                }
                Text(node.name)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.foreground)
                Text(node.desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TokenBarStyle.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(TokenBarStyle.line)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(node.calls)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("calls/wk")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(node.ctx.map { String(format: "%.1f", $0) } ?? "\u{2014}")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                        Text("K")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                    }
                    Text("ctx cost")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.size)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text("on disk")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }

            if !node.neighbours.isEmpty {
                Divider().overlay(TokenBarStyle.line)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Relationships")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.muted)
                    ForEach(graph.links.filter { $0.fromId == node.id || $0.toId == node.id }, id: \.id) { link in
                        let peer = link.fromId == node.id ? link.toId : link.fromId
                        let peerName = peer.split(separator: "/").last.map(String.init) ?? peer
                        HStack(spacing: 6) {
                            Text(link.kind)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(linkColor(link.kind))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(linkColor(link.kind).opacity(0.12), in: Capsule())
                            Text(peerName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TokenBarStyle.foreground)
                        }
                    }
                }
            }

            Spacer()

            Text("modified \(node.broken ? "missing" : "recently")")
                .font(.system(size: 10.5))
                .foregroundStyle(TokenBarStyle.faint)
        }
        .padding(16)
        .overlay(alignment: .leading) {
            TokenBarStyle.line.frame(width: 1)
        }
    }
}

// MARK: - MCP Solar System

struct McpSolarSystemView: View {
    @State private var selectedName: String?
    @State private var hoveredName: String?

    private var allItems: [LibraryMcpItem] {
        let dirs: [LibraryMcpDir] = mcpDirs
        return dirs.flatMap { $0.items }
    }
    private var loadedItems: [LibraryMcpItem] { allItems.filter { $0.loaded } }
    private var availableItems: [LibraryMcpItem] { allItems.filter { !$0.loaded } }
    private var tokensInContext: Double { loadedItems.reduce(0) { $0 + $1.tokens } }
    private let budget: Double = 128

    private var activeItem: LibraryMcpItem? {
        if let name = hoveredName { return allItems.first { $0.name == name } }
        if let name = selectedName { return allItems.first { $0.name == name } }
        return loadedItems.first
    }

    var body: some View {
        VStack(spacing: 12) {
            statsBar
            HStack(spacing: 0) {
                canvasArea
                if let item = activeItem {
                    mcpDetailPanel(item)
                        .frame(width: 260)
                }
            }
            .frame(height: 540)
            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
    }

    private var statsBar: some View {
        HStack(spacing: 20) {
            statKPI(value: "\(loadedItems.count)/\(allItems.count)", label: "servers loaded")
            Rectangle().fill(TokenBarStyle.line).frame(width: 1, height: 28)
            statKPI(value: String(format: "%.1fK", tokensInContext), label: "in agent context")
            Rectangle().fill(TokenBarStyle.line).frame(width: 1, height: 28)
            statKPI(value: "\(Int(min(100, tokensInContext / budget * 100)))%", label: "of \(Int(budget))K window")
            Spacer()
        }
        .padding(14)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func statKPI(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(TokenBarStyle.foreground)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(TokenBarStyle.faint)
        }
    }

    private static let mcpCX: CGFloat = 500
    private static let mcpCY: CGFloat = 270
    private static let mcpRingLoaded: CGFloat = 130
    private static let mcpRingAvail: CGFloat = 230
    private static let mcpRingBudget: CGFloat = 180
    private static let limeColor = Color(red: 0.83, green: 0.97, blue: 0.42)

    private var canvasArea: some View {
        Canvas { context, size in
            drawMcpCanvas(context: &context, size: size)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: break
            case .ended: hoveredName = nil
            }
        }
    }

    private func drawMcpCanvas(context: inout GraphicsContext, size: CGSize) {
        let sx = size.width / 1000
        let sy = size.height / 540
        let cx = Self.mcpCX
        let cy = Self.mcpCY

        drawOrbits(context: &context, sx: sx, sy: sy, cx: cx, cy: cy)
        drawConnectionLines(context: &context, sx: sx, sy: sy, cx: cx, cy: cy)
        drawAgent(context: &context, sx: sx, sy: sy, cx: cx, cy: cy)
        drawAllServers(context: &context, sx: sx, sy: sy, cx: cx, cy: cy)

        let labelX = (cx + Self.mcpRingBudget + 20) * sx
        let labelY = cy * sy
        let labelText = Text("context window \u{00B7} \(Int(budget))K")
            .font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.3))
        context.draw(labelText, at: CGPoint(x: labelX, y: labelY))
    }

    private func drawOrbits(context: inout GraphicsContext, sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat) {
        let budgetR = Self.mcpRingBudget
        let budgetRect = CGRect(x: (cx - budgetR) * sx, y: (cy - budgetR) * sy, width: budgetR * 2 * sx, height: budgetR * 2 * sy)
        context.stroke(Path(ellipseIn: budgetRect), with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))

        let loadedR = Self.mcpRingLoaded
        let loadedRect = CGRect(x: (cx - loadedR) * sx, y: (cy - loadedR) * sy, width: loadedR * 2 * sx, height: loadedR * 2 * sy)
        context.stroke(Path(ellipseIn: loadedRect), with: .color(Color.white.opacity(0.04)), lineWidth: 0.5)

        let availR = Self.mcpRingAvail
        let availRect = CGRect(x: (cx - availR) * sx, y: (cy - availR) * sy, width: availR * 2 * sx, height: availR * 2 * sy)
        context.stroke(Path(ellipseIn: availRect), with: .color(Color.white.opacity(0.03)), lineWidth: 0.5)
    }

    private func drawConnectionLines(context: inout GraphicsContext, sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat) {
        let count = loadedItems.count
        for (i, item) in loadedItems.enumerated() {
            let angle = CGFloat(i) / CGFloat(max(1, count)) * .pi * 2 - .pi / 2
            let ix = cx + cos(angle) * Self.mcpRingLoaded
            let iy = cy + sin(angle) * Self.mcpRingLoaded
            var path = Path()
            path.move(to: CGPoint(x: ix * sx, y: iy * sy))
            path.addLine(to: CGPoint(x: cx * sx, y: cy * sy))
            let color = healthColor(item.health.status)
            context.stroke(path, with: .color(color.opacity(0.2)), lineWidth: 0.7)
        }
    }

    private func drawAgent(context: inout GraphicsContext, sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat) {
        let glowRect = CGRect(x: (cx - 40) * sx, y: (cy - 40) * sy, width: 80 * sx, height: 80 * sy)
        context.fill(Path(ellipseIn: glowRect), with: .color(Self.limeColor.opacity(0.08)))
        let coreRect = CGRect(x: (cx - 22) * sx, y: (cy - 22) * sy, width: 44 * sx, height: 44 * sy)
        context.fill(Path(ellipseIn: coreRect), with: .color(Self.limeColor.opacity(0.25)))
        context.stroke(Path(ellipseIn: coreRect), with: .color(Self.limeColor.opacity(0.45)), lineWidth: 1)
        let label = Text("Agent").font(.system(size: 9, weight: .semibold)).foregroundStyle(Self.limeColor.opacity(0.8))
        context.draw(label, at: CGPoint(x: cx * sx, y: cy * sy))
    }

    private func drawAllServers(context: inout GraphicsContext, sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat) {
        let loadedCount = loadedItems.count
        for (i, item) in loadedItems.enumerated() {
            let angle = CGFloat(i) / CGFloat(max(1, loadedCount)) * .pi * 2 - .pi / 2
            let ix = cx + cos(angle) * Self.mcpRingLoaded
            let iy = cy + sin(angle) * Self.mcpRingLoaded
            drawServer(context: context, item: item, x: ix, y: iy, sx: sx, sy: sy, isLoaded: true)
        }
        let availCount = availableItems.count
        for (i, item) in availableItems.enumerated() {
            let offset: CGFloat = .pi / CGFloat(max(1, availCount))
            let angle = CGFloat(i) / CGFloat(max(1, availCount)) * .pi * 2 - .pi / 2 + offset
            let ix = cx + cos(angle) * Self.mcpRingAvail
            let iy = cy + sin(angle) * Self.mcpRingAvail
            drawServer(context: context, item: item, x: ix, y: iy, sx: sx, sy: sy, isLoaded: false)
        }
    }

    private func drawServer(context: GraphicsContext, item: LibraryMcpItem, x: CGFloat, y: CGFloat, sx: CGFloat, sy: CGFloat, isLoaded: Bool) {
        let r = max(10, min(22, 8 + CGFloat(sqrt(item.tokens)) * 3))
        let center = CGPoint(x: x * sx, y: y * sy)
        let color = healthColor(item.health.status)
        let isActive = activeItem?.name == item.name
        let alpha: Double = isActive ? 1.0 : (isLoaded ? 0.85 : 0.35)

        if isActive {
            let halo = Path(ellipseIn: CGRect(x: center.x - r - 5, y: center.y - r - 5, width: (r + 5) * 2, height: (r + 5) * 2))
            context.fill(halo, with: .color(color.opacity(0.12)))
        }

        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.fill(circle, with: .color(color.opacity(alpha)))

        context.draw(
            Text(item.name)
                .font(.system(size: 9, weight: isActive ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(isLoaded ? 0.7 : 0.3)),
            at: CGPoint(x: center.x, y: center.y + r + 12)
        )
        context.draw(
            Text(String(format: "%.1fK", item.tokens))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Color.white.opacity(isLoaded ? 0.45 : 0.2)),
            at: CGPoint(x: center.x, y: center.y + r + 24)
        )
    }

    private func healthColor(_ status: McpHealthStatus) -> Color {
        switch status {
        case .ok: Color(red: 0.30, green: 0.78, blue: 0.55)
        case .degraded: Color(red: 0.91, green: 0.72, blue: 0.43)
        case .down: TokenBarStyle.error
        case .unchecked: TokenBarStyle.faint
        }
    }

    private func mcpDetailPanel(_ item: LibraryMcpItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(healthColor(item.health.status))
                        .frame(width: 8, height: 8)
                    Text(item.name)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                }
                Text(item.source)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                Text(item.desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TokenBarStyle.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(item.loaded ? TokenBarStyle.input : TokenBarStyle.faint)
                    .frame(width: 6, height: 6)
                Text(item.loaded ? "loaded \u{00B7} in context" : "not loaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.loaded ? TokenBarStyle.input : TokenBarStyle.faint)
            }
            .padding(8)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))

            Divider().overlay(TokenBarStyle.line)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(String(format: "%.1f", item.tokens))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                        Text("K")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                    }
                    Text("tokens")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.tools)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("tools")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }

            if let note = item.health.note {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 11))
                }
                .foregroundStyle(healthColor(item.health.status))
            }

            Spacer()
        }
        .padding(16)
        .overlay(alignment: .leading) {
            TokenBarStyle.line.frame(width: 1)
        }
    }
}
