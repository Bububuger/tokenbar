import AppKit
import SwiftUI
import TokenBarCore

struct PopoverView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.openWindow) private var openWindowAction
    @Environment(\.dismiss) private var dismissPopover
    @State private var selectedTab: PopoverTab = .projects
    // CL-P0-004: Popover Hero status pill mirrors menubar pause flag.
    @AppStorage("tokenbar.menuBarPaused") private var isPaused = false
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    // CL-P0-013: which PopKPI ("In" / "Out" / "Cache") is expanded inline.
    @State private var expandedPopKPI: String?

    private enum PopoverTab: String, CaseIterable, Identifiable {
        case projects = "Projects"
        case agents = "Agents"
        case models = "Models"

        var id: String { rawValue }
    }

    private enum PopoverRankingRowKind {
        case project
        case agent
        case model
    }

    var body: some View {
        ZStack {
            TokenBarPopoverBackground()
            VStack(alignment: .leading, spacing: 0) {
                // CL-P0-026: brief banner shown when the runtime fires its
                // post-midnight refresh. Auto-hides after 1.5s.
                if let changed = runtimeModel.dayChangedAt,
                   Date().timeIntervalSince(changed) < 1.5 {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.and.horizon.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.accent)
                        Text("Day changed — refreshing…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(TokenBarStyle.accent.opacity(0.12), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
                hero
                Divider().padding(.vertical, 10)
                todayBreakdown
                Divider().padding(.vertical, 10)
                activity
                Divider().padding(.vertical, 10)
                rankings
                Divider().padding(.vertical, 8)
                footer
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 372)
        .foregroundStyle(TokenBarStyle.foreground)
        .onAppear {
            let started = Date()
            TokenBarTelemetry.mark(
                "popover.appear.begin",
                metadata: "events=\(popover.eventsCount) refresh_state=\(runtimeModel.refreshState)"
            )
            runtimeModel.updateRefreshState()
            TokenBarTelemetry.timing(
                "popover.appear",
                startedAt: started,
                metadata: "events=\(popover.eventsCount)",
                success: true
            )
            Task { @MainActor in
                await Task.yield()
                TokenBarTelemetry.timing(
                    "popover.first_runloop",
                    startedAt: started,
                    metadata: "events=\(popover.eventsCount) refresh_state=\(runtimeModel.refreshState)"
                )
                try? await Task.sleep(for: .milliseconds(16))
                TokenBarTelemetry.timing(
                    "popover.first_frame_plus_16ms",
                    startedAt: started,
                    metadata: "events=\(popover.eventsCount) refresh_state=\(runtimeModel.refreshState)"
                )
            }
        }
    }

    private var popover: TokenBarPopoverSnapshot {
        runtimeModel.popoverSnapshot
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 10) {
            TokenBarBrandGlyph(size: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("TokenBar")
                    .font(.headline)
                Text("Updated \(tokenbarRelativeTime(popover.lastIndexedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(tokenbarCompactTokens(popover.today.totalTokens))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .tbNumberTooltip(precise: popover.today.totalTokens, window: "today")
                Text("\(popover.todaySessionCount) sessions · \(tokenbarCompactCurrency(popover.todayCost))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .tbNumberTooltip(precise: popover.todayCost, window: "today (est.)")
            }

            VStack(alignment: .trailing, spacing: 6) {
                TokenBarNativeStatusBadge(
                    text: isPaused ? "Paused" : runtimeModel.refreshState.rawValue.capitalized,
                    color: isPaused ? TokenBarStyle.warn : TokenBarStyle.statusColor(for: runtimeModel.refreshState)
                )

                Button {
                    TokenBarTelemetry.event("popover.refresh.click", success: true)
                    Task { await runtimeModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(isPaused)
                .rotationEffect(.degrees(runtimeModel.refreshState == .refreshing ? 360 : 0))
                .animation(runtimeModel.refreshState == .refreshing
                           ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                           : .default,
                           value: runtimeModel.refreshState)
                .help(isPaused ? "Paused — resume from the menubar to refresh" : "Refresh now")
            }
        }
    }

    private var todayBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(popover.yesterdayDeltaText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                popKpiCard("In", value: popover.today.inputTokens, pct: popover.inputShare, color: TokenBarStyle.input)
                popKpiCard("Out", value: popover.today.outputTokens, pct: popover.outputShare, color: TokenBarStyle.output)
                popKpiCard("Cache", value: popover.today.cacheTokens, pct: popover.cacheShare, color: TokenBarStyle.cache)
            }
            // CL-P0-013: clicking a PopKPI expands a mini detail row showing
            // today / yesterday / 7d-avg below the bar — collapses on second
            // click or by tapping any other PopKPI.
            if let expandedPopKPI {
                TokenBarKPIDetailDrawer(
                    title: expandedPopKPI,
                    today: popKpiToday(expandedPopKPI),
                    yesterday: popKpiYesterday(expandedPopKPI),
                    sevenDayAverage: popKpiSevenDayAverage(expandedPopKPI),
                    cost: nil,
                    onClose: { withAnimation(.easeOut(duration: 0.18)) { self.expandedPopKPI = nil } }
                )
            }
            InputOutputCacheBar(summary: popover.today, height: 4)
        }
    }

    private func popKpiCard(_ title: String, value: Int, pct: String, color: Color) -> some View {
        PopKPI(
            title: title,
            value: tokenbarCompactTokens(value),
            pct: pct,
            color: color,
            preciseValue: value,
            onTap: {
                withAnimation(.easeOut(duration: 0.18)) {
                    expandedPopKPI = (expandedPopKPI == title) ? nil : title
                }
            },
            isExpanded: expandedPopKPI == title
        )
    }

    private func popKpiToday(_ title: String) -> Int {
        switch title {
        case "In":    return runtimeModel.snapshot.today.inputTokens
        case "Out":   return runtimeModel.snapshot.today.outputTokens
        case "Cache": return runtimeModel.snapshot.today.cacheTokens
        default:      return runtimeModel.snapshot.today.totalTokens
        }
    }
    private func popKpiYesterday(_ title: String) -> Int {
        guard runtimeModel.snapshot.last30Days.count >= 2 else { return 0 }
        let y = runtimeModel.snapshot.last30Days[runtimeModel.snapshot.last30Days.count - 2]
        switch title {
        case "In":    return y.summary.inputTokens
        case "Out":   return y.summary.outputTokens
        case "Cache": return y.summary.cacheTokens
        default:      return y.summary.totalTokens
        }
    }
    private func popKpiSevenDayAverage(_ title: String) -> Int {
        let window = Array(runtimeModel.snapshot.last30Days.suffix(7))
        guard !window.isEmpty else { return 0 }
        let sum: Int
        switch title {
        case "In":    sum = window.reduce(0) { $0 + $1.summary.inputTokens }
        case "Out":   sum = window.reduce(0) { $0 + $1.summary.outputTokens }
        case "Cache": sum = window.reduce(0) { $0 + $1.summary.cacheTokens }
        default:      sum = window.reduce(0) { $0 + $1.summary.totalTokens }
        }
        return sum / window.count
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(popover.hourlyActivityText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("By hour")
                .font(.caption)
                .foregroundStyle(.secondary)
            HourlyHeatmapView(hours: popover.hourly.hoursOfDay, showAxis: false)

            HStack {
                Text("Last 30 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HeatLegend()
            }
            UsageStackedBarChart(days: popover.last30Days, height: 38)
            HStack {
                Text(popover.last30Days.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                Spacer()
                Text("peak \(popover.peakDay?.formatted(.dateTime.month(.abbreviated).day()) ?? "n/a")")
                Spacer()
                Text(popover.last30Days.last?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(TokenBarStyle.faint)
        }
    }

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Rankings · 30d")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Ranking", selection: $selectedTab) {
                    ForEach(PopoverTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 205)
                .onChange(of: selectedTab) { _, tab in
                    TokenBarTelemetry.event("popover.ranking_tab.change", metadata: "tab=\(tab.rawValue)", success: true)
                }
            }

            VStack(spacing: 0) {
                switch selectedTab {
                case .projects:
                    ForEach(Array(popover.projectRows.enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            kind: .project,
                            index: index,
                            name: row.name,
                            subtitle: row.subtitle,
                            value: tokenbarCompactTokens(row.summary.totalTokens),
                            cost: tokenbarCompactCurrency(row.cost),
                            badge: nil,
                            summary: row.summary,
                            color: TokenBarStyle.input
                        ) {
                            runtimeModel.openProject(named: row.name)
                            openMain(route: .project(row.name))
                        }
                    }
                case .agents:
                    ForEach(Array(popover.agentRows.enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            kind: .agent,
                            index: index,
                            name: row.name,
                            subtitle: row.subtitle,
                            value: tokenbarCompactTokens(row.summary.totalTokens),
                            cost: tokenbarCompactCurrency(row.cost),
                            badge: row.badge,
                            summary: nil,
                            color: TokenBarStyle.agentColor(row.name),
                            action: nil
                        )
                    }
                case .models:
                    ForEach(Array(popover.modelRows.enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            kind: .model,
                            index: index,
                            name: row.name,
                            subtitle: row.subtitle,
                            value: tokenbarCompactTokens(row.summary.totalTokens),
                            cost: tokenbarCompactCurrency(row.cost),
                            badge: row.badge,
                            summary: nil,
                            color: TokenBarStyle.agentColor(row.agentName ?? row.name),
                            action: nil
                        )
                    }
                    if popover.modelRows.isEmpty {
                        Text("No model attribution yet.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openMain(route: .today)
            } label: {
                Label("Open Details", systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            // CL-P2-003: when there are zero warnings, the footer chip
            // collapses to a `quaternaryLabel` color and is no longer
            // clickable — avoids drawing attention to a healthy state.
            Group {
                if popover.warningCount == 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                            .frame(width: 6, height: 6)
                        Text("0")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        Text("warnings")
                            .font(.caption)
                    }
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                } else {
                    Button { openMain(route: .diagnostics) } label: {
                        Label("\(popover.warningCount) warnings", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(TokenBarStyle.warn)
                }
            }
        }
    }

    private func openMain(route: TokenBarMainRoute) {
        let started = Date()
        runtimeModel.mainRoute = route
        dismissPopover()
        openWindowAction(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        TokenBarTelemetry.event(
            "popover.open_main",
            metadata: "route=\(route)",
            success: true,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private func rankingRow(
        kind: PopoverRankingRowKind,
        index: Int,
        name: String,
        subtitle: String,
        value: String,
        cost: String,
        badge: String?,
        summary: UsageSummary?,
        color: Color,
        action: (() -> Void)?
    ) -> some View {
        return Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .regular))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(width: 66, alignment: .trailing)
                        .tbTooltip("\(name) · \(value) tokens")
                    if kind == .project, let summary {
                        InputOutputCacheBar(summary: summary, height: 3)
                            .frame(width: 66)
                    } else if let badge, kind == .model {
                        Text(badge)
                            .font(.system(size: 8.8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.cache)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TokenBarStyle.cache.opacity(0.11), in: Capsule())
                    } else if let badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                            .lineLimit(1)
                    }
                }
                .frame(width: 68, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cost.isEmpty ? "—" : cost)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(cost.isEmpty ? TokenBarStyle.faint : TokenBarStyle.cost)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(width: 62, alignment: .trailing)
                        .tbTooltip("\(name) · estimated cost \(cost.isEmpty ? "n/a" : cost)")
                }
                .frame(width: 62, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(action != nil)
        .overlay(Divider(), alignment: .bottom)
        .help("\(name)\n\(subtitle)")
    }

}

struct PopKPI: View {
    let title: String
    let value: String
    let pct: String
    let color: Color
    var preciseValue: Int? = nil
    var onTap: (() -> Void)? = nil
    var isExpanded: Bool = false

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
                    .help("Toggle In/Out/Cache mini detail")
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(TokenBarStyle.muted)
                Spacer()
                // CL-P2-002: trailing-aligned with fixed minWidth so the %
                // glyph lines up across In / Out / Cache cards regardless of
                // 1-/2-/3-digit values.
                Text(pct)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            Group {
                if let preciseValue {
                    Text(value).tbNumberTooltip(precise: preciseValue, window: "today")
                } else {
                    Text(value)
                }
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if isExpanded {
                Rectangle()
                    .fill(TokenBarStyle.accent.opacity(0.55))
                    .frame(height: 1)
            }
        }
    }
}

private struct TokenBarNativeStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}
