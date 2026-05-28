import SwiftUI
import TokenBarCore

// MARK: - Data models

enum LibraryTab: String, CaseIterable {
    case skills
    case plugins
    case mcp
}

enum LibraryScope: String {
    case user
    case project
    case shared
}

struct LibrarySkillItem: Identifiable {
    let id = UUID()
    let name: String
    let isReal: Bool
    let target: String?
    let size: String
    let contextK: Double?
    let modified: String
    let desc: String
    let broken: Bool

    init(name: String, isReal: Bool, target: String? = nil, size: String, contextK: Double?, modified: String, desc: String, broken: Bool = false) {
        self.name = name
        self.isReal = isReal
        self.target = target
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
    let id = UUID()
    let name: String
    let version: String
    let source: String
    let bundle: String
    let state: String
}

enum McpHealthStatus: String {
    case ok
    case degraded
    case down
    case unchecked
}

struct McpHealthInfo {
    let status: McpHealthStatus
    let latency: Int?
    let last: String
    let note: String?

    init(status: McpHealthStatus, latency: Int? = nil, last: String, note: String? = nil) {
        self.status = status
        self.latency = latency
        self.last = last
        self.note = note
    }
}

struct LibraryMcpItem: Identifiable {
    let id = UUID()
    let name: String
    let loaded: Bool
    let source: String
    let tools: Int
    let tokens: Double
    let desc: String
    let broken: Bool
    let health: McpHealthInfo

