import AppKit
import SwiftUI
import TokenBarCore

struct PopoverView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.openWindow) private var openWindowAction
    @State private var selectedTab: PopoverTab = .projects
    // CL-P0-004: Popover Hero status pill mirrors menubar pause flag.
    @AppStorage("tokenbar.menuBarPaused") private var isPaused = false
    // CL-P0-013: which PopKPI ("In" / "Out" / "Cache") is expanded inline.
    @State private var expandedPopKPI: String?

    private enum PopoverTab: String, CaseIterable, Identifiable {
        case projects = "Projects"
        case agents = "Agents"
        case models = "Models"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            TokenBarGlassBackground()
            VStack(alignment: .leading, spacing: 10) {
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
                    .transition(.opacity)
                }
                hero
                todayBreakdown
                activity
                rankings
                footer
            }
            .padding(12)
        }
        .frame(width: 360, height: 760)
        .foregroundStyle(TokenBarStyle.foreground)
        .task { await runtimeModel.bootstrapIfNeeded() }
        .onAppear { runtimeModel.updateRefreshState() }
    }

    private var hero: some View {
        TokenBarCard(padding: 13) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.muted)
                    // CL-P1-004: split unit suffix into 13pt faint glyph.
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        let split = tokenbarSplitStagedTokens(runtimeModel.snapshot.today.totalTokens)
                        Text(split.number)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if !split.suffix.isEmpty {
                            Text(split.suffix)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(TokenBarStyle.faint)
                                .baselineOffset(4)
                        }
                    }
                    .tbNumberTooltip(precise: runtimeModel.snapshot.today.totalTokens, window: "today")
                    Text("\(todaySessionCount) sessions")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(TokenBarStyle.faint)
                }

                HStack(spacing: 9) {
                    TokenBarBrandGlyph(size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TokenBar")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Updated \(tokenbarRelativeTime(runtimeModel.diagnostics.lastIndexedAt))")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                        HStack(spacing: 3) {
                            // CL-P2-001: $ glyph rendered with rounded design
                            // so it matches the Hero numeric stack rather than
                            // the monospaced digits used for the value.
                            (
                                Text("$").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                + Text(tokenbarCurrency(runtimeModel.snapshot.estimatedCostToday.totalCost, maximumFractionDigits: 3).dropFirst())
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            )
                                .foregroundStyle(TokenBarStyle.cost)
                                .tbNumberTooltip(precise: runtimeModel.snapshot.estimatedCostToday.totalCost, window: "today (est.)")
                            Text("est.")
                                .font(.system(size: 10))
                                .foregroundStyle(TokenBarStyle.faint)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    // CL-P0-004: when paused, the pill overrides the refresh
                    // state badge so the whole Popover surface visibly reflects
                    // the user's pause toggle (menubar ❘❘ + Hero PAUSED).
                    if isPaused {
                        TokenBarStatusPill(text: "PAUSED", color: TokenBarStyle.warn)
                    } else {
                        TokenBarStatusPill(text: runtimeModel.refreshState.rawValue, color: TokenBarStyle.statusColor(for: runtimeModel.refreshState))
                    }
                    Button {
                        Task { await runtimeModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                            .rotationEffect(.degrees(runtimeModel.refreshState == .refreshing ? 360 : 0))
                            .animation(runtimeModel.refreshState == .refreshing
                                       ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                                       : .default,
                                       value: runtimeModel.refreshState)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPaused)
                    .help(isPaused ? "Paused — resume from the menubar to refresh" : "Refresh now")
                }
            }
        }
    }

    private var todayBreakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Today Breakdown")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TokenBarStyle.muted)
                Spacer()
                Text(yesterdayDeltaText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(yesterdayDeltaText.contains("+") ? TokenBarStyle.cache : TokenBarStyle.faint)
            }
            HStack(spacing: 6) {
                popKpiCard("In", value: runtimeModel.snapshot.today.inputTokens, pct: inputShare, color: TokenBarStyle.input)
                popKpiCard("Out", value: runtimeModel.snapshot.today.outputTokens, pct: outputShare, color: TokenBarStyle.output)
                popKpiCard("Cache", value: runtimeModel.snapshot.today.cacheTokens, pct: cacheShare, color: TokenBarStyle.cache)
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
            InputOutputCacheBar(summary: runtimeModel.snapshot.today, height: 4)
        }
    }

    private func popKpiCard(_ title: String, value: Int, pct: String, color: Color) -> some View {
        PopKPI(
            title: title,
            value: tokenbarTokens(value),
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
                Text("By hour")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(TokenBarStyle.faint)
                Spacer()
                Text(hourlyActivityText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.cache)
            }
            HourlyHeatmapView(hours: hourly.hoursOfDay, showAxis: false)

            HStack {
                Text("Last 30 days")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TokenBarStyle.muted)
                Spacer()
                HeatLegend()
            }
            UsageStackedBarChart(days: runtimeModel.snapshot.last30Days, height: 38)
            HStack {
                Text(runtimeModel.snapshot.last30Days.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                Spacer()
                Text("peak \(runtimeModel.snapshot.peakDay?.formatted(.dateTime.month(.abbreviated).day()) ?? "n/a")")
                Spacer()
                Text(runtimeModel.snapshot.last30Days.last?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(TokenBarStyle.faint)
        }
    }

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Rankings · 30d")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TokenBarStyle.muted)
                Spacer()
                Picker("", selection: $selectedTab) {
                    ForEach(PopoverTab.allCases) { tab in
                        // CL-P2-004: design canvas spec is 10.5pt mono.
                        Text(tab.rawValue)
                            .font(.system(size: 10.5, weight: .medium))
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 185)
            }

            VStack(spacing: 0) {
                switch selectedTab {
                case .projects:
                    ForEach(Array(runtimeModel.snapshot.topProjects.prefix(5).enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            index: index,
                            name: row.name,
                            subtitle: projectAgentSubtitle(row.name),
                            value: tokenbarTokens(row.summary.totalTokens),
                            cost: "",
                            badge: nil,
                            summary: row.summary,
                            color: TokenBarStyle.input
                        ) {
                            runtimeModel.openProject(named: row.name)
                            openMain(route: .project(row.name))
                        }
                    }
                case .agents:
                    ForEach(Array(runtimeModel.snapshot.topAgents.prefix(5).enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            index: index,
                            name: row.name,
                            subtitle: agentModelSubtitle(row.name),
                            value: tokenbarTokens(row.summary.totalTokens),
                            cost: "",
                            badge: shareText(row.summary.totalTokens, total: runtimeModel.snapshot.last30Summary.totalTokens),
                            summary: nil,
                            color: TokenBarStyle.agentColor(row.name),
                            action: nil
                        )
                    }
                case .models:
                    ForEach(Array(modelRows.prefix(5).enumerated()), id: \.element.id) { index, row in
                        rankingRow(
                            index: index,
                            name: row.name,
                            subtitle: row.attribution,
                            value: tokenbarTokens(row.summary.totalTokens),
                            cost: tokenbarCurrency(row.cost),
                            badge: "\(tokenbarPercent(row.cacheRatio)) cache",
                            summary: nil,
                            color: TokenBarStyle.agentColor(row.agentName),
                            action: nil
                        )
                    }
                    if modelRows.isEmpty {
                        Text("No model attribution yet.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .padding(.top, 2)
        .overlay(Divider().overlay(TokenBarStyle.line), alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openMain(route: .today)
            } label: {
                Label("Open Details", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            // CL-P2-003: when there are zero warnings, the footer chip
            // collapses to a `quaternaryLabel` color and is no longer
            // clickable — avoids drawing attention to a healthy state.
            Group {
                if warningCount == 0 {
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
                        HStack(spacing: 6) {
                            Circle()
                                .fill(TokenBarStyle.warn)
                                .frame(width: 6, height: 6)
                                .shadow(color: TokenBarStyle.warn.opacity(0.55), radius: 5)
                            Text("\(warningCount)")
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            Text("warnings")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TokenBarStyle.warn)
                }
            }
        }
        .padding(.top, 8)
        .overlay(Divider().overlay(TokenBarStyle.line), alignment: .top)
    }

    private var hourly: HourlyUsageSnapshot {
        UsageAggregator.makeHourlySnapshot(from: runtimeModel.events, referenceDate: Date(), days: 1)
    }

    private var hourlyActivityText: String {
        guard let peak = hourly.peakHourOfDay else {
            return "no peak yet"
        }
        return "peak \(String(format: "%02d:00", peak.hourOfDay)) · \(tokenbarTokens(peak.summary.totalTokens)) · \(tokenbarIdleHourRanges(hourly.hoursOfDay))"
    }

    private var warningCount: Int {
        // CL-P0-022: snapshot.warningCount is the single source of truth.
        runtimeModel.snapshot.warningCount
    }

    private var modelRows: [TokenBarModelBreakdown] {
        tokenbarModelBreakdowns(events: runtimeModel.events, days: 30)
    }

    private var todaySessionCount: Int {
        tokenbarSessionCount(runtimeModel.events)
    }

    private var yesterdayDeltaText: String {
        let calendar = Calendar(identifier: .gregorian)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else {
            return "vs yest. n/a"
        }
        let yesterdayTotal = runtimeModel.events
            .filter { calendar.isDate($0.timestamp, inSameDayAs: yesterday) }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheTokens }
        guard yesterdayTotal > 0 else {
            return "vs yest. n/a"
        }
        let delta = Double(runtimeModel.snapshot.today.totalTokens - yesterdayTotal) / Double(yesterdayTotal)
        let sign = delta >= 0 ? "+" : ""
        let percent = Int((delta * 100).rounded())
        if abs(percent) > 999 {
            return "vs yest. \(sign)>999%"
        }
        return "vs yest. \(sign)\(percent)%"
    }

    private var inputShare: String { shareText(runtimeModel.snapshot.today.inputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var outputShare: String { shareText(runtimeModel.snapshot.today.outputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var cacheShare: String { shareText(runtimeModel.snapshot.today.cacheTokens, total: runtimeModel.snapshot.today.totalTokens) }

    private func shareText(_ value: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))%"
    }

    private func projectAgentSubtitle(_ projectName: String) -> String {
        let agents = runtimeModel.events
            .filter { $0.projectName == projectName }
            .reduce(into: [String: Int]()) { totals, event in
                totals[event.agent.displayName, default: 0] += event.inputTokens + event.outputTokens + event.cacheTokens
            }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        return agents.isEmpty ? "local indexed project" : agents.joined(separator: " · ")
    }

    private func agentModelSubtitle(_ agentName: String) -> String {
        let models = runtimeModel.events
            .filter { $0.agent.displayName == agentName }
            .reduce(into: [String: Int]()) { totals, event in
                let model = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
                totals[model, default: 0] += event.inputTokens + event.outputTokens + event.cacheTokens
            }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map(\.key)
        return models.isEmpty ? "agent share" : models.joined(separator: " · ")
    }

    private func openMain(route: TokenBarMainRoute) {
        runtimeModel.mainRoute = route
        openWindowAction(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rankingRow(
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
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                    if let summary {
                        InputOutputCacheBar(summary: summary, height: 3)
                            .frame(width: 74)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                    if !cost.isEmpty {
                        Text(cost)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.cost)
                    }
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.cache)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TokenBarStyle.cache.opacity(0.10), in: Capsule())
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.55)), alignment: .bottom)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(
            isExpanded ? TokenBarStyle.accent.opacity(0.55) : TokenBarStyle.line,
            lineWidth: isExpanded ? 1.5 : 1
        ))
    }
}
