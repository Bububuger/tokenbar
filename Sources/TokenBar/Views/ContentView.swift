import AppKit
import SwiftUI
import TokenBarCore

struct ContentView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var selectedRange = "30d"
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"

    var body: some View {
        HStack(spacing: 0) {
            TokenBarSidebar(
                activeRoute: runtimeModel.mainRoute,
                projects: runtimeModel.snapshot.topProjects,
                warnings: warningCount,
                refreshState: runtimeModel.refreshState,
                lastIndexedAt: runtimeModel.diagnostics.lastIndexedAt,
                onSelectOverview: { runtimeModel.mainRoute = .today },
                onSelectDiagnostics: { runtimeModel.mainRoute = .diagnostics },
                onSelectSettings: { runtimeModel.mainRoute = .settings },
                onSelectProject: { runtimeModel.openProject(named: $0) }
            )
            .frame(width: TokenBarStyle.sidebarWidth)

            Divider()
                .overlay(TokenBarStyle.line)

            ZStack {
                TokenBarGlassBackground()
                if runtimeModel.mainRoute == .settings {
                    SettingsView()
                        .environmentObject(runtimeModel)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                            switch runtimeModel.mainRoute {
                            case .today:
                                OverviewPage(selectedRange: $selectedRange)
                                    .environmentObject(runtimeModel)
                            case .diagnostics:
                                DiagnosticsView()
                                    .environmentObject(runtimeModel)
                            case .settings:
                                EmptyView()
                            case .project(let projectName):
                                projectPage(projectName)
                            }
                        }
                        .padding(TokenBarStyle.pagePadding)
                    }
                }
            }
        }
        .frame(minWidth: 1280, minHeight: 980)
        .foregroundStyle(TokenBarStyle.foreground)
        .task { await runtimeModel.bootstrapIfNeeded() }
    }

    private var warningCount: Int {
        // CL-P0-022: snapshot.warningCount is the single source of truth.
        runtimeModel.snapshot.warningCount
    }

    @ViewBuilder
    private func projectPage(_ projectName: String) -> some View {
        ZStack(alignment: .top) {
            if let detail = runtimeModel.projectDetail, detail.projectName == projectName {
                ZStack(alignment: .bottomTrailing) {
                    ProjectDetailView(
                        detail: detail,
                        projectPath: runtimeModel.projectPath(for: projectName),
                        allTimeSummary: runtimeModel.allTimeSummary(for: projectName),
                        allTimeCost: tokenbarCostProjection(events: runtimeModel.events.filter { $0.projectName == projectName }),
                        prompts: runtimeModel.promptHistory(for: projectName),
                        events: runtimeModel.events,
                        refreshState: runtimeModel.refreshState,
                        switchState: runtimeModel.projectSwitchState?.projectName == projectName ? runtimeModel.projectSwitchState : nil,
                        todayCost: tokenbarEstimatedCost(events: runtimeModel.events, days: 1),
                        rangeCost: tokenbarEstimatedCost(events: runtimeModel.events, days: 30),
                        todayTokens: runtimeModel.snapshot.today.totalTokens,
                        totalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                        todaySessions: tokenbarSessionCount(runtimeModel.events),
                        onRefresh: { Task { await runtimeModel.refresh() } },
                        onBack: { runtimeModel.mainRoute = .today }
                    )
                    if let state = runtimeModel.projectSwitchState, state.projectName == projectName {
                        ProjectSwitchBadge(state: state)
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            } else {
                ProjectDetailPendingView(projectName: projectName)
                    .task(id: projectName) {
                        if runtimeModel.projectSwitchState?.projectName != projectName {
                            runtimeModel.openProject(named: projectName)
                        }
                    }
            }

            if let state = runtimeModel.projectSwitchState, state.projectName == projectName {
                ProjectSwitchRail(progress: state.progress)
                    .opacity(state.phase == .done ? 0 : 1)
            }
        }
    }

}

private struct ProjectDetailPendingView: View {
    let projectName: String

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("~/code/\(projectName)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
                Text(projectName)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text("Loading project detail from the local index")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 220, alignment: .top)
    }
}