    init(name: String, loaded: Bool, source: String, tools: Int, tokens: Double, desc: String, broken: Bool = false, health: McpHealthInfo) {
        self.name = name
        self.loaded = loaded
        self.source = source
        self.tools = tools
        self.tokens = tokens
        self.desc = desc
        self.broken = broken
        self.health = health
    }
}

struct LibraryMcpDir: Identifiable {
    let id: String
    let scope: LibraryScope
    let path: String
    let label: String
    let sub: String
    let items: [LibraryMcpItem]
}

// MARK: - Fixture data

let skillDirs: [LibrarySkillDir] = [
    LibrarySkillDir(
        id: "user", scope: .user, path: "~/.claude/skills/",
        label: "User", sub: "personal \u{00B7} synced via dotfiles repo",
        items: [
            LibrarySkillItem(name: "frontend-design", isReal: true, size: "4.2K", contextK: 1.4, modified: "2d ago", desc: "Aesthetic direction for designs outside an existing brand system"),
            LibrarySkillItem(name: "make-a-deck", isReal: true, size: "6.8K", contextK: 2.1, modified: "2d ago", desc: "Slide presentation in HTML"),
            LibrarySkillItem(name: "interactive-prototype", isReal: false, target: "~/dev/skills-repo/interactive-prototype/", size: "12K", contextK: 3.6, modified: "4h ago", desc: "Working app with real interactions"),
            LibrarySkillItem(name: "wireframe", isReal: false, target: "~/dev/skills-repo/wireframe/", size: "3.4K", contextK: 1.0, modified: "4h ago", desc: "Explore many ideas with wireframes and storyboards"),
            LibrarySkillItem(name: "save-as-pdf", isReal: true, size: "1.1K", contextK: 0.4, modified: "11d ago", desc: "Print-ready PDF export"),
            LibrarySkillItem(name: "animations", isReal: true, size: "2.8K", contextK: 0.9, modified: "7d ago", desc: "Timeline-based motion design"),
        ]
    ),
    LibrarySkillDir(
        id: "project", scope: .project, path: "./.claude/skills/",
        label: "Project", sub: "scoped to ~/code/tokenbar/",
        items: [
            LibrarySkillItem(name: "tokenbar-style-guide", isReal: true, size: "5.6K", contextK: 1.7, modified: "31m ago", desc: "Repo-local style reference for the TokenBar visual system"),
            LibrarySkillItem(name: "frontend-design", isReal: true, size: "3.9K", contextK: 1.2, modified: "2h ago", desc: "Project-specific override \u{00B7} narrower scope"),
            LibrarySkillItem(name: "mock-fixtures", isReal: false, target: "~/dev/skills-repo/mock-fixtures/", size: "2.1K", contextK: 0.7, modified: "4h ago", desc: "Realistic sample data generators"),
        ]
    ),
    LibrarySkillDir(
        id: "shared", scope: .shared, path: "~/.config/agent-shared/skills/",
        label: "Shared", sub: "third-party \u{00B7} read-only",
        items: [
            LibrarySkillItem(name: "shadcn-recipes", isReal: false, target: "~/dev/community/shadcn-recipes/", size: "18K", contextK: 5.4, modified: "3w ago", desc: "shadcn component recipes & layouts"),
            LibrarySkillItem(name: "figma-importer", isReal: false, target: "~/Library/Caches/agent/_dl/figma-importer-v0.4/", size: "\u{2014}", contextK: nil, modified: "missing", desc: "Import Figma exports", broken: true),
            LibrarySkillItem(name: "db-migrations", isReal: true, size: "7.2K", contextK: 2.2, modified: "5d ago", desc: "Generate Postgres/SQLite migration scripts"),
            LibrarySkillItem(name: "make-a-deck", isReal: true, size: "5.4K", contextK: 1.6, modified: "6d ago", desc: "Older fork \u{00B7} shipped with shared bundle"),
        ]
    ),
]

private let plugins: [LibraryPluginItem] = [
    LibraryPluginItem(name: "git-context", version: "1.4.2", source: "marketplace", bundle: "6 commands \u{00B7} 2 hooks", state: "active"),
    LibraryPluginItem(name: "jira-link", version: "0.9.0", source: "marketplace", bundle: "3 commands", state: "active"),
    LibraryPluginItem(name: "vscode-bridge", version: "2.1.0", source: "local", bundle: "1 command \u{00B7} 4 hooks", state: "active"),
    LibraryPluginItem(name: "linear-tasks", version: "0.3.1", source: "marketplace", bundle: "4 commands", state: "active"),
    LibraryPluginItem(name: "k8s-debug", version: "1.0.0", source: "npm \u{00B7} @infra/k8s-debug", bundle: "7 commands \u{00B7} 1 hook", state: "active"),
    LibraryPluginItem(name: "playwright-record", version: "0.6.4", source: "marketplace", bundle: "2 commands", state: "disabled"),
    LibraryPluginItem(name: "sentry-context", version: "0.2.0", source: "marketplace", bundle: "2 commands", state: "active"),
    LibraryPluginItem(name: "sql-explain", version: "1.2.0", source: "local", bundle: "3 commands", state: "active"),
]

let mcpDirs: [LibraryMcpDir] = [
    LibraryMcpDir(
        id: "mcp-user", scope: .user, path: "~/.config/claude/mcp_servers.json",
        label: "User", sub: "global defaults \u{00B7} loaded into every project unless overridden",
        items: [
            LibraryMcpItem(name: "filesystem", loaded: true, source: "npx \u{00B7} @mcp/filesystem", tools: 14, tokens: 8.4, desc: "Local file read/write within allow-listed dirs", health: McpHealthInfo(status: .ok, latency: 18, last: "2m ago")),
            LibraryMcpItem(name: "github", loaded: true, source: "npx \u{00B7} @mcp/github", tools: 22, tokens: 21.0, desc: "Repo \u{00B7} PR \u{00B7} issue \u{00B7} actions \u{2014} scoped token", health: McpHealthInfo(status: .ok, latency: 142, last: "2m ago")),
            LibraryMcpItem(name: "postgres", loaded: true, source: "~/bin/mcp-postgres", tools: 9, tokens: 6.2, desc: "Schema introspection + read-only queries", health: McpHealthInfo(status: .degraded, latency: 824, last: "2m ago", note: "slow handshake")),
            LibraryMcpItem(name: "slack", loaded: false, source: "npx \u{00B7} @mcp/slack", tools: 8, tokens: 7.2, desc: "DMs, channels, threads", health: McpHealthInfo(status: .ok, latency: 96, last: "14m ago")),
            LibraryMcpItem(name: "notion", loaded: false, source: "npx \u{00B7} @mcp/notion", tools: 12, tokens: 18.4, desc: "Pages, databases, properties", health: McpHealthInfo(status: .unchecked, last: "never")),
            LibraryMcpItem(name: "stripe", loaded: false, source: "npx \u{00B7} @mcp/stripe", tools: 9, tokens: 11.0, desc: "Customers, subs, charges \u{2014} live mode", health: McpHealthInfo(status: .down, last: "1h ago", note: "401 \u{00B7} auth expired")),
            LibraryMcpItem(name: "sentry", loaded: false, source: "npx \u{00B7} @mcp/sentry", tools: 5, tokens: 4.4, desc: "Issues + events", health: McpHealthInfo(status: .ok, latency: 204, last: "22m ago")),
            LibraryMcpItem(name: "vercel", loaded: false, source: "local \u{00B7} ~/bin/mcp-vercel", tools: 7, tokens: 5.6, desc: "Deploys, env vars, projects", health: McpHealthInfo(status: .unchecked, last: "never")),
        ]
    ),
    LibraryMcpDir(
        id: "mcp-project", scope: .project, path: "./.claude/mcp.json",
        label: "Project", sub: "tokenbar-only \u{00B7} checked into repo \u{00B7} merged after user scope",
        items: [
            LibraryMcpItem(name: "linear", loaded: true, source: "npx \u{00B7} @mcp/linear", tools: 11, tokens: 9.8, desc: "Issues, projects, cycles, status", health: McpHealthInfo(status: .ok, latency: 78, last: "2m ago")),
            LibraryMcpItem(name: "chromium", loaded: true, source: "npx \u{00B7} @mcp/playwright", tools: 18, tokens: 24.0, desc: "Headless browser drive \u{2014} slow", health: McpHealthInfo(status: .degraded, latency: 1420, last: "2m ago", note: "high p95")),
            LibraryMcpItem(name: "figma", loaded: true, source: "npx \u{00B7} @mcp/figma", tools: 6, tokens: 14.8, desc: "Read frames, export PNG", health: McpHealthInfo(status: .ok, latency: 236, last: "2m ago")),
            LibraryMcpItem(name: "datadog", loaded: false, source: "npx \u{00B7} @mcp/datadog", tools: 10, tokens: 9.8, desc: "Metrics, dashboards, monitors", broken: true, health: McpHealthInfo(status: .down, last: "5m ago", note: "handshake failed \u{00B7} ETIMEDOUT")),
        ]
    ),
]

// MARK: - Helpers

private func duplicateNames(in dirs: [LibrarySkillDir]) -> Set<String> {
    var counts: [String: Int] = [:]
    for d in dirs {
        for item in d.items where item.isReal {
            counts[item.name, default: 0] += 1
        }
    }
    return Set(counts.filter { $0.value >= 2 }.keys)
}

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
        }
    }

    private var backgroundColor: Color {
        switch scope {
        case .user: TokenBarStyle.input.opacity(0.10)
        case .project: Color(red: 0.78, green: 0.90, blue: 0.39).opacity(0.10)
        case .shared: Color.white.opacity(0.05)
        }
    }

    private var borderColor: Color {
        switch scope {
        case .user: TokenBarStyle.input.opacity(0.30)
        case .project: Color(red: 0.78, green: 0.90, blue: 0.39).opacity(0.30)
        case .shared: Color.white.opacity(0.16)
        }
    }
}

