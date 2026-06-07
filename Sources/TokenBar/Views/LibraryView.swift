import SwiftUI
import TokenBarCore

// MARK: - Skill detail selection state

@MainActor
final class SkillDetailSelection: ObservableObject {
    @Published var item: LibrarySkillItem?
    @Published var scope: LibraryScope = .user
    @Published var scopeLabel: String = ""

    func select(_ item: LibrarySkillItem, scope: LibraryScope, scopeLabel: String) {
        self.item = item
        self.scope = scope
        self.scopeLabel = scopeLabel
    }

    func dismiss() {
        item = nil
    }
}

// MARK: - Data models

enum LibraryTab: String, CaseIterable {
    case skills
    case plugins
    case mcp
}

struct LibrarySkillItem: Identifiable {
    var id: String { path }
    let name: String
    let isReal: Bool
    let target: String?
    let path: String
    let size: String
    let contextK: Double?
    let modified: String
    let desc: String
    let broken: Bool

    init(name: String, isReal: Bool, target: String? = nil, path: String, size: String, contextK: Double?, modified: String, desc: String, broken: Bool = false) {
        self.name = name
        self.isReal = isReal
        self.target = target
        self.path = path
        self.size = size
        self.contextK = contextK
        self.modified = modified
        self.desc = desc
        self.broken = broken
    }
}

struct LibrarySkillDir: Identifiable {
    let id: String
    let scope: LibraryScope
    let path: String
    let label: String
    let sub: String
    let items: [LibrarySkillItem]
}

struct LibraryPluginItem: Identifiable {
    let id: String
    let name: String
    let version: String
    let source: String
    let bundle: String
    let path: String
}

struct LibraryMcpItem: Identifiable {
    let id: String
    let name: String
    let source: String
    let tokens: Double
    let desc: String
    let isDisabled: Bool
    let scope: LibraryScope
    let sourceFile: String
}

struct LibraryMcpDir: Identifiable {
    let id: String
    let scope: LibraryScope
    let path: String
    let label: String
    let sub: String
    let items: [LibraryMcpItem]
}

// MARK: - Snapshot projection