struct ProjectSwitchRail: View {
    let progress: Double
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(120, proxy.size.width * CGFloat(min(max(progress, 0.05), 1.0)))
            let sweepWidth = min(width, 180)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(TokenBarStyle.accent.opacity(0.14))
                    .frame(height: 1)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                TokenBarStyle.accent.opacity(0.0),
                                TokenBarStyle.accent.opacity(0.95),
                                TokenBarStyle.lime.opacity(0.95),
                                TokenBarStyle.accent.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width, height: 2.5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.0),
                                        Color.white.opacity(0.86),
                                        TokenBarStyle.lime.opacity(0.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: sweepWidth, height: 2.5)
                            .offset(x: sweep ? max(0, width - sweepWidth) : -sweepWidth * 0.65)
                            .opacity(progress < 1 ? 0.9 : 0)
                    }
                    .shadow(color: TokenBarStyle.accent.opacity(0.6), radius: 8, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.16), value: progress)
        .onAppear {
            sweep = false
            withAnimation(.linear(duration: 0.55).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

private struct ProjectSwitchBadge: View {
    let state: ProjectSwitchState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.phase == .done ? TokenBarStyle.cache : TokenBarStyle.accent)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(TokenBarStyle.muted)
            Text(state.projectName)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(TokenBarStyle.foreground)
                .lineLimit(1)
            if state.phase == .stream {
                Text("\(Int((state.progress * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.lime)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(TokenBarStyle.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
    }

    private var label: String {
        switch state.phase {
        case .snap:
            "switching to"
        case .stream:
            "streaming"
        case .done:
            "live ·"
        }
    }
}

private struct TokenBarSidebar: View {
    let activeRoute: TokenBarMainRoute
    let projects: [UsageBreakdown]
    let warnings: Int
    let refreshState: RefreshState
    let lastIndexedAt: Date?
    let onSelectOverview: () -> Void
    let onSelectDiagnostics: () -> Void
    let onSelectSettings: () -> Void
    let onSelectProject: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    TokenBarBrandGlyph(size: 30)
                    Text("TokenBar")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }

                VStack(spacing: 6) {
                    routeRow(icon: "square.grid.2x2", title: "Overview", value: "", selected: isOverview, action: onSelectOverview)
                    routeRow(icon: "waveform.path.ecg", title: "Diagnostics", value: warnings > 0 ? "\(warnings)" : "", selected: isDiagnostics, action: onSelectDiagnostics)
                    routeRow(icon: "gearshape", title: "Settings", value: "", selected: isSettings, action: onSelectSettings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text("Projects")
                    Spacer()
                    Text("\(projects.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)

                // CL-P1-012: scroll once project count exceeds the visible
                // 12 slots so long workspaces stay reachable.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                    ForEach(projects) { project in
                        Button {
                            onSelectProject(project.name)
                        } label: {
                            HStack(spacing: 8) {
                                Text(project.name)
                                    .font(.system(size: 13, weight: selectedProject(project.name) ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer()
                                Text(tokenbarTokens(project.summary.totalTokens))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.faint)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selectedProject(project.name)
                                          ? Color(nsColor: .controlAccentColor).opacity(0.18)
                                          : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedProject(project.name) ? TokenBarStyle.foreground : TokenBarStyle.muted)
                    }
                    }
                }
                .frame(maxHeight: 360)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(TokenBarStyle.statusColor(for: refreshState))
                    .frame(width: 6, height: 6)
                    .shadow(color: TokenBarStyle.statusColor(for: refreshState).opacity(0.55), radius: 5)
                Text("v0.1.0")
                    .font(.system(size: 10.5, design: .monospaced))
                Spacer()
                Text(tokenbarRelativeTime(lastIndexedAt))
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(TokenBarStyle.faint)
            .padding(16)
        }
        // CL-P0-008: sidebar uses the standard SwiftUI .bar material with a
        // Reduce Transparency fallback (see TokenBarSidebarBackground).
        .background(TokenBarSidebarBackground())
    }

    private var isOverview: Bool {
        activeRoute == .today
    }

    private var isDiagnostics: Bool {
        activeRoute == .diagnostics
    }

    private var isSettings: Bool {
        activeRoute == .settings
    }

    private func selectedProject(_ name: String) -> Bool {
        if case .project(let projectName) = activeRoute {
            return projectName == name
        }
        return false
    }

    private func routeRow(icon: String, title: String, value: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? TokenBarStyle.input : TokenBarStyle.muted)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.warn)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(TokenBarStyle.warn.opacity(0.10), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected
                          ? Color(nsColor: .controlAccentColor).opacity(0.18)
                          : Color.clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TokenBarStyle.line, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
    }
}