// MARK: - Filter pills

private enum SkillFilter: String, CaseIterable {
    case all
    case real
    case symlinks
    case duplicates
    case broken
}

private struct FilterPillButton: View {
    let label: String
    let count: Int
    let isActive: Bool
    let tone: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(countBackground, in: Capsule())
                    .foregroundStyle(countForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pillBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(pillForeground)
    }

    private var pillForeground: Color {
        guard isActive else { return TokenBarStyle.faint }
        switch tone {
        case "sym": return TokenBarStyle.input
        case "dup": return Color(red: 1.0, green: 0.71, blue: 0.33)
        case "err": return Color(red: 0.89, green: 0.42, blue: 0.42)
        default: return TokenBarStyle.foreground
        }
    }

    private var pillBackground: Color {
        guard isActive else { return .clear }
        switch tone {
        case "sym": return TokenBarStyle.input.opacity(0.12)
        case "dup": return Color(red: 1.0, green: 0.71, blue: 0.33).opacity(0.12)
        case "err": return Color(red: 0.89, green: 0.42, blue: 0.42).opacity(0.12)
        default: return Color.white.opacity(0.08)
        }
    }

    private var countBackground: Color {
        guard isActive else { return Color.white.opacity(0.04) }
        switch tone {
        case "sym": return TokenBarStyle.input.opacity(0.22)
        case "dup": return Color(red: 1.0, green: 0.71, blue: 0.33).opacity(0.22)
        case "err": return Color(red: 0.89, green: 0.42, blue: 0.42).opacity(0.22)
        default: return Color.white.opacity(0.10)
        }
    }