func projectSkillDirs(from snapshot: LibrarySnapshot) -> [LibrarySkillDir] {
    var dirs: [LibrarySkillDir] = []
    let scopeOrder: [LibraryScope] = [.user, .project, .shared, .plugin]
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func displayPath(_ raw: String) -> String {
        raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    for scope in scopeOrder {
        let skills = snapshot.skillsByScope[scope] ?? []
        guard !skills.isEmpty else { continue }
        // Sub-group by scope_root so each on-disk skills directory (e.g.
        // ~/.codex/skills, ~/.agents/skills) shows as its own collapsible
        // card. Before this, all user-scope skills were jammed into one
        // "User" bucket and individual roots were invisible.
        let groupedByRoot = Dictionary(grouping: skills, by: \.scopeRoot.path)
        let sortedRoots = groupedByRoot.keys.sorted()

        for rootPath in sortedRoots {
            let rootSkills = groupedByRoot[rootPath] ?? []
            let rootDisplay = displayPath(rootPath)
            let label: String
            let sub: String
            switch scope {
            case .user:
                label = "User \u{00B7} \(rootDisplay)"
                sub = "\(rootSkills.count) skill\(rootSkills.count == 1 ? "" : "s")"
            case .project:
                let projectName = (rootPath as NSString).pathComponents.dropLast(2).last ?? "project"
                label = "Project \u{00B7} \(projectName)"
                sub = "\(rootSkills.count) skill\(rootSkills.count == 1 ? "" : "s") \u{00B7} \(rootDisplay)"
            case .shared:
                label = "Shared \u{00B7} \(rootDisplay)"
                sub = "\(rootSkills.count) skill\(rootSkills.count == 1 ? "" : "s")"
            case .plugin:
                let pluginId = rootSkills.first?.pluginId ?? "plugin"
                label = "Plugin \u{00B7} \(pluginId)"
                sub = "\(rootSkills.count) skill\(rootSkills.count == 1 ? "" : "s") \u{00B7} \(rootDisplay)"
            }

            let items = rootSkills.map { skill -> LibrarySkillItem in
                let sizeStr = formatBytes(skill.sizeBytes)
                let contextK = skill.estimatedTokens > 0 ? Double(skill.estimatedTokens) / 1000.0 : nil
                let modified = formatter.localizedString(for: skill.modifiedAt, relativeTo: Date())
                return LibrarySkillItem(
                    name: skill.name,
                    isReal: !skill.isSymlink,
                    target: skill.resolvedTarget?.path,
                    path: skill.path.path,
                    size: sizeStr,
                    contextK: contextK,
                    modified: modified,
                    desc: skill.description ?? "",
                    broken: skill.isBroken
                )
            }

            // Within a directory, group by type (real skills first, then
            // symlinks), and within each group sort by estimated context desc
            // so the heaviest skills surface at the top.
            let sortedItems = items.sorted { lhs, rhs in
                if lhs.isReal != rhs.isReal { return lhs.isReal && !rhs.isReal }
                return (lhs.contextK ?? 0) > (rhs.contextK ?? 0)
            }

            dirs.append(LibrarySkillDir(
                id: "\(scope.rawValue):\(rootPath)",
                scope: scope,
                path: rootPath,
                label: label,
                sub: sub,
                items: sortedItems
            ))
        }
    }
    return dirs
}

func projectMcpDirs(from snapshot: LibrarySnapshot) -> [LibraryMcpDir] {
    var dirs: [LibraryMcpDir] = []
    let scopeOrder: [LibraryScope] = [.user, .project]
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func displayPath(_ raw: String) -> String {
        raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    for scope in scopeOrder {
        let servers = snapshot.mcpByScope[scope] ?? []
        guard !servers.isEmpty else { continue }
        // Sub-group by source_file so each config file (~/.claude.json,
        // <project>/.mcp.json, etc.) gets its own collapsible card.
        let groupedBySource = Dictionary(grouping: servers, by: \.sourceFile.path)
        let sortedSources = groupedBySource.keys.sorted()

        for sourcePath in sortedSources {
            let serverList = groupedBySource[sourcePath] ?? []
            let sourceDisplay = displayPath(sourcePath)
            let label: String
            let sub: String
            switch scope {
            case .user:
                label = "User \u{00B7} \(sourceDisplay)"
                sub = "\(serverList.count) server\(serverList.count == 1 ? "" : "s")"
            case .project:
                // sourcePath is <project>/.mcp.json — show the project dir name.
                let projectName = (sourcePath as NSString).deletingLastPathComponent
                let projectDisplay = (projectName as NSString).lastPathComponent
                label = "Project \u{00B7} \(projectDisplay)"
                sub = "\(serverList.count) server\(serverList.count == 1 ? "" : "s") \u{00B7} \(displayPath(projectName))"
            case .shared:
                label = "Shared \u{00B7} \(sourceDisplay)"
                sub = "\(serverList.count) server\(serverList.count == 1 ? "" : "s")"
            case .plugin:
                label = "Plugin \u{00B7} \(sourceDisplay)"
                sub = "\(serverList.count) server\(serverList.count == 1 ? "" : "s")"
            }

            let items = serverList.map { server -> LibraryMcpItem in
                let tokens = Double(server.estimatedTokens) / 1000.0
                return LibraryMcpItem(
                    id: "\(scope.rawValue):\(sourcePath):\(server.name)",
                    name: server.name,
                    source: server.command,
                    tokens: tokens,
                    desc: server.args.joined(separator: " "),
                    isDisabled: server.isDisabled,
                    scope: server.scope,
                    sourceFile: server.sourceFile.path
                )
            }

            dirs.append(LibraryMcpDir(
                id: "mcp:\(scope.rawValue):\(sourcePath)",
                scope: scope,
                path: sourcePath,
                label: label,
                sub: sub,
                items: items
            ))
        }
    }
    return dirs
}

func projectPlugins(from snapshot: LibrarySnapshot) -> [LibraryPluginItem] {
    snapshot.plugins.map { plugin in
        let bundle: String
        if plugin.scope == "local", let pp = plugin.projectPath {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            bundle = pp.hasPrefix(home) ? "~" + pp.dropFirst(home.count) : pp
        } else {
            bundle = plugin.marketplace
        }
        return LibraryPluginItem(
            id: plugin.fullId,
            name: plugin.name,
            version: plugin.version,
            source: plugin.scope,
            bundle: bundle,
            path: plugin.installPath
        )
    }
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    let kb = Double(bytes) / 1024.0
    if kb < 1024 { return String(format: "%.1fK", kb) }
    let mb = kb / 1024.0
    return String(format: "%.1fM", mb)
}

typealias LibraryScope = TokenBarCore.LibraryScope

// MARK: - Helpers

// MARK: - Scope pill

private struct ScopePill: View {
    let scope: LibraryScope
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor, in: Capsule())
            .overlay(Capsule().stroke(borderColor, lineWidth: 1))
            .foregroundStyle(foregroundColor)
    }

    private var foregroundColor: Color {
        switch scope {
        case .user: TokenBarStyle.input
        case .project: Color(red: 0.78, green: 0.90, blue: 0.39)
        case .shared: TokenBarStyle.muted
        case .plugin: Color(red: 0.85, green: 0.55, blue: 0.95)
        }
    }

    private var backgroundColor: Color {
        switch scope {
        case .user: TokenBarStyle.input.opacity(0.10)
        case .project: Color(red: 0.78, green: 0.90, blue: 0.39).opacity(0.10)
        case .shared: Color.white.opacity(0.05)
        case .plugin: Color(red: 0.85, green: 0.55, blue: 0.95).opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch scope {
        case .user: TokenBarStyle.input.opacity(0.30)
        case .project: Color(red: 0.78, green: 0.90, blue: 0.39).opacity(0.30)
        case .shared: Color.white.opacity(0.16)
        case .plugin: Color(red: 0.85, green: 0.55, blue: 0.95).opacity(0.30)
        }
    }
}

// MARK: - Library Tab Selector

private struct LibraryTabSelector: View {
    let selectedTab: LibraryTab
    let onSelect: (LibraryTab) -> Void
    let skillDirs: [LibrarySkillDir]
    let plugins: [LibraryPluginItem]
    let mcpDirs: [LibraryMcpDir]

    private var totalSkills: Int { skillDirs.reduce(0) { $0 + $1.items.count } }
    private var totalPlugins: Int { plugins.count }
    private var allMcp: [LibraryMcpItem] { mcpDirs.flatMap(\.items) }
    private var mcpTokens: Double { allMcp.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        HStack(spacing: 8) {
            tabItem(
                tab: .skills,
                icon: "book.closed",
                label: "Skills",
                count: totalSkills,
                meta: "\(skillDirs.count) directories"
            )
            tabItem(
                tab: .plugins,
                icon: "powerplug",
                label: "Plugins",
                count: totalPlugins,
                meta: "\(totalPlugins) installed"
            )
            tabItem(
                tab: .mcp,
                icon: "circle.grid.cross",
                label: "MCP",
                count: allMcp.count,
                meta: "\(String(format: "%.1f", mcpTokens))K est. context"
            )
        }
    }

    private func tabItem(tab: LibraryTab, icon: String, label: String, count: Int, meta: String) -> some View {
        let selected = selectedTab == tab
        return Button { onSelect(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(selected ? TokenBarStyle.input.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(selected ? TokenBarStyle.input : TokenBarStyle.faint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
                    Text(meta)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(count)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? TokenBarStyle.surface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? TokenBarStyle.line : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skill card (Codex-inspired grid card)

private struct SkillCardView: View {
    let item: LibrarySkillItem
    let scope: LibraryScope
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                typeIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.broken ? TokenBarStyle.error : TokenBarStyle.foreground)
                        .lineLimit(1)
                    Text(item.desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    ctxBadge
                    statusIcon
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .offset(y: isHovered ? -1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var typeIcon: some View {
        Image(systemName: item.isReal ? "book.closed.fill" : "arrow.up.right")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 34, height: 34)
            .background(
                item.isReal
                    ? Color.white.opacity(0.05)
                    : TokenBarStyle.input.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .foregroundStyle(item.broken ? TokenBarStyle.error : (item.isReal ? TokenBarStyle.muted : TokenBarStyle.input))
    }

    private var ctxBadge: some View {
        Group {
            if let ctx = item.contextK {
                HStack(spacing: 0) {
                    Text(String(format: "%.1f", ctx))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("K")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            } else {
                Text("\u{2014}")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            if item.broken {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TokenBarStyle.error)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TokenBarStyle.lime)
            }
        }
    }

    private var cardBorderColor: Color {
        if item.broken { return TokenBarStyle.error.opacity(0.35) }
        if isHovered { return TokenBarStyle.input.opacity(0.50) }
        return TokenBarStyle.line
    }
}

// MARK: - Skill detail panel (modal overlay)

private struct SkillDetailPanel: View {
    let item: LibrarySkillItem
    let scope: LibraryScope
    let scopeLabel: String
    let onClose: () -> Void
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showDeleteAlert = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().background(TokenBarStyle.line)
                descriptionSection
                Divider().background(TokenBarStyle.line)
                infoTable
                Divider().background(TokenBarStyle.line)
                footerButtons
            }
            .frame(width: 520)
            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
        .alert("Delete \(item.name)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { deleteToTrash() }
        } message: {
            Text(item.isReal
                 ? "This permanently moves the skill directory to the Trash:\n\(item.path)"
                 : "This removes the symlink only \u{2014} the target it points to is untouched:\n\(item.path)")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.isReal ? "book.closed.fill" : "arrow.up.right")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
                .background(
                    item.isReal
                        ? Color.white.opacity(0.05)
                        : TokenBarStyle.input.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .foregroundStyle(item.broken ? TokenBarStyle.error : (item.isReal ? TokenBarStyle.muted : TokenBarStyle.input))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.foreground)
                    Text("Skill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.faint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                ScopePill(scope: scope, label: scopeLabel)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.muted)
        }
        .padding(20)
    }

    private var descriptionSection: some View {
        Text(item.desc.isEmpty ? "No description" : item.desc)
            .font(.system(size: 13))
            .foregroundStyle(item.desc.isEmpty ? TokenBarStyle.faint : TokenBarStyle.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }

    private var infoTable: some View {
        VStack(spacing: 0) {
            infoRow(label: "Type", value: {
                HStack(spacing: 6) {
                    Image(systemName: item.isReal ? "book.closed.fill" : "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                    Text(item.isReal ? "Real file" : "Symlink")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(item.isReal ? TokenBarStyle.muted : TokenBarStyle.input)
            })

            if !item.isReal {
                infoRow(label: "Target", value: {
                    HStack(spacing: 6) {
                        Text(item.target ?? "unknown")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(item.broken ? TokenBarStyle.error : TokenBarStyle.muted)
                            .lineLimit(1)
                        if item.broken {
                            Text("missing")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(TokenBarStyle.error)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(TokenBarStyle.error.opacity(0.12), in: Capsule())
                        }
                    }
                })
            }

            infoRow(label: "Context cost", value: {
                if let ctx = item.contextK {
                    Text("\(String(format: "%.1f", ctx))K tokens")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.cost)
                } else {
                    Text("unknown")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            })

            infoRow(label: "Size on disk", value: {
                Text(item.size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
            })

            infoRow(label: "Last modified", value: {
                Text(item.modified)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
            })
        }
        .padding(.vertical, 6)
    }

    private func infoRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(TokenBarStyle.faint)
                .frame(width: 110, alignment: .leading)
            value()
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var footerButtons: some View {
        HStack {
            Button {
                showDeleteAlert = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                    Text("Uninstall")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.muted)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                    Text("Reveal in Finder")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.muted)
        }
        .padding(20)
    }

    private func deleteToTrash() {
        let url = URL(fileURLWithPath: item.path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            runtimeModel.rebuildLibrarySnapshot(trigger: "ui.skill_deleted")
        } catch {
            try? FileManager.default.removeItem(at: url)
            runtimeModel.rebuildLibrarySnapshot(trigger: "ui.skill_deleted.fallback")
        }
        onClose()
    }
}

// MARK: - Skills tab body (Codex-inspired card grid)

private enum ScopeFilter: String, CaseIterable {
    case all
    case user
    case project
    case shared
}

// MARK: - Collapsible skill section

private struct SkillSectionView: View {
    let dir: LibrarySkillDir
    let onSelect: (LibrarySkillItem, LibraryScope, String) -> Void
    @State private var isOpen = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if isOpen {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(dir.items) { item in
                        SkillCardView(item: item, scope: dir.scope) {
                            onSelect(item, dir.scope, dir.label)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private var sectionHeader: some View {
        let real = dir.items.filter(\.isReal).count
        let sym = dir.items.count - real
        let ctx = dir.items.reduce(0.0) { $0 + ($1.contextK ?? 0) }
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(TokenBarStyle.faint)

                ScopePill(scope: dir.scope, label: dir.label)

                Text(dir.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 3) {
                    Text("\(real) real")
                    Text("\u{00B7}")
                    Text("\(sym) symlink")
                    Text("\u{00B7}")
                    Text(String(format: "%.1fK ctx", ctx))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if isOpen { TokenBarStyle.line.frame(height: 1) }
        }
    }
}

// MARK: - Skills tab body (Codex-inspired card grid)

private struct SkillsBody: View {
    let skillDirs: [LibrarySkillDir]
    let onRescan: () -> Void
    @EnvironmentObject private var detailSelection: SkillDetailSelection
    @State private var scopeFilter: ScopeFilter = .all

    private var total: Int { skillDirs.reduce(0) { $0 + $1.items.count } }

    private var filteredDirs: [LibrarySkillDir] {
        guard scopeFilter != .all else { return skillDirs }
        return skillDirs.filter { dir in
            switch scopeFilter {
            case .all: true
            case .user: dir.scope == .user
            case .project: dir.scope == .project
            case .shared: dir.scope == .shared
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            ForEach(filteredDirs) { dir in
                SkillSectionView(dir: dir) { item, scope, label in
                    detailSelection.select(item, scope: scope, scopeLabel: label)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField(placeholder: "Search \(total) skills\u{2026}", maxWidth: .infinity)
            scopePicker
        }
        .padding(.vertical, 4)
    }

    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(ScopeFilter.allCases, id: \.self) { filter in
                Button { scopeFilter = filter } label: {
                    Text(filter == .all ? "All" : filter.rawValue.capitalized)
                        .font(.system(size: 11.5, weight: scopeFilter == filter ? .semibold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            scopeFilter == filter ? Color.white.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(scopeFilter == filter ? TokenBarStyle.foreground : TokenBarStyle.faint)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }
}

// MARK: - Plugin row

private struct LibraryPluginRow: View {
    let plugin: LibraryPluginItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "powerplug")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(TokenBarStyle.muted)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.foreground)
                        .lineLimit(1)
                    Text("v\(plugin.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                HStack(spacing: 8) {
                    Text(plugin.bundle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TokenBarStyle.faint)
                    Text("\u{00B7}")
                        .foregroundStyle(TokenBarStyle.faint.opacity(0.5))
                    Text(plugin.source)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }

            Spacer()

            Button { revealInFinder() } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.muted)
            .help("Open in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            TokenBarStyle.line.frame(height: 1)
                .padding(.leading, 46)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plugin.path)])
    }
}

// MARK: - Plugins tab body

private struct PluginsBody: View {
    let plugins: [LibraryPluginItem]
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            VStack(spacing: 0) {
                ForEach(plugins) { plugin in
                    LibraryPluginRow(plugin: plugin)
                }
            }
            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField(placeholder: "Search \(plugins.count) plugins\u{2026}")
            Spacer()
            ghostButton(icon: "arrow.clockwise", label: "Rescan", action: onRescan)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - MCP context cost ribbon

private struct McpContextRibbon: View {
    let total: Int
    let tokens: Double
    let budget: Double = 128

    private var pct: Double { min(100, (tokens / budget) * 100) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 22) {
                    kpiBlock(
                        value: Text("\(total)").foregroundStyle(TokenBarStyle.foreground),
                        label: "servers"
                    )
                    divider
                    kpiBlock(
                        value: Text(String(format: "%.1f", tokens)).foregroundStyle(TokenBarStyle.foreground) + Text("K").foregroundStyle(TokenBarStyle.faint),
                        label: "in agent context"
                    )
                    divider
                    kpiBlock(
                        value: Text("\(Int(pct.rounded()))").foregroundStyle(TokenBarStyle.foreground) + Text("%").foregroundStyle(TokenBarStyle.faint),
                        label: "of \(Int(budget))K window"
                    )
                }

                Spacer()
            }

            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [TokenBarStyle.input, TokenBarStyle.lime],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, CGFloat(pct) / 100 * 600), height: 8)
                }
                .frame(maxWidth: .infinity)

                HStack {
                    Text("0K")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                    Spacer()
                    Text("context budget \u{00B7} before any prompt")
                        .font(.system(size: 10))
                        .foregroundStyle(TokenBarStyle.faint)
                    Spacer()
                    Text("\(Int(budget))K")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }
        }
        .padding(16)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func kpiBlock(value: Text, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(.system(size: 20, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(TokenBarStyle.faint)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(TokenBarStyle.line)
            .frame(width: 1, height: 28)
    }
}

// MARK: - MCP row

private struct LibraryMcpRow: View {
    let item: LibraryMcpItem
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showDeleteAlert = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(item.isDisabled ? TokenBarStyle.faint.opacity(0.5) : TokenBarStyle.muted)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.isDisabled ? TokenBarStyle.faint : TokenBarStyle.foreground)
                        .lineLimit(1)
                    if item.isDisabled {
                        disabledPill
                    }
                }
                HStack(spacing: 8) {
                    Text(item.desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TokenBarStyle.faint.opacity(0.7))
                        .lineLimit(1)
                    Text("\u{00B7}")
                        .foregroundStyle(TokenBarStyle.faint.opacity(0.5))
                    Text(item.source)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            mcpCostCell

            Button { showDeleteAlert = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.error)
            .help("Delete from config")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            TokenBarStyle.line.frame(height: 1)
                .padding(.leading, 52)
        }
        .alert("Delete \(item.name)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                runtimeModel.deleteMcpServer(name: item.name, sourceFile: URL(fileURLWithPath: item.sourceFile))
            }
        } message: {
            Text("This removes the \"\(item.name)\" entry from:\n\(item.sourceFile)")
        }
    }

    private var disabledPill: some View {
        Text("disabled")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TokenBarStyle.faint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private var mcpCostCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 0) {
                Text(String(format: "%.1f", item.tokens))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                Text("K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }
            Text("est. tokens")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)
        }
        .frame(width: 80, alignment: .trailing)
    }
}

// MARK: - MCP scope card

private struct McpScopeCard: View {
    let dir: LibraryMcpDir
    @State private var isOpen = false

    // Sort by estimated tokens desc so the heaviest servers surface first.
    private var sortedItems: [LibraryMcpItem] { dir.items.sorted { $0.tokens > $1.tokens } }
    private var totalTokens: Double { dir.items.reduce(0) { $0 + $1.tokens } }
    private var disabledCount: Int { dir.items.filter(\.isDisabled).count }

    var body: some View {
        VStack(spacing: 0) {
            scopeHeader
            if isOpen {
                ForEach(sortedItems) { item in
                    LibraryMcpRow(item: item)
                }
            }
        }
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir.path)])
    }

    private var scopeHeader: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(TokenBarStyle.faint)
                ScopePill(scope: dir.scope, label: dir.label)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dir.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                    Text(dir.sub)
                        .font(.system(size: 11))
                        .foregroundStyle(TokenBarStyle.faint.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                scopeCounts

                Button { revealConfigFile() } label: {
                    Text("Reveal")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if isOpen { TokenBarStyle.line.frame(height: 1) }
        }
    }

    private var scopeCounts: some View {
        HStack(spacing: 4) {
            countChip("\(dir.items.count)", label: "total", color: TokenBarStyle.muted)
            sepDot
            countChip(String(format: "%.1f", totalTokens), label: "K ctx", color: TokenBarStyle.cost)
            if disabledCount > 0 {
                sepDot
                countChip("\(disabledCount)", label: "disabled", color: TokenBarStyle.faint)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var sepDot: some View {
        Text("\u{00B7}")
            .foregroundStyle(TokenBarStyle.faint.opacity(0.5))
    }

    private func countChip(_ value: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(TokenBarStyle.faint)
        }
    }
}

// MARK: - MCP tab body

private struct MCPBody: View {
    let mcpDirs: [LibraryMcpDir]
    @State private var scopeFilter: McpScopeFilter = .all

    private enum McpScopeFilter: String { case all, user, project }

    private var allItems: [LibraryMcpItem] { mcpDirs.flatMap(\.items) }
    private var ctxTokens: Double { allItems.reduce(0) { $0 + $1.tokens } }

    private var filteredDirs: [LibraryMcpDir] {
        switch scopeFilter {
        case .all: return mcpDirs
        case .user: return mcpDirs.filter { $0.scope == .user }
        case .project: return mcpDirs.filter { $0.scope == .project }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Graph view disabled (matches the Skills tab decision) — the
            // solar-system layout was carrying its own dead weight without
            // adding signal over the list view.
            McpContextRibbon(total: allItems.count, tokens: ctxTokens)
            toolbar
            ForEach(filteredDirs) { dir in
                McpScopeCard(dir: dir)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField(placeholder: "Search \(allItems.count) servers\u{2026}")
            segmentedPicker
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var segmentedPicker: some View {
        HStack(spacing: 0) {
            segButton("All", filter: .all)
            segButton("User", filter: .user)
            segButton("Project", filter: .project)
        }
        .padding(2)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func segButton(_ label: String, filter: McpScopeFilter) -> some View {
        Button { scopeFilter = filter } label: {
            Text(label)
                .font(.system(size: 11.5, weight: scopeFilter == filter ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(scopeFilter == filter ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(scopeFilter == filter ? TokenBarStyle.foreground : TokenBarStyle.faint)
    }
}

// MARK: - Shared toolbar helpers

@MainActor private func searchField(placeholder: String, maxWidth: CGFloat = 260) -> some View {
    HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TokenBarStyle.faint)
        Text(placeholder)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(TokenBarStyle.faint)
        Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    .frame(maxWidth: maxWidth)
}

@MainActor private func ghostButton(icon: String?, label: String, action: @escaping () -> Void = {}) -> some View {
    Button(action: action) {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .foregroundStyle(TokenBarStyle.muted)
}

@MainActor private func primaryButton(icon: String?, label: String) -> some View {
    Button {} label: {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(TokenBarStyle.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.input.opacity(0.35), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .foregroundStyle(TokenBarStyle.input)
}

// MARK: - Library page

struct LibraryView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var selectedTab: LibraryTab = .skills

    private var skillDirs: [LibrarySkillDir] { projectSkillDirs(from: runtimeModel.librarySnapshot) }
    private var plugins: [LibraryPluginItem] { projectPlugins(from: runtimeModel.librarySnapshot) }
    private var mcpDirs: [LibraryMcpDir] { projectMcpDirs(from: runtimeModel.librarySnapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            pageHeader
            if let errorState = runtimeModel.librarySnapshot.scanStates.values.first(where: { $0.lastError != nil }) {
                errorBanner(errorState.lastError ?? "Unknown error")
            }
            LibraryTabSelector(
                selectedTab: selectedTab,
                onSelect: { selectedTab = $0 },
                skillDirs: skillDirs,
                plugins: plugins,
                mcpDirs: mcpDirs
            )
            switch selectedTab {
            case .skills:
                SkillsBody(
                    skillDirs: skillDirs,
                    onRescan: { runtimeModel.rebuildLibrarySnapshot(trigger: "manual.rescan") }
                )
            case .plugins:
                PluginsBody(plugins: plugins, onRescan: { runtimeModel.rebuildLibrarySnapshot(trigger: "manual.rescan") })
            case .mcp:
                MCPBody(mcpDirs: mcpDirs)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Library")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                if runtimeModel.librarySnapshot.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("Skills, prompt templates, plugins, and MCP servers TokenBar can see on disk \u{2014} and what\u{2019}s currently loaded into agent context.")
                .font(.system(size: 13))
                .foregroundStyle(TokenBarStyle.muted)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(TokenBarStyle.error)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(TokenBarStyle.error)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TokenBarStyle.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.error.opacity(0.2), lineWidth: 1))
    }
}

struct LibraryContainer: View {
    @StateObject private var detailSelection = SkillDetailSelection()
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel

    var body: some View {
        ScrollView {
            LibraryView()
                .padding(TokenBarStyle.pagePadding)
        }
        .overlay {
            if let item = detailSelection.item {
                SkillDetailPanel(
                    item: item,
                    scope: detailSelection.scope,
                    scopeLabel: detailSelection.scopeLabel,
                    onClose: { detailSelection.dismiss() }
                )
                .environmentObject(runtimeModel)
            }
        }
        .environmentObject(detailSelection)
    }
}