private struct OverviewPage: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Binding var selectedRange: String
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    /// CL-P0-012: which KPI (Total / Input / Output / Cache) is currently
    /// expanded into a detail drawer. `nil` = collapsed.
    @State private var expandedKPI: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            pageHeader
            // CL-P0-027: when no events and no custom sources, the user has
            // pointed TokenBar at nothing — show onboarding instead of empty
            // KPI/chart cards that look like data is broken.
            if showOnboarding {
                OnboardingCard(onOpenSettings: { runtimeModel.mainRoute = .settings })
            } else {
                kpiRow
                if let expandedKPI {
                    TokenBarKPIDetailDrawer(
                        title: expandedKPI,
                        today: kpiToday(expandedKPI),
                        yesterday: kpiYesterday(expandedKPI),
                        sevenDayAverage: kpiSevenDayAverage(expandedKPI),
                        cost: expandedKPI == "Total" ? todayCost : nil,
                        onClose: { withAnimation(.easeOut(duration: 0.18)) { self.expandedKPI = nil } }
                    )
                }
                hourlyCard
                RangeBarsCard(
                    days: rangeDays,
                    title: rangeTitle,
                    subtitle: tokenbarRangeAvailabilityNote(selection: selectedRange, availableDays: runtimeModel.snapshot.last30Days.count)
                )
                HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                    RankingCard(
                        title: "Top projects",
                        footnote: "\(min(runtimeModel.snapshot.topProjects.count, 5)) of \(runtimeModel.snapshot.topProjects.count)",
                        rows: tokenbarRankingRows(
                            rows: runtimeModel.snapshot.topProjects,
                            events: runtimeModel.events,
                            kind: .project,
                            days: tokenbarDaysForRange(selectedRange)
                        ),
                        onSelect: { runtimeModel.openProject(named: $0) }
                    )
                    RankingCard(
                        title: "Top agents",
                        footnote: "\(runtimeModel.snapshot.topAgents.count) active",
                        rows: tokenbarRankingRows(
                            rows: runtimeModel.snapshot.topAgents,
                            events: runtimeModel.events,
                            kind: .agent,
                            days: tokenbarDaysForRange(selectedRange)
                        ),
                        onSelect: nil
                    )
                }
                ModelBreakdownTable(
                    title: "Model",
                    subtitle: "Share of tokens · \(tokenbarRangeTitle(selectedRange).lowercased())",
                    totalCost: tokenbarCompactCurrency(rangeCost),
                    rows: tokenbarModelBreakdowns(
                        events: runtimeModel.events,
                        days: tokenbarDaysForRange(selectedRange)
                    )
                )
            }
        }
    }

    private var showOnboarding: Bool {
        runtimeModel.events.isEmpty && runtimeModel.customSources.isEmpty
    }

    private var pageHeader: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("\(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · visible numbers are from the local TokenBar index")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            Spacer()
            TopRightCluster(
                todayCost: todayCost,
                rangeCost: rangeCost,
                todayTokens: runtimeModel.snapshot.today.totalTokens,
                totalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                todaySessions: tokenbarSessionCount(runtimeModel.events),
                refreshState: runtimeModel.refreshState,
                onRefresh: { Task { await runtimeModel.refresh() } }
            )
            .layoutPriority(2)
            DateRangeControl(selection: $selectedRange)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var todayCost: Double {
        tokenbarEstimatedCost(events: runtimeModel.events, days: 1)
    }

    private var rangeCost: Double {
        tokenbarEstimatedCost(events: runtimeModel.events, days: tokenbarDaysForRange(selectedRange))
    }

    private var kpiRow: some View {
        HStack(spacing: TokenBarStyle.sectionSpacing) {
            kpiCard(title: "Total", value: runtimeModel.snapshot.today.totalTokens, meta: "today", color: TokenBarStyle.muted)
            kpiCard(title: "Input", value: runtimeModel.snapshot.today.inputTokens, meta: inputShare, color: TokenBarStyle.input)
            kpiCard(title: "Output", value: runtimeModel.snapshot.today.outputTokens, meta: outputShare, color: TokenBarStyle.output)
            kpiCard(title: "Cache", value: runtimeModel.snapshot.today.cacheTokens, meta: cacheShare, color: TokenBarStyle.cache)
        }
    }

    private func kpiCard(title: String, value: Int, meta: String, color: Color) -> some View {
        let baseline = kpiSevenDayAverage(title)  // proxy for 30d P50
        let status = TokenBarUsageStatus.compute(today: value, baseline30d: baseline)
        return TokenBarKPI(
            title: title,
            value: tokenbarTokens(value),
            meta: meta,
            color: color,
            onTap: {
                withAnimation(.easeOut(duration: 0.18)) {
                    expandedKPI = (expandedKPI == title) ? nil : title
                }
            },
            isExpanded: expandedKPI == title,
            preciseValue: value,
            status: status
        )
    }

    private func kpiToday(_ title: String) -> Int {
        switch title {
        case "Input":  return runtimeModel.snapshot.today.inputTokens
        case "Output": return runtimeModel.snapshot.today.outputTokens
        case "Cache":  return runtimeModel.snapshot.today.cacheTokens
        default:       return runtimeModel.snapshot.today.totalTokens
        }
    }

    private func kpiYesterday(_ title: String) -> Int {
        guard runtimeModel.snapshot.last30Days.count >= 2 else { return 0 }
        let yesterday = runtimeModel.snapshot.last30Days[runtimeModel.snapshot.last30Days.count - 2]
        switch title {
        case "Input":  return yesterday.summary.inputTokens
        case "Output": return yesterday.summary.outputTokens
        case "Cache":  return yesterday.summary.cacheTokens
        default:       return yesterday.summary.totalTokens
        }
    }

    private func kpiSevenDayAverage(_ title: String) -> Int {
        let window = Array(runtimeModel.snapshot.last30Days.suffix(7))
        guard !window.isEmpty else { return 0 }
        let total: Int
        switch title {
        case "Input":  total = window.reduce(0) { $0 + $1.summary.inputTokens }
        case "Output": total = window.reduce(0) { $0 + $1.summary.outputTokens }
        case "Cache":  total = window.reduce(0) { $0 + $1.summary.cacheTokens }
        default:       total = window.reduce(0) { $0 + $1.summary.totalTokens }
        }
        return total / window.count
    }

    private var hourlyCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("By hour, today")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("24 buckets · local timezone")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("peak \(tokenbarTokens(hourly.peakHourOfDay?.summary.totalTokens ?? 0))")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.cache)
                        Text(hourlyIdleText)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(TokenBarStyle.faint)
                    }
                }
                HourlyHeatmapView(hours: hourly.hoursOfDay)
            }
        }
    }

    private var hourly: HourlyUsageSnapshot {
        UsageAggregator.makeHourlySnapshot(from: runtimeModel.events, referenceDate: Date(), days: 1)
    }

    private var hourlyIdleText: String {
        if hourly.peakHourOfDay == nil {
            return "no activity"
        }
        return tokenbarIdleHourRanges(hourly.hoursOfDay)
    }

    private var rangeDays: [UsageDay] {
        tokenbarRangeDays(runtimeModel.snapshot.last30Days, selection: selectedRange)
    }

    private var rangeTitle: String {
        tokenbarRangeTitle(selectedRange)
    }

    private var inputShare: String { shareText(runtimeModel.snapshot.today.inputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var outputShare: String { shareText(runtimeModel.snapshot.today.outputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var cacheShare: String { shareText(runtimeModel.snapshot.today.cacheTokens, total: runtimeModel.snapshot.today.totalTokens) }

    private func shareText(_ value: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))%"
    }
}

struct TopRightCluster: View {
    let todayCost: Double
    let rangeCost: Double
    let todayTokens: Int
    let totalTokens: Int
    let todaySessions: Int
    let refreshState: RefreshState
    let onRefresh: (() -> Void)?

    @AppStorage("tokenbar.menuBarMirrorMode") private var mirrorModeRaw = MenuBarMirrorMode.off.rawValue
    @AppStorage("tokenbar.menuBarPaused") private var isPaused = false
    @State private var showFlyout = false

    private func copyCostSummary() {
        let line = "Today ~ \(tokenbarCompactCurrency(todayCost)) · 30d ~ \(tokenbarCompactCurrency(rangeCost)) · \(tokenbarCompactTokens(totalTokens)) tokens"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Today ~")
                        .foregroundStyle(TokenBarStyle.muted)
                    Text(tokenbarCompactCurrency(todayCost))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Divider().frame(height: 15).overlay(TokenBarStyle.line)
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.cache)
                    Text("30d ~")
                        .foregroundStyle(TokenBarStyle.muted)
                    Text(tokenbarCompactCurrency(rangeCost))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .foregroundStyle(TokenBarStyle.faint)
                    Text(tokenbarCompactTokens(totalTokens))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TokenBarStyle.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
            // CL-P2-006: clicking the cost capsule copies a human-readable
            // string to the pasteboard and shows a brief toast tooltip.
            .contentShape(Capsule())
            .onTapGesture { copyCostSummary() }
            .help("Click to copy today / 30d cost summary")

            Button {
                showFlyout.toggle()
            } label: {
                HStack(spacing: 7) {
                    TokenBarStatusGlyph(state: refreshState, paused: isPaused)
                    if mirrorMode != .off {
                        Text(menuValue)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Circle()
                        .fill(isPaused ? TokenBarStyle.warn : TokenBarStyle.statusColor(for: refreshState))
                        .frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(TokenBarStyle.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
            .help("Menu bar mirrors \(mirrorMode.title.lowercased()).")
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $showFlyout, arrowEdge: .bottom) {
                menuFlyout
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var mirrorMode: MenuBarMirrorMode {
        MenuBarMirrorMode(rawValue: mirrorModeRaw) ?? .off
    }

    private var menuValue: String {
        tokenbarMirrorValue(
            mode: mirrorMode,
            todayTokens: todayTokens,
            todayCost: todayCost,
            todaySessions: todaySessions
        )
    }

    private var menuFlyout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar mirrors")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Circle()
                    .fill(isPaused ? TokenBarStyle.warn : TokenBarStyle.statusColor(for: refreshState))
                    .frame(width: 6, height: 6)
                Text(menuValue.isEmpty ? "hidden" : menuValue)
                    .font(.system(size: 12.5, design: .monospaced))
                Spacer()
                Text("updated now")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
            }
            .padding(9)
            .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            flyoutButton("Force refresh", systemImage: "arrow.clockwise", trailing: "⌘R") {
                onRefresh?()
            }
            flyoutButton(isPaused ? "Resume tracking" : "Pause tracking", systemImage: isPaused ? "play" : "pause", trailing: isPaused ? "paused" : "tracking") {
                isPaused.toggle()
            }
            flyoutButton("Reopen popover", systemImage: "menubar.rectangle", trailing: "click status item") {
                showFlyout = false
            }

            Text("Show in menu bar")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
                .padding(.top, 2)

            HStack(spacing: 5) {
                ForEach(MenuBarMirrorMode.allCases) { mode in
                    Button {
                        mirrorModeRaw = mode.rawValue
                    } label: {
                        VStack(spacing: 2) {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: .medium))
                            Text(tokenbarMirrorValue(mode: mode, todayTokens: todayTokens, todayCost: todayCost, todaySessions: todaySessions).isEmpty ? "—" : tokenbarMirrorValue(mode: mode, todayTokens: todayTokens, todayCost: todayCost, todaySessions: todaySessions))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(mirrorMode == mode ? TokenBarStyle.foreground.opacity(0.75) : TokenBarStyle.faint)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(mirrorMode == mode ? TokenBarStyle.input.opacity(0.22) : TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit TokenBar")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(TokenBarStyle.error)
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 310)
        .background(TokenBarGlassBackground())
    }

    private func flyoutButton(_ title: String, systemImage: String, trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                Text(title)
                Spacer()
                Text(trailing)
                    .foregroundStyle(TokenBarStyle.faint)
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(TokenBarStyle.foreground)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct RankingCard: View {
    let title: String
    let footnote: String
    let rows: [TokenBarRankingRow]
    let onSelect: ((String) -> Void)?

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.faint)
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { index, row in
                        Button {
                            onSelect?(row.name)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(rankColor(index))
                                    .frame(width: 22, height: 22)
                                    .background(rankColor(index).opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    // CL-P0-015: real per-row attribution
                                    // (top agents for project rows, top
                                    // projects for agent rows) replaces the
                                    // old hard-coded "local indexed usage".
                                    Text(row.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(tokenbarCompactTokens(row.totalTokens))
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(TokenBarStyle.foreground)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                        .tbNumberTooltip(precise: row.totalTokens, window: row.name)
                                    Text(tokenbarCompactCurrency(row.cost))
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(TokenBarStyle.cost)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                        .tbNumberTooltip(precise: row.cost, window: row.name)
                                }
                                .frame(width: 92, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(onSelect != nil)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.6)), alignment: .bottom)
                    }
                    if rows.isEmpty {
                        Text("No local rows yet.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // CL-P1-009: positions 4+ use quaternaryLabelColor so the badge fades
    // back rather than reusing the (token-coded) line color and confusing
    // viewers about meaning.
    private func rankColor(_ index: Int) -> Color {
        switch index {
        case 0: TokenBarStyle.accent
        case 1: TokenBarStyle.output
        case 2: TokenBarStyle.cache
        case 3: Color(nsColor: .systemPurple)
        default: Color(nsColor: .quaternaryLabelColor)
        }
    }
}

/// CL-P0-027: shown on Overview when no events and no custom sources exist.
/// Tapping the button routes the user to Settings where they can add a source.
private struct OnboardingCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        TokenBarCard(padding: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.accent)
                    Text("Welcome — point TokenBar at your first source")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                Text("TokenBar reads usage events from local data sources only. Nothing leaves this Mac. Add a source to begin indexing.")
                    .font(.callout)
                    .foregroundStyle(TokenBarStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