    private var countForeground: Color {
        guard isActive else { return TokenBarStyle.faint }
        switch tone {
        case "sym": return TokenBarStyle.input
        case "dup": return Color(red: 1.0, green: 0.71, blue: 0.33)
        case "err": return Color(red: 0.89, green: 0.42, blue: 0.42)
        default: return .white
        }
    }
}

// MARK: - Library Tab Selector

private struct LibraryTabSelector: View {
    let selectedTab: LibraryTab
    let onSelect: (LibraryTab) -> Void

    private var totalSkills: Int { skillDirs.reduce(0) { $0 + $1.items.count } }
    private var totalPlugins: Int { plugins.count }
    private var allMcp: [LibraryMcpItem] { mcpDirs.flatMap(\.items) }
    private var loadedMcp: Int { allMcp.filter(\.loaded).count }
    private var loadedTokens: Double { allMcp.filter(\.loaded).reduce(0) { $0 + $1.tokens } }

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
                meta: "\(plugins.filter { $0.state == "active" }.count) active"
            )
            tabItem(
                tab: .mcp,
                icon: "circle.grid.cross",
                label: "MCP",
                count: allMcp.count,
                meta: "\(loadedMcp) loaded \u{00B7} \(String(format: "%.1f", loadedTokens))K"
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

// MARK: - Skill row

private struct LibrarySkillRow: View {
    let item: LibrarySkillItem
    let isDuplicate: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isReal ? "doc" : "arrow.up.right")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(item.broken ? TokenBarStyle.error : (item.isReal ? TokenBarStyle.muted : TokenBarStyle.input))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.broken ? TokenBarStyle.error : TokenBarStyle.foreground)
                        .lineLimit(1)

                    if isDuplicate {
                        duplicatePill
                    }

                    if !item.isReal {
                        HStack(spacing: 4) {
                            Text("\u{2192}")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TokenBarStyle.input)
                            Text(item.target ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(item.broken ? TokenBarStyle.error : TokenBarStyle.input)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    (item.broken ? TokenBarStyle.error : TokenBarStyle.input).opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                                .lineLimit(1)
                        }
                    }

                    if item.broken {
                        brokenPill
                    }
                }

                Text(item.desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            costCell

            HStack(spacing: 6) {
                iconButton(systemName: "folder", tooltip: "Open in Finder")
                textButton(label: "Move", tooltip: "Move\u{2026}")
                iconButton(systemName: "trash", tooltip: "Delete", isDanger: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            TokenBarStyle.line.frame(height: 1)
                .padding(.leading, 46)
        }
    }

    private var costCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let ctx = item.contextK {
                HStack(spacing: 0) {
                    Text(String(format: "%.1f", ctx))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("K")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
            } else {
                Text("\u{2014}")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }
            Text("ctx")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)
            HStack(spacing: 0) {
                Text(item.size)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                Text(" on disk")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TokenBarStyle.faint.opacity(0.7))
            }
        }
        .frame(width: 80, alignment: .trailing)
    }

    private var duplicatePill: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 8, weight: .semibold))
            Text("duplicate name")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.71, blue: 0.33))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color(red: 1.0, green: 0.71, blue: 0.33).opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color(red: 1.0, green: 0.71, blue: 0.33).opacity(0.25), lineWidth: 1))
    }

    private var brokenPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 8, weight: .semibold))
            Text("target missing")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(TokenBarStyle.error)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(TokenBarStyle.error.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(TokenBarStyle.error.opacity(0.25), lineWidth: 1))
    }

    private func iconButton(systemName: String, tooltip: String, isDanger: Bool = false) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDanger ? TokenBarStyle.error : TokenBarStyle.muted)
        .help(tooltip)
    }

    private func textButton(label: String, tooltip: String) -> some View {
        Button {} label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(TokenBarStyle.muted)
        .help(tooltip)
    }
}

