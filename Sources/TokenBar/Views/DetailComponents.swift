import AppKit
import SwiftUI
import TokenBarCore

// MARK: - Shared helpers for Source / Model drill-in pages (design §03b / §03c)

/// Resolve the **source** a usage event belongs to. Built-in events map to
/// their agent's display name; custom-source events (id prefixed
/// `custom:<recordId>:`) carry the *underlying* plugin's agent, so grouping by
/// `agent.displayName` would collapse every custom source into e.g. "Claude
/// Code". Instead we recover the configured source's user-given name from the
/// id prefix, so each custom source the user added is its own source entry.
func tokenbarSourceName(for event: UsageEvent, customNamesById: [String: String]) -> String {
    if event.id.hasPrefix("custom:") {
        let parts = event.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2, let name = customNamesById[String(parts[1])] {
            return name
        }
    }
    return event.agent.displayName
}

/// All-time source rankings as `UsageBreakdown` rows for the sidebar Sources
/// tab — one row per configured source (built-in agent or named custom source).
func tokenbarSourceBreakdowns(events: [UsageEvent], customNamesById: [String: String]) -> [UsageBreakdown] {
    Dictionary(grouping: events) { tokenbarSourceName(for: $0, customNamesById: customNamesById) }
        .map { name, grouped in UsageBreakdown(name: name, summary: tokenbarSummary(grouped)) }
        .filter { $0.summary.totalTokens > 0 }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
}

/// Share of tokens by project, as donut slices reusing `AgentShareSlice`
/// (name + tokens + percentage). `TokenBarDonut`/`agentColor` key off `name`,
/// so project names get their own stable colors automatically.
func tokenbarProjectShare(events: [UsageEvent], topCount: Int = 5) -> [AgentShareSlice] {
    let total = tokenbarSummary(events).totalTokens
    guard total > 0 else { return [] }
    return Dictionary(grouping: events, by: \.projectName)
        .map { name, grouped in
            let tokens = tokenbarSummary(grouped).totalTokens
            return AgentShareSlice(name: name, totalTokens: tokens, percentage: Double(tokens) / Double(total))
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens == rhs.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.totalTokens > rhs.totalTokens
        }
        .prefix(topCount)
        .map { $0 }
}

/// Recent session row for the Source / Model pages. Unlike the Project page's
/// `ProjectSessionSummary` (which shows the agent), these show the project the
/// session ran in plus a secondary tag — the model (on a Source page) or the
/// source (on a Model page).
struct DetailSessionSummary: Identifiable, Sendable, Hashable {
    enum Tag: Sendable, Hashable { case model, source }

    let sessionId: String
    let projectName: String
    let tag: String
    let timestamp: Date
    let summary: UsageSummary

    var id: String { sessionId }

    static func make(events: [UsageEvent], tag: Tag, limit: Int = 6) -> [DetailSessionSummary] {
        Dictionary(grouping: events, by: \.sessionId)
            .compactMap { sessionId, grouped -> DetailSessionSummary? in
                guard let latest = grouped.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                let tagText: String
                switch tag {
                case .model:
                    tagText = latest.modelName?.isEmpty == false ? latest.modelName! : latest.agent.displayName
                case .source:
                    tagText = latest.agent.displayName
                }
                return DetailSessionSummary(
                    sessionId: sessionId,
                    projectName: latest.projectName,
                    tag: tagText,
                    timestamp: latest.timestamp,
                    summary: tokenbarSummary(grouped)
                )
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.summary.totalTokens > rhs.summary.totalTokens
                }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(limit)
            .map { $0 }
    }
}

/// Donut + legend card. Slices are clickable when `onSelect` is provided
/// (used for Project Share, which drills into the project page).
struct ShareDonutCard: View {
    let title: String
    let slices: [AgentShareSlice]
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 22) {
                    TokenBarDonut(slices: slices)
                        .frame(width: 150, height: 150)
                    VStack(spacing: 9) {
                        if slices.isEmpty {
                            Text("No share available in this window.")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(slices.prefix(5)) { slice in
                                Button {
                                    onSelect?(slice.name)
                                } label: {
                                    HStack(spacing: 9) {
                                        Circle()
                                            .fill(TokenBarStyle.agentColor(slice.name))
                                            .frame(width: 7, height: 7)
                                        Text(slice.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .foregroundStyle(TokenBarStyle.foreground)
                                        Spacer()
                                        Text(tokenbarPercent(slice.percentage))
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(TokenBarStyle.muted)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .allowsHitTesting(onSelect != nil)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 246, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 286)
    }
}

/// Recent-sessions card used by Source / Model pages. Each row shows the
/// timestamp, project, the secondary tag (model or source), and tokens, with
/// an expandable in/out/cache drawer.
struct SourceModelSessionsCard: View {
    let sessions: [DetailSessionSummary]
    @Binding var expandedSession: String?

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if sessions.isEmpty {
                    Text("No sessions in the current window.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    ForEach(sessions.prefix(6)) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedSession = expandedSession == session.sessionId ? nil : session.sessionId
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(TokenBarStyle.agentColor(session.tag))
                                        .frame(width: 7, height: 7)
                                    Text(session.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.muted)
                                        .frame(width: 92, alignment: .leading)
                                    Text(session.projectName)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(session.tag)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                        .frame(width: 104, alignment: .leading)
                                    Text(tokenbarTokens(session.summary.totalTokens))
                                        .font(.system(size: 13, design: .monospaced))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(width: 64, alignment: .trailing)
                                    Image(systemName: expandedSession == session.sessionId ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .frame(width: 12, alignment: .trailing)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            if expandedSession == session.sessionId {
                                HStack(spacing: 18) {
                                    sessionStat("Input", value: session.summary.inputTokens, color: TokenBarStyle.input)
                                    sessionStat("Output", value: session.summary.outputTokens, color: TokenBarStyle.output)
                                    sessionStat("Cache", value: session.summary.cacheTokens, color: TokenBarStyle.cache)
                                    Spacer()
                                    Text(session.sessionId)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 5)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionStat(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(TokenBarStyle.faint)
            Text(tokenbarTokens(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

/// Back chevron used by the Source / Model detail headers. Same affordance as
/// the Project page's `HoverableBackButton` (which is file-private there).
struct HoverableDetailBackButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 11, height: 11)
                Text("Back")
                    .font(.caption)
            }
            .foregroundStyle(hovered ? TokenBarStyle.foreground : TokenBarStyle.faint)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut(.escape, modifiers: [])
    }
}
