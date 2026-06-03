import AppKit
import SwiftUI
import TokenBarCore

/// Source drill-in (design §03b · source-detail.jsx). Mirrors the Project
/// detail page but scopes everything to one **source** (agent display name):
/// KPIs, range bars, a Project Share donut, recent sessions tagged with the
/// model, and the per-model mix table. All numbers come from real indexed
/// events for the source — no fixtures.
struct SourceDetailView: View {
    let sourceName: String
    let events: [UsageEvent]
    let allTimeSummary: UsageSummary
    let allTimeCost: Double
    @Binding var selectedRange: String
    let refreshState: RefreshState
    let onRefresh: (() -> Void)?
    let onBack: () -> Void
    let onSelectProject: (String) -> Void

    @State private var metrics = SourceDetailRangeMetrics.empty
    @State private var isRangeLoading = false
    @State private var expandedSession: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LazyVStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                header
                kpiRow
                RangeBarsCard(
                    days: metrics.days,
                    title: tokenbarRangeTitle(selectedRange),
                    subtitle: metrics.availabilityNote,
                    summary: metrics.rangeSummary
                )
                HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                    ShareDonutCard(
                        title: "Project Share",
                        slices: metrics.projectShare,
                        onSelect: onSelectProject
                    )
                    SourceModelSessionsCard(
                        sessions: metrics.recentSessions,
                        expandedSession: $expandedSession
                    )
                }
                ModelBreakdownTable(
                    title: "Model",
                    subtitle: "Models used by \(sourceName).",
                    totalCost: tokenbarCompactCurrency(metrics.rangeCost),
                    rows: metrics.modelRows
                )
            }
            if isRangeLoading {
                TokenBarPageUpdatingOverlay(label: "updating \(tokenbarRangeShortLabel(selectedRange))")
            }
        }
        .animation(.easeOut(duration: 0.14), value: isRangeLoading)
        .task(id: metricsTaskID) {
            await rebuildMetrics()
        }
        .onChange(of: selectedRange) { _, _ in
            withAnimation(.easeOut(duration: 0.12)) { isRangeLoading = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoverableDetailBackButton(action: onBack)
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Source")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(TokenBarStyle.faint)
                        .textCase(.uppercase)
                    Text(sourceName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(metrics.modelLine.isEmpty ? "No model attribution yet" : metrics.modelLine)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    TopRightCluster(
                        todayCost: metrics.todayCost,
                        rangeCost: metrics.rangeCost,
                        todayTokens: metrics.todaySummary.totalTokens,
                        totalTokens: metrics.rangeSummary.totalTokens,
                        todaySessions: metrics.todaySessionCount,
                        refreshState: refreshState,
                        onRefresh: onRefresh,
                        rangeLabel: tokenbarRangeShortLabel(selectedRange)
                    )
                    DateRangeControl(selection: $selectedRange)
                    HStack(spacing: 34) {
                        statBlock(label: "Est. cost", value: tokenbarCompactCurrency(allTimeCost), color: TokenBarStyle.cost)
                        statBlock(label: "All-time total", value: tokenbarCompactTokens(allTimeSummary.totalTokens), color: TokenBarStyle.foreground)
                    }
                }
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: TokenBarStyle.sectionSpacing) {
            TokenBarKPI(title: "Total", value: tokenbarTokens(metrics.rangeSummary.totalTokens), meta: tokenbarRangeShortLabel(selectedRange), color: TokenBarStyle.muted)
            TokenBarKPI(title: "Input", value: tokenbarTokens(metrics.rangeSummary.inputTokens), meta: "source input", color: TokenBarStyle.input)
            TokenBarKPI(title: "Output", value: tokenbarTokens(metrics.rangeSummary.outputTokens), meta: "source output", color: TokenBarStyle.output)
            TokenBarKPI(title: "Cache", value: tokenbarTokens(metrics.rangeSummary.cacheTokens), meta: "source cache", color: TokenBarStyle.cache)
        }
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(TokenBarStyle.muted)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private var metricsTaskID: String {
        "\(sourceName)|\(selectedRange)|\(events.count)|\(events.last?.id ?? "none")"
    }

    @MainActor
    private func rebuildMetrics() async {
        let sourceName = sourceName
        let selection = selectedRange
        let events = events
        guard !events.isEmpty else {
            metrics = .empty
            isRangeLoading = false
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            SourceDetailRangeMetrics.make(sourceName: sourceName, events: events, selection: selection)
        }.value
        guard !Task.isCancelled, self.selectedRange == selection else { return }
        metrics = computed
        withAnimation(.easeOut(duration: 0.14)) { isRangeLoading = false }
    }
}

// MARK: - Metrics

struct SourceDetailRangeMetrics: Sendable, Hashable {
    let days: [UsageDay]
    let availabilityNote: String
    let modelLine: String
    let rangeSummary: UsageSummary
    let todaySummary: UsageSummary
    let rangeCost: Double
    let todayCost: Double
    let todaySessionCount: Int
    let modelRows: [TokenBarModelBreakdown]
    let projectShare: [AgentShareSlice]
    let recentSessions: [DetailSessionSummary]

    static let empty = SourceDetailRangeMetrics(
        days: [],
        availabilityNote: "Preparing range",
        modelLine: "",
        rangeSummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        todaySummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        rangeCost: 0,
        todayCost: 0,
        todaySessionCount: 0,
        modelRows: [],
        projectShare: [],
        recentSessions: []
    )

    static func make(
        sourceName: String,
        events: [UsageEvent],
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SourceDetailRangeMetrics {
        // `events` are already scoped to this source (built-in agent or named
        // custom source) by the caller, so no further agent filter here.
        let sourceEvents = events
        let rangeEvents = tokenbarRangeEvents(events: sourceEvents, selection: selection, referenceDate: referenceDate, calendar: calendar)
        let todayEvents = tokenbarEventsInLastDays(events: sourceEvents, referenceDate: referenceDate, calendar: calendar)
        let days = tokenbarUsageDays(events: sourceEvents, selection: selection, referenceDate: referenceDate, calendar: calendar)
        let modelRows = tokenbarModelBreakdowns(events: rangeEvents, days: nil, referenceDate: referenceDate, calendar: calendar)
        return SourceDetailRangeMetrics(
            days: days,
            availabilityNote: tokenbarRangeAvailabilityNote(selection: selection, days: days, events: sourceEvents, referenceDate: referenceDate, calendar: calendar),
            modelLine: modelRows.prefix(2).map(\.name).joined(separator: " · "),
            rangeSummary: tokenbarSummary(rangeEvents),
            todaySummary: tokenbarSummary(todayEvents),
            rangeCost: tokenbarEstimatedCost(events: rangeEvents),
            todayCost: tokenbarEstimatedCost(events: todayEvents),
            todaySessionCount: tokenbarSessionCount(sourceEvents, referenceDate: referenceDate),
            modelRows: modelRows,
            projectShare: tokenbarProjectShare(events: rangeEvents),
            recentSessions: DetailSessionSummary.make(events: rangeEvents, tag: .model, limit: 6)
        )
    }
}