// MARK: - Skill directory card (collapsible)

private struct SkillDirCard: View {
    let dir: LibrarySkillDir
    let dupNames: Set<String>
    let filter: SkillFilter
    @State private var isOpen = true

    private var filteredItems: [LibrarySkillItem] {
        dir.items.filter { item in
            switch filter {
            case .all: true
            case .real: item.isReal
            case .symlinks: !item.isReal
            case .duplicates: item.isReal && dupNames.contains(item.name)
            case .broken: item.broken
            }
        }
    }

    var body: some View {
        if filter != .all && filteredItems.isEmpty { EmptyView() } else {
            VStack(spacing: 0) {
                directoryHeader
                if isOpen {
                    ForEach(filteredItems) { item in
                        LibrarySkillRow(item: item, isDuplicate: item.isReal && dupNames.contains(item.name))
                    }
                }
            }
            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
    }

    private var directoryHeader: some View {
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

                dirCounts

                Button {} label: {
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

    private var dirCounts: some View {
        let total = dir.items.count
        let real = dir.items.filter(\.isReal).count
        let sym = total - real
        let ctxTotal = dir.items.reduce(0.0) { $0 + ($1.contextK ?? 0) }
        let brokenCt = dir.items.filter(\.broken).count
        return HStack(spacing: 4) {
            countChip("\(total)", label: "total", color: TokenBarStyle.muted)
            sepDot
            countChip("\(real)", label: "real", color: TokenBarStyle.foreground)
            sepDot
            countChip("\(sym)", label: "symlink", color: TokenBarStyle.input)
            sepDot
            countChip(String(format: "%.1f", ctxTotal), label: "K ctx", color: TokenBarStyle.cost)
            if brokenCt > 0 {
                sepDot
                countChip("\(brokenCt)", label: "broken", color: TokenBarStyle.error)
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

// MARK: - Skills tab body

private struct SkillsBody: View {
    @State private var viewMode: LibraryViewMode = .graph
    @State private var filter: SkillFilter = .all
    @State private var searchText = ""

    private var dupNames: Set<String> { duplicateNames(in: skillDirs) }
    private var total: Int { skillDirs.reduce(0) { $0 + $1.items.count } }
    private var realCount: Int { skillDirs.reduce(0) { $0 + $1.items.filter(\.isReal).count } }
    private var symCount: Int { total - realCount }
    private var dupCount: Int { skillDirs.reduce(0) { $0 + $1.items.filter { $0.isReal && dupNames.contains($0.name) }.count } }
    private var brokenCount: Int { skillDirs.reduce(0) { $0 + $1.items.filter(\.broken).count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryModeBar(
                title: viewMode == .graph ? "Skill constellation" : "All skills",
                subtitle: viewMode == .graph
                    ? "hover a node to preview \u{00B7} click to inspect \u{00B7} \u{2318} click to pin"
                    : "flat list of every skill TokenBar found on disk \u{00B7} use filters to drill down",
                mode: viewMode,
                onChange: { viewMode = $0 }
            )

            if viewMode == .graph {
                SkillsConstellationView()
            } else {
                toolbar
                ForEach(skillDirs) { dir in
                    SkillDirCard(dir: dir, dupNames: dupNames, filter: filter)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField(placeholder: "Search \(total) skills\u{2026}")
            filterSegment
            Spacer()
            ghostButton(icon: "arrow.clockwise", label: "Rescan")
            primaryButton(icon: "plus", label: "Add symlink\u{2026}")
        }
        .padding(.vertical, 4)
    }

    private var filterSegment: some View {
        HStack(spacing: 0) {
            FilterPillButton(label: "All", count: total, isActive: filter == .all, tone: "") { filter = .all }
            FilterPillButton(label: "Real", count: realCount, isActive: filter == .real, tone: "") { filter = .real }
            FilterPillButton(label: "Symlinks", count: symCount, isActive: filter == .symlinks, tone: "sym") { filter = .symlinks }
            FilterPillButton(label: "Duplicates", count: dupCount, isActive: filter == .duplicates, tone: "dup") { filter = .duplicates }
            FilterPillButton(label: "Broken", count: brokenCount, isActive: filter == .broken, tone: "err") { filter = .broken }
        }
        .padding(2)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }
}

// MARK: - Plugin row

private struct LibraryPluginRow: View {
    let plugin: LibraryPluginItem

    private var isDisabled: Bool { plugin.state == "disabled" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "powerplug")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(isDisabled ? TokenBarStyle.faint.opacity(0.5) : TokenBarStyle.muted)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(isDisabled ? TokenBarStyle.faint : TokenBarStyle.foreground)
                        .lineLimit(1)
                    Text("v\(plugin.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                    if isDisabled {
                        Text("disabled")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.faint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.04), in: Capsule())
                            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
                    }
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

            HStack(spacing: 6) {
                Button {} label: {
                    Text(isDisabled ? "Enable" : "Disable")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)

                Button {} label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            TokenBarStyle.line.frame(height: 1)
                .padding(.leading, 46)
        }
    }
}

// MARK: - Plugins tab body

private struct PluginsBody: View {
    @State private var pluginFilter = "all"

    private var filtered: [LibraryPluginItem] {
        switch pluginFilter {
        case "active": plugins.filter { $0.state == "active" }
        case "disabled": plugins.filter { $0.state == "disabled" }
        default: plugins
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            VStack(spacing: 0) {
                ForEach(filtered) { plugin in
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
            segmentedPicker
            Spacer()
            ghostButton(icon: "arrow.clockwise", label: "Rescan")
        }
        .padding(.vertical, 4)
    }

    private var segmentedPicker: some View {
        HStack(spacing: 0) {
            segButton("All", id: "all")
            segButton("Active", id: "active")
            segButton("Disabled", id: "disabled")
        }
        .padding(2)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func segButton(_ label: String, id: String) -> some View {
        Button { pluginFilter = id } label: {
            Text(label)
                .font(.system(size: 11.5, weight: pluginFilter == id ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(pluginFilter == id ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(pluginFilter == id ? TokenBarStyle.foreground : TokenBarStyle.faint)
    }
}

// MARK: - MCP context cost ribbon

private struct McpContextRibbon: View {
    let loaded: Int
    let total: Int
    let tokens: Double
    let budget: Double = 128

    private var pct: Double { min(100, (tokens / budget) * 100) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 22) {
                    kpiBlock(
                        value: Text("\(loaded)").foregroundStyle(TokenBarStyle.foreground) + Text("/\(total)").foregroundStyle(TokenBarStyle.faint),
                        label: "loaded"
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

                HStack(spacing: 8) {
                    ghostButton(icon: "arrow.clockwise", label: "Reload all")
                    ghostButton(icon: nil, label: "Unload all")
                }
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

// MARK: - MCP health pill

private struct McpHealthPill: View {
    let health: McpHealthInfo

    private var statusLabel: String {
        switch health.status {
        case .ok: "reachable"
        case .degraded: "slow"
        case .down: "unreachable"
        case .unchecked: "not checked"
        }
    }

    private var dotColor: Color {
        switch health.status {
        case .ok: Color(red: 0.30, green: 0.78, blue: 0.55)
        case .degraded: Color(red: 0.91, green: 0.72, blue: 0.43)
        case .down: TokenBarStyle.error
        case .unchecked: TokenBarStyle.faint
        }
    }

    private var pillBg: Color {
        switch health.status {
        case .ok: Color(red: 0.30, green: 0.78, blue: 0.55).opacity(0.08)
        case .degraded: Color(red: 0.91, green: 0.72, blue: 0.43).opacity(0.08)
        case .down: TokenBarStyle.error.opacity(0.08)
        case .unchecked: Color.white.opacity(0.03)
        }
    }

    private var pillBorder: Color {
        switch health.status {
        case .ok: Color(red: 0.30, green: 0.78, blue: 0.55).opacity(0.25)
        case .degraded: Color(red: 0.91, green: 0.72, blue: 0.43).opacity(0.25)
        case .down: TokenBarStyle.error.opacity(0.25)
        case .unchecked: TokenBarStyle.line
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(dotColor)
            if let latency = health.latency {
                Text("\(latency)ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(dotColor.opacity(0.8))
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(pillBg, in: Capsule())
        .overlay(Capsule().stroke(pillBorder, lineWidth: 1))
        .help(health.note.map { "\(statusLabel) \u{00B7} \($0) \u{00B7} checked \(health.last)" } ?? "\(statusLabel) \u{00B7} checked \(health.last)")
    }
}

// MARK: - MCP row

private struct LibraryMcpRow: View {
    let item: LibraryMcpItem

    var body: some View {
        HStack(spacing: 12) {
            toggleSwitch

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.loaded ? TokenBarStyle.foreground : TokenBarStyle.muted)
                        .lineLimit(1)
                    McpHealthPill(health: item.health)
                }
                HStack(spacing: 8) {
                    Text(item.desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.loaded ? TokenBarStyle.faint : TokenBarStyle.faint.opacity(0.7))
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

            HStack(spacing: 6) {
                Button {} label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                        Text("Check")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)

                Button {} label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            TokenBarStyle.line.frame(height: 1)
                .padding(.leading, 52)
        }
    }

    private var toggleSwitch: some View {
        ZStack {
            Capsule()
                .fill(item.loaded ? TokenBarStyle.input.opacity(0.30) : Color.white.opacity(0.06))
                .overlay(Capsule().stroke(item.loaded ? TokenBarStyle.input.opacity(0.50) : TokenBarStyle.line, lineWidth: 1))
            Circle()
                .fill(item.loaded ? TokenBarStyle.input : TokenBarStyle.muted)
                .frame(width: 12, height: 12)
                .shadow(color: item.loaded ? TokenBarStyle.input.opacity(0.5) : .clear, radius: 4)
                .offset(x: item.loaded ? 7 : -7)
        }
        .frame(width: 36, height: 20)
    }

    private var mcpCostCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 0) {
                Text(String(format: "%.1f", item.tokens))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.loaded ? TokenBarStyle.foreground : TokenBarStyle.faint)
                Text("K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }
            Text("tokens")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)
            HStack(spacing: 0) {
                Text("\(item.tools)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                Text(" tools")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TokenBarStyle.faint.opacity(0.7))
            }
        }
        .frame(width: 80, alignment: .trailing)
    }
}

// MARK: - MCP scope card

private struct McpScopeCard: View {
    let dir: LibraryMcpDir
    @State private var isOpen = true

    private var onItems: [LibraryMcpItem] { dir.items.filter(\.loaded) }
    private var offItems: [LibraryMcpItem] { dir.items.filter { !$0.loaded } }
    private var loadedCount: Int { onItems.count }
    private var totalTokens: Double { onItems.reduce(0) { $0 + $1.tokens } }
    private var downCount: Int { dir.items.filter { $0.health.status == .down }.count }
    private var degradedCount: Int { dir.items.filter { $0.health.status == .degraded }.count }

    var body: some View {
        VStack(spacing: 0) {
            scopeHeader
            if isOpen {
                if !onItems.isEmpty {
                    groupLabel(
                        dot: TokenBarStyle.input,
                        label: "Loaded",
                        count: onItems.count,
                        meta: "contributing to every agent turn"
                    )
                    ForEach(onItems) { item in
                        LibraryMcpRow(item: item)
                    }
                }
                if !offItems.isEmpty {
                    groupLabel(
                        dot: TokenBarStyle.faint,
                        label: "Available \u{00B7} not loaded",
                        count: offItems.count,
                        meta: "configured but absent from context \u{2014} flip to load"
                    )
                    ForEach(offItems) { item in
                        LibraryMcpRow(item: item)
                    }
                }
            }
        }
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
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

                HStack(spacing: 6) {
                    Button {} label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .medium))
                            Text("Check all")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TokenBarStyle.muted)

                    Button {} label: {
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
            countChip("\(loadedCount)", label: "loaded", color: TokenBarStyle.foreground)
            sepDot
            countChip(String(format: "%.1f", totalTokens), label: "K ctx", color: TokenBarStyle.cost)
            if downCount > 0 {
                sepDot
                countChip("\(downCount)", label: "down", color: TokenBarStyle.error)
            }
            if degradedCount > 0 {
                sepDot
                countChip("\(degradedCount)", label: "slow", color: Color(red: 0.91, green: 0.72, blue: 0.43))
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

    private func groupLabel(dot: Color, label: String, count: Int, meta: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .shadow(color: dot == TokenBarStyle.input ? dot.opacity(0.5) : .clear, radius: 3)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.muted)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.04), in: Capsule())
            Text(meta)
                .font(.system(size: 10.5))
                .foregroundStyle(TokenBarStyle.faint)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.015))
        .overlay(alignment: .top) { TokenBarStyle.line.frame(height: 1) }
    }
}

// MARK: - MCP tab body

private struct MCPBody: View {
    @State private var viewMode: LibraryViewMode = .graph
    @State private var mcpFilter = "all"

    private var allItems: [LibraryMcpItem] { mcpDirs.flatMap(\.items) }
    private var loadedItems: [LibraryMcpItem] { allItems.filter(\.loaded) }
    private var ctxTokens: Double { loadedItems.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryModeBar(
                title: viewMode == .graph ? "MCP solar system" : "All MCP servers",
                subtitle: viewMode == .graph
                    ? "the dashed ring is your context window \u{00B7} inside = loaded \u{00B7} outside = configured-but-idle"
                    : "by scope \u{00B7} toggle to load into context",
                mode: viewMode,
                onChange: { viewMode = $0 }
            )

            if viewMode == .graph {
                McpSolarSystemView()
            } else {
                McpContextRibbon(loaded: loadedItems.count, total: allItems.count, tokens: ctxTokens)
                toolbar
                ForEach(mcpDirs) { dir in
                    McpScopeCard(dir: dir)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField(placeholder: "Search \(allItems.count) servers\u{2026}")
            segmentedPicker
            Spacer()
            primaryButton(icon: "plus", label: "Add server\u{2026}")
        }
        .padding(.vertical, 4)
    }

    private var segmentedPicker: some View {
        HStack(spacing: 0) {
            segButton("All", id: "all")
            segButton("Loaded", id: "loaded")
            segButton("Available", id: "available")
            segButton("Broken", id: "broken")
        }
        .padding(2)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func segButton(_ label: String, id: String) -> some View {
        Button { mcpFilter = id } label: {
            Text(label)
                .font(.system(size: 11.5, weight: mcpFilter == id ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(mcpFilter == id ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(mcpFilter == id ? TokenBarStyle.foreground : TokenBarStyle.faint)
    }
}

// MARK: - Shared toolbar helpers

@MainActor private func searchField(placeholder: String) -> some View {
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
    .frame(maxWidth: 260)
}

@MainActor private func ghostButton(icon: String?, label: String) -> some View {
    Button {} label: {
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
    @State private var selectedTab: LibraryTab = .skills

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            pageHeader
            LibraryTabSelector(selectedTab: selectedTab, onSelect: { selectedTab = $0 })
            switch selectedTab {
            case .skills:
                SkillsBody()
            case .plugins:
                PluginsBody()
            case .mcp:
                MCPBody()
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Skills, prompt templates, plugins, and MCP servers TokenBar can see on disk \u{2014} and what\u{2019}s currently loaded into agent context.")
                .font(.system(size: 13))
                .foregroundStyle(TokenBarStyle.muted)
        }
    }
}
